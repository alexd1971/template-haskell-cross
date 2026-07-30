{ pkgs, hs }:

let
  mkGhcWrapperForVersion = version:
    let
      compiler = hs.mkCompilerForVersion version;
    in
    pkgs.writeShellScriptBin "ghc-${version}" ''
      exec ${compiler.targetGhcWithPlugin}/bin/ghc "$@"
    '';

  mkGhcPkgWrapperForVersion = version:
    let
      compiler = hs.mkCompilerForVersion version;
    in
    pkgs.writeShellScriptBin "ghc-${version}-pkg" ''
      exec ${compiler.targetGhcWithPlugin}/bin/ghc-pkg "$@"
    '';

  ghcProfileVersions = map (profile: profile.version) (builtins.attrValues hs.compilerProfiles);

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

    cross_ghc_version="''${TH_CROSS_GHC_VERSION:-}"
    worker_package="''${TH_CROSS_TEST_WORKER_PACKAGE:-host-ghc9103-worker}"
    worker_profile="''${TH_CROSS_TEST_WORKER_PROFILE:-}"

    if [ -n "$cross_ghc_version" ]; then
      compiler_expr="(builtins.getFlake \"path:$PWD\").lib.${pkgs.stdenv.hostPlatform.system}.mkCompilerForVersion \"$cross_ghc_version\""
      worker_expr="($compiler_expr).hostWorker"
      target_ghc_expr="($compiler_expr).targetGhcWithPlugin"
      worker="$(nix build --no-link --print-out-paths --impure --expr "$worker_expr")"
      target_ghc="$(nix build --no-link --print-out-paths --impure --expr "$target_ghc_expr")"
      test_ghc="$target_ghc/bin/ghc"
      test_ghc_pkg="$target_ghc/bin/ghc-pkg"
      store_suffix="ghc-$cross_ghc_version"
    elif [ -n "$worker_profile" ]; then
      worker_expr="(builtins.getFlake \"path:$PWD\").lib.${pkgs.stdenv.hostPlatform.system}.compilers.$worker_profile.hostWorker"
      worker="$(nix build --no-link --print-out-paths --impure --expr "$worker_expr")"
      test_ghc="''${TH_CROSS_TEST_GHC:-ghc-9.10.3}"
      test_ghc_pkg="''${TH_CROSS_TEST_GHC_PKG:-''${test_ghc}-pkg}"
      store_suffix="$(printf '%s' "$test_ghc" | tr -c 'A-Za-z0-9_.-' '_')"
    else
      worker="$(nix build --no-link --print-out-paths ".#$worker_package")"
      test_ghc="''${TH_CROSS_TEST_GHC:-ghc-9.10.3}"
      test_ghc_pkg="''${TH_CROSS_TEST_GHC_PKG:-''${test_ghc}-pkg}"
      store_suffix="$(printf '%s' "$test_ghc" | tr -c 'A-Za-z0-9_.-' '_')"
    fi

    store_dir="''${TH_CROSS_TEST_STORE_DIR:-$PWD/.cabal-store-nix-$store_suffix}"
    build_dir="''${TH_CROSS_TEST_BUILDDIR:-dist-newstyle-nix-$store_suffix}"

    export TH_HOST_WORKER="$worker/bin/th-host-worker"
    export TH_CROSS_TEST_GHC="$test_ghc"

    exec cabal \
      --store-dir "$store_dir" \
      test \
      --project-dir . \
      --builddir "$build_dir" \
      --with-compiler "$test_ghc" \
      --with-hc-pkg "$test_ghc_pkg" \
      "$@"
  '';

in
# Development environment for local Cabal iteration. Cross-GHC experiments are
# intentionally Nix packages, because they depend on exact compiler derivations.
pkgs.mkShell {
  packages = [
    pkgs.cabal-install
    thCrossBuild
    thCrossTest
    pkgs.gmp
    pkgs.zlib
  ]
  ++ map mkGhcWrapperForVersion ghcProfileVersions
  ++ map mkGhcPkgWrapperForVersion ghcProfileVersions;

  shellHook = ''
    export LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.gmp pkgs.zlib ]}:''${LIBRARY_PATH:-}"
    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.gmp pkgs.zlib ]}:''${LD_LIBRARY_PATH:-}"
    export NIX_LDFLAGS="-L${pkgs.gmp}/lib -L${pkgs.zlib}/lib ''${NIX_LDFLAGS:-}"

    cat <<'EOF'
TH cross dev shell

Compilers:
  ghc-9.10.3      raw TH plugin/test compiler
  ghc-9.12.4      GHC 9.12.4 compiler profile

Helpers:
  th-cross-build     cabal build th-cross-plugin and dependencies with isolated Nix Cabal store
  th-cross-test      cabal test th-cross-plugin:integration
  th-cross-test -p   run matching integration tests

Environment:
  raw TH tests use the wrapped patched GHC 9.10 worker
  set TH_CROSS_GHC_VERSION=9.12.4 to switch compiler profile
  set TH_CROSS_TEST_STORE_DIR or TH_CROSS_TEST_BUILDDIR to override compiler-specific Cabal paths

Nix checks:
  nix flake check -L

Maintenance:
  nix run .#regen-cabal-nix
EOF
  '';
}
