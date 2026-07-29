{ mkDerivation, base, binary, bytestring, ghc, ghc-boot, ghci, lib
, template-haskell
}:
mkDerivation {
  pname = "th-cross-protocol";
  version = "0.1.0.0";
  src = ../../protocol;
  libraryHaskellDepends = [
    base binary bytestring ghc ghc-boot ghci template-haskell
  ];
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
}
