{ pkgs, compilerSets }:

let
  # `compilerSets` is this project's compiler registry from
  # `haskell-pkgs.nix`: supported GHC profiles plus patched worker GHC,
  # host worker package sets, target plugin builds, and helper tools. It is
  # intentionally distinct from nixpkgs' generic `haskellPackages`.

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

  buildDependencyFields = [
    "libraryHaskellDepends"
    "executableHaskellDepends"
  ];

  # Packages shipped with GHC are already visible through the compiler package
  # DB. nixpkgs does not always expose them as ordinary Haskell derivations with
  # `pname`, so they are not part of the worker `ghcWithPackages` environment
  # and should not be compared as external host dependencies.
  compilerBundledPackageNames = [
    "Cabal"
    "Cabal-syntax"
    "array"
    "base"
    "binary"
    "bytestring"
    "containers"
    "deepseq"
    "directory"
    "exceptions"
    "filepath"
    "ghc"
    "ghc-bignum"
    "ghc-boot"
    "ghc-boot-th"
    "ghc-compact"
    "ghc-experimental"
    "ghc-heap"
    "ghc-internal"
    "ghc-platform"
    "ghc-prim"
    "ghc-toolchain"
    "ghci"
    "haskeline"
    "hpc"
    "integer-gmp"
    "mtl"
    "os-string"
    "parsec"
    "pretty"
    "process"
    "rts"
    "semaphore-compat"
    "stm"
    "template-haskell"
    "terminfo"
    "text"
    "time"
    "transformers"
    "unix"
    "xhtml"
  ];

  componentHaskellDependsFromCabalDeps =
    fields:
    cabalDeps:
    pkgs.lib.concatMap
      (field: cabalDeps.${field} or [ ])
      fields;

  dependencyPackageNames =
    dependencies:
    map
      (dependency:
        if dependency == null then
          null
        else
          dependency.pname or null)
      dependencies;

  hasBuildDependency =
    packageName:
    args:
    builtins.elem packageName
      (dependencyPackageNames (componentHaskellDependsFromCabalDeps buildDependencyFields args));

  # nixpkgs Haskell derivations expose their Cabal dependency fields through
  # `passthru.getCabalDeps`. Use dependency `pname`, not the full derivation
  # name, as the key for the corresponding host package set.
  hostPackageNamesFromCabalDeps =
    cabalDeps:
    pkgs.lib.unique
      (builtins.filter
        (packageName:
          packageName != null
          && !(builtins.elem packageName compilerBundledPackageNames))
        (map
          (dependency:
            if dependency == null then
              null
            else
              dependency.pname)
          (componentHaskellDependsFromCabalDeps componentDependencyFields cabalDeps)));

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

        # ansi-terminal-types-1.1.3 marks modules as Safe while importing
        # `colour`, which does not expose a Safe module. This is reached through
        # aeson -> vector -> tasty in the target dependency graph.
        ansi-terminal-types =
          pkgs.haskell.lib.overrideCabal super.ansi-terminal-types (old: {
            postPatch = (old.postPatch or "") + ''
              sed -i '/{-# LANGUAGE Safe/d' src/System/Console/ANSI/Types.hs
              sed -i '/{-# LANGUAGE Safe/d' src/System/Console/ANSI/Codes.hs
            '';
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
    hostPackages:
    if hostPackages == [ ] then
      {
        worker = "${compiler.hostWorker}/bin/th-host-worker";
        hostGhcPkg = "${compiler.patchedGhc}/bin/ghc-pkg";
      }
    else
      let
        hostGhcWithPackages =
          compiler.hostHaskellPkgs.ghcWithPackages
            (_: hostPackages);
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
${pkgs.lib.concatStringsSep "\n" compilerBundledPackageNames}
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
      # Base target package set with target-profile policy only. Use this when
      # constructing derivations that must not recursively inject the TH plugin.
      rawCrossHaskellPkgs =
        mkCrossHaskellPkgs {
          inherit crossPkgs crossGhc targetProfile;
          profile = compilerSets.compilerProfiles.${compiler.packageSetName};
        };

      pluginLibDir = "${targetPlugin}/lib/ghc-${targetPluginGhcVersion}";

      hostPackageNamesFromDerivationArgs =
        args:
        # Automatic wrapping is applied to every target dependency package.
        # Tests and benchmarks are disabled for those packages, so do not force
        # their dependency fields during Nix evaluation; some packages have
        # broken test-only dependencies in nixpkgs.
        pkgs.lib.unique
          (builtins.filter
            (packageName:
              packageName != null
              && !(builtins.elem packageName compilerBundledPackageNames))
            (map
              (dependency:
                if dependency == null then
                  null
                else
                  dependency.pname or null)
              (componentHaskellDependsFromCabalDeps buildDependencyFields args)));

      mkDerivationWithWorkerConfig =
        localHostPackages:
        hostPackageNames:
        validateCabalContext:
        args:
        let
          buildArgs =
            args
            // pkgs.lib.optionalAttrs (!validateCabalContext) {
              testHaskellDepends = [ ];
              benchmarkHaskellDepends = [ ];
            };
          externalHostPackageNames =
            builtins.filter (packageName: packageName != buildArgs.pname) hostPackageNames;
          workerHostPackages =
            builtins.filter
              (package: package != null)
              (map
                (packageName:
                  if builtins.hasAttr packageName localHostPackages then
                    localHostPackages.${packageName}
                  else if builtins.hasAttr packageName compiler.hostHaskellPkgs then
                    compiler.hostHaskellPkgs.${packageName}
                  else
                    null)
                externalHostPackageNames);
          workerContext = mkWorkerWithHostPackages compiler workerHostPackages;
        in
        rawCrossHaskellPkgs.mkDerivation
          (buildArgs // {
            doCheck = false;
            doHaddock = false;
            doHoogle = false;
            enableExternalInterpreter = false;
            enableLibraryProfiling = false;
            preConfigure = (buildArgs.preConfigure or "") + ''

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
                hostPackageNames = map (package: package.pname) workerHostPackages;
                inherit (workerContext) worker hostGhcPkg;
              }}
              ${appendCrossPluginFlags}
            '';
            postConfigure =
              (buildArgs.postConfigure or "")
              # Run the Cabal graph validation only for explicitly wrapped
              # final packages. Dependency packages still get the plugin hook,
              # but validating every transitive dependency would add overhead
              # without improving the final package's worker context.
              + pkgs.lib.optionalString validateCabalContext ''
                ${cabalContextValidationScript compiler.nixTools externalHostPackageNames [ buildArgs.pname ]}
              '';
          });

      mkDerivationWithWorker =
        localHostPackages:
        hostPackageNames:
        mkDerivationWithWorkerConfig localHostPackages hostPackageNames true;

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
        # Public target package set. Packages that directly depend on
        # `template-haskell` get the remote-TH plugin hook automatically; other
        # transitive dependencies stay on the raw target builder to avoid
        # changing large non-TH dependency graphs such as vector/tasty.
        rawCrossHaskellPkgs.override {
          overrides = _: _: {
            mkDerivation = args:
              if hasBuildDependency "template-haskell" args then
                mkDerivationWithWorkerConfig
                  { }
                  (hostPackageNamesFromDerivationArgs args)
                  false
                  args
              else
                rawCrossHaskellPkgs.mkDerivation args;
          };
        };

      buildPackage =
        { packageFile
        , packageArgs ? { }
        , localPackages ? { }
        , derivationArgs ? { }
        }:
        let
          mkLocalPackages = packageSet:
            let
              localPackageOutputs =
                pkgs.lib.mapAttrs
                  (_: localPackage:
                    let
                      packageArguments = builtins.functionArgs (import localPackage.packageFile);
                      localDependencyArguments =
                        pkgs.lib.filterAttrs
                          (packageName: _: builtins.hasAttr packageName packageArguments)
                          localPackageOutputs;
                    in
                    packageSet.callPackage
                      localPackage.packageFile
                      ((localPackage.packageArgs or { }) // localDependencyArguments))
                  localPackages;
            in
            localPackageOutputs;

          targetLocalPackages = mkLocalPackages crossHaskellPkgs;
          hostLocalPackages = mkLocalPackages compiler.hostHaskellPkgs;
          targetPackageArgs = packageArgs // targetLocalPackages;
          basePackage = crossHaskellPkgs.callPackage packageFile targetPackageArgs;
          hostPackageNames = hostPackageNamesFromCabalDeps basePackage.getCabalDeps;
        in
        crossHaskellPkgs.callPackage packageFile
          (targetPackageArgs // {
            # Consumers may need a build-time environment variable or hook for
            # their final derivation. Merge it here so it also reaches the
            # worker-enabled builder rather than bypassing the TH plugin.
            mkDerivation = args:
              mkDerivationWithWorker hostLocalPackages hostPackageNames
                (args // derivationArgs);
          });

      checkCabalContext =
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
        buildPackage
        checkCabalContext
        ;
    };

  targetProfiles = import ./target-profiles.nix { inherit pkgs; };
  supportedGhcVersions =
    pkgs.lib.sort pkgs.lib.versionOlder
      (map (profile: profile.version) (builtins.attrValues compilerSets.compilerProfiles));
  supportedTargets = builtins.attrNames targetProfiles;

  mkCrossFor =
    { ghcVersion
    , target ? "aarch64-linux"
    }:
    let
      compiler = compilerSets.mkCompilerForVersion ghcVersion;
      compilerProfile = compilerSets.compilerProfiles.${compiler.packageSetName};
      targetProfile = targetProfiles.${target}
        or (throw "Unsupported TH cross target ${target}; add it to nix/flake/target-profiles.nix");
      inherit (targetProfile) crossPkgs targetName targetTriple;
      crossGhc = import ./mk-cross-ghc.nix {
        profile = compilerProfile;
        inherit crossPkgs targetName targetTriple;
        bootPkgs = pkgs.haskell.packages.${compiler.packageSetName};
      };
    in
    (mkWorkerEnabledPackageSet {
      inherit crossPkgs crossGhc compiler targetProfile;
      targetGhcPkg = "${crossGhc}/bin/${targetTriple}-ghc-pkg";
      targetPlugin = compiler.targetPlugin;
      nativeGhcPkg = "${pkgs.haskell.compiler.${compiler.packageSetName}}/bin/ghc-pkg";
      targetPluginGhcVersion = compiler.version;
    })
    // {
      # Embedding integrations may need target compiler runtime artifacts.
      # Selecting and packaging them is integration policy, not th-cross.
      targetGhc = crossGhc;
    };
in
{
  inherit
    mkCrossFor
    supportedGhcVersions
    supportedTargets
    ;

  # Non-API escape hatch for repository maintenance and diagnostics. External
  # consumers should use `mkCrossFor` plus the returned `buildPackage` helpers.
  internal = {
    inherit (compilerSets)
      compilerProfiles
      mkCompilerForVersion
      compilers
      ;
  };
}
