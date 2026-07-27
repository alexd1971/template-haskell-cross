{ pkgs, hs, crossGhc9103Aarch64 }:

let
  # This experiment checks the current promising route for a real cross-GHC:
  # load a native plugin into an aarch64 cross compiler through `-fplugin-library`
  # and let that plugin delegate TH execution to the patched GHC 9.10.3 host
  # worker.

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

  # Preferred package-level build shape: reuse nixpkgs' Haskell generic
  # builder and inject only the cross-GHC/plugin-specific pieces.
  genericBuilderPackages =
    let
      crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
      consumerPlugin = hs.consumerGhc9103HaskellPkgs.th-cross-plugin;
      pluginLibDir = "${consumerPlugin}/lib/ghc-9.10.3";
      nativeGhcPkg = "${pkgs.haskell.compiler.ghc9103}/bin/ghc-pkg";
      targetGhcPkg = "${crossGhc9103Aarch64}/bin/aarch64-unknown-linux-gnu-ghc-pkg";
      defaultWorker = "${hs.hostGhc9103HaskellPkgs.th-host-worker}/bin/th-host-worker";

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
      # splices with native patched GHC 9.10.3, so give it a host-side package
      # DB that mirrors the target component dependencies by package name.
      mkWorkerWithHostPackages =
        hostPackageNames:
        if hostPackageNames == [ ] then
          {
            worker = defaultWorker;
            hostGhcPkg = "${hs.patchedNativeGhc9103}/bin/ghc-pkg";
          }
        else
          let
            hostGhcWithPackages =
              hs.hostGhc9103HaskellPkgs.ghcWithPackages
                (hpkgs: map (packageName: hpkgs.${packageName}) hostPackageNames);
          in
          {
            worker = "${pkgs.runCommand
              "th-host-worker-ghc9103-with-host-packages"
            {
              nativeBuildInputs = [
                pkgs.makeWrapper
              ];
            }
            ''
              mkdir -p "$out/bin"
              makeWrapper \
                ${hs.hostGhc9103HaskellPkgs.th-host-worker}/bin/.th-host-worker-wrapped \
                "$out/bin/th-host-worker" \
                --set TH_HOST_GHC_LIBDIR "${hostGhcWithPackages}/lib/ghc-9.10.3/lib"
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
          ghc = crossGhc9103Aarch64;
          compilerConfig =
            crossPkgs.callPackage
              (pkgs.path + "/pkgs/development/haskell-modules/configuration-ghc-9.10.x.nix")
              {
                haskellLib = pkgs.haskell.lib.compose;
              };
        };

      # Validate that the host worker package DB chosen during Nix evaluation
      # matches the external package dependencies Cabal resolved for this
      # package during `Setup configure`.
      #
      # `expectedHostPackageNames` comes from nixpkgs' evaluation-time
      # `getCabalDeps` metadata and is used to build the host GHC 9.10.3 package
      # environment.
      #
      # `excludedPackageNames` contains package names that may appear in
      # Cabal's configured component graph but must not be installed as external
      # worker dependencies, such as the package's own internal library.
      cabalContextValidationScript =
        expectedHostPackageNames:
        excludedPackageNames:
        ''
          mkdir -p "$out/nix-support"
          expected_packages="$out/nix-support/nix-derived-host-package-names"
          excluded_packages="$out/nix-support/excluded-host-package-names"

          cat > "$expected_packages" <<'EOF'
${pkgs.lib.concatStringsSep "\n" expectedHostPackageNames}
EOF

          cat > "$excluded_packages" <<'EOF'
