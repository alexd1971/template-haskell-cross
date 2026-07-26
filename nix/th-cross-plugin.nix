{ callPackage
, haskellLib
, hostGhc
}:

haskellLib.dontCheck
  (haskellLib.overrideCabal
    (callPackage ./generated/th-cross-plugin.nix { })
    (old: {
      configureFlags = (old.configureFlags or [ ]) ++ [
        "--with-ghc=${hostGhc}/bin/ghc"
        "--with-ghc-pkg=${hostGhc}/bin/ghc-pkg"
      ];
    }))
