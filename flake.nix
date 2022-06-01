{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/master";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }: {} // (flake-utils.lib.eachSystem [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" ] (system:
  

    let
      overlay = import ./nix/overlay.nix { };
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowBroken = true;
          allowUnfree = true;
        };

        overlays = [overlay];
      };
      servant-hmac-auth-lib = pkgs.servant-hmac-auth.haskellPkgs.servant-hmac-auth;
    in
      rec {
        defaultPackage = servant-hmac-auth-lib;
        checks = { };
      }
  ));
}
