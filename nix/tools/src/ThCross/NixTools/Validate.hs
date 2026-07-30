{-# LANGUAGE CPP #-}

-- | Validate Nix-derived host package names against Cabal setup-config.
module ThCross.NixTools.Validate
  ( validateCabalComponentContext
  ) where

import Control.Monad (unless)
import Data.List (intercalate, nub, sort)
import Distribution.Simple.Configure (getPersistBuildConfig)
import Distribution.Simple.LocalBuildInfo (allComponentsInBuildOrder)
import Distribution.Types.ComponentLocalBuildInfo
  ( componentLocalName
  , componentPackageDeps
  )
import Distribution.Types.ComponentName (showComponentName)
import Distribution.Types.LocalBuildInfo (LocalBuildInfo)
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
#if MIN_VERSION_Cabal(3,14,0)
import Distribution.Utils.Path (makeSymbolicPath)
#endif
import System.Directory (createDirectoryIfMissing)
import System.Exit (die)
import System.FilePath ((</>))

data ComponentDependency = ComponentDependency
  { dependencyPackageName :: String
  , dependencyUnitId :: String
  }

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
  localBuildInfo <- readLocalBuildInfo
  pure $
    map
      ( \component ->
          ( showComponentName (componentLocalName component)
          , map componentDependency (componentPackageDeps component)
          )
      )
      (allComponentsInBuildOrder localBuildInfo)

readLocalBuildInfo :: IO LocalBuildInfo
readLocalBuildInfo =
#if MIN_VERSION_Cabal(3,14,0)
  getPersistBuildConfig Nothing (makeSymbolicPath "dist")
#else
  getPersistBuildConfig "dist"
#endif

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
