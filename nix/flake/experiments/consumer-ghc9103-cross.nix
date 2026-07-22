{ pkgs, hs, thCrossLib }:

let
  # This experiment checks the current promising route for a real cross-GHC:
  # load a native plugin into an aarch64 cross compiler through `-fplugin-library`
  # and let that plugin delegate TH execution to the GHC 9.8.4 host worker.

  plainCrossGhc =
    pkgs.pkgsCross.aarch64-multiplatform.buildPackages.haskell.compiler.ghc9103;

  bootstrappedCrossGhc =
    let
      crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
    in
    crossPkgs.buildPackages.haskell.compiler.ghc9103.override {
      # This is an experimental cross-GHC shape for -fplugin-library. Hadrian
      # only enables the cross stage0 internal interpreter when the bootstrap
      # compiler has the same version as the compiler being built.
      bootPkgs = pkgs.haskell.packages.ghc9103;
    };

  forcedInternalInterpreterCrossGhc =
    (bootstrappedCrossGhc).overrideAttrs (old: {
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

  # These fields describe the plugin as seen by the consumer/cross compiler.
  # The worker remains host-side GHC 9.8.4; the plugin is built for the GHC
  # version that loads it, here GHC 9.10.3.
  pluginLibraryArgs = {
    consumerName = "consumer-ghc9103";
    consumerGhcVersion = "9.10.3";
    consumerPlugin = hs.consumerGhc9103HaskellPkgs.th-cross-plugin;
    worker = "${hs.hostHaskellPkgs.th-host-worker}/bin/th-host-worker";
  };
in
{
  packages = {
    # Baseline same-version-bootstrap cross-GHC. It exposes `-fplugin-library`
    # but still cannot load the plugin in this repository's current setup.
    consumer-ghc9103-cross-ghc-bootstrapped = bootstrappedCrossGhc;

    # Patched cross-GHC that currently passes the TH worker smoke test.
    consumer-ghc9103-cross-ghc-forced-internal-interpreter =
      forcedInternalInterpreterCrossGhc;

    consumer-ghc9103-cross-plugin-library-probe =
      thCrossLib.mkConsumerCrossPluginLibraryProbe
        (pluginLibraryArgs // {
          name = "th-cross-consumer-ghc9103-cross-plugin-library-probe";
          crossGhcDrv = plainCrossGhc;
        });

    consumer-ghc9103-cross-plugin-library-bootstrapped-probe =
      thCrossLib.mkConsumerCrossPluginLibraryProbe
        (pluginLibraryArgs // {
          name = "th-cross-consumer-ghc9103-cross-plugin-library-bootstrapped-probe";
          crossGhcDrv = bootstrappedCrossGhc;
        });

    consumer-ghc9103-cross-plugin-library-forced-internal-interpreter-probe =
      thCrossLib.mkConsumerCrossPluginLibraryProbe
        (pluginLibraryArgs // {
          name = "th-cross-consumer-ghc9103-cross-plugin-library-forced-internal-interpreter-probe";
          crossGhcDrv = forcedInternalInterpreterCrossGhc;
        });

    consumer-ghc9103-cross-worker-smoke =
      thCrossLib.mkConsumerCrossWorkerSmoke
        (pluginLibraryArgs // {
          crossGhcDrv = forcedInternalInterpreterCrossGhc;
        });
  };
}
