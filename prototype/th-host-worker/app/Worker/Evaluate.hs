{-# LANGUAGE LambdaCase #-}

-- | Host-side Template Haskell evaluation through a native GHC session.
module Worker.Evaluate
  ( EvaluationCache
  , evaluateModuleSplice
  , newEvaluationCache
  ) where

import Control.Exception (SomeException, catch, displayException)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import System.Directory (createDirectoryIfMissing)
import System.IO (hPutStrLn, stderr)
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
import GHC.Data.Bag (bagToList)
import GHC.Driver.Env.Types (HscEnv (..))
import GHC.Driver.Hooks (Hooks (..))
import GHC.Driver.Session
  ( GeneralFlag (Opt_ForceRecomp)
  , gopt_set
  , hiDir
  , importPaths
  , objectDir
  , stubDir
  )
import GHC.Hs (GhcPs, GhcTc, LHsDecl, LHsExpr)
import GHC.Parser.Annotation (getLocA)
import GHC.Tc.Gen.Splice (defaultRunMeta)
import GHC.Tc.Errors.Types (THError (ReportCustomQuasiError), TcRnMessage (TcRnTHError))
import GHC.Tc.Types (TcGblEnv (..), TcM)
import GHC.Tc.Utils.Monad (getErrsVar, getGblEnv, liftIO, readTcRef, writeTcRef)
import GHC.Types.Error
  ( Messages
  , MsgEnvelope (errMsgDiagnostic)
  , emptyMessages
  , getMessages
  , unionMessages
  )
import GHC.Types.Meta
  ( MetaHook
  , MetaRequest (..)
  , metaRequestD
  , metaRequestE
  )
import GHC.Types.SrcLoc
  ( SrcSpan (..)
  , srcSpanEndCol
  , srcSpanEndLine
  , srcSpanStartCol
  , srcSpanStartLine
  )
import GHC.Unit.Module (moduleName, moduleNameString)
import GHC.Utils.Outputable
  ( SDoc
  , defaultSDocContext
  , ppr
  , renderWithContext
  , sdocSuppressUniques
  )
import System.FilePath ((</>), takeDirectory)
import System.Process (readProcess)
import THCross.Protocol
  ( SpliceDiagnostic (..)
  , SpliceResult (..)
  , SourceSpan (..)
  , SpliceKind (..)
  , SpliceRequest (..)
  , SpliceResponse (..)
  , sourceSpanKeyText
  , spliceKindToStr
  )
import THCross.SpliceKey
  ( SpliceKey
  , mkSpliceKey
  )

-- | Splice expansions captured while native GHC loaded the requested module.
type CapturedSplices = Map.Map SpliceKey SpliceResult

-- | In-process cache of splice expansion results captured by whole-module loads.
--
-- The worker process is persistent, so this cache survives multiple requests
-- handled by one worker. It is intentionally not written to disk yet.
type EvaluationCache = IORef CapturedSplices

-- | Create an empty worker-local expansion cache.
newEvaluationCache :: IO EvaluationCache
newEvaluationCache =
  newIORef Map.empty

-- | Evaluate the requested splice and preserve the original request id.
evaluateModuleSplice :: EvaluationCache -> SpliceRequest -> IO SpliceResponse
evaluateModuleSplice cache request = do
  result <- evaluateModuleSpliceText cache request `catch` handleEvalException
  pure $
    case result of
      Right spliceResult ->
        SpliceOk (requestId request) spliceResult
      Left err ->
        SpliceError (requestId request) err

-- | Convert unexpected GHC API/runtime exceptions into protocol errors.
handleEvalException :: SomeException -> IO (Either String SpliceResult)
handleEvalException =
  pure . Left . ("native GHC splice evaluation failed: " <>) . displayException

-- | Compile the source module with native GHC and capture splice expansions
-- produced by GHC's normal Template Haskell evaluator.
--
-- This is the host-side equivalent of normal module compilation. The worker
-- creates a native GHC session, adds the source directory to the import path,
-- installs a capture hook, sets the requested source file as the target, and
-- calls 'load'. During 'load', GHC performs normal declaration-group ordering and
-- invokes the hook for each splice it encounters.
evaluateModuleSpliceText :: EvaluationCache -> SpliceRequest -> IO (Either String SpliceResult)
evaluateModuleSpliceText cache request = do
  cached <- Map.lookup (requestSpliceKey request) <$> readIORef cache
  case cached of
    Just spliceResult -> do
      hPutStrLn stderr ("th-host-worker: cache hit " <> requestSourceFile request)
      pure (Right spliceResult)
    Nothing -> do
      hPutStrLn stderr ("th-host-worker: cache miss " <> requestSourceFile request)
      capturesResult <- captureModuleSplices request
      case capturesResult of
        Left err ->
          pure (Left err)
        Right captures -> do
          modifyIORef' cache (Map.union captures)
          pure (selectCapturedSplice request captures)

-- | Load the requested source module and capture all supported splice expansions.
captureModuleSplices :: SpliceRequest -> IO (Either String CapturedSplices)
captureModuleSplices request = do
  capturesRef <- newIORef Map.empty
  dependentFilesRef <- newIORef []
  ghcLibDir <- getGhcLibDir
  createDirectoryIfMissing True hostWorkerBuildDir
  result <- runGhc (Just ghcLibDir) $ do
    dflags <- getSessionDynFlags
    setSessionDynFlags (workerDynFlags dflags)
    installCaptureHook capturesRef dependentFilesRef
    loadRequestedModule
  case result of
    Failed ->
      pure (Left ("host GHC failed to load " <> requestSourceFile request))
    Succeeded -> do
      captures <- readIORef capturesRef
      dependentFiles <- readIORef dependentFilesRef
      pure (Right (attachDependentFiles dependentFiles captures))
  where
    sourceDir =
      takeDirectory (requestSourceFile request)

    workerDynFlags dflags =
      (gopt_set dflags Opt_ForceRecomp)
        { importPaths = sourceDir : importPaths dflags
        , objectDir = Just hostWorkerBuildDir
        , hiDir = Just hostWorkerBuildDir
        , stubDir = Just hostWorkerBuildDir
        }

    loadRequestedModule = do
      target <- guessTarget (requestSourceFile request) Nothing Nothing
      setTargets [target]
      load LoadAllTargets

-- | Attach module-level dependent files to each captured splice result.
attachDependentFiles :: [FilePath] -> CapturedSplices -> CapturedSplices
attachDependentFiles dependentFiles =
  Map.map
    ( \spliceResult ->
        spliceResult {spliceResultDependentFiles = dependentFiles}
    )

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
-- The prototype shells out to @ghc --print-libdir@ so the worker uses the same
-- GHC installation that built/runs it. A packaged version should make this more
-- explicit.
getGhcLibDir :: IO FilePath
getGhcLibDir =
  trimTrailingNewline <$> readProcess "ghc" ["--print-libdir"] ""

-- | Install a host-only hook that delegates to the previous hook/default GHC
-- evaluator, records the generated splice, and returns it unchanged.
installCaptureHook :: IORef CapturedSplices -> IORef [FilePath] -> Ghc ()
installCaptureHook capturesRef dependentFilesRef = do
  hscEnv <- getSession
  let hooks0 = hsc_hooks hscEnv
      previousRunMeta = runMetaHook hooks0
      hooks1 = hooks0 {runMetaHook = Just (captureMetaHook capturesRef dependentFilesRef previousRunMeta)}
  setSession hscEnv {hsc_hooks = hooks1}

-- | Host-side 'runMetaHook' wrapper that records expansions without changing
-- native evaluation behavior.
--
-- For supported splice kinds, it delegates to the previous runMeta hook or
-- 'defaultRunMeta' first. That produces the real @GhcPs@ expansion in the native
-- session. The hook then pretty-prints the expansion, stores it in 'capturesRef',
-- and returns the original expansion back to GHC so module loading continues.
captureMetaHook ::
  IORef CapturedSplices ->
  IORef [FilePath] ->
  Maybe (MetaHook TcM) ->
  MetaHook TcM
captureMetaHook capturesRef dependentFilesRef previousRunMeta request spliceExpr =
  case request of
    MetaE wrap -> do
      expanded <-
        captureSpliceResult
          ExpressionSplice
          (metaRequestE runMeta)
          prettyExpandedExpression
      pure (wrap expanded)
    MetaD wrap -> do
      expanded <-
        captureSpliceResult
          DeclarationSplice
          (metaRequestD runMeta)
          prettyExpandedDeclarations
      pure (wrap expanded)
    _ ->
      runMeta request spliceExpr
  where
    runMeta = fromMaybe defaultRunMeta previousRunMeta

    captureSpliceResult spliceKind evaluateSplice renderExpanded = do
      (expanded, diagnostics) <-
        evaluateWithIsolatedDiagnostics (evaluateSplice spliceExpr)
      renderedExpansion <- renderExpanded expanded
      spliceKey <- mkCapturedSpliceKey spliceKind spliceExpr
      dependentFiles <- getDependentFiles
      liftIO $ do
        writeIORef dependentFilesRef dependentFiles
        modifyIORef' capturesRef (Map.insert spliceKey (mkSpliceResult renderedExpansion diagnostics))
      pure expanded

-- | Construct a captured splice result before module-level effects are attached.
mkSpliceResult :: String -> [SpliceDiagnostic] -> SpliceResult
mkSpliceResult renderedExpansion diagnostics =
  SpliceResult
    { spliceResultHaskell = renderedExpansion
    , spliceResultDependentFiles = []
    , spliceResultDiagnostics = diagnostics
    }

-- | Evaluate one splice while separately recording TH diagnostics.
--
-- Host GHC stores @reportWarning@ and @reportError@ in the current 'TcM'
-- message bag. Temporarily clearing that bag gives us the messages produced by
-- this splice alone; restoring the union afterwards keeps normal host
-- compilation semantics intact.
evaluateWithIsolatedDiagnostics :: TcM a -> TcM (a, [SpliceDiagnostic])
evaluateWithIsolatedDiagnostics action = do
  errsVar <- getErrsVar
  previousMessages <- readTcRef errsVar
  writeTcRef errsVar emptyMessages
  result <- action
  spliceMessages <- readTcRef errsVar
  writeTcRef errsVar (spliceMessages `unionMessages` previousMessages)
  pure (result, extractTHDiagnostics spliceMessages)

-- | Keep only diagnostics explicitly emitted by Template Haskell @report*@.
extractTHDiagnostics :: Messages TcRnMessage -> [SpliceDiagnostic]
extractTHDiagnostics messages =
  mapMaybe extractTHDiagnostic (bagToList (getMessages messages))
  where
    extractTHDiagnostic message =
      case errMsgDiagnostic message of
        TcRnTHError (ReportCustomQuasiError isError text) ->
          Just (SpliceDiagnostic isError text)
        _ ->
          Nothing

-- | Read files registered through @addDependentFile@ in the host GHC session.
getDependentFiles :: TcM [FilePath]
getDependentFiles = do
  tcGblEnv <- getGblEnv
  readTcRef (tcg_dependent_files tcGblEnv)

-- | Attach the source-occurrence splice key to a captured expansion.
--
-- This runs in 'TcM' inside the host compiler, so it can read the current
-- 'TcGblEnv' to discover which module is being compiled when the splice fires.
mkCapturedSpliceKey ::
  SpliceKind ->
  LHsExpr GhcTc ->
  TcM SpliceKey
mkCapturedSpliceKey spliceKind spliceExpr = do
  tcGblEnv <- getGblEnv
  let spliceModuleName = moduleNameString (moduleName (tcg_mod tcGblEnv))
      sourceSpan = protocolSourceSpan (getLocA spliceExpr)
      spliceKindName = spliceKindToStr spliceKind
  pure (mkSpliceKey spliceModuleName spliceKindName (sourceSpanKeyText sourceSpan))

-- | Convert a generated expression AST back to textual Haskell for the wire
-- format.
prettyExpandedExpression :: LHsExpr GhcPs -> TcM String
prettyExpandedExpression =
  pure . renderHaskell . ppr

-- | Convert generated declaration ASTs back to textual Haskell for the wire
-- format.
prettyExpandedDeclarations :: [LHsDecl GhcPs] -> TcM String
prettyExpandedDeclarations =
  pure . unlines . map (renderHaskell . ppr)

-- | Render Haskell without GHC-generated uniques.
--
-- Suppressing uniques keeps declarations such as generated data constructors
-- readable and reparsable by the cross-side compiler.
renderHaskell :: SDoc -> String
renderHaskell =
  renderWithContext defaultSDocContext {sdocSuppressUniques = True}

-- | Convert a GHC source span into the protocol span used for matching.
protocolSourceSpan :: SrcSpan -> SourceSpan
protocolSourceSpan = \case
  RealSrcSpan realSpan _ ->
    SourceSpan
      { sourceSpanStartLine = srcSpanStartLine realSpan
      , sourceSpanStartColumn = srcSpanStartCol realSpan
      , sourceSpanEndLine = srcSpanEndLine realSpan
      , sourceSpanEndColumn = srcSpanEndCol realSpan
      }
  UnhelpfulSpan _ ->
    SourceSpan 1 1 1 1

-- | Find the host-side expansion corresponding to the cross-side request.
--
-- Loading a module can execute several splices. The worker first selects by the
-- opaque splice key derived from module name, splice kind, and source span.
selectCapturedSplice :: SpliceRequest -> CapturedSplices -> Either String SpliceResult
selectCapturedSplice request captures =
  case Map.lookup (requestSpliceKey request) captures of
    Just spliceResult ->
      Right spliceResult
    Nothing ->
      Left $
        "host GHC did not capture requested splice; request key "
          <> show (requestSpliceKey request)
          <> "; captured "
          <> show (Map.size captures)
          <> " splice(s): "
          <> show (Map.keys captures)

-- | Remove trailing newlines from command output such as @ghc --print-libdir@.
trimTrailingNewline :: String -> String
trimTrailingNewline =
  reverse . dropWhile (`elem` ['\n', '\r']) . reverse
