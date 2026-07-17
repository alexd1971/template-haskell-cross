{ mkDerivation
, base
, binary
, bytestring
, containers
, directory
, filepath
, ghc
, ghc-boot
, ghci
, lib
, process
, th-cross-plugin
}:

mkDerivation {
  pname = "th-host-worker";
  version = "0.1.0.0";
  src = ../../prototype/th-host-worker;
  isLibrary = false;
  isExecutable = true;
  executableHaskellDepends = [
    base
    binary
    bytestring
    containers
    directory
    filepath
    ghc
    ghc-boot
    ghci
    process
    th-cross-plugin
  ];
  license = lib.licenses.bsd3;
}
