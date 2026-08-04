# @path: derivations/zcode/flake.nix
# @author: redskaber
# @datetime: 2026-08-04
# @description: Production-ready flake for ZCode (auto-updated sources).
# Supports x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin.
# @directory: https://nix.dev/manual/nix/2.33/command-ref/new-cli/nix3-flake.html

{
  description = "Nix Flake for ZCode (auto-updated sources, 4 platforms)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      allowUnfree = system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      sources = import ./sources.nix;
    in {
      packages = forAllSystems (system:
        let pkgs = allowUnfree system;
        in {
          default = pkgs.callPackage ./package.nix {
            inherit pkgs system sources;
          };
        });

      apps = forAllSystems (system:
        let pkgs = allowUnfree system;
        in {
          update-sources = {
            type = "app";
            program = "${pkgs.writeShellScript "update-sources" ''
              exec ${./update.sh}
            ''}";
          };
        });
    };
}
