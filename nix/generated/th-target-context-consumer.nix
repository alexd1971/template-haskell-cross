{ mkDerivation, base, lib, template-haskell }:
mkDerivation {
  pname = "th-target-context-consumer";
  version = "0.1.0.0";
  src = ../../consumer/target-context;
  libraryHaskellDepends = [ base template-haskell ];
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
}
