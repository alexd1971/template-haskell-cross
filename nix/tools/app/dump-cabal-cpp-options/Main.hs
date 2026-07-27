-- | Print Cabal CPP options from every component in the current package.
--
-- The cross experiment forwards these options to the host worker so its native
-- GHC session sees the same CPP-conditioned source as the target build.
import qualified Data.List as List
import Distribution.PackageDescription (BuildInfo (cppOptions))
import ThCross.NixTools.Cabal (dumpCabalField, extractFromAllComponents)

main :: IO ()
main =
  dumpCabalField (List.nub . extractFromAllComponents cppOptions)
