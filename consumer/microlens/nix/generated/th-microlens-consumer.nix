{ mkDerivation, base, lib, microlens, microlens-th }:
mkDerivation {
  pname = "th-microlens-consumer";
  version = "0.1.0.0";
  src = ../..;
  libraryHaskellDepends = [ base microlens microlens-th ];
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
}
