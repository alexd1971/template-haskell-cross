{ mkDerivation, base, bytestring, Cabal, Cabal-syntax, directory
, filepath, lib, process
}:
mkDerivation {
  pname = "th-cross-nix-tools";
  version = "0.1.0.0";
  src = ../../nix/tools;
  isLibrary = false;
  isExecutable = true;
  libraryHaskellDepends = [
    base bytestring Cabal Cabal-syntax directory filepath process
  ];
  executableHaskellDepends = [
    base bytestring Cabal Cabal-syntax directory filepath
  ];
  doHaddock = false;
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
  mainProgram = "th-cross-nix-tool";
}
