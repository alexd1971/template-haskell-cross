{ callPackage
, haskellLib
, hostGhcLibDir
, makeWrapper
, th-cross-plugin
}:

haskellLib.overrideCabal
  (callPackage ./generated/th-host-worker.nix {
    inherit th-cross-plugin;
  })
  (old: {
    buildTools = (old.buildTools or [ ]) ++ [
      makeWrapper
    ];
    postInstall = (old.postInstall or "") + ''
      wrapProgram "$out/bin/th-host-worker" \
        --set TH_HOST_GHC_LIBDIR "${hostGhcLibDir}"
    '';
  })
