{
  description = "TH cross microlens example";

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
    in
    {
      packages.${system} = {
        default =
          thCross.buildPackage ./nix/generated/th-microlens-consumer.nix;

        cabal-context-probe =
          thCross.checkCabalContext ./nix/generated/th-microlens-consumer.nix;
      };
    };
}
