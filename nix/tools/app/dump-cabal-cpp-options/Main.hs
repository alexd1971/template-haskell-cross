import qualified Data.List as List
import Distribution.PackageDescription (BuildInfo (cppOptions))
import ThCross.NixTools.Cabal (dumpCabalField, extractFromAllComponents)

main :: IO ()
main =
  dumpCabalField (List.nub . extractFromAllComponents cppOptions)
