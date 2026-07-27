{ mkDerivation, aeson, base, lib, template-haskell }:
mkDerivation {
  pname = "th-aeson-consumer";
  version = "0.1.0.0";
  src = ../../prototype/th-aeson-consumer;
  libraryHaskellDepends = [ aeson base template-haskell ];
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
}
