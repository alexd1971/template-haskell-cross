{
  description = "TH cross dependency splice example";

  inputs = {
    th-cross.url = "path:../..";
  };

  outputs = { th-cross, ... }:
    let
      system = "x86_64-linux";
      ghcVersion =
        let value = builtins.getEnv "TH_CROSS_GHC_VERSION";
        in if value == "" then "9.10.3" else value;
      target =
        let value = builtins.getEnv "TH_CROSS_TARGET";
        in if value == "" then "aarch64-linux" else value;
      thCross = th-cross.lib.${system}.mkCrossFor { inherit ghcVersion target; };
      dependencyPackage =
        thCross.buildPackage ./dependency/nix/generated/th-splice-dependency.nix;
    in
    {
      packages.${system} = {
        "th-splice-dependency" = dependencyPackage;
        default =
          thCross.buildPackageWith ./consumer/nix/generated/th-dependency-consumer.nix {
            "th-splice-dependency" = dependencyPackage;
          };
      };
    };
}
