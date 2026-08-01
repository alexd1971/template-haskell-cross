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
  haskellModulesLib = pkgs.haskell.lib.compose;

  mkHaskellPackageSet =
    { ghc
    , compilerConfigFile
    , baseHaskellPkgs
    , overrides
    }:
    pkgs.callPackage (pkgs.path + "/pkgs/development/haskell-modules") {
      haskellLib = haskellModulesLib;
      buildHaskellPackages = baseHaskellPkgs;
      inherit ghc overrides;
      compilerConfig =
        pkgs.callPackage
          (pkgs.path + "/pkgs/development/haskell-modules/${compilerConfigFile}")
          {
            haskellLib = haskellModulesLib;
          };
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
      baseHaskellPkgs = pkgs.haskell.packages.${profile.packageSetName};

      patchedGhc =
        compiler.overrideAttrs (old: {
          patches = (old.patches or []) ++ profile.workerPatches;
        });

      targetHaskellPkgs = baseHaskellPkgs.override {
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
          };
      };

      hostHaskellPkgs =
        mkHaskellPackageSet {
          ghc = patchedGhc;
          inherit baseHaskellPkgs;
          inherit (profile) compilerConfigFile;
          overrides = selfH: superH: {
            # The worker only needs the shared protocol package from this
            # patched-GHC package set. The plugin is built separately in
            # `targetHaskellPkgs`, where it is loaded by the target compiler.
            th-cross-protocol =
              pkgs.callPackage ../th-cross-protocol.nix {
                callPackage = selfH.callPackage;
                inherit haskellLib;
                hostGhc = patchedGhc;
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
        baseHaskellPkgs.callPackage ../th-cross-nix-tools.nix { };
    in
    {
      inherit patchedGhc hostHaskellPkgs targetGhcWithPlugin nixTools;

      inherit (profile) version packageSetName;

      hostWorker = hostHaskellPkgs.th-host-worker;
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
in
{
  inherit
    compilerProfiles
    mkCompilerForVersion
    compilers
    ;
}
