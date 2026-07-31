{ mkDerivation, base, lib, th-splice-dependency }:
mkDerivation {
  pname = "th-dependency-consumer";
  version = "0.1.0.0";
  src = ../..;
  libraryHaskellDepends = [ base th-splice-dependency ];
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
}
