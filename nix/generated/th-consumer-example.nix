{ mkDerivation, base, lib, template-haskell }:
mkDerivation {
  pname = "th-consumer-example";
  version = "0.1.0.0";
  src = ../../prototype/th-consumer-example;
  libraryHaskellDepends = [ base template-haskell ];
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
}
