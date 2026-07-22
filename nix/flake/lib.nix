{ pkgs, testFixturesDir }:

rec {
  # Compile one fixture module with a cross-GHC while loading THCross.Plugin via
  # `-fplugin-library`. This is intentionally lower-level than Cabal package
  # integration: it gives experiments a small, inspectable smoke/probe builder.
  mkCrossCompileFixtureWithPlugin =
    crossGhcDrv:
    { name
    , buildSubdir
    , consumerGhcVersion
    , consumerPlugin
    , fixtureName
    , description
    , worker
    , includePluginOptions ? false
    }:
    let
      crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
      crossTargetTriple = crossPkgs.stdenv.hostPlatform.config;
      crossGhc = "${crossGhcDrv}/bin/${crossTargetTriple}-ghc";
      pluginLibDir = "${consumerPlugin}/lib/ghc-${consumerGhcVersion}";
      fixture = testFixturesDir + "/${fixtureName}";
    in
    pkgs.runCommand
      name
      { }
      ''
        build_dir="$TMPDIR/${buildSubdir}"
        mkdir -p "$build_dir"

        plugin_conf=$(find "${pluginLibDir}" -path '*/package.conf.d/th-cross-plugin-*.conf' | head -n 1)
        plugin_so=$(find "${pluginLibDir}" -name 'libHSth-cross-plugin-*.so' | head -n 1)
        plugin_unit=$(sed -n 's/^id:[[:space:]]*//p' "$plugin_conf")
        # External plugin loading uses the host dynamic linker. The plugin's
        # transitive Haskell shared libraries are not in a standard runtime
        # search path inside this runCommand, so collect their directories.
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
          echo "worker=${worker}"
          echo "pluginConf=$plugin_conf"
          echo "pluginSo=$plugin_so"
          echo "pluginUnit=$plugin_unit"
          echo
          if ${if includePluginOptions then "true" else "false"}; then
            echo "plugin-related options:"
            "${crossGhc}" --show-options | grep 'plugin' || true
            echo
          fi
          echo "cross info:"
          "${crossGhc}" --info | grep -E 'cross compiling|Project version|Booter version|Stage|Host platform|Target platform|Have interpreter|GHC Dynamic|LibDir' || true
          echo
          echo "${description}"
        } > "$out"

        # Semicolon format is GHC's `-fplugin-library` payload:
        # library path; unit id; module; JSON-like plugin args.
        set +e
        "${crossGhc}" \
          -v0 \
          -fno-code \
          -fno-external-interpreter \
          -fforce-recomp \
          -i${testFixturesDir} \
          -outputdir "$build_dir" \
          -hidir "$build_dir" \
          -odir "$build_dir" \
          -stubdir "$build_dir" \
          "-fplugin-library=$plugin_so;$plugin_unit;THCross.Plugin;[\"worker=${worker}\"]" \
          ${fixture} \
          >> "$out" 2>&1
        compile_exit="$?"
        set -e

        {
          echo
          echo "compileExit=$compile_exit"
          if [ "$compile_exit" -eq 0 ]; then
            echo "status=ok"
          else
            echo "status=blocked"
          fi
        } >> "$out"
      '';

  # Probe whether a cross-GHC can load the plugin at all. The fixture has no TH,
  # so failures here are plugin-loading/runtime-linker issues, not splice issues.
  mkConsumerCrossPluginLibraryProbe =
    { name
    , consumerName
    , consumerGhcVersion
    , consumerPlugin
    , worker
    , crossGhcDrv
    }:
    mkCrossCompileFixtureWithPlugin
      crossGhcDrv
      {
        inherit name;
        buildSubdir = "${consumerName}-cross-plugin-library-build";
        inherit consumerGhcVersion consumerPlugin;
        fixtureName = "NoTH.hs";
        description = "compile NoTH.hs with -fplugin-library:";
        inherit worker;
        includePluginOptions = true;
      };

  # End-to-end smoke: cross-GHC loads the plugin, the plugin asks the host worker
  # to evaluate a TH splice, then the cross-GHC consumes the generated fragment.
  mkConsumerCrossWorkerSmoke =
    { consumerName
    , consumerGhcVersion
    , consumerPlugin
    , worker
    , crossGhcDrv
    }:
    mkCrossCompileFixtureWithPlugin
      crossGhcDrv
      {
        name = "th-cross-${consumerName}-cross-worker-smoke";
        buildSubdir = "${consumerName}-cross-worker-build";
        inherit consumerGhcVersion consumerPlugin worker;
        fixtureName = "Example.hs";
        description = "compile Example.hs with -fplugin-library and host worker:";
      };
}