base
template-haskell
${pkgs.lib.concatStringsSep "\n" excludedPackageNames}
EOF

          ${hs.nixTools}/bin/validate-cabal-component-context \
            "$expected_packages" \
            "$excluded_packages" \
            "$out/nix-support"
        '';

      appendCabalSourceDirsToPluginOptions =
        ''
          ${hs.nixTools}/bin/dump-cabal-source-dirs \
            > th-cross-cabal-source-dirs

          while IFS= read -r source_dir; do
            if [ -n "$source_dir" ]; then
              plugin_options="$plugin_options,\"host-source-dir=$PWD/$source_dir\""
            fi
          done < th-cross-cabal-source-dirs
        '';

      appendCabalCppOptionsToPluginOptions =
        ''
          ${hs.nixTools}/bin/dump-cabal-cpp-options \
            > th-cross-cabal-cpp-options

          while IFS= read -r cpp_option; do
            if [ -n "$cpp_option" ]; then
              plugin_options="$plugin_options,\"host-ghc-option=$cpp_option\""
            fi
          done < th-cross-cabal-cpp-options
        '';

      appendHostPackageIdsToPluginOptions =
        hostGhcPkg:
        hostPackageNames:
        pkgs.lib.concatMapStringsSep "\n" (packageName: ''
          host_package_id="$("${hostGhcPkg}" field ${pkgs.lib.escapeShellArg packageName} id --simple-output)"
          plugin_options="$plugin_options,\"host-package-id=$host_package_id\""
        '') hostPackageNames;

      appendUnitIdMapOptions =
        hostGhcPkg:
        ''
          ${hs.nixTools}/bin/dump-th-cross-unit-id-map-options \
            "${hostGhcPkg}" \
            "${targetGhcPkg}" \
            "$packageConfDir" \
            > th-cross-unit-id-map-options

          while IFS= read -r plugin_option; do
            if [ -n "$plugin_option" ]; then
              plugin_options="$plugin_options,\"$plugin_option\""
            fi
          done < th-cross-unit-id-map-options
        '';

      finalizePluginOptions =
        ''
          plugin_options="$plugin_options]"
        '';

      appendCrossPluginFlags =
        ''
          appendToVar configureFlags "--ghc-option=-v0"
          appendToVar configureFlags "--ghc-option=-fno-external-interpreter"
          appendToVar configureFlags "--ghc-option=-fforce-recomp"
          appendToVar configureFlags "--ghc-option=-fplugin-library=$plugin_so;$plugin_unit;THCross.Plugin;$plugin_options"
        '';

      mkConsumerDerivationWithWorker =
        hostPackageNames:
        args:
        let
          externalHostPackageNames =
            builtins.filter (packageName: packageName != args.pname) hostPackageNames;
          workerContext = mkWorkerWithHostPackages externalHostPackageNames;
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

              # Build the JSON-like option list passed as the fourth
              # `-fplugin-library` field. Each block appends one category of
              # cross/host context required by the plugin and worker.
              plugin_options="[\"worker=${workerContext.worker}\""
              ${appendHostPackageIdsToPluginOptions workerContext.hostGhcPkg externalHostPackageNames}
              ${appendUnitIdMapOptions workerContext.hostGhcPkg}
              ${appendCabalSourceDirsToPluginOptions}
              ${appendCabalCppOptionsToPluginOptions}
              ${finalizePluginOptions}
              ${appendCrossPluginFlags}
            '';
            postConfigure =
              pkgs.lib.concatStringsSep "\n" [
                (args.postConfigure or "")
                (cabalContextValidationScript externalHostPackageNames [ args.pname ])
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
                (cabalContextValidationScript expectedHostPackageNames [ args.pname ])
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
          expectedHostPackageNames =
            builtins.filter
              (packageName: packageName != basePackage.pname)
              (hostPackageNamesFromCabalDeps basePackage.getCabalDeps);
        in
        crossHaskellPkgs.callPackage packageFile {
          mkDerivation = mkCabalContextProbe expectedHostPackageNames;
        };
    in
    {
      targetContextConsumer =
        callPackageWithWorker ../../../nix/generated/th-target-context-consumer.nix;

      microlensConsumer =
        callPackageWithWorker ../../../nix/generated/th-microlens-consumer.nix;

      aesonConsumer =
        callPackageWithWorker ../../../nix/generated/th-aeson-consumer.nix;

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
    # Patched cross-GHC with -fplugin-library support.
    cross-ghc9103-aarch64-linux =
      crossGhc9103Aarch64;
    consumer-ghc9103-cross-target-context-package =
      genericBuilderPackages.targetContextConsumer;
    consumer-ghc9103-cross-microlens-package = genericBuilderPackages.microlensConsumer;
    consumer-ghc9103-cross-aeson-package = genericBuilderPackages.aesonConsumer;
    consumer-ghc9103-cross-microlens-cabal-context-probe =
      genericBuilderPackages.microlensConsumerCabalContextProbe;
    consumer-ghc9103-cross-executable-package = genericBuilderPackages.executableConsumer;
    consumer-ghc9103-cross-executable-qemu-smoke = genericBuilderPackages.executableConsumerQemuSmoke;
  };
}
