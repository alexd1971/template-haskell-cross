{ pkgs }:

let
  crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;

  plain =
    crossPkgs.buildPackages.haskell.compiler.ghc9103;

  bootstrapped =
    plain.override {
      # This is an experimental cross-GHC shape for -fplugin-library. Hadrian
      # only enables the cross stage0 internal interpreter when the bootstrap
      # compiler has the same version as the compiler being built.
      bootPkgs = pkgs.haskell.packages.ghc9103;
    };

  forcedInternalInterpreter =
    bootstrapped.overrideAttrs (old: {
      # Same-version bootstrap satisfies Hadrian's cross ghci workaround, but
      # the stage1 cross compiler is built in Hadrian's stage0 context. Force
      # HAVE_INTERNAL_INTERPRETER through the compiler package cabal file
      # instead of bypassing GHC.Driver.Plugins directly. In cross builds
      # Hadrian copies stage0/bin/ghc into stage1/bin/ghc, so export dynamic
      # symbols from the stage0 ghc-bin executable that will actually be
      # installed/run.
      hadrianFlags = old.hadrianFlags ++ [
        "stage0.ghc-bin.ghc.link.opts += -optl-Wl,--export-dynamic"
      ];
      patches = (old.patches or []) ++ [
        ../../patches/ghc-9.10.3-force-compiler-internal-interpreter.patch
        ../../patches/ghc-9.10.3-ignore-empty-th-finalizers.patch
      ];
    });
in
{
  inherit plain bootstrapped forcedInternalInterpreter;
}
