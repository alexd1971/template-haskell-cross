{ pkgs, hs }:

let
  # The shell uses wrapper names that match the GHC versions we discuss in docs
  # and tests, while delegating to the exact Nix-provided compiler derivations.
  ghc984Wrapper = pkgs.writeShellScriptBin "ghc-9.8.4" ''
    exec ${pkgs.haskell.compiler.ghc984}/bin/ghc "$@"
  '';

  ghc984PkgWrapper = pkgs.writeShellScriptBin "ghc-9.8.4-pkg" ''
    exec ${pkgs.haskell.compiler.ghc984}/bin/ghc-pkg "$@"
  '';

  ghc984DefaultPkgWrapper = pkgs.writeShellScriptBin "ghc-pkg" ''
    exec ${pkgs.haskell.compiler.ghc984}/bin/ghc-pkg "$@"
  '';

  ghc9103Wrapper = pkgs.writeShellScriptBin "ghc-9.10.3" ''
    exec ${hs.consumerGhc9103}/bin/ghc "$@"
  '';

  ghc9103PkgWrapper = pkgs.writeShellScriptBin "ghc-9.10.3-pkg" ''
    exec ${hs.consumerGhc9103}/bin/ghc-pkg "$@"
  '';

  ghc948Wrapper = pkgs.writeShellScriptBin "ghc-9.4.8" ''
    exec ${hs.consumerGhc948}/bin/ghc "$@"
  '';

  ghc948PkgWrapper = pkgs.writeShellScriptBin "ghc-9.4.8-pkg" ''
    exec ${hs.consumerGhc948}/bin/ghc-pkg "$@"
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
      set -- th-cross-plugin:integration --test-show-details=direct
    fi

    cabal_before=(
      --store-dir "$PWD/.cabal-store-nix"
    )

    cabal_after=(
      --project-dir prototype
      --builddir dist-newstyle-nix
      --with-compiler ghc-9.8.4
      --with-hc-pkg ghc-9.8.4-pkg
    )

    cabal "''${cabal_before[@]}" build "''${cabal_after[@]}" th-host-worker
    export TH_HOST_WORKER
    TH_HOST_WORKER="$(cabal "''${cabal_before[@]}" list-bin "''${cabal_after[@]}" th-host-worker)"

    exec cabal \
      "''${cabal_before[@]}" \
      test \
      "''${cabal_after[@]}" \
      "$@"
  '';
in
# Development environment for local Cabal iteration. Cross-GHC experiments are
# intentionally Nix packages, because they depend on exact compiler derivations.
pkgs.mkShell {
  packages = [
    pkgs.cabal-install
    ghc984Wrapper
    ghc984PkgWrapper
    ghc984DefaultPkgWrapper
    ghc948Wrapper
    ghc948PkgWrapper
    ghc9103Wrapper
    ghc9103PkgWrapper
    thCrossBuild
    thCrossTest
    pkgs.gmp
    pkgs.zlib
  ];

  shellHook = ''
    export TH_HOST_GHC_LIBDIR="${pkgs.haskell.compiler.ghc984}/lib/ghc-9.8.4/lib"
    export LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.gmp pkgs.zlib ]}:''${LIBRARY_PATH:-}"
    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.gmp pkgs.zlib ]}:''${LD_LIBRARY_PATH:-}"
    export NIX_LDFLAGS="-L${pkgs.gmp}/lib -L${pkgs.zlib}/lib ''${NIX_LDFLAGS:-}"

    cat <<'EOF'
TH cross dev shell

Compilers:
  ghc-9.8.4       host worker / normal prototype build
  ghc-9.4.8       consumer-side plugin compatibility checks
  ghc-9.10.3      consumer-side plugin compatibility checks

Helpers:
  th-cross-build  cabal build all with isolated Nix Cabal store
  th-cross-test   cabal test th-cross-plugin:integration

Environment:
  TH_HOST_GHC_LIBDIR points at Nix GHC 9.8.4 for the host worker

Nix checks:
  nix flake check -L

Maintenance:
  nix run .#regen-cabal-nix
EOF
  '';
}
