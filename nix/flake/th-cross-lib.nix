{ pkgs, compilerSets }:

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
    , profile
    , targetProfile
    }:
    let
      baseHaskellPkgs =
        crossPkgs.callPackage (pkgs.path + "/pkgs/development/haskell-modules") {
          haskellLib = pkgs.haskell.lib.compose;
          buildHaskellPackages = pkgs.haskell.packages.${profile.packageSetName};
          ghc = crossGhc;
          compilerConfig =
            crossPkgs.callPackage
              (pkgs.path + "/pkgs/development/haskell-modules/${profile.compilerConfigFile}")
              {
                haskellLib = pkgs.haskell.lib.compose;
              };
        };

      baseOverrides = _: super: {
        # TH execution is handled by th-host-worker, not by nixpkgs iserv-proxy.
        # Disable the default cross-package-set iserv path to avoid pulling
        # emulators such as qemu-user into target dependency builds.
        mkDerivation = args:
          super.mkDerivation
            (args // {
              enableExternalInterpreter = false;
            });
      };

      targetOverrides =
        targetProfile.haskellPackageOverrides or (_: _: { });
    in
    baseHaskellPkgs.override {
      overrides =
        pkgs.lib.composeExtensions
          baseOverrides
          targetOverrides;
    };

  mkWorkerWithHostPackages =
    compiler:
    hostPackageNames:
    if hostPackageNames == [ ] then
      {
        worker = "${compiler.hostWorker}/bin/th-host-worker";
        hostGhcPkg = "${compiler.patchedGhc}/bin/ghc-pkg";
      }
    else
      let
        hostGhcWithPackages =
          compiler.hostHaskellPkgs.ghcWithPackages
            (hpkgs: map (packageName: hpkgs.${packageName}) hostPackageNames);
      in
      {
        worker = "${pkgs.runCommand
          "th-host-worker-ghc${pkgs.lib.replaceStrings [ "." ] [ "" ] compiler.version}-with-host-packages"
        {
          nativeBuildInputs = [
            pkgs.makeWrapper
          ];
        }
        ''
          mkdir -p "$out/bin"
          makeWrapper \
            ${compiler.hostWorker}/bin/.th-host-worker-wrapped \
            "$out/bin/th-host-worker" \
            --set TH_HOST_GHC_LIBDIR "${hostGhcWithPackages}/lib/ghc-${compiler.version}/lib"
        ''}/bin/th-host-worker";
        hostGhcPkg = "${hostGhcWithPackages}/bin/ghc-pkg";
      };

  cabalContextValidationScript =
    nixTools:
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

      ${nixTools}/bin/th-cross-nix-tool \
        validate-cabal-component-context \
        "$expected_packages" \
        "$excluded_packages" \
        "$out/nix-support"
    '';

  generatePluginConfig =
    { nixTools
    , worker
    , hostGhcPkg
    , targetGhcPkg
    , hostPackageNames
    }:
    ''
      ${nixTools}/bin/th-cross-nix-tool \
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
    , compiler
    , targetGhcPkg
    , targetPlugin
    , nativeGhcPkg
    , targetPluginGhcVersion
    , targetProfile
    }:
    let
      rawCrossHaskellPkgs =
        mkCrossHaskellPkgs {
          inherit crossPkgs crossGhc targetProfile;
          profile = compilerSets.compilerProfiles.${compiler.packageSetName};
        };

      pluginLibDir = "${targetPlugin}/lib/ghc-${targetPluginGhcVersion}";

      hostPackageNamesFromDerivationArgs =
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
                  dependency.pname or null)
              (componentHaskellDependsFromCabalDeps args)));

      mkDerivationWithWorkerConfig =
        hostPackageNames:
        validateCabalContext:
        args:
        let
          externalHostPackageNames =
            builtins.filter (packageName: packageName != args.pname) hostPackageNames;
          workerHostPackageNames =
            builtins.filter
              (packageName: builtins.hasAttr packageName compiler.hostHaskellPkgs)
              externalHostPackageNames;
          workerContext = mkWorkerWithHostPackages compiler workerHostPackageNames;
        in
        rawCrossHaskellPkgs.mkDerivation
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
                nixTools = compiler.nixTools;
                hostPackageNames = workerHostPackageNames;
                inherit (workerContext) worker hostGhcPkg;
              }}
              ${appendCrossPluginFlags}
            '';
            postConfigure =
              (args.postConfigure or "")
              + pkgs.lib.optionalString validateCabalContext ''
                ${cabalContextValidationScript compiler.nixTools externalHostPackageNames [ args.pname ]}
              '';
          });

      mkDerivationWithWorker =
        hostPackageNames:
        mkDerivationWithWorkerConfig hostPackageNames true;

      mkCabalContextProbe =
        expectedHostPackageNames:
        args:
        rawCrossHaskellPkgs.mkDerivation
          (args // {
            doCheck = false;
            doHaddock = false;
            doHoogle = false;
            enableLibraryProfiling = false;
            postConfigure =
              pkgs.lib.concatStringsSep "\n" [
                (args.postConfigure or "")
                (cabalContextValidationScript compiler.nixTools expectedHostPackageNames [ args.pname ])
              ];
          });

      crossHaskellPkgs =
        rawCrossHaskellPkgs.override {
          overrides = _: _: {
            mkDerivation = args:
              mkDerivationWithWorkerConfig
                (hostPackageNamesFromDerivationArgs args)
                false
                args;
          };
        };

      callPackageWithWorkerArgs =
        packageFile:
        packageArgs:
        let
          basePackage = crossHaskellPkgs.callPackage packageFile packageArgs;
          hostPackageNames = hostPackageNamesFromCabalDeps basePackage.getCabalDeps;
        in
        crossHaskellPkgs.callPackage packageFile
          (packageArgs // {
            mkDerivation = mkDerivationWithWorker hostPackageNames;
          });

      callPackageWithWorker =
        packageFile:
        callPackageWithWorkerArgs packageFile { };

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

      buildPackageWith = callPackageWithWorkerArgs;

      buildPackage = packageFile: buildPackageWith packageFile { };

      checkCabalContext = callPackageCabalContextProbe;
    in
    {
      inherit
        crossHaskellPkgs
        rawCrossHaskellPkgs
        hostPackageNamesFromCabalDeps
        hostPackageNamesFromDerivationArgs
        mkDerivationWithWorker
        mkCabalContextProbe
        buildPackageWith
        buildPackage
        checkCabalContext
        callPackageWithWorkerArgs
        callPackageWithWorker
        callPackageCabalContextProbe
        ;
    };

  targetProfiles = import ./target-profiles.nix { inherit pkgs; };

  mkCrossFor =
    { ghcVersion
    , target ? "aarch64-linux"
    }:
    let
      compiler = compilerSets.mkCompilerForVersion ghcVersion;
      compilerProfile = compilerSets.compilerProfiles.${compiler.packageSetName};
      targetProfile = targetProfiles.${target}
        or (throw "Unsupported TH cross target ${target}; add it to targetProfiles in nix/flake/th-cross-lib.nix");
      inherit (targetProfile) crossPkgs targetName targetTriple;
      crossGhc = import ./mk-cross-ghc.nix {
        profile = compilerProfile;
        inherit crossPkgs targetName targetTriple;
        bootPkgs = pkgs.haskell.packages.${compiler.packageSetName};
      };
    in
    mkWorkerEnabledPackageSet {
      inherit crossPkgs crossGhc compiler targetProfile;
      targetGhcPkg = "${crossGhc}/bin/${targetTriple}-ghc-pkg";
      targetPlugin = compiler.targetPlugin;
      nativeGhcPkg = "${pkgs.haskell.compiler.${compiler.packageSetName}}/bin/ghc-pkg";
      targetPluginGhcVersion = compiler.version;
    };

  mkAarch64LinuxForVersion = version:
    mkCrossFor {
      ghcVersion = version;
      target = "aarch64-linux";
    };

  ghc9103Aarch64Linux =
    mkAarch64LinuxForVersion "9.10.3";
in
{
  inherit
    ghc9103Aarch64Linux
    targetProfiles
    mkCrossFor
    mkAarch64LinuxForVersion
    hostPackageNamesFromCabalDeps
    mkWorkerWithHostPackages
    mkWorkerEnabledPackageSet
    ;
}
