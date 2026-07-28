{ mkDerivation, aeson, base, bytestring, lib, template-haskell }:
mkDerivation {
  pname = "cross-app";
  version = "0.1.0.0";
  src = ../..;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [ aeson base bytestring template-haskell ];
  executableHaskellDepends = [ aeson base bytestring ];
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
  mainProgram = "cross-app";
}
