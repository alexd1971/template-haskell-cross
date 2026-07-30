let
  patches = {
    exportRunTH = ../patches/export-runth.patch;
    forceCompilerInternalInterpreter = ../patches/force-compiler-internal-interpreter.patch;
    ignoreEmptyTHFinalizers = ../patches/ignore-empty-th-finalizers.patch;
  };

  mkGhcProfile =
    { version
    , packageSetName
    , compilerConfigFile
    , workerPatchNames
    , crossPatchNames ? []
    , jailbreak ? false
    , includeTargetContextConsumer ? false
    }:
    {
      inherit
        version
        packageSetName
        compilerConfigFile
        jailbreak
        includeTargetContextConsumer
        ;

      workerPatches = map (name: patches.${name}) workerPatchNames;
      crossPatches = map (name: patches.${name}) crossPatchNames;
    };
in
{
  ghc984 = mkGhcProfile {
    version = "9.8.4";
    packageSetName = "ghc984";
    compilerConfigFile = "configuration-ghc-9.8.x.nix";
    workerPatchNames = [ "exportRunTH" ];
    crossPatchNames = [
      "forceCompilerInternalInterpreter"
      "ignoreEmptyTHFinalizers"
    ];
  };

  ghc9103 = mkGhcProfile {
    version = "9.10.3";
    packageSetName = "ghc9103";
    compilerConfigFile = "configuration-ghc-9.10.x.nix";
    workerPatchNames = [ "exportRunTH" ];
    crossPatchNames = [
      "forceCompilerInternalInterpreter"
      "ignoreEmptyTHFinalizers"
    ];
    includeTargetContextConsumer = true;
  };

  ghc9124 = mkGhcProfile {
    version = "9.12.4";
    packageSetName = "ghc9124";
    compilerConfigFile = "configuration-ghc-9.12.x.nix";
    workerPatchNames = [ "exportRunTH" ];
    crossPatchNames = [
      "forceCompilerInternalInterpreter"
      "ignoreEmptyTHFinalizers"
    ];
  };
}
