{ self, nixpkgs }:

let
  # Keep the top-level flake small: this module wires together package sets,
  # reusable helpers, experiments, apps, checks, and dev shells.
  systems = [
    "x86_64-linux"
    "aarch64-darwin"
  ];

  forAllSystems = f:
    nixpkgs.lib.genAttrs systems (system:
      f (import nixpkgs { inherit system; }));

  testFixturesDir = ../../plugin/test/fixtures;
in
{
  packages = forAllSystems (pkgs:
    let
      # Project-local compiler registry: supported GHC profiles plus the
      # derived patched/native/target package sets. This is not nixpkgs'
      # generic `haskellPackages`.
      compilerSets = import ./haskell-pkgs.nix { inherit pkgs; };

      crossGhc9103Aarch64 = import ./mk-cross-ghc.nix {
        profile = compilerSets.compilerProfiles.ghc9103;
        crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
        bootPkgs = pkgs.haskell.packages.ghc9103;
        targetName = "aarch64-linux";
        targetTriple = "aarch64-unknown-linux-gnu";
      };
    in
    {
      patched-ghc9103 = compilerSets.patchedNativeGhc9103;
      host-ghc9103-worker = compilerSets.hostGhc9103HaskellPkgs.th-host-worker;
      target-ghc9103-protocol = compilerSets.targetGhc9103HaskellPkgs.th-cross-protocol;
      target-ghc9103-plugin = compilerSets.targetGhc9103HaskellPkgs.th-cross-plugin;
      target-ghc9103-with-plugin = compilerSets.targetGhc9103WithPlugin;
      cross-ghc9103-aarch64-linux = crossGhc9103Aarch64;
      target-ghc9103-target-context-package = compilerSets.targetGhc9103HaskellPkgs.th-target-context-consumer;
      th-cross-nix-tools = compilerSets.nixTools;
      default = compilerSets.hostGhc9103HaskellPkgs.th-host-worker;
    });

  apps = forAllSystems (pkgs:
    import ./apps.nix { inherit pkgs; });

  checks = forAllSystems (pkgs:
    let
      compilerSets = import ./haskell-pkgs.nix { inherit pkgs; };
      packages = self.packages.${pkgs.stdenv.hostPlatform.system};
    in
    import ./checks.nix {
      inherit pkgs compilerSets packages testFixturesDir;
    });

  lib = forAllSystems (pkgs:
    let
      compilerSets = import ./haskell-pkgs.nix { inherit pkgs; };
    in
    (import ./th-cross-lib.nix {
      inherit pkgs compilerSets;
    })
    // {
      inherit (compilerSets) compilerProfiles mkCompilerFromProfile mkCompilerForVersion compilers;
    });

  devShells = forAllSystems (pkgs:
    let
      compilerSets = import ./haskell-pkgs.nix { inherit pkgs; };
    in
    {
      default = import ./dev-shell.nix {
        inherit pkgs compilerSets;
      };
    });

  templates = {
    cross-app = {
      path = ../../templates/cross-app;
      description = "Template Haskell cross-compilation app scaffold";
    };

    default = self.templates.cross-app;
  };
}
