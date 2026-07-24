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
crossGhc9103=${crossPkgs.buildPackages.haskell.compiler.ghc9103.version}
crossGhc9103Compiler=${crossPkgs.buildPackages.haskell.compiler.ghc9103.name}
workingCrossGhc=cross-ghc9103-aarch64-linux (patched, see docs/ghc-cross-patches.md)
crossGhc984Status=unsupported by plain nixpkgs cross set: GHC >= 9.6 can't be cross-compiled here
EOF
  ''
