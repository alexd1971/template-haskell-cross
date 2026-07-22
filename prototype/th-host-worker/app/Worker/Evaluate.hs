{-# LANGUAGE LambdaCase #-}

-- | Host-side Template Haskell evaluation through a native GHC session.
module Worker.Evaluate
  ( EvaluationCache
  , evaluateModuleSplice
  , newEvaluationCache
  ) where

import Control.Exception (SomeException, catch, displayException)
import Data.Binary (encode)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Word (Word8)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
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
  , ModRenaming (ModRenaming)
  , PackageArg (PackageArg)
  , PackageFlag (ExposePackage)
  , gopt_set
  , hiDir
  , importPaths
  , objectDir
  , packageFlags
  , stubDir
  )
import GHC.Hs (GhcPs, GhcTc, LHsDecl, LHsExpr)
import GHC.Parser.Annotation (getLocA)
import GHC.Serialized (Serialized)
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
  , metaRequestAW
  , metaRequestD
  , metaRequestE
  , metaRequestP
  , metaRequestT
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
  ( Outputable
  , SDoc
  , defaultSDocContext
  , ppr
  , renderWithContext
  , sdocSuppressUniques
  )
import GHCi.TH.Binary ()
import System.FilePath ((</>), takeDirectory)
import System.Process (readProcess)
import THCross.Protocol
  ( SpliceDiagnostic (..)
  , SpliceForeignFile (..)
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
type CapturedSplices = Map.Map SpliceKey CapturedSplice

-- | Captured expansion plus the splice kind used for fallback matching.
data CapturedSplice = CapturedSplice
  { capturedSpliceKind :: !SpliceKind
  , capturedSpliceResult :: !SpliceResult
  }

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
  result <- evaluateModuleSpliceResult cache request `catch` handleEvalException
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
evaluateModuleSpliceResult :: EvaluationCache -> SpliceRequest -> IO (Either String SpliceResult)
evaluateModuleSpliceResult cache request = do
  cached <- selectCapturedSplice request <$> readIORef cache
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
          pure (selectCapturedSpliceOrError request captures)

-- | Load the requested source module and capture all supported splice expansions.
captureModuleSplices :: SpliceRequest -> IO (Either String CapturedSplices)
captureModuleSplices request = do
  capturesRef <- newIORef Map.empty
  dependentFilesRef <- newIORef []
  foreignFilesRef <- newIORef []
  ghcLibDir <- getGhcLibDir
  extraPackages <- getHostGhcPackages
  createDirectoryIfMissing True hostWorkerBuildDir
  result <- runGhc (Just ghcLibDir) $ do
    dflags <- getSessionDynFlags
    setSessionDynFlags (workerDynFlags extraPackages dflags)
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

    workerDynFlags extraPackages dflags =
      (gopt_set dflags Opt_ForceRecomp)
        { importPaths = sourceDir : importPaths dflags
        , objectDir = Just hostWorkerBuildDir
        , hiDir = Just hostWorkerBuildDir
        , stubDir = Just hostWorkerBuildDir
        , packageFlags = map exposeHostPackage extraPackages <> packageFlags dflags
        }

    loadRequestedModule = do
      target <- guessTarget (requestSourceFile request) Nothing Nothing
      setTargets [target]
      load LoadAllTargets

-- | Attach module-level replayable effects to each captured splice result.
attachModuleEffects :: [FilePath] -> [SpliceForeignFile] -> CapturedSplices -> CapturedSplices
attachModuleEffects dependentFiles foreignFiles =
  Map.map
    ( \captured ->
        captured
          { capturedSpliceResult =
              (capturedSpliceResult captured)
                { spliceResultDependentFiles = dependentFiles
                , spliceResultForeignFiles = foreignFiles
                }
          }
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
-- Packaged environments should set @TH_HOST_GHC_LIBDIR@ so the worker does not
-- accidentally discover the consumer GHC from @PATH@. The @ghc --print-libdir@
-- fallback keeps the manually built prototype convenient to run.
getGhcLibDir :: IO FilePath
getGhcLibDir = do
  explicitLibDir <- lookupEnv "TH_HOST_GHC_LIBDIR"
  case explicitLibDir of
    Just libDir -> pure libDir
    Nothing -> trimTrailingNewline <$> readProcess "ghc" ["--print-libdir"] ""

-- | Package names to expose in the host-side GHC session.
--
-- A bare GHC API session does not know the Cabal component package flags from
-- the cross build. The first Nix prototype passes the host-buildable generator
-- dependencies explicitly through this environment variable.
getHostGhcPackages :: IO [String]
getHostGhcPackages = do
  explicitPackages <- lookupEnv "TH_HOST_GHC_PACKAGES"
  pure (maybe [] words explicitPackages)

-- | Convert a package name into the DynFlags representation of @-package name@.
exposeHostPackage :: String -> PackageFlag
exposeHostPackage packageName =
  ExposePackage
    ("-package " <> packageName)
    (PackageArg packageName)
    (ModRenaming True [])

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
--
-- For supported splice kinds, it delegates to the previous runMeta hook or
-- 'defaultRunMeta' first. That produces the real @GhcPs@ expansion in the native
-- session. The hook then pretty-prints the expansion, stores it in 'capturesRef',
-- and returns the original expansion back to GHC so module loading continues.
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
        captureSpliceResult
          ExpressionSplice
          (metaRequestE runMeta)
      pure (wrap expanded)
    MetaD wrap -> do
      expanded <-
        captureDeclarationSpliceResult
          DeclarationSplice
          (metaRequestD runMeta)
      pure (wrap expanded)
    MetaP wrap -> do
      expanded <-
        captureSpliceResult
          PatternSplice
          (metaRequestP runMeta)
      pure (wrap expanded)
    MetaT wrap -> do
      expanded <-
        captureSpliceResult
          TypeSplice
          (metaRequestT runMeta)
      pure (wrap expanded)
    MetaAW wrap -> do
      serialized <-
        captureAnnotationWrapper
          (metaRequestAW runMeta)
      pure (wrap serialized)
  where
    runMeta = fromMaybe defaultRunMeta previousRunMeta

    captureSpliceResult spliceKind evaluateSplice =
      captureRenderedSpliceResult spliceKind evaluateSplice prettyExpanded

    captureDeclarationSpliceResult spliceKind evaluateSplice =
      captureRenderedSpliceResult spliceKind evaluateSplice prettyExpandedDeclarations

    captureRenderedSpliceResult spliceKind evaluateSplice renderExpanded = do
      (expanded, diagnostics, addedTopDecls) <-
        evaluateWithIsolatedSpliceState (evaluateSplice spliceExpr)
      renderedExpansion <- renderExpanded expanded
      renderedAddedTopDecls <- prettyExpandedDeclarations addedTopDecls
      spliceKey <- mkCapturedSpliceKey spliceKind spliceExpr
      dependentFiles <- getDependentFiles
      foreignFiles <- getForeignFiles
      liftIO $ do
        writeIORef dependentFilesRef dependentFiles
        writeIORef foreignFilesRef foreignFiles
        modifyIORef' capturesRef (Map.insert spliceKey (CapturedSplice spliceKind (mkSpliceResult renderedExpansion Nothing renderedAddedTopDecls diagnostics)))
      pure expanded

    captureAnnotationWrapper evaluateSplice = do
      (serialized, diagnostics, _addedTopDecls) <-
        evaluateWithIsolatedSpliceState (evaluateSplice spliceExpr)
      spliceKey <- mkCapturedSpliceKey AnnotationWrapperSplice spliceExpr
      liftIO $ do
        modifyIORef'
          capturesRef
          ( Map.insert
              spliceKey
              ( CapturedSplice
                  AnnotationWrapperSplice
                  (mkSpliceResult "" (Just (encodeAnnotationWrapper serialized)) "" diagnostics)
              )
          )
      pure serialized

-- | Construct a captured splice result before module-level effects are attached.
mkSpliceResult :: String -> Maybe [Word8] -> String -> [SpliceDiagnostic] -> SpliceResult
mkSpliceResult renderedExpansion annotationWrapper renderedAddedTopDecls diagnostics =
  SpliceResult
    { spliceResultHaskell = renderedExpansion
    , spliceResultAnnotationWrapper = annotationWrapper
    , spliceResultDependentFiles = []
    , spliceResultForeignFiles = []
    , spliceResultAddedTopDecls = renderedAddedTopDecls
    , spliceResultDiagnostics = diagnostics
    }

-- | Encode a same-version annotation wrapper payload for the cross-side plugin.
encodeAnnotationWrapper :: Serialized -> [Word8]
encodeAnnotationWrapper =
  LBS.unpack . encode

-- | Evaluate one splice while separately recording replayable TH state.
--
-- Host GHC stores @reportWarning@ and @reportError@ in the current 'TcM'
-- message bag. Temporarily clearing that bag gives us the messages produced by
-- this splice alone; restoring the union afterwards keeps normal host
-- compilation semantics intact.
--
-- @addTopDecls@ similarly writes to a cumulative 'TcGblEnv' ref. Isolating it
-- lets the worker capture declarations added by this splice without duplicating
-- declarations added by earlier splices.
evaluateWithIsolatedSpliceState :: TcM a -> TcM (a, [SpliceDiagnostic], [LHsDecl GhcPs])
evaluateWithIsolatedSpliceState action = do
  errsVar <- getErrsVar
  previousMessages <- readTcRef errsVar
  tcGblEnv <- getGblEnv
  let topDeclsVar = tcg_th_topdecls tcGblEnv
  previousTopDecls <- readTcRef topDeclsVar
  writeTcRef errsVar emptyMessages
  writeTcRef topDeclsVar []
  result <- action
  spliceMessages <- readTcRef errsVar
  addedTopDecls <- readTcRef topDeclsVar
  writeTcRef errsVar (spliceMessages `unionMessages` previousMessages)
  writeTcRef topDeclsVar (addedTopDecls <> previousTopDecls)
  pure (result, extractTHDiagnostics spliceMessages, addedTopDecls)

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

-- | Read foreign files registered through @addForeignFilePath@ in the host GHC
-- session.
getForeignFiles :: TcM [SpliceForeignFile]
getForeignFiles = do
  tcGblEnv <- getGblEnv
  map toSpliceForeignFile <$> readTcRef (tcg_th_foreign_files tcGblEnv)
  where
    toSpliceForeignFile (lang, path) =
      SpliceForeignFile
        { spliceForeignFileLang = lang
        , spliceForeignFilePath = path
        }

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

-- | Convert a generated AST node back to textual Haskell for the wire format.
prettyExpanded :: Outputable a => a -> TcM String
prettyExpanded =
  pure . renderHaskell . ppr

-- | Convert generated declaration ASTs back to textual Haskell for the wire
-- format.
prettyExpandedDeclarations :: [LHsDecl GhcPs] -> TcM String
prettyExpandedDeclarations =
  fmap unlines . mapM prettyExpanded

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
selectCapturedSplice :: SpliceRequest -> CapturedSplices -> Maybe SpliceResult
selectCapturedSplice request captures =
  case Map.lookup (requestSpliceKey request) captures of
    Just captured ->
      Just (capturedSpliceResult captured)
    Nothing ->
      selectAnnotationWrapperFallback request captures

-- | Select the host-side expansion corresponding to the cross-side request, or
-- produce a diagnostic error.
selectCapturedSpliceOrError :: SpliceRequest -> CapturedSplices -> Either String SpliceResult
selectCapturedSpliceOrError request captures =
  case selectCapturedSplice request captures of
    Just spliceResult -> Right spliceResult
    Nothing ->
      Left $
        "host GHC did not capture requested splice; request key "
          <> show (requestSpliceKey request)
          <> "; captured "
          <> show (Map.size captures)
          <> " splice(s): "
          <> show (Map.keys captures)

-- | Annotation declarations replayed from text get synthetic source spans on
-- the cross side. For the MVP, fall back to the only captured annotation wrapper
-- in the module.
selectAnnotationWrapperFallback :: SpliceRequest -> CapturedSplices -> Maybe SpliceResult
selectAnnotationWrapperFallback request captures
  | requestSpliceKind request /= AnnotationWrapperSplice = Nothing
  | otherwise =
      case [capturedSpliceResult captured | captured <- Map.elems captures, capturedSpliceKind captured == AnnotationWrapperSplice] of
        [spliceResult] -> Just spliceResult
        _ -> Nothing

-- | Remove trailing newlines from command output such as @ghc --print-libdir@.
trimTrailingNewline :: String -> String
trimTrailingNewline =
  reverse . dropWhile (`elem` ['\n', '\r']) . reverse
