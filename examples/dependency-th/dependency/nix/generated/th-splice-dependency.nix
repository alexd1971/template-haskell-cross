{ mkDerivation, base, lib, template-haskell }:
mkDerivation {
  pname = "th-splice-dependency";
  version = "0.1.0.0";
  src = ../..;
  libraryHaskellDepends = [ base template-haskell ];
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
}
