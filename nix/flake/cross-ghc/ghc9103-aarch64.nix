# Patched cross-GHC 9.10.3 producing aarch64-linux binaries.
#
# Applies three cross-GHC changes (documented in passthru.crossPatchNotes):
#   P1  Force HAVE_INTERNAL_INTERPRETER in the compiler package
#   P2  --export-dynamic on stage0 ghc-bin
#   P3  Empty ThModFinalizers are no-ops
#
# See docs/ghc-cross-patches.md for rationale and upstream status of each
# patch.

{ pkgs }:

let
  crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;

  # Same-version bootstrap: Hadrian only enables the stage0 internal
  # interpreter when bootPkgs uses the same GHC version as the compiler
  # being built.
  bootstrapped =
    crossPkgs.buildPackages.haskell.compiler.ghc9103.override {
      bootPkgs = pkgs.haskell.packages.ghc9103;
    };
in
bootstrapped.overrideAttrs (old:
  let
    # P1: Force HAVE_INTERNAL_INTERPRETER in the compiler package so
    #     GHC.Driver.Plugins.loadExternalPlugins does not panic.  The
    #     macro is normally gated behind `flag(internal-interpreter)`,
    #     which conflates TH interpreter support with the ability to
    #     dlopen a plugin shared library.
    forceInternalInterpreterPatch =
      ../../patches/ghc-9.10.3-force-compiler-internal-interpreter.patch;

    # P3: addModFinalizersWithLclEnv with an empty finalizer list is now
    #     a no-op.  Without this, runRemoteModFinalizers calls tcGetInterp
    #     before checking whether there is any work to do, and tcGetInterp
    #     fails on a cross compiler.
    emptyFinalizersPatch =
      ../../patches/ghc-9.10.3-ignore-empty-th-finalizers.patch;

    # P2: --export-dynamic on the stage0 ghc-bin executable so dlopen'd
    #     plugin shared objects can resolve RTS symbols.  In cross builds
    #     Hadrian copies stage0/bin/ghc → stage1/bin/ghc, hence stage0.
    #     iserv already receives the same flag upstream.
    exportDynamicFlag =
      "stage0.ghc-bin.ghc.link.opts += -optl-Wl,--export-dynamic";
  in
  {
    hadrianFlags = old.hadrianFlags ++ [ exportDynamicFlag ];
    patches = (old.patches or []) ++ [
      forceInternalInterpreterPatch
      emptyFinalizersPatch
    ];

    passthru = (old.passthru or {}) // {
      crossPatchNotes = {
        summary = "Cross-GHC 9.10.3 for aarch64-linux with -fplugin-library support";
        patches = [
          {
            id = "P1";
            tag = "HAVE_INTERNAL_INTERPRETER";
            description = ''
              Make CPP-Options: -DHAVE_INTERNAL_INTERPRETER unconditional
              for the compiler package.  loadExternalPlugins is gated on
              this macro; without it -fplugin-library panics.
            '';
            upstream = ''
              The proper fix is to decouple internal interpreter from
              plugin-loading in GHC.Driver.Plugins.  The current patch
              forces the macro as a pragmatic shortcut; a real fix requires design work in GHC upstream.
            '';
          }
          {
            id = "P2";
            tag = "--export-dynamic";
            description = ''
              Add -optl-Wl,--export-dynamic to the stage0 ghc-bin link
              step so the statically-linked cross-GHC exports its RTS
              symbols to dlopen'd plugin shared objects.
            '';
            upstream = ''
              Same mechanism already used by iserv in Hadrian.
              Should be upstreamable as a one-line Hadrian change.
            '';
          }
          {
            id = "P3";
            tag = "empty-finalizers";
            description = ''
              Short-circuit addModFinalizersWithLclEnv when the finalizer
              list is empty.  Prevents runRemoteModFinalizers from calling
              tcGetInterp on a cross compiler that has no interpreter.
            '';
            upstream = ''
              Standalone bugfix: an empty finalizer list should never
              require an interpreter.  Upstreamable independently.
            '';
          }
        ];
      };
    };
  })
