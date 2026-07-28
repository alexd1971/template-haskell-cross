{
  description = "TH cross aeson consumer fixture";

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
        thCross.callPackageWithWorker ./nix/generated/th-aeson-consumer.nix;
    };
}
