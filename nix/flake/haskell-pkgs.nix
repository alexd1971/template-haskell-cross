{ pkgs }:

let
  # This file contains only Haskell package-set wiring. Cross-GHC experiments
  # live under `experiments/`.

  # Native host-side package set. The worker must run on the build host and
  # currently targets GHC 9.8.4 because the first prototype is tied to that GHC
  # API.
  hostHaskellPkgs = pkgs.haskell.packages.ghc984.override {
    overrides = selfH: superH: {
      th-cross-plugin =
        pkgs.callPackage ../th-cross-plugin.nix {
          callPackage = selfH.callPackage;
          haskellLib = pkgs.haskell.lib;
        };
      th-host-worker =
        pkgs.callPackage ../th-host-worker.nix {
          callPackage = selfH.callPackage;
          haskellLib = pkgs.haskell.lib;
          hostGhcLibDir = "${pkgs.haskell.compiler.ghc984}/lib/ghc-9.8.4/lib";
          th-cross-plugin = selfH.th-cross-plugin;
        };
    };
  };

  # Consumer-side package set. This is still native x86_64-linux in the current
  # flake, but it models the side that will eventually become a cross target
  # package set.
  consumerGhc9103HaskellPkgs = pkgs.haskell.packages.ghc9103.override {
    overrides = selfH: superH: {
      th-cross-plugin =
        pkgs.callPackage ../th-cross-plugin.nix {
          callPackage = selfH.callPackage;
          haskellLib = pkgs.haskell.lib;
        };
      th-consumer-example =
        selfH.callPackage ../generated/th-consumer-example.nix { };
    };
  };

  nixTools = pkgs.haskell.packages.ghc9103.callPackage ../th-cross-nix-tools.nix { };
in
{
  inherit hostHaskellPkgs consumerGhc9103HaskellPkgs nixTools;

  consumerGhc9103 = consumerGhc9103HaskellPkgs.ghcWithPackages (hpkgs: [
    hpkgs.th-cross-plugin
  ]);
}
