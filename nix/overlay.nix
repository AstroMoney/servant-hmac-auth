{ }:
final: prev:
let
  compiler = "ghc8107";
in
{
  servant-hmac-auth = {
    haskellPkgs = prev.haskell.packages.${compiler}.override(old: {
      overrides = prev.lib.composeExtensions (old.overrides or (_:_:{})) (self: super: {
        servant-hmac-auth = (self.callCabal2nix "servant-hmac-auth" ../. rec {});
      });
    });
  };
}