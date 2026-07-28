-- | Host-side GHC session setup and Template Haskell capture hook.
module Worker.Capture
  ( captureModuleSplices
  ) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeDirectory)
import System.IO (hPutStrLn, stderr)
import System.Process (readProcess)
import GHC
  ( Ghc
  , GhcMonad (getSession)
  , LoadHowMuch (LoadAllTargets)
  , SuccessFlag (..)
  , guessTarget
  , getSessionDynFlags
  , load
  , runGhc
  , setSession
  , setSessionDynFlags
  , setTargets
  )
import GHC.Driver.Env.Types (HscEnv (..))
import GHC.Driver.Hooks (Hooks (..))
import GHC.Driver.Session
  ( GeneralFlag (Opt_ForceRecomp)
  , flagsAll
  , gopt_set
  , hiDir
  , importPaths
  , objectDir
  , parseDynamicFlagsFull
  , stubDir
  )
import GHC.Hs (GhcTc, LHsExpr)
import GHC.Tc.Gen.Splice (defaultRunMeta)
import GHC.Tc.Types (TcM)
import GHC.Tc.Utils.Monad (liftIO)
import GHC.Types.Meta
  ( MetaHook
  , MetaRequest (..)
  , metaRequestAW
  )
import GHC.Types.SrcLoc
  ( noLoc
  , unLoc
  )
import THCross.Protocol
  ( SpliceForeignFile
  , SpliceKind (..)
  , SpliceRequest (..)
  , SpliceResult
  )
import Worker.SpliceCache
  ( CapturedSplice (..)
  , CapturedSplices
  , attachModuleEffects
  )
import Worker.TH
  ( convertDeclarationsOrFail
  , convertExpressionOrFail
  , convertPatternOrFail
  , convertTypeOrFail
  , encodeAnnotationWrapper
  , evaluateSplice
  , getDependentFiles
  , getForeignFiles
  , mkCapturedSpliceKey
  , mkSpliceResult
  , runMetaDeclsTH
  , runMetaExpTH
  , runMetaPatTH
  , runMetaTypeTH
  )

-- | Load the requested source module and capture all supported splice expansions.
captureModuleSplices :: SpliceRequest -> IO (Either String CapturedSplices)
captureModuleSplices request = do
  capturesRef <- newIORef Map.empty
  dependentFilesRef <- newIORef []
  foreignFilesRef <- newIORef []
  ghcLibDir <- getGhcLibDir
  extraPackageIds <- getHostGhcPackageIds request
  hPutStrLn stderr ("th-host-worker: import paths " <> show workerImportPaths)
  createDirectoryIfMissing True hostWorkerBuildDir
  result <- runGhc (Just ghcLibDir) $ do
    dflags <- getSessionDynFlags
    (dflagsWithHostOptions, remainingArgs, _warnings) <-
      parseDynamicFlagsFull
        flagsAll
        True
        (workerDynFlags dflags)
        (map noLoc (hostPackageIdArgs extraPackageIds <> requestHostGhcOptions request))
    case remainingArgs of
      [] ->
        setSessionDynFlags dflagsWithHostOptions
      _ ->
        fail ("unsupported host GHC option(s): " <> show (map unLoc remainingArgs))
    installCaptureHook capturesRef dependentFilesRef foreignFilesRef
    loadRequestedModule
  case result of
    Failed ->
      pure (Left ("host GHC failed to load " <> requestSourceFile request))
    Succeeded -> do
      captures <- readIORef capturesRef
      dependentFiles <- readIORef dependentFilesRef
      foreignFiles <- readIORef foreignFilesRef
      pure (Right (attachModuleEffects dependentFiles foreignFiles captures))
  where
    sourceDir =
      takeDirectory (requestSourceFile request)

    workerImportPaths =
      case requestHostSourceDirs request of
        [] -> [sourceDir]
        hostSourceDirs -> hostSourceDirs

    workerDynFlags dflags =
      (gopt_set dflags Opt_ForceRecomp)
        { importPaths = workerImportPaths <> importPaths dflags
        , objectDir = Just hostWorkerBuildDir
        , hiDir = Just hostWorkerBuildDir
        , stubDir = Just hostWorkerBuildDir
        }

    hostPackageIdArgs =
      concatMap (\unitId -> ["-package-id", unitId])

    loadRequestedModule = do
      target <- guessTarget (requestSourceFile request) Nothing Nothing
      setTargets [target]
      load LoadAllTargets

