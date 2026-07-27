{ mkDerivation, aeson, base, lib }:
mkDerivation {
  pname = "th-aeson-consumer";
  version = "0.1.0.0";
  src = ../../prototype/th-aeson-consumer;
  libraryHaskellDepends = [ aeson base ];
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
}
