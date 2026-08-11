{
  description = "kelliher-web — shared web hosting infrastructure for *.kelliher.info";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  # Thin wrapper: the NixOS module lives in ./modules (split by concern and
  # aggregated by ./modules/default.nix); the dev shell in ./devshell.nix.
  # This file only wires inputs → outputs.
  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    {
      nixosModules.default = import ./modules;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = import ./devshell.nix { inherit pkgs; };
      }
    );
}
