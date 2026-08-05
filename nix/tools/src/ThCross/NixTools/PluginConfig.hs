-- | Build the plugin config file consumed by `THCross.Plugin`.
module ThCross.NixTools.PluginConfig
  ( writePluginConfig
  ) where

import Control.Monad (forM)
import qualified Data.ByteString as ByteString
import qualified Data.List as List
import Distribution.PackageDescription
  ( BuildInfo (cppOptions, defaultExtensions, defaultLanguage, hsSourceDirs, oldExtensions, otherExtensions)
  , GenericPackageDescription
  )
import Distribution.PackageDescription.Parsec (parseGenericPackageDescriptionMaybe)
import Distribution.Pretty (prettyShow)
import Distribution.Utils.Path (getSymbolicPath)
import Language.Haskell.Extension (Extension (..), KnownExtension, Language)
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
      languageOptions =
        map ("host-ghc-option=" <>) $
          List.nub (extractFromAllComponents languageFields gpd)
      configLines =
        ["worker=" <> worker]
          <> map ("host-package-id=" <>) hostPackageIds
          <> unitIdMapOptions
          <> sourceDirOptions
          <> cppOptions'
          <> languageOptions
  writeFile outputFile (unlines configLines)
  where
    resolveHostPackageIds packageName =
      words <$> ghcPkg hostGhcPkg ["field", packageName, "id", "--simple-output"]

    -- | Collect the @default-language@, @default-extensions@,
    -- @other-extensions@, and legacy @extensions@ fields from every
    -- component's 'BuildInfo'.
    --
    -- The worker runs an independent native GHC session and does not read the
    -- Cabal component configuration, so without these options it would fall
    -- back to its default language and extension set. That breaks modules that
    -- rely on extensions enabled in the .cabal file instead of per-module
    -- LANGUAGE pragmas, for example @TemplateHaskell@ under @GHC2021@.
    languageFields bi =
      maybe [] languageFlag (defaultLanguage bi)
        <> map extensionFlag (defaultExtensions bi)
        <> map extensionFlag (otherExtensions bi)
        <> map extensionFlag (oldExtensions bi)

    languageFlag :: Language -> [String]
    languageFlag language = ["-X" <> prettyShow language]

    extensionFlag :: Extension -> String
    extensionFlag extension = "-X" <> renderExtension extension

    renderExtension :: Extension -> String
    renderExtension = \case
      EnableExtension known -> prettyShow known
      DisableExtension known -> "No" <> prettyShow known
      UnknownExtension name -> name

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
