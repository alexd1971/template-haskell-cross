{ callPackage
, haskellLib
, th-cross-plugin
, th-host-worker
}:

haskellLib.overrideCabal
  (callPackage ./generated/th-consumer-example.nix { })
  (old: {
    libraryHaskellDepends = (old.libraryHaskellDepends or [ ]) ++ [
      th-cross-plugin
    ];
    buildFlags = (old.buildFlags or [ ]) ++ [
      "--ghc-options=-package=th-cross-plugin"
      "--ghc-options=-fplugin=THCross.Plugin"
      "--ghc-options=-fplugin-opt=THCross.Plugin:worker=${th-host-worker}/bin/th-host-worker"
    ];
    enableLibraryProfiling = false;
  })
