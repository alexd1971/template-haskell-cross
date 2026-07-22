{ self, nixpkgs }:

let
  # Keep the top-level flake small: this module wires together package sets,
  # reusable helpers, experiments, apps, checks, and dev shells.
  systems = [
    "x86_64-linux"
  ];

  forAllSystems = f:
    nixpkgs.lib.genAttrs systems (system:
      f (import nixpkgs { inherit system; }));

  testFixturesDir = ../../prototype/th-cross-plugin/test/fixtures;
in
{
  packages = forAllSystems (pkgs:
    let
      # `hs` contains the host-side and consumer-side Haskell package sets.
      # `thCrossLib` contains experiment helpers that are independent from one
      # specific GHC version.
      hs = import ./haskell-pkgs.nix { inherit pkgs; };
      thCrossLib = import ./lib.nix { inherit pkgs testFixturesDir; };

      # Each file under `experiments/` owns one investigation branch. Adding a
      # new experiment should usually mean adding one file there and merging
      # its exported `packages` here.
      aarch64LinuxCrossProbe = import ./experiments/aarch64-linux-cross-probe.nix {
        inherit pkgs;
      };
      crossGhc9103Aarch64 = import ./cross-ghc/ghc9103-aarch64.nix {
        inherit pkgs;
      };
      consumerGhc9103Cross = import ./experiments/consumer-ghc9103-cross.nix {
        inherit pkgs hs thCrossLib crossGhc9103Aarch64;
      };
      consumerGhc948Cross = import ./experiments/consumer-ghc948-cross.nix {
        inherit pkgs hs testFixturesDir;
      };
    in
    {
      host-ghc984-worker = hs.hostHaskellPkgs.th-host-worker;
      host-ghc984-plugin = hs.hostHaskellPkgs.th-cross-plugin;
      consumer-ghc9103-plugin = hs.consumerGhc9103HaskellPkgs.th-cross-plugin;
      consumer-ghc948-plugin = hs.consumerGhc948HaskellPkgs.th-cross-plugin;
      consumer-ghc9103-ghc = hs.consumerGhc9103;
      consumer-ghc948-ghc = hs.consumerGhc948;
      consumer-ghc9103-package = hs.consumerGhc9103HaskellPkgs.th-consumer-example;
      aarch64-linux-cross-probe = aarch64LinuxCrossProbe;
      default = hs.hostHaskellPkgs.th-host-worker;
    }
    # Experiment packages are merged after the base packages so their public
    # attribute names stay local to the experiment module.
    // consumerGhc9103Cross.packages
    // consumerGhc948Cross.packages);

  apps = forAllSystems (pkgs:
    import ./apps.nix { inherit pkgs; });

  checks = forAllSystems (pkgs:
    let
      hs = import ./haskell-pkgs.nix { inherit pkgs; };
      packages = self.packages.${pkgs.stdenv.hostPlatform.system};
      aarch64LinuxCrossProbe = import ./experiments/aarch64-linux-cross-probe.nix {
        inherit pkgs;
      };
    in
    import ./checks.nix {
      inherit pkgs hs packages testFixturesDir aarch64LinuxCrossProbe;
    });

  devShells = forAllSystems (pkgs:
    let
      hs = import ./haskell-pkgs.nix { inherit pkgs; };
    in
    {
      default = import ./dev-shell.nix { inherit pkgs hs; };
    });
}
