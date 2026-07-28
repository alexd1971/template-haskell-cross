{ mkDerivation, base, lib, microlens, microlens-th
, template-haskell
}:
mkDerivation {
  pname = "th-executable-consumer";
  version = "0.1.0.0";
  src = ../../consumer/executable;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [ base microlens-th template-haskell ];
  executableHaskellDepends = [ base microlens ];
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
  mainProgram = "th-executable-consumer";
}
