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

      componentHaskellDependsFromCabalDeps =
        cabalDeps:
        pkgs.lib.concatMap
          (field: cabalDeps.${field} or [ ])
          componentDependencyFields;

      # nixpkgs Haskell derivations expose their Cabal dependency fields through
      # `passthru.getCabalDeps`. Use dependency `pname`, not the full derivation
      # name, as the key for the corresponding host package set.
      hostPackageNamesFromCabalDeps =
        cabalDeps:
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
                  dependency.pname)
              (componentHaskellDependsFromCabalDeps cabalDeps)));

      # Real TH generators often live in dependencies. The worker evaluates
      # splices with native GHC 9.8.4, so give it a host-side package DB that
      # mirrors the target component dependencies by package name.
      mkWorkerWithHostPackages =
        hostPackageNames:
        if hostPackageNames == [ ] then
          {
            worker = defaultWorker;
            hostGhcPkg = "${pkgs.haskell.compiler.ghc984}/bin/ghc-pkg";
          }
        else
          let
            hostGhcWithPackages =
              pkgs.haskell.packages.ghc984.ghcWithPackages
                (hpkgs: map (packageName: hpkgs.${packageName}) hostPackageNames);
          in
          {
            worker = "${pkgs.runCommand
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
            hostGhcPkg = "${hostGhcWithPackages}/bin/ghc-pkg";
          };

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

      cabalContextValidationScript =
        expectedHostPackageNames:
        ''
          cat > dump-cabal-component-deps.hs <<'EOF'
import Distribution.Simple.Configure (getPersistBuildConfig)
import Distribution.Simple.LocalBuildInfo (allComponentsInBuildOrder)
import Distribution.Types.ComponentLocalBuildInfo
  (componentLocalName, componentPackageDeps)
import Distribution.Types.ComponentName (showComponentName)
import Distribution.Types.MungedPackageId (mungedName)
import Distribution.Types.MungedPackageName (encodeCompatPackageName)
import Distribution.Types.PackageName (unPackageName)
import Distribution.Types.UnitId (unUnitId)

main :: IO ()
main = do
  localBuildInfo <- getPersistBuildConfig "dist"
  mapM_ printComponent (allComponentsInBuildOrder localBuildInfo)

printComponent component = do
  putStrLn ("component " <> showComponentName (componentLocalName component))
  mapM_ printDependency (componentPackageDeps component)

printDependency (unitId, packageId) =
  putStrLn
    ( "  "
        <> unPackageName (encodeCompatPackageName (mungedName packageId))
        <> " "
        <> unUnitId unitId
    )
EOF

          mkdir -p "$out/nix-support"
          ${pkgs.haskell.compiler.ghc9103}/bin/ghc \
            -v0 \
            -package Cabal \
            --make dump-cabal-component-deps.hs \
            -o dump-cabal-component-deps

          ./dump-cabal-component-deps \
            > "$out/nix-support/cabal-component-deps"

          cat > "$out/nix-support/nix-derived-host-package-names" <<'EOF'
