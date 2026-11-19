# DuckDB built from source as one self-contained static archive, with
# extensions compiled in and their C dependencies folded into the archive.
#
# Called with nixpkgs' static package set (`pkgsStatic`): musl on Linux, so a
# program linking this archive can be fully static; static libraries on macOS.
#
# Every pin comes from sources.json (scripts/update.sh writes it): the DuckDB
# release, and the exact commits that release pins for each out-of-tree
# extension in its own .github/config/extensions/<name>.cmake. The build fails
# if the two disagree.
#
# Output:
#   lib/libduckdb_static.a  DuckDB, the extensions, a generated
#                           `duckdb_register_static_extensions()`, and CRoaring,
#                           OpenSSL, curl, libpq and zlib.
#   include/duckdb.h, include/duckdb_static_extension.h
# Link it and the C++ runtime; call duckdb_register_static_extensions() before
# opening a database. Nothing is ever downloaded or loaded from a file.
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  python3,
  croaring,
  openssl,
  curlMinimal,
  libpq,
  tzdata,
  zlib,
  removeReferencesTo,
  sources ? lib.importJSON ./sources.json,
  # In-tree extensions to link, before the out-of-tree ones from sources.json.
  inTreeExtensions ? [
    "core_functions"
    "parquet"
    "json"
    "icu"
  ],
}:
let
  inherit (sources.duckdb) version;

  # OpenSSL looks for its config and CA directory in OPENSSLDIR, which nixpkgs
  # points into the store. Programs built with this archive run outside Nix, so
  # use the conventional /etc/ssl (macOS has it too).
  openssl' = openssl.overrideAttrs (old: {
    configureFlags = map (
      flag: if lib.hasPrefix "--openssldir=" flag then "--openssldir=/etc/ssl" else flag
    ) old.configureFlags;
    installFlags = (old.installFlags or [ ]) ++ [ "OPENSSLDIR=${placeholder "etc"}/etc/ssl" ];
  });
  # libcurl with OpenSSL and nothing else, as httpfs and quack ask for.
  curl' = curlMinimal.override {
    openssl = openssl';
    scpSupport = false;
    http2Support = false;
  };
  libpq' = libpq.override (
    {
      openssl = openssl';
    }
    // lib.optionalAttrs stdenv.hostPlatform.isDarwin {
      # libpq only records tzdata's path. The static darwin tzdata fails one of
      # its own self-tests (now.ck); its data is what matters here.
      tzdata = tzdata.overrideAttrs { doCheck = false; };
    }
  );

  fetch =
    src:
    fetchFromGitHub {
      owner = src.owner or "duckdb";
      inherit (src) repo rev hash;
    };

  extensions = lib.mapAttrs (
    name: ext:
    ext
    // {
      src = fetch ext;
      # DuckDB's convention for an extension built from a commit.
      version = lib.substring 0 10 ext.rev;
      submodules = lib.mapAttrs (_: fetch) (ext.submodules or { });
    }
  ) sources.extensions;

  linked = inTreeExtensions ++ lib.attrNames extensions;

  extensionConfig = builtins.toFile "extensions.cmake" (
    lib.concatStrings (
      map (name: "duckdb_extension_load(${name})\n") inTreeExtensions
      ++ lib.mapAttrsToList (name: ext: ''
        duckdb_extension_load(${name}
            SOURCE_DIR @${name}@
            EXTENSION_VERSION ${ext.version}
        )
      '') extensions
    )
  );

  depArchives = [
    "${croaring}/lib/libroaring.a"
    "${lib.getDev libpq'}/lib/libpq.a"
    "${lib.getDev libpq'}/lib/libpgcommon.a"
    "${lib.getDev libpq'}/lib/libpgport.a"
    "${lib.getLib curl'}/lib/libcurl.a"
    "${lib.getLib openssl'}/lib/libssl.a"
    "${lib.getLib openssl'}/lib/libcrypto.a"
    "${lib.getLib zlib}/lib/libz.a"
  ];
