{ mkDerivation, base, binary, bytestring, containers, directory
, filepath, ghc, ghc-boot, ghci, lib, process, template-haskell
, th-cross-protocol
}:
mkDerivation {
  pname = "th-host-worker";
  version = "0.1.0.0";
  src = ../../worker;
  isLibrary = false;
  isExecutable = true;
  executableHaskellDepends = [
    base binary bytestring containers directory filepath ghc ghc-boot
    ghci process template-haskell th-cross-protocol
  ];
  license = lib.meta.getLicenseFromSpdxId "BSD-3-Clause";
  mainProgram = "th-host-worker";
}