${pkgs.lib.concatStringsSep "\n" expectedHostPackageNames}
EOF

          awk '/^  / { print $1 }' "$out/nix-support/cabal-component-deps" \
            | grep -v -E '^(base|template-haskell)$' \
            | sort -u \
            > "$out/nix-support/cabal-derived-package-names"

          sort -u "$out/nix-support/nix-derived-host-package-names" \
            > "$out/nix-support/nix-derived-host-package-names.sorted"

          if ! diff -u \
            "$out/nix-support/nix-derived-host-package-names.sorted" \
            "$out/nix-support/cabal-derived-package-names" \
            > "$out/nix-support/package-name-diff"; then
            echo "Nix-derived host package names differ from Cabal setup-config package names" >&2
            cat "$out/nix-support/package-name-diff" >&2
            exit 1
          fi
        '';

      mkConsumerDerivationWithWorker =
        hostPackageNames:
        args:
        let
          workerContext = mkWorkerWithHostPackages hostPackageNames;
        in
        crossHaskellPkgs.mkDerivation
          (args // {
            doCheck = false;
            doHaddock = false;
            doHoogle = false;
            enableExternalInterpreter = false;
            enableLibraryProfiling = false;
            preConfigure = (args.preConfigure or "") + ''

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
              appendToVar configureFlags "--ghc-option=-fplugin-library=$plugin_so;$plugin_unit;THCross.Plugin;[\"worker=${workerContext.worker}\"]"
              ${pkgs.lib.concatMapStringsSep "\n" (packageName: ''
                host_package_id="$("${workerContext.hostGhcPkg}" field ${pkgs.lib.escapeShellArg packageName} id --simple-output)"
                appendToVar configureFlags "--ghc-option=-fplugin-opt=THCross.Plugin:host-package-id=$host_package_id"
              '') hostPackageNames}
            '';
            postConfigure =
              pkgs.lib.concatStringsSep "\n" [
                (args.postConfigure or "")
                (cabalContextValidationScript hostPackageNames)
              ];
          });

      mkCabalContextProbe =
        expectedHostPackageNames:
        args:
        crossHaskellPkgs.mkDerivation
          (args // {
            doCheck = false;
            doHaddock = false;
            doHoogle = false;
            enableLibraryProfiling = false;
            postConfigure =
              pkgs.lib.concatStringsSep "\n" [
                (args.postConfigure or "")
                (cabalContextValidationScript expectedHostPackageNames)
              ];
          });

      callPackageWithWorker =
        packageFile:
        let
          basePackage = crossHaskellPkgs.callPackage packageFile { };
          hostPackageNames = hostPackageNamesFromCabalDeps basePackage.getCabalDeps;
        in
        crossHaskellPkgs.callPackage packageFile {
          mkDerivation = mkConsumerDerivationWithWorker hostPackageNames;
        };

      callPackageCabalContextProbe =
        packageFile:
        let
          basePackage = crossHaskellPkgs.callPackage packageFile { };
          expectedHostPackageNames = hostPackageNamesFromCabalDeps basePackage.getCabalDeps;
        in
        crossHaskellPkgs.callPackage packageFile {
          mkDerivation = mkCabalContextProbe expectedHostPackageNames;
        };
    in
    {
      example =
        callPackageWithWorker ../../../nix/generated/th-consumer-example.nix;

      microlensConsumer =
        callPackageWithWorker ../../../nix/generated/th-microlens-consumer.nix;

      executableConsumer =
        callPackageWithWorker ../../../nix/generated/th-executable-consumer.nix;

      microlensConsumerCabalContextProbe =
        callPackageCabalContextProbe ../../../nix/generated/th-microlens-consumer.nix;

      executableConsumerQemuSmoke =
        pkgs.runCommand
          "th-cross-consumer-ghc9103-cross-executable-qemu-smoke"
          {
            nativeBuildInputs = [
              pkgs.qemu-user
            ];
          }
          ''
            output="$(${pkgs.qemu-user}/bin/qemu-aarch64 ${genericBuilderPackages.executableConsumer}/bin/th-executable-consumer)"

            if [ "$output" != '"Ada"' ]; then
              echo "expected: \"Ada\"" >&2
              echo "actual:   $output" >&2
              exit 1
            fi

            {
              echo "executable=${genericBuilderPackages.executableConsumer}/bin/th-executable-consumer"
              echo "qemu=${pkgs.qemu-user}/bin/qemu-aarch64"
              echo "output=$output"
              echo "status=ok"
            } > "$out"
          '';
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
    consumer-ghc9103-cross-microlens-cabal-context-probe =
      genericBuilderPackages.microlensConsumerCabalContextProbe;
    consumer-ghc9103-cross-executable-package = genericBuilderPackages.executableConsumer;
    consumer-ghc9103-cross-executable-qemu-smoke = genericBuilderPackages.executableConsumerQemuSmoke;
  };
}
