import qualified Data.List as List
import Distribution.PackageDescription (BuildInfo (hsSourceDirs))
import Distribution.Utils.Path (getSymbolicPath)
import ThCross.NixTools.Cabal (dumpCabalField, extractFromAllComponents)

main :: IO ()
main =
  dumpCabalField (List.nub . filter (not . null) . map getSymbolicPath . extractFromAllComponents hsSourceDirs)
