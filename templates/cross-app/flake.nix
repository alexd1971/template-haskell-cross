{
  description = "Template Haskell cross-compilation app scaffold";

  inputs = {
    th-cross.url = "github:alexd1971/template-haskell-cross";
  };

  outputs = { th-cross, ... }:
    let
      system = "x86_64-linux";
      thCross = th-cross.lib.${system}.ghc9103Aarch64Linux;
    in
    {
      packages.${system}.default =
        thCross.callPackageWithWorker ./nix/generated/cross-app.nix;
    };
}
