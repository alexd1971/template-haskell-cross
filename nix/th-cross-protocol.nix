{ callPackage
, haskellLib
, hostGhc
}:

haskellLib.overrideCabal
  (callPackage ./generated/th-cross-protocol.nix { })
  (old: {
    configureFlags = (old.configureFlags or [ ]) ++ [
      "--with-ghc=${hostGhc}/bin/ghc"
      "--with-ghc-pkg=${hostGhc}/bin/ghc-pkg"
    ];
  })
