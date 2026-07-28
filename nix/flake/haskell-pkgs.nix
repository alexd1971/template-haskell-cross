{ pkgs }:

let
  # This file contains only Haskell package-set wiring. Cross-GHC experiments
  # live under `experiments/`.

  mkHaskellPackageSet =
    { ghc
    , compilerConfig
    , overrides
    }:
    pkgs.callPackage (pkgs.path + "/pkgs/development/haskell-modules") {
      haskellLib = pkgs.haskell.lib.compose;
      buildHaskellPackages = pkgs.haskell.packages.ghc9103;
      inherit ghc compilerConfig overrides;
    };

  ghc9103CompilerConfig =
    pkgs.callPackage
      (pkgs.path + "/pkgs/development/haskell-modules/configuration-ghc-9.10.x.nix")
      {
        haskellLib = pkgs.haskell.lib.compose;
      };

  # Native GHC 9.10.3 with the minimal export-list patch needed by the raw
  # Template Haskell AST worker path.
  patchedNativeGhc9103 =
    pkgs.haskell.compiler.ghc9103.overrideAttrs (old: {
      patches = (old.patches or []) ++ [
        ../patches/ghc-9.10.3-export-runth.patch
      ];
    });

  # Consumer-side package set. This is still native x86_64-linux in the current
  # flake, but it models the side that will eventually become a cross target
  # package set.
  consumerGhc9103HaskellPkgs = pkgs.haskell.packages.ghc9103.override {
    overrides = selfH: superH: {
      th-cross-protocol =
        pkgs.callPackage ../th-cross-protocol.nix {
          callPackage = selfH.callPackage;
          haskellLib = pkgs.haskell.lib;
          hostGhc = selfH.ghc;
        };
      th-cross-plugin =
        pkgs.callPackage ../th-cross-plugin.nix {
          callPackage = selfH.callPackage;
          haskellLib = pkgs.haskell.lib;
          hostGhc = selfH.ghc;
        };
      th-target-context-consumer =
        selfH.callPackage ../../consumer/target-context/nix/generated/th-target-context-consumer.nix { };
    };
  };

  hostGhc9103HaskellPkgs =
    mkHaskellPackageSet {
      ghc = patchedNativeGhc9103;
      compilerConfig = ghc9103CompilerConfig;
      overrides = selfH: superH: {
        # Shared protocol package used by both worker and plugin. The public
        # consumer-side plugin remains `consumerGhc9103HaskellPkgs.th-cross-plugin`.
        th-cross-protocol =
          pkgs.callPackage ../th-cross-protocol.nix {
            callPackage = selfH.callPackage;
            haskellLib = pkgs.haskell.lib;
            hostGhc = patchedNativeGhc9103;
          };
        th-cross-plugin =
          pkgs.callPackage ../th-cross-plugin.nix {
            callPackage = selfH.callPackage;
            haskellLib = pkgs.haskell.lib;
            hostGhc = selfH.ghc;
          };
        th-host-worker =
          pkgs.callPackage ../th-host-worker.nix {
            callPackage = selfH.callPackage;
            haskellLib = pkgs.haskell.lib;
            hostGhc = patchedNativeGhc9103;
            hostGhcLibDir = "${patchedNativeGhc9103}/lib/ghc-9.10.3/lib";
          };
      };
    };

  nixTools = pkgs.haskell.packages.ghc9103.callPackage ../th-cross-nix-tools.nix { };
in
{
  inherit patchedNativeGhc9103 hostGhc9103HaskellPkgs consumerGhc9103HaskellPkgs nixTools;

  consumerGhc9103 = consumerGhc9103HaskellPkgs.ghcWithPackages (hpkgs: [
    hpkgs.th-cross-plugin
  ]);
}
