{ thCrossLib }:

# Keep flake checks on the same production path external consumers use:
# `mkCrossFor` plus `buildPackage`. Broader version/target/example matrices are
# run manually because cold cross-GHC builds can take hours.
let
  defaultCross = thCrossLib.mkCrossFor {
    ghcVersion = "9.10.3";
    target = "aarch64-linux";
  };
in
{
  ghc9103-aarch64-linux-target-context =
    defaultCross.buildPackage ../../examples/target-context/nix/generated/th-target-context-consumer.nix;
}
