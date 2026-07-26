{ callPackage
, haskellLib
, hostGhc
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
    configureFlags = (old.configureFlags or [ ]) ++ [
      "--with-ghc=${hostGhc}/bin/ghc"
      "--with-ghc-pkg=${hostGhc}/bin/ghc-pkg"
    ];
    postInstall = (old.postInstall or "") + ''
      wrapProgram "$out/bin/th-host-worker" \
        --set TH_HOST_GHC_LIBDIR "${hostGhcLibDir}"
    '';
  })
