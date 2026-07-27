-- | Entry point for Nix-side helpers used by TH cross experiments.
import System.Environment (getArgs)
import System.Exit (die)
import ThCross.NixTools.PluginConfig (writePluginConfig)
import ThCross.NixTools.Validate (validateCabalComponentContext)

main :: IO ()
main = do
  args <- getArgs
  case args of
    "plugin-config" : outputFile : worker : hostGhcPkg : targetGhcPkg : targetPackageDb : hostPackageNames ->
      writePluginConfig outputFile worker hostGhcPkg targetGhcPkg targetPackageDb hostPackageNames
    ["validate-cabal-component-context", expectedPackagesFile, excludedPackagesFile, outputDir] ->
      validateCabalComponentContext expectedPackagesFile excludedPackagesFile outputDir
    _ ->
      die $
        unlines
          [ "usage:"
          , "  th-cross-nix-tool plugin-config OUTPUT WORKER HOST_GHC_PKG TARGET_GHC_PKG TARGET_PACKAGE_DB [HOST_PACKAGE_NAME...]"
          , "  th-cross-nix-tool validate-cabal-component-context EXPECTED_PACKAGES EXCLUDED_PACKAGES OUTPUT_DIR"
          ]
