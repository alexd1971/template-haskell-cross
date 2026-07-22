{ mkDerivation
, base
, lib
, microlens
, microlens-th
}:

mkDerivation {
  pname = "th-microlens-consumer";
  version = "0.1.0.0";
  src = ../../prototype/th-microlens-consumer;
  isLibrary = true;
  isExecutable = false;
  libraryHaskellDepends = [
    base
    microlens
    microlens-th
  ];
  license = lib.licenses.bsd3;
}
