{ pkgs, hs, testFixturesDir }:

let
  # GHC 9.4.8 is useful as a plain nixpkgs cross-GHC baseline. It does not have
  # the newer `-fplugin-library` route, so this experiment keeps the older
  # `-package-db`/`-fplugin` shape and documents where it blocks.
  crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
  crossTargetTriple = crossPkgs.stdenv.hostPlatform.config;
  crossGhc = "${crossPkgs.buildPackages.haskell.compiler.ghc948}/bin/${crossTargetTriple}-ghc";
  pluginPackageDb = "${hs.consumerGhc948}/lib/ghc-9.4.8/package.conf.d";
  worker = "${hs.hostHaskellPkgs.th-host-worker}/bin/th-host-worker";

  # Both GHC 9.4.8 probes use the same command shape; only the fixture changes.
  mkGhc948CrossSmoke = { name, buildSubdir, fixtureName, comment ? "" }:
    pkgs.runCommand
      name
      {
        nativeBuildInputs = [
          hs.consumerGhc948
        ];
      }
      ''
        build_dir="$TMPDIR/${buildSubdir}"
        mkdir -p "$build_dir"

        echo "cross target triple: ${crossTargetTriple}"
        echo "cross GHC: ${crossGhc}"
        echo "plugin package DB: ${pluginPackageDb}"
        echo "worker: ${worker}"

        plugin_library_path=$(
          find \
            "${hs.consumerGhc948}/lib/ghc-9.4.8" \
            -name '*.so*' \
            -printf '%h\n' \
            | sort -u \
            | paste -sd:
        )
        export LD_LIBRARY_PATH="$plugin_library_path''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

        ${comment}
        "${crossGhc}" \
          -v0 \
          -fno-code \
          -fno-external-interpreter \
          -fforce-recomp \
          -package-db ${pluginPackageDb} \
          -plugin-package th-cross-plugin \
          -i${testFixturesDir} \
          -outputdir "$build_dir" \
          -hidir "$build_dir" \
          -odir "$build_dir" \
          -stubdir "$build_dir" \
          -fplugin=THCross.Plugin \
          -fplugin-opt=THCross.Plugin:worker=${worker} \
          ${testFixturesDir + "/${fixtureName}"}

        touch "$out"
      '';
in
{
  packages = {
    consumer-ghc948-cross-worker-smoke =
      mkGhc948CrossSmoke {
        name = "th-cross-consumer-ghc948-cross-worker-smoke";
        buildSubdir = "consumer-ghc948-cross-build";
        fixtureName = "Example.hs";
        comment = ''
          # GHC 9.4 currently fails here before runMetaHook: plugins require
          # -fno-external-interpreter, while cross TH asks for a target code
          # interpreter.
        '';
      };

    consumer-ghc948-cross-plugin-no-th-smoke =
      mkGhc948CrossSmoke {
        name = "th-cross-consumer-ghc948-cross-plugin-no-th-smoke";
        buildSubdir = "consumer-ghc948-cross-no-th-build";
        fixtureName = "NoTH.hs";
      };
  };
}
