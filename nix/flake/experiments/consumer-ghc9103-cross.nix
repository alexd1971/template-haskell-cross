{ pkgs, hs, thCrossLib, crossGhc9103Aarch64 }:

let
  # This experiment checks the current promising route for a real cross-GHC:
  # load a native plugin into an aarch64 cross compiler through `-fplugin-library`
  # and let that plugin delegate TH execution to the GHC 9.8.4 host worker.

  # These fields describe the plugin as seen by the consumer/cross compiler.
  # The worker remains host-side GHC 9.8.4; the plugin is built for the GHC
  # version that loads it, here GHC 9.10.3.
  pluginLibraryArgs = {
    consumerName = "consumer-ghc9103";
    consumerGhcVersion = "9.10.3";
    consumerPlugin = hs.consumerGhc9103HaskellPkgs.th-cross-plugin;
    worker = "${hs.hostHaskellPkgs.th-host-worker}/bin/th-host-worker";
  };

  cabalPackageSmoke =
    let
      crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
      crossTargetTriple = crossPkgs.stdenv.hostPlatform.config;
      crossGhcDrv = crossGhc9103Aarch64.forcedInternalInterpreter;
      crossGhc = "${crossGhcDrv}/bin/${crossTargetTriple}-ghc";
      crossGhcPkg = "${crossGhcDrv}/bin/${crossTargetTriple}-ghc-pkg";
      crossBinutils = crossPkgs.buildPackages.bintools;
      consumerPlugin = hs.consumerGhc9103HaskellPkgs.th-cross-plugin;
      pluginLibDir = "${consumerPlugin}/lib/ghc-9.10.3";
      worker = "${hs.hostHaskellPkgs.th-host-worker}/bin/th-host-worker";
    in
    pkgs.runCommand
      "th-cross-consumer-ghc9103-cross-cabal-package-smoke"
      {
        nativeBuildInputs = [
          pkgs.haskell.compiler.ghc9103
          crossBinutils
        ];
      }
      ''
        build_dir="$TMPDIR/consumer-ghc9103-cross-cabal-package-build"
        mkdir -p "$build_dir"
        cp -R ${../../../prototype/th-consumer-example} "$build_dir/th-consumer-example"
        chmod -R u+w "$build_dir/th-consumer-example"
        cd "$build_dir/th-consumer-example"

        cat > Setup.hs <<'EOF'
import Distribution.Simple

main :: IO ()
main = defaultMain
EOF

        plugin_conf=$(find "${pluginLibDir}" -path '*/package.conf.d/th-cross-plugin-*.conf' | head -n 1)
        plugin_so=$(find "${pluginLibDir}" -name 'libHSth-cross-plugin-*.so' | head -n 1)
        plugin_unit=$(sed -n 's/^id:[[:space:]]*//p' "$plugin_conf")
        plugin_library_path=$(
          find \
            "${pluginLibDir}" \
            -name '*.so*' \
            -printf '%h\n' \
            | sort -u \
            | paste -sd:
        )

        export LD_LIBRARY_PATH="$plugin_library_path''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

        {
          echo "crossTargetTriple=${crossTargetTriple}"
          echo "crossGhc=${crossGhc}"
          echo "crossGhcPkg=${crossGhcPkg}"
          echo "crossBinutils=${crossBinutils}"
          echo "worker=${worker}"
          echo "pluginConf=$plugin_conf"
          echo "pluginSo=$plugin_so"
          echo "pluginUnit=$plugin_unit"
          echo
          echo "cabal package: th-consumer-example"
          echo "configure/build with Setup.hs and cross-GHC:"
        } > "$out"

        set +e
        ${pkgs.haskell.compiler.ghc9103}/bin/runghc Setup.hs configure \
          --builddir=dist-cross \
          --with-compiler="${crossGhc}" \
          --with-hc-pkg="${crossGhcPkg}" \
          --with-ld="${crossBinutils}/bin/${crossTargetTriple}-ld" \
          --with-ar="${crossBinutils}/bin/${crossTargetTriple}-ar" \
          --prefix="$TMPDIR/install" \
          --ghc-option=-v0 \
          --ghc-option=-fno-external-interpreter \
          --ghc-option=-fforce-recomp \
          "--ghc-option=-fplugin-library=$plugin_so;$plugin_unit;THCross.Plugin;[\"worker=${worker}\"]" \
          >> "$out" 2>&1
        configure_exit="$?"

        if [ "$configure_exit" -eq 0 ]; then
          ${pkgs.haskell.compiler.ghc9103}/bin/runghc Setup.hs build \
            --builddir=dist-cross \
            >> "$out" 2>&1
          build_exit="$?"
        else
          build_exit=125
        fi
        set -e

        {
          echo
          echo "configureExit=$configure_exit"
          echo "buildExit=$build_exit"
          if [ "$configure_exit" -eq 0 ] && [ "$build_exit" -eq 0 ]; then
            echo "status=ok"
          else
            echo "status=blocked"
          fi
        } >> "$out"
      '';
in
{
  packages = {
    # Baseline same-version-bootstrap cross-GHC. It exposes `-fplugin-library`
    # but still cannot load the plugin in this repository's current setup.
    consumer-ghc9103-cross-ghc-bootstrapped =
      crossGhc9103Aarch64.bootstrapped;

    # Patched cross-GHC that currently passes the TH worker smoke test.
    consumer-ghc9103-cross-ghc-forced-internal-interpreter =
      crossGhc9103Aarch64.forcedInternalInterpreter;

    consumer-ghc9103-cross-plugin-library-probe =
      thCrossLib.mkConsumerCrossPluginLibraryProbe
        (pluginLibraryArgs // {
          name = "th-cross-consumer-ghc9103-cross-plugin-library-probe";
          crossGhcDrv = crossGhc9103Aarch64.plain;
        });

    consumer-ghc9103-cross-plugin-library-bootstrapped-probe =
      thCrossLib.mkConsumerCrossPluginLibraryProbe
        (pluginLibraryArgs // {
          name = "th-cross-consumer-ghc9103-cross-plugin-library-bootstrapped-probe";
          crossGhcDrv = crossGhc9103Aarch64.bootstrapped;
        });

    consumer-ghc9103-cross-plugin-library-forced-internal-interpreter-probe =
      thCrossLib.mkConsumerCrossPluginLibraryProbe
        (pluginLibraryArgs // {
          name = "th-cross-consumer-ghc9103-cross-plugin-library-forced-internal-interpreter-probe";
          crossGhcDrv = crossGhc9103Aarch64.forcedInternalInterpreter;
        });

    consumer-ghc9103-cross-worker-smoke =
      thCrossLib.mkConsumerCrossWorkerSmoke
        (pluginLibraryArgs // {
          crossGhcDrv = crossGhc9103Aarch64.forcedInternalInterpreter;
        });

    consumer-ghc9103-cross-cabal-package-smoke = cabalPackageSmoke;
  };
}
