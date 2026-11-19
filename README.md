# duckdb-static

[DuckDB](https://duckdb.org) as **one static archive with its extensions
compiled in**, built from source with Nix, kept current automatically, and
served from its own binary cache.

Link `libduckdb_static.a` and you get DuckDB plus `core_functions`, `parquet`,
`json`, `icu`, `ducklake`, `httpfs`, `postgres_scanner` and `quack`, with their
C dependencies (CRoaring, OpenSSL, curl, libpq, zlib) inside the same archive.
A program built with it never downloads or `dlopen`s an extension, so it can be
a single static binary that runs anywhere, offline. On Linux the archive is
built for musl, so the program can be fully static.

| | |
|---|---|
| Systems | `x86_64-linux`, `aarch64-linux` (musl), `aarch64-darwin` |
| Output | `lib/libduckdb_static.a`, `include/duckdb.h`, `include/duckdb_static_extension.h` |
| Pins | `sources.json`: the DuckDB release, and the extension commits that release pins |
| Cache | `https://github.com/akshatagarwl/duckdb-static/releases/download/nix-cache` |

## Use it

```nix
{
  inputs = {
    duckdb-static.url = "github:akshatagarwl/duckdb-static";
    # Use the same nixpkgs, so the archive is a cache hit and your program is
    # built with the same (static) toolchain and C++ runtime.
    nixpkgs.follows = "duckdb-static/nixpkgs";
  };

  outputs = { duckdb-static, ... }: {
    # duckdb-static.packages.${system}.default
  };
}
```

From C, register the extensions once, before opening a database:

```c
#include "duckdb.h"
int32_t duckdb_register_static_extensions(void);

duckdb_register_static_extensions();
duckdb_open(NULL, &db);   /* LOAD ducklake; LOAD httpfs; ... all work offline */
```

Link with the C++ driver of the same toolchain (for the C++ runtime), e.g.
`$CXX main.o libduckdb_static.a`. From Rust, point
[`libduckdb-sys`](https://crates.io/crates/libduckdb-sys) at it with
`DUCKDB_STATIC=1 DUCKDB_LIB_DIR=<out>/lib DUCKDB_INCLUDE_DIR=<out>/include`.

For another extension set (not cached):
`pkgs.pkgsStatic.callPackage duckdb-static.lib.package { inTreeExtensions = [ ... ]; }`.

## The binary cache

Each build on `main` is signed and published as assets of the
[`nix-cache` release](https://github.com/akshatagarwl/duckdb-static/releases/tag/nix-cache),
which Nix reads like any HTTP binary cache. The flake declares it in
`nixConfig`, but Nix only honours that for trusted users. To use it everywhere,
add it to the system configuration. On NixOS:

```nix
nix.settings = {
  extra-substituters = [ "https://github.com/akshatagarwl/duckdb-static/releases/download/nix-cache" ];
  extra-trusted-public-keys = [ "duckdb-static.github.akshatagarwl-1:1yQ0flJ3vpCoIicGqSTO8gHezxiCOj2M0VLyJXXqQVQ=" ];
};
```

Elsewhere, the same two lines in `/etc/nix/nix.conf`. In GitHub Actions, pass
them as `extra_nix_config` to `cachix/install-nix-action`.

## How it stays current

`update.yml` runs daily. When DuckDB publishes a release, `scripts/update.sh`
rewrites `sources.json` from the release itself (the extension commits come
from its `.github/config/extensions/*.cmake`). On Mondays nixpkgs is updated
too. The change is built and smoke-tested natively on all three systems and
published to the cache, and only then fast-forwarded onto `main`, with a
`duckdb-v<version>` tag on each new DuckDB release. A failed build leaves
`main` untouched.

`test/smoke.c` links the archive, registers the extensions, checks each one is
statically linked at the pinned version, and uses them (a DuckLake table,
Parquet, JSON, ICU time zones, the httpfs, postgres and quack catalogs), with
autoloading and autoinstall compiled out. It also checks that the program
links nothing but the operating system.

## Licence

The packaging is MIT ([LICENSE](LICENSE)). DuckDB and its extensions are MIT;
the bundled libraries keep their own licences (OpenSSL: Apache-2.0, curl: curl,
libpq: PostgreSQL, CRoaring: Apache-2.0/MIT, zlib: zlib).
