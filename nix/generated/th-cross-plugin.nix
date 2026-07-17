{ mkDerivation
, aeson
, base
, binary
, bytestring
, directory
, filepath
, ghc
, ghc-boot
, ghci
, lib
, process
, tasty
, tasty-hunit
}:

mkDerivation {
  pname = "th-cross-plugin";
  version = "0.1.0.0";
  src = ../../prototype/th-cross-plugin;
  isLibrary = true;
  isExecutable = false;
  libraryHaskellDepends = [
    aeson
    base
    binary
    bytestring
    ghc
    ghc-boot
    ghci
    process
  ];
  testHaskellDepends = [
    base
    directory
    filepath
    process
    tasty
    tasty-hunit
  ];
  license = lib.licenses.bsd3;
}
