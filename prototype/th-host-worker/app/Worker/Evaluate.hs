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
import qualified Language.Haskell.TH as TH
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
  , PackageArg (UnitIdArg)
  , PackageFlag (ExposePackage)
  , flagsAll
  , gopt_set
  , hiDir
  , importPaths
  , objectDir
  , packageFlags
  , parseDynamicFlagsFull
  , stubDir
  )
import GHC.Hs (GhcPs, GhcTc, LHsDecl, LHsExpr)
import GHC.Parser.Annotation (getLocA)
import GHC.Serialized (Serialized)
import GHC.Tc.Gen.Splice (defaultRunMeta)
#if MIN_VERSION_ghc(9,10,0)
import GHC.Tc.Gen.Splice (runMeta', runTHExp)
#endif
import GHC.Tc.Errors.Types (THError (ReportCustomQuasiError), TcRnMessage (TcRnTHError))
import GHC.Tc.Types (TcGblEnv (..), TcM)
import GHC.Tc.Utils.Monad (getErrsVar, getGblEnv, liftIO, readTcRef, writeTcRef)
#if MIN_VERSION_ghc(9,10,0)
import GHC.ThToHs (convertToHsExpr)
import GHC.Types.Basic (Origin (FromSource))
#endif
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
  , noLoc
  , srcSpanEndCol
  , srcSpanEndLine
  , srcSpanStartCol
  , srcSpanStartLine
  , unLoc
  )
