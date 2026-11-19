# Compiles test/smoke.c against the archive with the same static toolchain,
# runs it, and checks that the program links nothing but the OS.
{
  lib,
  stdenv,
  file,
  duckdb,
}:
let
  args = [ "v${duckdb.version}" ] ++ lib.mapAttrsToList (n: e: "${n}=${e.version}") duckdb.extensions;
in
stdenv.mkDerivation {
  name = "duckdb-static-smoke-${duckdb.version}";
  dontUnpack = true;
  nativeBuildInputs = [ file ];
  buildPhase = ''
    $CC -O1 -I${duckdb}/include -c ${./smoke.c} -o smoke.o
    # The C++ driver, for the C++ runtime DuckDB needs; on macOS also the
    # system frameworks curl and the TLS code use (proxies, trust store).
    $CXX smoke.o ${duckdb}/lib/libduckdb_static.a -o smoke ${lib.escapeShellArgs duckdb.linkFlags}
    ./smoke ${lib.escapeShellArgs args}
    file smoke
    ${
      if stdenv.hostPlatform.isLinux then
        ''
          file smoke | grep -q 'statically linked' || { echo "smoke is not statically linked" >&2; exit 1; }
        ''
      else
        ''
          /usr/bin/otool -L smoke | tail -n +2 | awk '{print $1}' | while read -r lib; do
            case "$lib" in
              /usr/lib/*|/System/Library/*) ;;
              *) echo "smoke links $lib, which is not part of macOS" >&2; exit 1 ;;
            esac
          done
        ''
    }
    touch "$out"
  '';
  dontInstall = true;
}
