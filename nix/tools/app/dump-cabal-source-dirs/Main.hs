-- | Print Cabal source directories from every component in the current package.
--
-- The cross experiment forwards these directories to the host worker so it can
-- load the same source modules that the target GHC is compiling.
import qualified Data.List as List
import Distribution.PackageDescription (BuildInfo (hsSourceDirs))
import Distribution.Utils.Path (getSymbolicPath)
import ThCross.NixTools.Cabal (dumpCabalField, extractFromAllComponents)

main :: IO ()
main =
  dumpCabalField (List.nub . filter (not . null) . map getSymbolicPath . extractFromAllComponents hsSourceDirs)
