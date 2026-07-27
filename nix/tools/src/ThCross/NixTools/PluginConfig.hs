-- | Build the plugin config file consumed by `THCross.Plugin`.
module ThCross.NixTools.PluginConfig
  ( writePluginConfig
  ) where

import Control.Monad (forM)
import qualified Data.ByteString as ByteString
import qualified Data.List as List
import Distribution.PackageDescription
  ( BuildInfo (cppOptions, hsSourceDirs)
  , GenericPackageDescription
  )
import Distribution.PackageDescription.Parsec (parseGenericPackageDescriptionMaybe)
import Distribution.Utils.Path (getSymbolicPath)
import System.Directory (getCurrentDirectory, listDirectory)
import System.Exit (ExitCode (..), die)
import System.FilePath ((</>), takeExtension)
import System.Process (readProcessWithExitCode)
import ThCross.NixTools.Cabal (extractFromAllComponents)

writePluginConfig :: FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> [String] -> IO ()
writePluginConfig outputFile worker hostGhcPkg targetGhcPkg targetPackageDb hostPackageNames = do
  currentDirectory <- getCurrentDirectory
  gpd <- readPackageDescription
  hostPackageIds <- concat <$> traverse resolveHostPackageIds hostPackageNames
  unitIdMapOptions <- buildUnitIdMapOptions hostGhcPkg targetGhcPkg targetPackageDb
  let sourceDirOptions =
        map ("host-source-dir=" <>) $
          map (currentDirectory </>) $
          List.nub $
            filter (not . null) $
              map getSymbolicPath $
                extractFromAllComponents hsSourceDirs gpd
      cppOptions' =
        map ("host-ghc-option=" <>) $
          List.nub (extractFromAllComponents cppOptions gpd)
      configLines =
        ["worker=" <> worker]
          <> map ("host-package-id=" <>) hostPackageIds
          <> unitIdMapOptions
          <> sourceDirOptions
          <> cppOptions'
  writeFile outputFile (unlines configLines)
  where
    resolveHostPackageIds packageName =
      words <$> ghcPkg hostGhcPkg ["field", packageName, "id", "--simple-output"]

readPackageDescription :: IO GenericPackageDescription
readPackageDescription = do
  cabalFiles <- filter ((== ".cabal") . takeExtension) <$> listDirectory "."
  case cabalFiles of
    [cabalFile] -> do
      cabalBytes <- ByteString.readFile cabalFile
      case parseGenericPackageDescriptionMaybe cabalBytes of
        Just gpd ->
          pure gpd
        Nothing ->
          fail ("failed to parse " <> cabalFile)
    [] ->
      fail "no .cabal file found"
    _ ->
      fail ("expected one .cabal file, found: " <> show cabalFiles)

buildUnitIdMapOptions :: FilePath -> FilePath -> FilePath -> IO [String]
buildUnitIdMapOptions hostGhcPkg targetGhcPkg targetPackageDb = do
  _ <- targetGhcPkg_ ["--package-db=" <> targetPackageDb, "recache"]
  componentMappings <- packageDbOptions ["--package-db=" <> targetPackageDb]
  globalMappings <- packageDbOptions []
  pure (componentMappings <> globalMappings)
  where
    targetGhcPkg_ =
      ghcPkg targetGhcPkg

    packageDbOptions targetPackageDbArgs = do
      targetPackages <-
        words <$> targetGhcPkg_ (targetPackageDbArgs <> ["list", "--simple-output"])
      concat <$> forM targetPackages (packageOptions targetPackageDbArgs)

    packageOptions targetPackageDbArgs targetPackage = do
      targetUnitIds <-
        words <$> targetGhcPkg_ (targetPackageDbArgs <> ["field", targetPackage, "id", "--simple-output"])
      case targetUnitIds of
        [targetUnitId] -> do
          packageName <-
            stripLine <$> targetGhcPkg_ (targetPackageDbArgs <> ["field", targetPackage, "name", "--simple-output"])
          packageVersion <-
            stripLine <$> targetGhcPkg_ (targetPackageDbArgs <> ["field", targetPackage, "version", "--simple-output"])
          hostUnitIdsResult <-
            tryGhcPkg hostGhcPkg ["field", packageName, "id", "--simple-output"]
          let sourcePackageMapping =
                "unit-id-map=" <> packageName <> "-" <> packageVersion <> "=" <> targetUnitId
              hostUnitIdMappings =
                case words <$> hostUnitIdsResult of
                  Just [hostUnitId] ->
                    ["unit-id-map=" <> hostUnitId <> "=" <> targetUnitId]
                  _ ->
                    []
          pure (sourcePackageMapping : hostUnitIdMappings)
        _ ->
          pure []

ghcPkg :: FilePath -> [String] -> IO String
ghcPkg ghcPkgPath ghcPkgArgs = do
  (exitCode, stdout, stderr) <- readProcessWithExitCode ghcPkgPath ghcPkgArgs ""
  case exitCode of
    ExitSuccess ->
      pure stdout
    ExitFailure _ ->
      die (unwords (ghcPkgPath : ghcPkgArgs) <> " failed: " <> stderr)

tryGhcPkg :: FilePath -> [String] -> IO (Maybe String)
tryGhcPkg ghcPkgPath ghcPkgArgs = do
  (exitCode, stdout, _stderr) <- readProcessWithExitCode ghcPkgPath ghcPkgArgs ""
  case exitCode of
    ExitSuccess ->
      pure (Just stdout)
    ExitFailure _ ->
      pure Nothing

stripLine :: String -> String
stripLine =
  unwords . words
