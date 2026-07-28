{
  description = "Template Haskell cross-compilation app scaffold";

  inputs = {
    # Replace this with your th-cross source, for example:
    # th-cross.url = "github:your-org/th-cross";
    th-cross.url = "path:/path/to/th-cross";
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
