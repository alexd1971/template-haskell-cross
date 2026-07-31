{ pkgs }:

let
  # This module returns the project-local compiler registry consumed by
  # `th-cross-lib.nix` as `compilerSets`. Each compiler entry bundles the
  # patched native worker compiler, host worker package set, target plugin
  # package set, and Nix helper tools for one supported GHC profile.
  #
  # This file contains only Haskell package-set wiring. Each supported compiler
  # version is described by an explicit profile in `ghc-profiles.nix`.
  compilerProfiles = import ./ghc-profiles.nix;

  mkHaskellPackageSet =
    { ghc
    , compilerConfig
    , buildHaskellPackages ? pkgs.haskell.packages.ghc9103
    , overrides
    }:
    pkgs.callPackage (pkgs.path + "/pkgs/development/haskell-modules") {
      haskellLib = pkgs.haskell.lib.compose;
      inherit buildHaskellPackages;
      inherit ghc compilerConfig overrides;
    };

  mkCompilerConfig = compilerConfigFile:
    pkgs.callPackage
      (pkgs.path + "/pkgs/development/haskell-modules/${compilerConfigFile}")
      {
        haskellLib = pkgs.haskell.lib.compose;
      };

  jailbreakHaskellLib =
    pkgs.haskell.lib // {
      overrideCabal = drv: f:
        pkgs.haskell.lib.doJailbreak (pkgs.haskell.lib.overrideCabal drv f);
    };

  mkCompilerFromProfile = profile:
    let
      haskellLib =
        if profile.jailbreak then jailbreakHaskellLib else pkgs.haskell.lib;

      compiler = pkgs.haskell.compiler.${profile.packageSetName};
      buildHaskellPackages = pkgs.haskell.packages.${profile.packageSetName};
      compilerConfig = mkCompilerConfig profile.compilerConfigFile;

      patchedGhc =
        compiler.overrideAttrs (old: {
          patches = (old.patches or []) ++ profile.workerPatches;
        });

      targetHaskellPkgs = buildHaskellPackages.override {
        overrides = selfH: superH:
          {
            th-cross-protocol =
              pkgs.callPackage ../th-cross-protocol.nix {
                callPackage = selfH.callPackage;
                inherit haskellLib;
                hostGhc = selfH.ghc;
              };
            th-cross-plugin =
              pkgs.callPackage ../th-cross-plugin.nix {
                callPackage = selfH.callPackage;
                inherit haskellLib;
                hostGhc = selfH.ghc;
              };
          }
          // pkgs.lib.optionalAttrs profile.includeTargetContextConsumer {
            th-target-context-consumer =
              selfH.callPackage ../../examples/target-context/nix/generated/th-target-context-consumer.nix { };
          };
      };

      hostHaskellPkgs =
        mkHaskellPackageSet {
          ghc = patchedGhc;
          inherit compilerConfig buildHaskellPackages;
          overrides = selfH: superH: {
            # Shared protocol package used by both worker and plugin. The public
            # target-side plugin remains `targetHaskellPkgs.th-cross-plugin`.
            th-cross-protocol =
              pkgs.callPackage ../th-cross-protocol.nix {
                callPackage = selfH.callPackage;
                inherit haskellLib;
                hostGhc = patchedGhc;
              };
            th-cross-plugin =
              pkgs.callPackage ../th-cross-plugin.nix {
                callPackage = selfH.callPackage;
                inherit haskellLib;
                hostGhc = selfH.ghc;
              };
            th-host-worker =
              pkgs.callPackage ../th-host-worker.nix {
                callPackage = selfH.callPackage;
                inherit haskellLib;
                hostGhc = patchedGhc;
                hostGhcLibDir = "${patchedGhc}/lib/ghc-${patchedGhc.version}/lib";
              };
          };
        };

      targetGhcWithPlugin = targetHaskellPkgs.ghcWithPackages (hpkgs: [
        hpkgs.th-cross-plugin
      ]);

      nixTools =
        buildHaskellPackages.callPackage ../th-cross-nix-tools.nix { };
    in
    {
      inherit patchedGhc hostHaskellPkgs targetHaskellPkgs targetGhcWithPlugin nixTools;

      inherit (profile) version packageSetName compilerConfigFile workerPatches crossPatches;

      hostWorker = hostHaskellPkgs.th-host-worker;
      targetProtocol = targetHaskellPkgs.th-cross-protocol;
      targetPlugin = targetHaskellPkgs.th-cross-plugin;
    };

  compilerProfileForVersion = version:
    let
      matches =
        pkgs.lib.filterAttrs (_name: profile: profile.version == version) compilerProfiles;
      names = builtins.attrNames matches;
    in
    if names == []
    then throw "Unsupported GHC version ${version}; add a profile in nix/flake/ghc-profiles.nix"
    else matches.${builtins.head names};

  mkCompilerForVersion = version:
    mkCompilerFromProfile (compilerProfileForVersion version);

  compilers = pkgs.lib.mapAttrs (_name: mkCompilerFromProfile) compilerProfiles;

  nixTools = compilers.ghc9103.nixTools;
in
{
  inherit
    compilerProfiles
    mkCompilerFromProfile
    mkCompilerForVersion
    compilers
    nixTools
    ;

  patchedNativeGhc9103 = compilers.ghc9103.patchedGhc;
  hostGhc9103HaskellPkgs = compilers.ghc9103.hostHaskellPkgs;
  targetGhc9103HaskellPkgs = compilers.ghc9103.targetHaskellPkgs;
  targetGhc9103WithPlugin = compilers.ghc9103.targetGhcWithPlugin;
}
