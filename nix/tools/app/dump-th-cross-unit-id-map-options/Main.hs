-- | Print plugin unit-id remapping options for raw Template Haskell payloads.
--
-- Raw TH exact names may mention source package ids or host installed unit ids.
-- The cross-side plugin must rewrite both forms to target installed unit ids
-- before handing the payload to GHC's TH-to-Hs converter.
import Control.Monad (forM_)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), die)
import System.Process (readProcessWithExitCode)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [hostGhcPkg, targetGhcPkg, targetPackageDb] ->
      dumpUnitIdMapOptions hostGhcPkg targetGhcPkg targetPackageDb
    _ ->
      die "usage: dump-th-cross-unit-id-map-options HOST_GHC_PKG TARGET_GHC_PKG TARGET_PACKAGE_DB"

dumpUnitIdMapOptions :: FilePath -> FilePath -> FilePath -> IO ()
dumpUnitIdMapOptions hostGhcPkg targetGhcPkg targetPackageDb = do
  _ <- targetGhcPkg_ ["--package-db=" <> targetPackageDb, "recache"]
  dumpPackageDbOptions ["--package-db=" <> targetPackageDb]
  dumpPackageDbOptions []
  where
    targetGhcPkg_ =
      ghcPkg targetGhcPkg

    dumpPackageDbOptions targetPackageDbArgs = do
      targetPackages <-
        words <$> targetGhcPkg_ (targetPackageDbArgs <> ["list", "--simple-output"])
      forM_ targetPackages $ dumpPackageOptions targetPackageDbArgs

    dumpPackageOptions targetPackageDbArgs targetPackage = do
      targetUnitIds <-
        words <$> targetGhcPkg_ (targetPackageDbArgs <> ["field", targetPackage, "id", "--simple-output"])
      case targetUnitIds of
        [targetUnitId] -> do
          packageName <-
            stripLine <$> targetGhcPkg_ (targetPackageDbArgs <> ["field", targetPackage, "name", "--simple-output"])
          packageVersion <-
            stripLine <$> targetGhcPkg_ (targetPackageDbArgs <> ["field", targetPackage, "version", "--simple-output"])
          putStrLn ("unit-id-map=" <> packageName <> "-" <> packageVersion <> "=" <> targetUnitId)
          hostUnitIdsResult <-
            tryGhcPkg hostGhcPkg ["field", packageName, "id", "--simple-output"]
          case words <$> hostUnitIdsResult of
            Just [hostUnitId] ->
              putStrLn ("unit-id-map=" <> hostUnitId <> "=" <> targetUnitId)
            _ ->
              pure ()
        _ ->
          pure ()

-- | Run a required @ghc-pkg@ query and fail the tool if it fails.
ghcPkg :: FilePath -> [String] -> IO String
ghcPkg ghcPkgPath ghcPkgArgs = do
  (exitCode, stdout, stderr) <- readProcessWithExitCode ghcPkgPath ghcPkgArgs ""
  case exitCode of
    ExitSuccess ->
      pure stdout
    ExitFailure _ ->
      die (unwords (ghcPkgPath : ghcPkgArgs) <> " failed: " <> stderr)

-- | Run an optional host @ghc-pkg@ query.
--
-- Not every target package has a corresponding host package in the worker
-- environment; those packages only receive a source-package-id mapping.
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
