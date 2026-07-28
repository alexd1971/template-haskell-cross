{
  description = "TH cross target-context example";

  inputs = {
    th-cross.url = "path:../..";
  };

  outputs = { th-cross, ... }:
    let
      system = "x86_64-linux";
      thCross = th-cross.lib.${system}.ghc9103Aarch64Linux;
    in
    {
      packages.${system}.default =
        thCross.callPackageWithWorker ./nix/generated/th-target-context-consumer.nix;
    };
}
