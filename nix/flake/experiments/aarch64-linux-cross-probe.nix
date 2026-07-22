{ pkgs }:

let
  # Lightweight documentation-as-derivation probe. It records which cross-GHCs
  # plain nixpkgs exposes for the selected target without compiling a fixture.
  crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
in
pkgs.runCommand
  "th-cross-aarch64-linux-cross-probe"
  { }
  ''
    cat > "$out" <<'EOF'
buildPlatform=${pkgs.stdenv.hostPlatform.config}
targetHostPlatform=${crossPkgs.stdenv.hostPlatform.config}
nativeHostGhc=${pkgs.haskell.compiler.ghc984.version}
crossGhc948=${crossPkgs.haskell.compiler.ghc948.version}
targetSideGhc948Compiler=${crossPkgs.haskell.compiler.ghc948.name}
buildHostCrossGhc948Compiler=${crossPkgs.buildPackages.haskell.compiler.ghc948.name}
consumerPluginShape=native build-host plugin built by consumer-ghc948-plugin
crossGhc984Status=unsupported by plain nixpkgs cross set: GHC >= 9.6 can't be cross-compiled here
nextStep=run consumer-ghc948-cross-worker-smoke to test cross-GHC plus native same-version plugin plus GHC 9.8.4 worker
EOF
  ''