import GHC.Unit.Module (moduleName, moduleNameString)
import GHC.Unit.Types (stringToUnit)
import GHC.Utils.Outputable
  ( Outputable
  , SDoc
  , defaultSDocContext
  , ppr
  , renderWithContext
  , sdocSuppressUniques
#if MIN_VERSION_ghc(9,10,0)
  , text
#endif
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
  , WireFormat (..)
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

-- | Worker-local cache key for one evaluated splice result.
--
-- 'SpliceKey' identifies the source occurrence. The component unit id and
-- source file scope that occurrence to the Cabal/GHC component context that
-- produced the expansion. The wire format is part of the key because raw TH
-- requests carry payloads that textual requests do not.
data CacheKey = CacheKey
  { cacheKeyComponentUnitId :: !String
  , cacheKeySourceFile :: !FilePath
  , cacheKeyWireFormat :: !WireFormat
  , cacheKeySpliceKey :: !SpliceKey
  }
  deriving (Eq, Ord, Show)

-- | Cached expansion results across requests handled by one worker process.
type CachedSplices = Map.Map CacheKey CapturedSplice

-- | In-process cache of splice expansion results captured by whole-module loads.
--
-- The worker process is persistent, so this cache survives multiple requests
-- handled by one worker. It is intentionally not written to disk yet.
type EvaluationCache = IORef CachedSplices

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
-- creates a native GHC session, adds the Cabal-derived source directories to
-- the import path, installs a capture hook, sets the requested source file as
-- the target, and calls 'load'. During 'load', GHC performs normal
-- declaration-group ordering and invokes the hook for each splice it encounters.
evaluateModuleSpliceResult :: EvaluationCache -> SpliceRequest -> IO (Either String SpliceResult)
evaluateModuleSpliceResult cache request = do
  cached <- selectCachedSplice request <$> readIORef cache
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
          case selectCapturedSpliceOrError request captures of
            Left err ->
              pure (Left err)
            Right spliceResult -> do
              modifyIORef' cache (cacheModuleSplices request captures spliceResult)
              pure (Right spliceResult)

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
        (workerDynFlags extraPackageIds dflags)
        (map noLoc (requestHostGhcOptions request))
    case remainingArgs of
      [] ->
        setSessionDynFlags dflagsWithHostOptions
      _ ->
        fail ("unsupported host GHC option(s): " <> show (map unLoc remainingArgs))
    installCaptureHook (requestWireFormat request) capturesRef dependentFilesRef foreignFilesRef
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

    workerDynFlags extraPackageIds dflags =
      (gopt_set dflags Opt_ForceRecomp)
        { importPaths = workerImportPaths <> importPaths dflags
        , objectDir = Just hostWorkerBuildDir
        , hiDir = Just hostWorkerBuildDir
        , stubDir = Just hostWorkerBuildDir
        , packageFlags =
            map exposeHostPackageId extraPackageIds
              <> packageFlags dflags
        }

    loadRequestedModule = do
      target <- guessTarget (requestSourceFile request) Nothing Nothing
      setTargets [target]
      load LoadAllTargets

-- | Cache key for the exact splice requested by the cross-side compiler.
requestCacheKey :: SpliceRequest -> CacheKey
requestCacheKey request =
  cacheKeyFor request (requestSpliceKey request)

-- | Scope a source-level splice key to the component context that evaluated it.
cacheKeyFor :: SpliceRequest -> SpliceKey -> CacheKey
cacheKeyFor request spliceKey =
  CacheKey
    { cacheKeyComponentUnitId = requestComponentUnitId request
    , cacheKeySourceFile = requestSourceFile request
    , cacheKeyWireFormat = requestWireFormat request
    , cacheKeySpliceKey = spliceKey
    }

-- | Insert all splices captured by one whole-module load into the worker cache.
--
-- The requested key is inserted too so fallback matches, such as annotation
-- wrappers with synthetic cross-side spans, become cache hits on later requests.
cacheModuleSplices :: SpliceRequest -> CapturedSplices -> SpliceResult -> CachedSplices -> CachedSplices
cacheModuleSplices request captures requestedSpliceResult cache =
  Map.insert (requestCacheKey request) requestedCapturedSplice $
    Map.union capturedCacheEntries cache
  where
    requestedCapturedSplice =
      CapturedSplice (requestSpliceKind request) requestedSpliceResult

    capturedCacheEntries =
      Map.fromList
        [ (cacheKeyFor request spliceKey, captured)
        | (spliceKey, captured) <- Map.toList captures
        ]

-- | Find a cached expansion for the request.
--
-- Annotation-wrapper requests can have synthetic cross-side spans after textual
-- declaration replay, so they retain the same single-wrapper fallback used for
-- freshly captured module results.
selectCachedSplice :: SpliceRequest -> CachedSplices -> Maybe SpliceResult
selectCachedSplice request cache =
  case Map.lookup (requestCacheKey request) cache of
    Just captured ->
      Just (capturedSpliceResult captured)
    Nothing ->
      selectCachedAnnotationWrapperFallback request cache

-- | Fallback for annotation wrappers cached from a previous whole-module load.
selectCachedAnnotationWrapperFallback :: SpliceRequest -> CachedSplices -> Maybe SpliceResult
selectCachedAnnotationWrapperFallback request cache
  | requestSpliceKind request /= AnnotationWrapperSplice = Nothing
  | otherwise =
      case
        [ capturedSpliceResult captured
        | (cacheKey, captured) <- Map.toList cache
        , cacheKeyComponentUnitId cacheKey == requestComponentUnitId request
        , cacheKeyWireFormat cacheKey == requestWireFormat request
        , capturedSpliceKind captured == AnnotationWrapperSplice
        ]
      of
        [spliceResult] -> Just spliceResult
        _ -> Nothing

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

-- | Exact host-side unit ids to expose in the host-side GHC session.
--
-- Unit ids correspond to @-package-id@ and avoid ambiguity when several
-- package instances with the same package name are present in a package DB.
getHostGhcPackageIds :: SpliceRequest -> IO [String]
getHostGhcPackageIds request = do
  explicitPackageIds <- lookupEnv "TH_HOST_GHC_PACKAGE_IDS"
  pure (requestHostPackageIds request <> maybe [] words explicitPackageIds)

-- | Convert a unit id into the DynFlags representation of @-package-id unit@.
exposeHostPackageId :: String -> PackageFlag
exposeHostPackageId unitId =
  ExposePackage
    ("-package-id " <> unitId)
    (UnitIdArg (stringToUnit unitId))
    (ModRenaming True [])

-- | Install a host-only hook that delegates to the previous hook/default GHC
-- evaluator, records the generated splice, and returns it unchanged.
installCaptureHook ::
  WireFormat ->
  IORef CapturedSplices ->
  IORef [FilePath] ->
  IORef [SpliceForeignFile] ->
  Ghc ()
installCaptureHook wireFormat capturesRef dependentFilesRef foreignFilesRef = do
  hscEnv <- getSession
  let hooks0 = hsc_hooks hscEnv
      previousRunMeta = runMetaHook hooks0
      hooks1 = hooks0 {runMetaHook = Just (captureMetaHook wireFormat capturesRef dependentFilesRef foreignFilesRef previousRunMeta)}
  setSession hscEnv {hsc_hooks = hooks1}

-- | Host-side 'runMetaHook' wrapper that records expansions without changing
-- native evaluation behavior.
--
-- For supported splice kinds, it delegates to the previous runMeta hook or
-- 'defaultRunMeta' first. That produces the real @GhcPs@ expansion in the native
-- session. The hook then pretty-prints the expansion, stores it in 'capturesRef',
-- and returns the original expansion back to GHC so module loading continues.
captureMetaHook ::
  WireFormat ->
  IORef CapturedSplices ->
  IORef [FilePath] ->
  IORef [SpliceForeignFile] ->
  Maybe (MetaHook TcM) ->
  MetaHook TcM
captureMetaHook wireFormat capturesRef dependentFilesRef foreignFilesRef previousRunMeta request spliceExpr =
  case request of
    MetaE wrap -> do
      expanded <-
        captureExpressionSpliceResult
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

    captureExpressionSpliceResult =
      case wireFormat of
        TextualWireFormat ->
          captureSpliceResult
            ExpressionSplice
            (metaRequestE runMeta)
        RawTHWireFormat ->
          captureRawExpressionSpliceResult

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
        modifyIORef' capturesRef (Map.insert spliceKey (CapturedSplice spliceKind (mkSpliceResult renderedExpansion Nothing Nothing renderedAddedTopDecls diagnostics)))
      pure expanded

    captureRawExpressionSpliceResult =
#if MIN_VERSION_ghc(9,10,0)
      do
        liftIO (hPutStrLn stderr "th-host-worker: raw-th expression start")
        (thExp, diagnostics, addedTopDecls) <-
          evaluateWithIsolatedSpliceState (runMetaExpRaw spliceExpr)
        liftIO (hPutStrLn stderr "th-host-worker: raw-th expression evaluated")
        hsExp <- convertRawExpressionOrFail spliceExpr thExp
        liftIO (hPutStrLn stderr "th-host-worker: raw-th expression converted")
        renderedAddedTopDecls <- prettyExpandedDeclarations addedTopDecls
        spliceKey <- mkCapturedSpliceKey ExpressionSplice spliceExpr
        dependentFiles <- getDependentFiles
        foreignFiles <- getForeignFiles
        liftIO $ do
          writeIORef dependentFilesRef dependentFiles
          writeIORef foreignFilesRef foreignFiles
          modifyIORef'
            capturesRef
            ( Map.insert
                spliceKey
                ( CapturedSplice
                    ExpressionSplice
                    (mkSpliceResult (TH.pprint thExp) (Just thExp) Nothing renderedAddedTopDecls diagnostics)
                )
            )
        pure hsExp
#else
      fail "raw-th wire format requires th-host-worker built with patched GHC 9.10 or newer"
#endif

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
                  (mkSpliceResult "" Nothing (Just (encodeAnnotationWrapper serialized)) "" diagnostics)
              )
          )
      pure serialized

