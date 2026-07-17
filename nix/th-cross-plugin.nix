{ callPackage
, haskellLib
}:

haskellLib.dontCheck
  (callPackage ./generated/th-cross-plugin.nix { })
