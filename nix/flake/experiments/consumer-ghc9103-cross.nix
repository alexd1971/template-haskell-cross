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

  # Read the native plugin package metadata in the same vocabulary GHC uses.
  # `-fplugin-library` still wants a concrete shared object path, so derive it
  # from `hs-libraries` plus the first `dynamic-library-dirs` entry.
  pluginLibraryMetadataScript =
    { pluginLibDir
    , nativeGhcPkg
    , consumerGhcVersion
    }:
    ''
      plugin_pkg_db="${pluginLibDir}/lib/package.conf.d"
      plugin_unit=$("${nativeGhcPkg}" --package-db="$plugin_pkg_db" field th-cross-plugin id --simple-output 2>/dev/null)
      plugin_hs_library=$("${nativeGhcPkg}" --package-db="$plugin_pkg_db" field th-cross-plugin hs-libraries --simple-output 2>/dev/null)
      plugin_dynamic_library_dirs=$("${nativeGhcPkg}" --package-db="$plugin_pkg_db" field th-cross-plugin dynamic-library-dirs --simple-output 2>/dev/null)
      set -- $plugin_dynamic_library_dirs
      plugin_so="$1/lib''${plugin_hs_library}-ghc${consumerGhcVersion}.so"
      plugin_library_path=$(printf '%s\n' $plugin_dynamic_library_dirs | paste -sd:)
    '';

  # Control package-level build that drives Cabal directly through Setup.hs.
  # This keeps a low-level, explicit baseline for comparing against nixpkgs'
  # generic Haskell builder below.
  manualSetupPackage =
    let
      crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
      crossTargetTriple = crossPkgs.stdenv.hostPlatform.config;
      crossGhcDrv = crossGhc9103Aarch64.forcedInternalInterpreter;
      crossGhc = "${crossGhcDrv}/bin/${crossTargetTriple}-ghc";
      crossGhcPkg = "${crossGhcDrv}/bin/${crossTargetTriple}-ghc-pkg";
      crossBinutils = crossPkgs.buildPackages.bintools;
      consumerPlugin = hs.consumerGhc9103HaskellPkgs.th-cross-plugin;
      pluginLibDir = "${consumerPlugin}/lib/ghc-9.10.3";
      nativeGhcPkg = "${pkgs.haskell.compiler.ghc9103}/bin/ghc-pkg";
      worker = "${hs.hostHaskellPkgs.th-host-worker}/bin/th-host-worker";
    in
    pkgs.runCommand
      "th-consumer-example-aarch64-unknown-linux-gnu-0.1.0.0"
      {
        nativeBuildInputs = [
          pkgs.haskell.compiler.ghc9103
          crossBinutils
        ];
      }
      ''
        mkdir -p "$out/nix-support"
        report="$out/nix-support/build-log"

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

        ${pluginLibraryMetadataScript {
          inherit pluginLibDir nativeGhcPkg;
          consumerGhcVersion = "9.10.3";
        }}

        export LD_LIBRARY_PATH="$plugin_library_path''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

        {
          echo "crossTargetTriple=${crossTargetTriple}"
          echo "crossGhc=${crossGhc}"
          echo "crossGhcPkg=${crossGhcPkg}"
          echo "crossBinutils=${crossBinutils}"
          echo "worker=${worker}"
          echo "pluginPkgDb=$plugin_pkg_db"
          echo "pluginSo=$plugin_so"
          echo "pluginUnit=$plugin_unit"
          echo
          echo "cabal package: th-consumer-example"
          echo "configure/build/copy with Setup.hs and cross-GHC:"
        } > "$report"

        ${pkgs.haskell.compiler.ghc9103}/bin/runghc Setup.hs configure \
          --builddir=dist-cross \
          --with-compiler="${crossGhc}" \
          --with-hc-pkg="${crossGhcPkg}" \
          --with-ld="${crossBinutils}/bin/${crossTargetTriple}-ld" \
          --with-ar="${crossBinutils}/bin/${crossTargetTriple}-ar" \
          --with-strip="${crossBinutils}/bin/${crossTargetTriple}-strip" \
          --prefix="$out" \
          --libdir="$out/lib" \
          --docdir="$out/share/doc/th-consumer-example-0.1.0.0" \
          --ghc-option=-v0 \
          --ghc-option=-fno-external-interpreter \
          --ghc-option=-fforce-recomp \
          "--ghc-option=-fplugin-library=$plugin_so;$plugin_unit;THCross.Plugin;[\"worker=${worker}\"]" \
          >> "$report" 2>&1

        ${pkgs.haskell.compiler.ghc9103}/bin/runghc Setup.hs build \
          --builddir=dist-cross \
          >> "$report" 2>&1

        ${pkgs.haskell.compiler.ghc9103}/bin/runghc Setup.hs copy \
          --builddir=dist-cross \
          >> "$report" 2>&1

        echo >> "$report"
        echo "status=ok" >> "$report"
      '';

  # Preferred package-level build shape: reuse nixpkgs' Haskell generic
  # builder and inject only the cross-GHC/plugin-specific pieces.
  genericBuilderPackages =
    let
      crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
      consumerPlugin = hs.consumerGhc9103HaskellPkgs.th-cross-plugin;
      pluginLibDir = "${consumerPlugin}/lib/ghc-9.10.3";
      nativeGhcPkg = "${pkgs.haskell.compiler.ghc9103}/bin/ghc-pkg";
      defaultWorker = "${hs.hostHaskellPkgs.th-host-worker}/bin/th-host-worker";

      componentDependencyFields = [
        "libraryHaskellDepends"
        "executableHaskellDepends"
        "testHaskellDepends"
        "benchmarkHaskellDepends"
      ];

      componentHaskellDepends =
        args:
        pkgs.lib.concatMap
          (field: args.${field} or [ ])
          componentDependencyFields;

      # The generated cabal2nix derivation passes concrete dependency
      # derivations in component-specific `*HaskellDepends` fields. For this
      # prototype, their Nix package names are also the names we expose in the
      # host GHC session.
      hostPackageNamesFor =
        args:
        pkgs.lib.unique
          (builtins.filter
            (packageName:
              packageName != null
              && packageName != "base"
              && packageName != "template-haskell")
            (map
              (dependency:
                if dependency == null then
                  null
                else
                  pkgs.lib.getName dependency)
              (componentHaskellDepends args)));

      # Real TH generators often live in dependencies. The worker evaluates
      # splices with native GHC 9.8.4, so give it a host-side package DB that
      # mirrors the target component dependencies by package name.
      mkWorkerWithHostPackages =
        hostPackages:
        if hostPackages == [ ] then
          defaultWorker
        else
          let
            hostGhcWithPackages =
              pkgs.haskell.packages.ghc984.ghcWithPackages
                (hpkgs: map (packageName: hpkgs.${packageName}) hostPackages);
          in
          "${pkgs.runCommand
            "th-host-worker-ghc984-with-host-packages"
          {
            nativeBuildInputs = [
              pkgs.makeWrapper
            ];
          }
          ''
            mkdir -p "$out/bin"
            makeWrapper \
              ${hs.hostHaskellPkgs.th-host-worker}/bin/.th-host-worker-wrapped \
              "$out/bin/th-host-worker" \
              --set TH_HOST_GHC_LIBDIR "${hostGhcWithPackages}/lib/ghc-9.8.4/lib"
          ''}/bin/th-host-worker";

      # Build a target package set around the patched cross-GHC. The stock
      # nixpkgs aarch64 GHC 9.10.3 package set uses the unpatched compiler, so
      # reusing it directly would not exercise our current working cross path.
      crossHaskellPkgs =
        crossPkgs.callPackage (pkgs.path + "/pkgs/development/haskell-modules") {
          haskellLib = pkgs.haskell.lib.compose;
          buildHaskellPackages = pkgs.haskell.packages.ghc9103;
          ghc = crossGhc9103Aarch64.forcedInternalInterpreter;
          compilerConfig =
            crossPkgs.callPackage
              (pkgs.path + "/pkgs/development/haskell-modules/configuration-ghc-9.10.x.nix")
              {
                haskellLib = pkgs.haskell.lib.compose;
              };
        };

      mkConsumerDerivationWithWorker =
        args:
        let
          hostPackages = hostPackageNamesFor args;
          worker = mkWorkerWithHostPackages hostPackages;
        in
        crossHaskellPkgs.mkDerivation
          (args // {
            doCheck = false;
            doHaddock = false;
            doHoogle = false;
            enableExternalInterpreter = false;
            enableLibraryProfiling = false;
            preConfigure = ''
              ${pluginLibraryMetadataScript {
                inherit pluginLibDir nativeGhcPkg;
                consumerGhcVersion = "9.10.3";
              }}
              # The external plugin is loaded into the cross-GHC process by the
              # host dynamic linker, so its transitive Haskell shared libraries must
              # be discoverable at plugin load time.
              export LD_LIBRARY_PATH="$plugin_library_path''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

              appendToVar configureFlags "--ghc-option=-v0"
              appendToVar configureFlags "--ghc-option=-fno-external-interpreter"
              appendToVar configureFlags "--ghc-option=-fforce-recomp"
              appendToVar configureFlags "--ghc-option=-fplugin-library=$plugin_so;$plugin_unit;THCross.Plugin;[\"worker=${worker}\"]"
              ${pkgs.lib.concatMapStringsSep "\n" (packageName: ''
                appendToVar configureFlags "--ghc-option=-fplugin-opt=THCross.Plugin:host-package=${packageName}"
              '') hostPackages}
            '';
          });
    in
    {
      example =
        crossHaskellPkgs.callPackage ../../../nix/generated/th-consumer-example.nix {
          mkDerivation = mkConsumerDerivationWithWorker;
        };

      microlensConsumer =
        crossHaskellPkgs.callPackage ../../../nix/generated/th-microlens-consumer.nix {
          mkDerivation = mkConsumerDerivationWithWorker;
        };

      executableConsumer =
        crossHaskellPkgs.callPackage ../../../nix/generated/th-executable-consumer.nix {
          mkDerivation = mkConsumerDerivationWithWorker;
        };
    };
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

    consumer-ghc9103-cross-cabal-package = manualSetupPackage;
    consumer-ghc9103-cross-generic-package = genericBuilderPackages.example;
    consumer-ghc9103-cross-microlens-package = genericBuilderPackages.microlensConsumer;
    consumer-ghc9103-cross-executable-package = genericBuilderPackages.executableConsumer;
  };
}
