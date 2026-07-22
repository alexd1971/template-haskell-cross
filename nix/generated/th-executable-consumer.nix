{ mkDerivation
, base
, lib
, microlens
, microlens-th
}:

mkDerivation {
  pname = "th-executable-consumer";
  version = "0.1.0.0";
  src = ../../prototype/th-executable-consumer;
  isLibrary = false;
  isExecutable = true;
  executableHaskellDepends = [
    base
    microlens
    microlens-th
  ];
  license = lib.licenses.bsd3;
}
