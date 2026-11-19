{
  description = "DuckDB as one static archive with extensions compiled in, built with Nix and cached";

  # The binary cache: signed NARs on this repository's `nix-cache` release.
  # Nix only uses a flake's cache for trusted users, or when it is also listed
  # in the system configuration (see README.md).
  nixConfig = {
    extra-substituters = [
      "https://github.com/akshatagarwl/duckdb-static/releases/download/nix-cache"
    ];
    extra-trusted-public-keys = [
      "duckdb-static.github.akshatagarwl-1:1yQ0flJ3vpCoIicGqSTO8gHezxiCOj2M0VLyJXXqQVQ="
    ];
  };

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      # Built and cached by CI. nixpkgs no longer supports x86_64-darwin.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        # Static (musl on Linux) with the default extension set; this is what
        # the cache holds. Consumers that want cache hits must use this
        # flake's nixpkgs (`inputs.nixpkgs.follows = "duckdb-static/nixpkgs"`).
        duckdb = pkgs.pkgsStatic.callPackage ./package.nix { };
        default = duckdb;
      });

      checks = forAllSystems (pkgs: {
        smoke = pkgs.pkgsStatic.callPackage ./test/smoke.nix {
          duckdb = self.packages.${pkgs.stdenv.hostPlatform.system}.duckdb;
        };
      });

      # For other extension sets or another package set (not cached):
      #   pkgs.pkgsStatic.callPackage duckdb-static.lib.package { inTreeExtensions = [ ... ]; }
      lib.package = ./package.nix;

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
