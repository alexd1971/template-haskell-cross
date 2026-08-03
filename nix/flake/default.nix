{ self, nixpkgs }:

let
  nixpkgsLib = nixpkgs.lib;

  # Keep the top-level flake small: this module only wires reusable package
  # sets, public helpers, maintenance apps, checks, dev shells, and templates.
  buildSystems = [
    "x86_64-linux"
    "aarch64-darwin"
  ];
  importNixpkgs = buildSystem:
    import nixpkgs {
      system = buildSystem;
      # Android cross toolchains in nixpkgs depend on SDK/NDK artifacts whose
      # source archives are marked unfree. Consumers cannot override this from
      # outside because target profiles are built from this package set.
      config.allowUnfree = true;
    };

  # Local equivalent of flake-utils' `eachSystem`.
  #
  # `mkOutputs` receives a nixpkgs package set for one build system and returns
  # normal flake sections, for example:
  #
  #   { packages = ...; checks = ...; lib = ...; }
  #
  # The flake schema wants those sections grouped the other way around:
  #
  #   { packages.x86_64-linux = ...; checks.x86_64-linux = ...; }
  #
  # So this helper evaluates `mkOutputs` once per build system and transposes
  # the result into the schema shape expected by Nix.
  forEachBuildSystem = mkOutputs:
    nixpkgsLib.foldl' nixpkgsLib.recursiveUpdate { }
      (map
        (buildSystem:
          nixpkgsLib.mapAttrs
            (_: sectionOutputs: { ${buildSystem} = sectionOutputs; })
            (mkOutputs (importNixpkgs buildSystem)))
        buildSystems);

in
  forEachBuildSystem (pkgs:
    let
      # Project-local compiler registry. This is not nixpkgs' generic
      # `haskellPackages`; it bundles supported GHC profiles, patched worker
      # compilers, target plugin packages, and Nix helper tools.
      compilerSets = import ./haskell-pkgs.nix { inherit pkgs; };
      thCrossLib = import ./th-cross-lib.nix {
        inherit pkgs compilerSets;
      };
    in
    {
      apps = import ./apps.nix { inherit pkgs; };

      checks = import ./checks.nix {
        inherit thCrossLib;
      };

      lib = thCrossLib;

      devShells = {
        default = import ./dev-shell.nix {
          inherit pkgs compilerSets;
        };
      };
    })
  // {
    templates = {
      cross-app = {
        path = ../../templates/cross-app;
        description = "Template Haskell cross-compilation app scaffold";
      };

      default = self.templates.cross-app;
    };
  }
