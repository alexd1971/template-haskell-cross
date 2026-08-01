{ pkgs, compilerSets }:

let
  mkGhcWrapperForVersion = version:
    let
      compiler = compilerSets.mkCompilerForVersion version;
    in
    pkgs.writeShellScriptBin "ghc-${version}" ''
      exec ${compiler.targetGhcWithPlugin}/bin/ghc "$@"
    '';

  mkGhcPkgWrapperForVersion = version:
    let
      compiler = compilerSets.mkCompilerForVersion version;
    in
    pkgs.writeShellScriptBin "ghc-${version}-pkg" ''
      exec ${compiler.targetGhcWithPlugin}/bin/ghc-pkg "$@"
    '';

  ghcProfileVersions =
    pkgs.lib.sort pkgs.lib.versionOlder
      (map (profile: profile.version) (builtins.attrValues compilerSets.compilerProfiles));
  ghcProfileList = pkgs.lib.concatStringsSep ", " ghcProfileVersions;
  requireGhcVersion = ''
    cross_ghc_version="''${TH_CROSS_GHC_VERSION:-}"
    if [ -z "$cross_ghc_version" ]; then
      echo "TH_CROSS_GHC_VERSION is required; supported versions: ${ghcProfileList}" >&2
      exit 2
    fi
  '';

  thCrossBuild = pkgs.writeShellScriptBin "th-cross-build" ''
    set -euo pipefail

    ${requireGhcVersion}

    if [ "$#" -eq 0 ]; then
      set -- th-cross-plugin
    elif [ "$1" = "all" ] || [ "$1" = "th-host-worker" ]; then
      echo "th-host-worker requires patched GHC; use: nix build --impure --expr 'let f = builtins.getFlake \"path:$PWD\"; c = f.lib.${pkgs.stdenv.hostPlatform.system}.internal.mkCompilerForVersion \"$TH_CROSS_GHC_VERSION\"; in c.hostWorker'" >&2
      exit 2
    fi

    store_suffix="ghc-$cross_ghc_version"

    exec cabal \
      --store-dir "$PWD/.cabal-store-nix-$store_suffix" \
      build \
      --project-dir . \
      --builddir "dist-newstyle-nix-$store_suffix" \
      --with-compiler "ghc-$cross_ghc_version" \
      --with-hc-pkg "ghc-$cross_ghc_version-pkg" \
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

    ${requireGhcVersion}

    compiler_expr="(builtins.getFlake \"path:$PWD\").lib.${pkgs.stdenv.hostPlatform.system}.internal.mkCompilerForVersion \"$cross_ghc_version\""
    worker_expr="($compiler_expr).hostWorker"
    target_ghc_expr="($compiler_expr).targetGhcWithPlugin"
    worker="$(nix build --no-link --print-out-paths --impure --expr "$worker_expr")"
    target_ghc="$(nix build --no-link --print-out-paths --impure --expr "$target_ghc_expr")"
    test_ghc="$target_ghc/bin/ghc"
    test_ghc_pkg="$target_ghc/bin/ghc-pkg"
    store_suffix="ghc-$cross_ghc_version"

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
  supported profiles: ${ghcProfileList}
  ghc-<version> and ghc-<version>-pkg wrappers are available for each profile

Helpers:
  th-cross-build     cabal build th-cross-plugin and dependencies with isolated Nix Cabal store
  th-cross-test      cabal test th-cross-plugin:integration
  th-cross-test -p   run matching integration tests

Environment:
  set TH_CROSS_GHC_VERSION=<version> before th-cross-build/th-cross-test
  set TH_CROSS_TEST_STORE_DIR or TH_CROSS_TEST_BUILDDIR to override compiler-specific Cabal paths

Nix checks:
  nix flake check -L

Maintenance:
  nix run .#regen-cabal-nix
EOF
  '';
}
