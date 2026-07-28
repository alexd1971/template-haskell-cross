{ pkgs, hs, crossGhc9103Aarch64 }:

let
  # Read the native plugin package metadata in the same vocabulary GHC uses.
  # `-fplugin-library` still wants a concrete shared object path, so derive it
  # from `hs-libraries` plus the first `dynamic-library-dirs` entry.
  pluginLibraryMetadataScript =
    { pluginLibDir
    , nativeGhcPkg
    , targetPluginGhcVersion
    }:
    ''
      plugin_pkg_db="${pluginLibDir}/lib/package.conf.d"
      plugin_unit=$("${nativeGhcPkg}" --package-db="$plugin_pkg_db" field th-cross-plugin id --simple-output 2>/dev/null)
      plugin_hs_library=$("${nativeGhcPkg}" --package-db="$plugin_pkg_db" field th-cross-plugin hs-libraries --simple-output 2>/dev/null)
      plugin_dynamic_library_dirs=$("${nativeGhcPkg}" --package-db="$plugin_pkg_db" field th-cross-plugin dynamic-library-dirs --simple-output 2>/dev/null)
      set -- $plugin_dynamic_library_dirs
      plugin_so="$1/lib''${plugin_hs_library}-ghc${targetPluginGhcVersion}.so"
      plugin_library_path=$(printf '%s\n' $plugin_dynamic_library_dirs | paste -sd:)
    '';

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

  mkCrossHaskellPkgs =
    { crossPkgs
    , crossGhc
    }:
    crossPkgs.callPackage (pkgs.path + "/pkgs/development/haskell-modules") {
      haskellLib = pkgs.haskell.lib.compose;
      buildHaskellPackages = pkgs.haskell.packages.ghc9103;
      ghc = crossGhc;
      compilerConfig =
        crossPkgs.callPackage
          (pkgs.path + "/pkgs/development/haskell-modules/configuration-ghc-9.10.x.nix")
          {
            haskellLib = pkgs.haskell.lib.compose;
          };
    };

  mkWorkerWithHostPackages =
    hostPackageNames:
    if hostPackageNames == [ ] then
      {
        worker = "${hs.hostGhc9103HaskellPkgs.th-host-worker}/bin/th-host-worker";
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

      ${hs.nixTools}/bin/th-cross-nix-tool \
        validate-cabal-component-context \
        "$expected_packages" \
        "$excluded_packages" \
        "$out/nix-support"
    '';

  generatePluginConfig =
    { worker
    , hostGhcPkg
    , targetGhcPkg
    , hostPackageNames
    }:
    ''
      ${hs.nixTools}/bin/th-cross-nix-tool \
        plugin-config \
        th-cross-plugin-options \
        "${worker}" \
        "${hostGhcPkg}" \
        "${targetGhcPkg}" \
        "$packageConfDir" \
        ${pkgs.lib.concatMapStringsSep " " pkgs.lib.escapeShellArg hostPackageNames}
    '';

  appendCrossPluginFlags =
    ''
      appendToVar configureFlags "--ghc-option=-v0"
      appendToVar configureFlags "--ghc-option=-fno-external-interpreter"
      appendToVar configureFlags "--ghc-option=-fforce-recomp"
      appendToVar configureFlags "--ghc-option=-fplugin-library=$plugin_so;$plugin_unit;THCross.Plugin;[\"config=$PWD/th-cross-plugin-options\"]"
    '';

  mkWorkerEnabledPackageSet =
    { crossPkgs
    , crossGhc
    , targetGhcPkg
    , targetPlugin
    , nativeGhcPkg
    , targetPluginGhcVersion
    }:
    let
      crossHaskellPkgs =
        mkCrossHaskellPkgs {
          inherit crossPkgs crossGhc;
        };

      pluginLibDir = "${targetPlugin}/lib/ghc-${targetPluginGhcVersion}";

      mkDerivationWithWorker =
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
                inherit pluginLibDir nativeGhcPkg targetPluginGhcVersion;
              }}

              # The external plugin is loaded into the cross-GHC process by the
              # host dynamic linker, so its transitive Haskell shared libraries
              # must be discoverable at plugin load time.
              export LD_LIBRARY_PATH="$plugin_library_path''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

              # Keep the `-fplugin-library` option short and stable. The helper
              # derives the worker, host package ids, unit-id map, source dirs,
              # and CPP options into one config file.
              ${generatePluginConfig {
                inherit targetGhcPkg;
                hostPackageNames = externalHostPackageNames;
                inherit (workerContext) worker hostGhcPkg;
              }}
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
          mkDerivation = mkDerivationWithWorker hostPackageNames;
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
      inherit
        crossHaskellPkgs
        hostPackageNamesFromCabalDeps
        mkDerivationWithWorker
        mkCabalContextProbe
        callPackageWithWorker
        callPackageCabalContextProbe
        ;
    };

  ghc9103Aarch64Linux =
    mkWorkerEnabledPackageSet {
      crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;
      crossGhc = crossGhc9103Aarch64;
      targetGhcPkg = "${crossGhc9103Aarch64}/bin/aarch64-unknown-linux-gnu-ghc-pkg";
      targetPlugin = hs.targetGhc9103HaskellPkgs.th-cross-plugin;
      nativeGhcPkg = "${pkgs.haskell.compiler.ghc9103}/bin/ghc-pkg";
      targetPluginGhcVersion = "9.10.3";
    };
in
{
  inherit
    ghc9103Aarch64Linux
    hostPackageNamesFromCabalDeps
    mkWorkerWithHostPackages
    mkWorkerEnabledPackageSet
    ;
}
