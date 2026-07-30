# Build a patched cross-GHC for a compiler profile and target package set.
#
# Applies profile.crossPatches plus the Hadrian --export-dynamic flag needed by
# dlopen'd plugin shared objects.

{ profile
, crossPkgs
, bootPkgs
, targetName
, targetTriple
}:

let
  compiler = crossPkgs.buildPackages.haskell.compiler.${profile.packageSetName};

  # Same-version bootstrap: Hadrian only enables the stage0 internal interpreter
  # when bootPkgs uses the same GHC version as the compiler being built.
  bootstrapped =
    compiler.override {
      inherit bootPkgs;
    };
in
bootstrapped.overrideAttrs (old:
  let
    # --export-dynamic on the stage0 ghc-bin executable so dlopen'd plugin
    # shared objects can resolve RTS symbols. In cross builds Hadrian copies
    # stage0/bin/ghc to stage1/bin/ghc, hence stage0.
    exportDynamicFlag =
      "stage0.ghc-bin.ghc.link.opts += -optl-Wl,--export-dynamic";
  in
  {
    hadrianFlags = old.hadrianFlags ++ [ exportDynamicFlag ];
    patches = (old.patches or []) ++ profile.crossPatches;

    passthru = (old.passthru or {}) // {
      crossPatchNotes = {
        summary = "Cross-GHC ${profile.version} for ${targetName} with -fplugin-library support";
        patches = [
          {
            id = "P1";
            tag = "HAVE_INTERNAL_INTERPRETER";
            description = ''
              Make CPP-Options: -DHAVE_INTERNAL_INTERPRETER unconditional
              for the compiler package. loadExternalPlugins is gated on
              this macro; without it -fplugin-library panics.
            '';
            upstream = ''
              The proper fix is to decouple internal interpreter from
              plugin-loading in GHC.Driver.Plugins. The current patch
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
              list is empty. Prevents runRemoteModFinalizers from calling
              tcGetInterp on a cross compiler that has no interpreter.
            '';
            upstream = ''
              Standalone bugfix: an empty finalizer list should never
              require an interpreter. Upstreamable independently.
            '';
          }
        ];

        inherit targetName targetTriple;
        ghcVersion = profile.version;
      };
    };
  })
