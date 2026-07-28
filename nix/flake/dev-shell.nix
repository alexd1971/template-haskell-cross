{ pkgs, hs }:

let
  ghc9103Wrapper = pkgs.writeShellScriptBin "ghc-9.10.3" ''
    exec ${hs.targetGhc9103WithPlugin}/bin/ghc "$@"
  '';

  ghc9103PkgWrapper = pkgs.writeShellScriptBin "ghc-9.10.3-pkg" ''
    exec ${hs.targetGhc9103WithPlugin}/bin/ghc-pkg "$@"
  '';

  thCrossBuild = pkgs.writeShellScriptBin "th-cross-build" ''
    set -euo pipefail

    if [ "$#" -eq 0 ]; then
      set -- th-cross-plugin
    elif [ "$1" = "all" ] || [ "$1" = "th-host-worker" ]; then
      echo "th-host-worker requires patched GHC; use: nix build .#host-ghc9103-worker" >&2
      exit 2
    fi

    exec cabal \
      --store-dir "$PWD/.cabal-store-nix" \
      build \
      --project-dir . \
      --builddir dist-newstyle-nix \
      --with-compiler ghc-9.10.3 \
      --with-hc-pkg ghc-9.10.3-pkg \
      "$@"
  '';

  thCrossTest = pkgs.writeShellScriptBin "th-cross-test" ''
    set -euo pipefail

    if [ "$#" -eq 0 ]; then
      set -- th-cross-plugin:integration --test-show-details=direct
    elif [ "$1" = "-p" ]; then
      if [ "$#" -ne 2 ]; then
        echo "usage: th-cross-test [-p TEST_PATTERN]" >&2
        exit 2
      fi
      pattern="$2"
      set -- th-cross-plugin:integration --test-show-details=direct --test-option=-p --test-option="$pattern"
    elif [[ "$1" == --test-* ]]; then
      set -- th-cross-plugin:integration --test-show-details=direct "$@"
    fi

    worker="$(nix build --no-link --print-out-paths .#host-ghc9103-worker)"
    export TH_HOST_WORKER="$worker/bin/th-host-worker"

    exec cabal \
      --store-dir "$PWD/.cabal-store-nix" \
      test \
      --project-dir . \
      --builddir dist-newstyle-nix \
      --with-compiler ghc-9.10.3 \
      --with-hc-pkg ghc-9.10.3-pkg \
      "$@"
  '';

in
# Development environment for local Cabal iteration. Cross-GHC experiments are
# intentionally Nix packages, because they depend on exact compiler derivations.
pkgs.mkShell {
  packages = [
    pkgs.cabal-install
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
  ghc-9.10.3      raw TH plugin/test compiler

Helpers:
  th-cross-build     cabal build th-cross-plugin and dependencies with isolated Nix Cabal store
  th-cross-test      cabal test th-cross-plugin:integration
  th-cross-test -p   run matching integration tests

Environment:
  raw TH tests use the wrapped patched GHC 9.10 worker

Nix checks:
  nix flake check -L

Maintenance:
  nix run .#regen-cabal-nix
EOF
  '';
}
