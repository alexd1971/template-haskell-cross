-- | Validate Nix-derived host package names against Cabal's configured
-- component dependency graph.
--
-- This catches cases where the worker package DB assembled at Nix evaluation
-- time no longer matches the dependencies Cabal actually selected during
-- `Setup configure`.
import Control.Monad (unless)
import Data.List (intercalate, nub, sort)
import Distribution.Simple.Configure (getPersistBuildConfig)
import Distribution.Simple.LocalBuildInfo (allComponentsInBuildOrder)
import Distribution.Types.ComponentLocalBuildInfo
  ( componentLocalName
  , componentPackageDeps
  )
import Distribution.Types.ComponentName (showComponentName)
import Distribution.Types.MungedPackageId
  ( MungedPackageId
  , mungedName
  )
import Distribution.Types.MungedPackageName (encodeCompatPackageName)
import Distribution.Types.PackageName (unPackageName)
import Distribution.Types.UnitId
  ( UnitId
  , unUnitId
  )
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath ((</>))

data ComponentDependency = ComponentDependency
  { dependencyPackageName :: String
  , dependencyUnitId :: String
  }

main :: IO ()
main = do
  args <- getArgs
  case args of
    [expectedPackagesFile, excludedPackagesFile, outputDir] ->
      validateCabalComponentContext expectedPackagesFile excludedPackagesFile outputDir
    _ ->
      die "usage: validate-cabal-component-context EXPECTED_PACKAGES EXCLUDED_PACKAGES OUTPUT_DIR"

validateCabalComponentContext :: FilePath -> FilePath -> FilePath -> IO ()
validateCabalComponentContext expectedPackagesFile excludedPackagesFile outputDir = do
  createDirectoryIfMissing True outputDir
  components <- cabalComponentDependencies
  expectedPackages <- normalizedLines <$> readFile expectedPackagesFile
  excludedPackages <- normalizedLines <$> readFile excludedPackagesFile
  let actualPackages =
        sort $
          filter (`notElem` excludedPackages) $
            nub (map dependencyPackageName (concatMap snd components))
      diffText =
        renderPackageDiff expectedPackages actualPackages

  writeFile (outputDir </> "cabal-component-deps") (renderComponentDependencies components)
  writeFile (outputDir </> "nix-derived-host-package-names.sorted") (unlines expectedPackages)
  writeFile (outputDir </> "cabal-derived-package-names") (unlines actualPackages)
  writeFile (outputDir </> "package-name-diff") diffText

  unless (null diffText) $
    die ("Nix-derived host package names differ from Cabal setup-config package names\n" <> diffText)

cabalComponentDependencies :: IO [(String, [ComponentDependency])]
cabalComponentDependencies = do
  localBuildInfo <- getPersistBuildConfig "dist"
  pure $
    map
      ( \component ->
          ( showComponentName (componentLocalName component)
          , map componentDependency (componentPackageDeps component)
          )
      )
      (allComponentsInBuildOrder localBuildInfo)

componentDependency :: (UnitId, MungedPackageId) -> ComponentDependency
componentDependency (unitId, packageId) =
  ComponentDependency
    { dependencyPackageName =
        unPackageName (encodeCompatPackageName (mungedName packageId))
    , dependencyUnitId = unUnitId unitId
    }

normalizedLines :: String -> [String]
normalizedLines =
  sort . nub . filter (not . null) . lines

renderComponentDependencies :: [(String, [ComponentDependency])] -> String
renderComponentDependencies components =
  concatMap renderComponent components
  where
    renderComponent (componentName, dependencies) =
      unlines $
        ("component " <> componentName)
          : map renderDependency dependencies

    renderDependency dependency =
      "  "
        <> dependencyPackageName dependency
        <> " "
        <> dependencyUnitId dependency

renderPackageDiff :: [String] -> [String] -> String
renderPackageDiff expected actual
  | expected == actual = ""
  | otherwise =
      unlines
        [ "--- nix-derived-host-package-names.sorted"
        , "+++ cabal-derived-package-names"
        , "@@"
        ]
        <> renderOnly "-" (expected `without` actual)
        <> renderOnly "+" (actual `without` expected)
  where
    without left right =
      filter (`notElem` right) left

    renderOnly prefix values =
      intercalate "" (map (\value -> prefix <> value <> "\n") values)
