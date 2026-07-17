{ mkDerivation
, base
, lib
}:

mkDerivation {
  pname = "th-consumer-example";
  version = "0.1.0.0";
  src = ../../prototype/th-consumer-example;
  isLibrary = true;
  isExecutable = false;
  libraryHaskellDepends = [
    base
  ];
  license = lib.licenses.bsd3;
}