-- | Construct a captured splice result before module-level effects are attached.
mkSpliceResult :: String -> Maybe TH.Exp -> Maybe [Word8] -> String -> [SpliceDiagnostic] -> SpliceResult
mkSpliceResult renderedExpansion rawExpression annotationWrapper renderedAddedTopDecls diagnostics =
  SpliceResult
    { spliceResultHaskell = renderedExpansion
    , spliceResultRawExpression = rawExpression
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

#if MIN_VERSION_ghc(9,10,0)
-- | Evaluate an expression splice to raw Template Haskell syntax without
-- converting it to GHC parsed syntax inside 'runMeta''.
runMetaExpRaw :: LHsExpr GhcTc -> TcM TH.Exp
runMetaExpRaw =
  runMeta'
    True
    (text . TH.pprint)
    (\_srcSpan hval -> Right <$> runTHExp hval)

-- | Convert raw Template Haskell syntax back to parsed GHC syntax so the host
-- GHC load keeps normal splice semantics while the raw payload is captured.
convertRawExpressionOrFail :: LHsExpr GhcTc -> TH.Exp -> TcM (LHsExpr GhcPs)
convertRawExpressionOrFail spliceExpr thExp =
  case convertToHsExpr generatedOrigin (getLocA spliceExpr) thExp of
    Left _err ->
      fail "raw TH expression conversion failed"
    Right hsExp ->
      pure hsExp

generatedOrigin :: Origin
generatedOrigin =
  FromSource
#endif

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
        TcRnTHError (ReportCustomQuasiError isError messageText) ->
          Just (SpliceDiagnostic isError messageText)
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
