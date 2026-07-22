{ mkDerivation
, base
, lib
, template-haskell
}:

mkDerivation {
  pname = "th-consumer-example";
  version = "0.1.0.0";
  src = ../../prototype/th-consumer-example;
  isLibrary = true;
  isExecutable = false;
  libraryHaskellDepends = [
    base
    template-haskell
  ];
  license = lib.licenses.bsd3;
}