in
stdenv.mkDerivation {
  pname = "duckdb-static";
  inherit version;

  src = fetch {
    repo = "duckdb";
    inherit (sources.duckdb) rev hash;
  };

  nativeBuildInputs = [
    cmake
    ninja
    python3
    removeReferencesTo
  ];
  buildInputs = [
    croaring
    openssl'
    curl'
    libpq'
    zlib
  ];

  postUnpack = lib.concatStrings (
    lib.mapAttrsToList (
      name: ext:
      ''
        cp -r ${ext.src} ext-${name}
        chmod -R u+w ext-${name}
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (path: src: ''
          rm -rf ext-${name}/${path}
          cp -r ${src} ext-${name}/${path}
          chmod -R u+w ext-${name}/${path}
        '') ext.submodules
      )
    ) extensions
  );

  preConfigure = ''
    # The extension commits must be the ones this DuckDB release pins.
    ${lib.concatStrings (
      lib.mapAttrsToList (name: ext: ''
        grep -q 'GIT_TAG ${ext.rev}' .github/config/extensions/${name}.cmake || {
          echo "duckdb-static: sources.json pins ${name} at ${ext.rev}, DuckDB v${version} does not:" >&2
          grep GIT_TAG .github/config/extensions/${name}.cmake >&2
          exit 1
        }
      '') extensions
    )}
    substitute ${extensionConfig} extensions.cmake ${
      lib.concatStrings (
        lib.mapAttrsToList (name: _: "--subst-var-by ${name} $NIX_BUILD_TOP/ext-${name} ") extensions
      )
    }
  '';

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DDUCKDB_EXTENSION_CONFIGS=extensions.cmake"
    "-DSTATICALLY_LINK_EXTENSIONS=${lib.concatStringsSep ";" linked}"
    "-DBUILD_SHELL=OFF"
    "-DBUILD_UNITTESTS=OFF"
    "-DBUILD_SHARED_LIBS=OFF"
    "-DENABLE_EXTENSION_AUTOLOADING=OFF"
    "-DENABLE_EXTENSION_AUTOINSTALL=OFF"
    # There is no .git: state the version DuckDB reports.
    "-DOVERRIDE_GIT_DESCRIBE=v${version}"
    "-DGIT_COMMIT_HASH=${sources.duckdb.rev}"
  ];

  # Only the static targets: `all` also builds every extension as a loadable
  # shared object, which a static toolchain cannot link and nothing here uses.
  ninjaFlags = [ "duckdb_static" ] ++ map (e: "${e}_extension") linked;

  postBuild = ''
    # DuckDB's own loader template: one call registers every linked extension.
    python3 ../scripts/generate_static_extension_loader.py -o static_extension_loader.c ${lib.concatStringsSep " " linked}
    $CC -O2 -c -I../src/include -DDUCKDB_STATIC_EXTENSION_LOADER_API= \
      static_extension_loader.c -o static_extension_loader.o
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib" "$out/include"
    archives=$(find "$PWD" -name '*.a' ! -path '*/_deps/*' | LC_ALL=C sort)
    # An MRI script keeps every member of every archive, even ones with the
    # same name. The toolchain's ar is GNU ar on Linux and llvm-ar on macOS;
    # both read MRI scripts.
    $AR rcD loader.a static_extension_loader.o
    {
      echo "create $out/lib/libduckdb_static.a"
      for a in "$PWD/loader.a" $archives ${toString depArchives}; do echo "addlib $a"; done
      echo save
      echo end
    } | $AR -M
    $RANLIB "$out/lib/libduckdb_static.a"
    cp ../src/include/duckdb.h ../src/include/duckdb_static_extension.h "$out/include/"
    runHook postInstall
  '';

  # The archive carries everything it needs, so the output must reference
  # nothing: drop the propagated inputs, and scrub the store paths compilers
  # leave in object files (dead outside Nix). `allowedReferences` enforces it.
  # Found with a byte-level scan rather than grep, whose handling of a 250 MB
  # binary depends on the platform's grep and locale.
  postFixup = ''
    rm -rf "$out/nix-support"
    refs=$(python3 ${./scripts/store-refs.py} "$out/lib/libduckdb_static.a" "$NIX_STORE")
    for ref in $refs; do
      echo "scrubbing $ref"
      remove-references-to -t "$ref" "$out/lib/libduckdb_static.a"
    done
  '';
  allowedReferences = [ ];

  passthru = {
    inherit linked extensions sources;
  };

  meta = {
    description = "DuckDB as one static archive with extensions compiled in";
    homepage = "https://github.com/akshatagarwl/duckdb-static";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
