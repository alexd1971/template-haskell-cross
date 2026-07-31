{ mkDerivation, aeson, base, lib, template-haskell }:
mkDerivation {
  pname = "th-splice-dependency";
  version = "0.1.0.0";
  src = ../..;
  libraryHaskellDepends = [ aeson base template-haskell ];
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
}
