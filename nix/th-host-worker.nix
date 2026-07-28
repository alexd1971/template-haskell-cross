{ callPackage
, haskellLib
, hostGhc
, hostGhcLibDir
, makeWrapper
}:

haskellLib.overrideCabal
  (callPackage ./generated/th-host-worker.nix { })
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