-- | Directory for object/interface/stub files produced by host-side GHC loads.
--
-- Without this, native GHC writes @.o@ and @.hi@ files next to the source module
-- being loaded. Keeping the artifacts under @dist-newstyle@ avoids polluting the
-- user's source tree while preserving normal compilation behavior in the worker.
hostWorkerBuildDir :: FilePath
hostWorkerBuildDir =
  "dist-newstyle" </> "th-cross-worker"

-- | Locate the native GHC library directory used to initialize 'runGhc'.
--
-- Packaged environments should set @TH_HOST_GHC_LIBDIR@ so the worker does not
-- accidentally discover the consumer GHC from @PATH@. The @ghc --print-libdir@
-- fallback keeps the manually built worker convenient to run.
getGhcLibDir :: IO FilePath
getGhcLibDir = do
  explicitLibDir <- lookupEnv "TH_HOST_GHC_LIBDIR"
  case explicitLibDir of
    Just libDir -> pure libDir
    Nothing -> trimTrailingNewline <$> readProcess "ghc" ["--print-libdir"] ""

-- | Exact host-side unit ids to expose in the host-side GHC session.
--
-- Unit ids correspond to @-package-id@ and avoid ambiguity when several
-- package instances with the same package name are present in a package DB.
getHostGhcPackageIds :: SpliceRequest -> IO [String]
getHostGhcPackageIds request = do
  explicitPackageIds <- lookupEnv "TH_HOST_GHC_PACKAGE_IDS"
  pure (requestHostPackageIds request <> maybe [] words explicitPackageIds)

-- | Install a host-only hook that delegates to the previous hook/default GHC
-- evaluator, records the generated splice, and returns it unchanged.
installCaptureHook ::
  IORef CapturedSplices ->
  IORef [FilePath] ->
  IORef [SpliceForeignFile] ->
  Ghc ()
installCaptureHook capturesRef dependentFilesRef foreignFilesRef = do
  hscEnv <- getSession
  let hooks0 = hsc_hooks hscEnv
      previousRunMeta = runMetaHook hooks0
      hooks1 = hooks0 {runMetaHook = Just (captureMetaHook capturesRef dependentFilesRef foreignFilesRef previousRunMeta)}
  setSession hscEnv {hsc_hooks = hooks1}

-- | Host-side 'runMetaHook' wrapper that records expansions without changing
-- native evaluation behavior.
captureMetaHook ::
  IORef CapturedSplices ->
  IORef [FilePath] ->
  IORef [SpliceForeignFile] ->
  Maybe (MetaHook TcM) ->
  MetaHook TcM
