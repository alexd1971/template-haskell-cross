{
  description = "Template Haskell cross-compilation app scaffold";

  inputs = {
    th-cross.url = "github:alexd1971/template-haskell-cross";
  };

  outputs = { th-cross, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f:
        builtins.listToAttrs
          (map
            (system: {
              name = system;
              value = f system;
            })
            systems);
      ghcVersion = "9.10.3";
      target = "aarch64-linux";
    in
    {
      packages = forAllSystems (system:
        let
          thCross = th-cross.lib.${system}.mkCrossFor { inherit ghcVersion target; };
        in
        {
          default =
            thCross.buildPackage ./nix/generated/cross-app.nix;
        });
    };
}
