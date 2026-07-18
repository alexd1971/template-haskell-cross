{
  description = "Template Haskell cross-compilation prototype";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
      ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f (import nixpkgs { inherit system; }));

      mkHaskellPkgs = pkgs:
        let
          # Native host-side package set. The worker must run on the build host
          # and currently targets GHC 9.8.4 because the first prototype is tied
          # to that GHC API.
          hostHaskellPkgs = pkgs.haskell.packages.ghc984.override {
            overrides = selfH: superH: {
              th-cross-plugin =
                pkgs.callPackage ./nix/th-cross-plugin.nix {
                  callPackage = selfH.callPackage;
                  haskellLib = pkgs.haskell.lib;
                };
              th-host-worker =
                pkgs.callPackage ./nix/th-host-worker.nix {
                  callPackage = selfH.callPackage;
                  haskellLib = pkgs.haskell.lib;
                  hostGhcLibDir = "${pkgs.haskell.compiler.ghc984}/lib/ghc-9.8.4/lib";
                  th-cross-plugin = selfH.th-cross-plugin;
                };
            };
          };

          # Consumer-side package set. This is still native x86_64-linux in the
          # current flake, but it models the side that will eventually become a
          # cross target package set.
          consumerHaskellPkgs = pkgs.haskell.packages.ghc9103.override {
            overrides = selfH: superH: {
              th-cross-plugin =
                pkgs.callPackage ./nix/th-cross-plugin.nix {
                  callPackage = selfH.callPackage;
                  haskellLib = pkgs.haskell.lib;
                };
              th-consumer-example =
                pkgs.callPackage ./nix/th-consumer-example.nix {
                  callPackage = selfH.callPackage;
                  haskellLib = pkgs.haskell.lib;
                  th-cross-plugin = selfH.th-cross-plugin;
                  th-host-worker = hostHaskellPkgs.th-host-worker;
                };
            };
          };
        in
        {
          inherit hostHaskellPkgs consumerHaskellPkgs;
          consumerGhc = consumerHaskellPkgs.ghcWithPackages (hpkgs: [
            hpkgs.th-cross-plugin
          ]);
        };
    in
    {
      packages = forAllSystems (pkgs:
        let
          hs = mkHaskellPkgs pkgs;
        in
        {
          th-host-worker = hs.hostHaskellPkgs.th-host-worker;
          th-cross-plugin-ghc984 = hs.hostHaskellPkgs.th-cross-plugin;
          th-cross-plugin-ghc9103 = hs.consumerHaskellPkgs.th-cross-plugin;
          consumer-ghc9103 = hs.consumerGhc;
          th-consumer-example = hs.consumerHaskellPkgs.th-consumer-example;

          default = hs.hostHaskellPkgs.th-host-worker;
        });

      apps = forAllSystems (pkgs: {
        regen-cabal-nix =
          let
            updateScript = pkgs.writeShellScriptBin "th-cross-regen-cabal-nix" ''
              set -euo pipefail

              repo_root="$PWD"
              mkdir -p "$repo_root/nix/generated"

              ${pkgs.cabal2nix}/bin/cabal2nix "$repo_root/prototype/th-cross-plugin" \
                > "$repo_root/nix/generated/th-cross-plugin.nix"

              ${pkgs.cabal2nix}/bin/cabal2nix "$repo_root/prototype/th-host-worker" \
                > "$repo_root/nix/generated/th-host-worker.nix"

              ${pkgs.cabal2nix}/bin/cabal2nix "$repo_root/prototype/th-consumer-example" \
                > "$repo_root/nix/generated/th-consumer-example.nix"
            '';
          in
          {
            type = "app";
            program = "${updateScript}/bin/th-cross-regen-cabal-nix";
            meta.description = "Regenerate checked-in Cabal-derived Nix expressions";
          };
      });

      checks = forAllSystems (pkgs:
        let
          hs = mkHaskellPkgs pkgs;
          packages = self.packages.${pkgs.stdenv.hostPlatform.system};
        in
        {
          cross-version-plugin = pkgs.runCommand
            "th-cross-cross-version-plugin-check"
            {
              nativeBuildInputs = [
                pkgs.haskell.compiler.ghc984
              ];
            }
            ''
              build_dir="$TMPDIR/consumer-build"
              mkdir -p "$build_dir"

              ${hs.consumerGhc}/bin/ghc \
                -v0 \
                -fno-code \
                -fforce-recomp \
                -i${./prototype/th-cross-plugin/test/fixtures} \
                -outputdir "$build_dir" \
                -hidir "$build_dir" \
                -odir "$build_dir" \
                -stubdir "$build_dir" \
                -fplugin=THCross.Plugin \
                -fplugin-opt=THCross.Plugin:worker=${packages.th-host-worker}/bin/th-host-worker \
                ${./prototype/th-cross-plugin/test/fixtures/Example.hs}

              touch "$out"
            '';

          consumer-package = hs.consumerHaskellPkgs.th-consumer-example;
        });

      devShells = forAllSystems (pkgs: {
        default =
          let
            hs = mkHaskellPkgs pkgs;
            ghc984Wrapper = pkgs.writeShellScriptBin "ghc-9.8.4" ''
              exec ${pkgs.haskell.compiler.ghc984}/bin/ghc "$@"
            '';

            ghc984PkgWrapper = pkgs.writeShellScriptBin "ghc-9.8.4-pkg" ''
              exec ${pkgs.haskell.compiler.ghc984}/bin/ghc-pkg "$@"
            '';

            ghc9103Wrapper = pkgs.writeShellScriptBin "ghc-9.10.3" ''
              exec ${hs.consumerGhc}/bin/ghc "$@"
            '';

            ghc9103PkgWrapper = pkgs.writeShellScriptBin "ghc-9.10.3-pkg" ''
              exec ${hs.consumerGhc}/bin/ghc-pkg "$@"
            '';

            thCrossBuild = pkgs.writeShellScriptBin "th-cross-build" ''
              set -euo pipefail

              if [ "$#" -eq 0 ]; then
                set -- all
              fi

              exec cabal \
                --store-dir "$PWD/.cabal-store-nix" \
                build \
                --project-dir prototype \
                --builddir dist-newstyle-nix \
                --with-compiler ghc-9.8.4 \
                --with-hc-pkg ghc-9.8.4-pkg \
                "$@"
            '';

            thCrossTest = pkgs.writeShellScriptBin "th-cross-test" ''
              set -euo pipefail

              if [ "$#" -eq 0 ]; then
                set -- th-cross-plugin:integration
              fi

              exec cabal \
                --store-dir "$PWD/.cabal-store-nix" \
                test \
                --project-dir prototype \
                --builddir dist-newstyle-nix \
                --with-compiler ghc-9.8.4 \
                --with-hc-pkg ghc-9.8.4-pkg \
                "$@"
            '';
          in
          pkgs.mkShell {
            packages = [
              pkgs.cabal-install
              ghc984Wrapper
              ghc984PkgWrapper
              ghc9103Wrapper
              ghc9103PkgWrapper
              thCrossBuild
              thCrossTest
              pkgs.gmp
              pkgs.zlib
            ];

            shellHook = ''
              export LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.gmp pkgs.zlib ]}:''${LIBRARY_PATH:-}"
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.gmp pkgs.zlib ]}:''${LD_LIBRARY_PATH:-}"
              export NIX_LDFLAGS="-L${pkgs.gmp}/lib -L${pkgs.zlib}/lib ''${NIX_LDFLAGS:-}"

              cat <<'EOF'
TH cross dev shell

Compilers:
  ghc-9.8.4       host worker / normal prototype build
  ghc-9.10.3      consumer-side plugin compatibility checks

Helpers:
  th-cross-build  cabal build all with isolated Nix Cabal store
  th-cross-test   cabal test th-cross-plugin:integration

Nix checks:
  nix flake check -L

Maintenance:
  nix run .#regen-cabal-nix
EOF
            '';
          };
      });
    };
}