captureMetaHook capturesRef dependentFilesRef foreignFilesRef previousRunMeta request spliceExpr =
  case request of
    MetaE wrap -> do
      expanded <-
        captureExpressionSpliceResult
      pure (wrap expanded)
    MetaD wrap -> do
      expanded <-
        captureDeclarationSpliceResult
      pure (wrap expanded)
    MetaP wrap -> do
      expanded <-
        capturePatternSpliceResult
      pure (wrap expanded)
    MetaT wrap -> do
      expanded <-
        captureTypeSpliceResult
      pure (wrap expanded)
    MetaAW wrap -> do
      serialized <-
        captureAnnotationWrapper
          (metaRequestAW runMeta)
      pure (wrap serialized)
  where
    runMeta = fromMaybe defaultRunMeta previousRunMeta

    captureExpressionSpliceResult = do
      liftIO (hPutStrLn stderr "th-host-worker: expression splice start")
      (thExp, diagnostics, addedTopDecls) <-
        evaluateSplice (runMetaExpTH spliceExpr)
      liftIO (hPutStrLn stderr "th-host-worker: expression splice evaluated")
      hsExp <- convertExpressionOrFail spliceExpr thExp
      liftIO (hPutStrLn stderr "th-host-worker: expression splice converted")
      recordCapturedSplice
        capturesRef
        dependentFilesRef
        foreignFilesRef
        ExpressionSplice
        spliceExpr
        (mkSpliceResult (Just thExp) Nothing Nothing Nothing Nothing addedTopDecls diagnostics)
      pure hsExp

    capturePatternSpliceResult = do
      (thPat, diagnostics, addedTopDecls) <-
        evaluateSplice (runMetaPatTH spliceExpr)
      hsPat <- convertPatternOrFail spliceExpr thPat
      recordCapturedSplice
        capturesRef
        dependentFilesRef
        foreignFilesRef
        PatternSplice
        spliceExpr
        (mkSpliceResult Nothing (Just thPat) Nothing Nothing Nothing addedTopDecls diagnostics)
      pure hsPat

    captureTypeSpliceResult = do
      (thType, diagnostics, addedTopDecls) <-
        evaluateSplice (runMetaTypeTH spliceExpr)
      hsType <- convertTypeOrFail spliceExpr thType
      recordCapturedSplice
        capturesRef
        dependentFilesRef
        foreignFilesRef
        TypeSplice
        spliceExpr
        (mkSpliceResult Nothing Nothing (Just thType) Nothing Nothing addedTopDecls diagnostics)
      pure hsType

    captureDeclarationSpliceResult = do
      (thDecls, diagnostics, addedTopDecls) <-
        evaluateSplice (runMetaDeclsTH spliceExpr)
      hsDecls <- convertDeclarationsOrFail spliceExpr thDecls
      recordCapturedSplice
        capturesRef
        dependentFilesRef
        foreignFilesRef
        DeclarationSplice
        spliceExpr
        (mkSpliceResult Nothing Nothing Nothing (Just thDecls) Nothing addedTopDecls diagnostics)
      pure hsDecls

    captureAnnotationWrapper runAnnotationWrapper = do
      (serialized, diagnostics, _addedTopDecls) <-
        evaluateSplice (runAnnotationWrapper spliceExpr)
      recordCapturedSplice
        capturesRef
        dependentFilesRef
        foreignFilesRef
        AnnotationWrapperSplice
        spliceExpr
        (mkSpliceResult Nothing Nothing Nothing Nothing (Just (encodeAnnotationWrapper serialized)) [] diagnostics)
      pure serialized

recordCapturedSplice ::
  IORef CapturedSplices ->
  IORef [FilePath] ->
  IORef [SpliceForeignFile] ->
  SpliceKind ->
  LHsExpr GhcTc ->
  SpliceResult ->
  TcM ()
recordCapturedSplice capturesRef dependentFilesRef foreignFilesRef spliceKind spliceExpr spliceResult = do
  spliceKey <- mkCapturedSpliceKey spliceKind spliceExpr
  dependentFiles <- getDependentFiles
  foreignFiles <- getForeignFiles
  liftIO $ do
    writeIORef dependentFilesRef dependentFiles
    writeIORef foreignFilesRef foreignFiles
    modifyIORef'
      capturesRef
      (Map.insert spliceKey (CapturedSplice spliceKind spliceResult))

-- | Remove trailing newlines from command output such as @ghc --print-libdir@.
trimTrailingNewline :: String -> String
trimTrailingNewline =
  reverse . dropWhile (`elem` ['\n', '\r']) . reverse
