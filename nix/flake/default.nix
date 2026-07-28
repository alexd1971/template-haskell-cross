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

  testFixturesDir = ../../plugin/test/fixtures;
in
{
  packages = forAllSystems (pkgs:
    let
      # `hs` contains the host-side and consumer-side Haskell package sets.
      hs = import ./haskell-pkgs.nix { inherit pkgs; };

      crossGhc9103Aarch64 = import ./cross-ghc/ghc9103-aarch64.nix {
        inherit pkgs;
      };
    in
    {
      patched-ghc9103 = hs.patchedNativeGhc9103;
      host-ghc9103-worker = hs.hostGhc9103HaskellPkgs.th-host-worker;
      consumer-ghc9103-protocol = hs.consumerGhc9103HaskellPkgs.th-cross-protocol;
      consumer-ghc9103-plugin = hs.consumerGhc9103HaskellPkgs.th-cross-plugin;
      consumer-ghc9103-ghc = hs.consumerGhc9103;
      cross-ghc9103-aarch64-linux = crossGhc9103Aarch64;
      consumer-ghc9103-target-context-package = hs.consumerGhc9103HaskellPkgs.th-target-context-consumer;
      th-cross-nix-tools = hs.nixTools;
      default = hs.hostGhc9103HaskellPkgs.th-host-worker;
    });

  apps = forAllSystems (pkgs:
    import ./apps.nix { inherit pkgs; });

  checks = forAllSystems (pkgs:
    let
      hs = import ./haskell-pkgs.nix { inherit pkgs; };
      packages = self.packages.${pkgs.stdenv.hostPlatform.system};
    in
    import ./checks.nix {
      inherit pkgs hs packages testFixturesDir;
    });

  lib = forAllSystems (pkgs:
    let
      hs = import ./haskell-pkgs.nix { inherit pkgs; };
      crossGhc9103Aarch64 = import ./cross-ghc/ghc9103-aarch64.nix {
        inherit pkgs;
      };
    in
    import ./th-cross-lib.nix {
      inherit pkgs hs crossGhc9103Aarch64;
    });

  devShells = forAllSystems (pkgs:
    let
      hs = import ./haskell-pkgs.nix { inherit pkgs; };
    in
    {
      default = import ./dev-shell.nix { inherit pkgs hs; };
    });
}
