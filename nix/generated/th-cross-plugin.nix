{ mkDerivation, base, binary, bytestring, directory
, filepath, ghc, ghc-boot, ghci, lib, process, tasty, tasty-hunit
, template-haskell, th-cross-protocol
}:
mkDerivation {
  pname = "th-cross-plugin";
  version = "0.1.0.0";
  src = ../../plugin;
  libraryHaskellDepends = [
    base binary bytestring ghc ghc-boot ghci process template-haskell
    th-cross-protocol
  ];
  testHaskellDepends = [
    base directory filepath process tasty tasty-hunit
  ];
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
}
