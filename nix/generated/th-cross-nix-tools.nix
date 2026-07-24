{ mkDerivation, base, bytestring, Cabal, directory, filepath, lib
}:
mkDerivation {
  pname = "th-cross-nix-tools";
  version = "0.1.0.0";
  src = ../../nix/tools;
  isLibrary = false;
  isExecutable = true;
  libraryHaskellDepends = [
    base bytestring Cabal directory filepath
  ];
  executableHaskellDepends = [
    base bytestring Cabal directory filepath
  ];
  doHaddock = false;
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
}
