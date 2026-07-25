{-# LANGUAGE LambdaCase #-}

-- | Prototype GHC plugin for intercepting Template Haskell splice evaluation.
--
-- The plugin installs a custom 'runMetaHook' through the driver plugin hook.
-- With @-fplugin-opt=THCross.Plugin:worker=PATH@ it asks an external binary
-- worker for generated Haskell text, parses that text locally, and returns the
-- resulting @GhcPs@ AST.
module THCross.Plugin (plugin) where

import Control.Concurrent.MVar
  ( MVar
  , modifyMVar
  , newMVar
  )
import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.Binary (decodeOrFail)
import qualified Data.ByteString.Lazy as LBS
import Data.List (stripPrefix)
import Data.Maybe (listToMaybe, mapMaybe)
import GHC.Driver.Env.Types (HscEnv (..))
import GHC.Driver.Hooks (Hooks (..))
import GHC.Driver.Plugins
  ( CommandLineOption
  , Plugin (..)
  , defaultPlugin
  , purePlugin
  )
import GHC.Data.FastString (unpackFS)
import GHC.Parser.Annotation (getLocA)
import GHC.Serialized (Serialized)
import GHC.Settings.Config (cProjectVersion)
import GHC.Tc.Errors.Types (THError (ReportCustomQuasiError), TcRnMessage (TcRnTHError))
import GHC.Tc.Types (TcGblEnv (..), TcM)
import GHC.Tc.Utils.Monad
  ( addDiagnostic
  , addErr
  , getGblEnv
  , liftIO
  , updTcRef
  )
import GHC.Types.Meta (MetaHook, MetaRequest (..))
import GHC.Types.SrcLoc
  ( SrcSpan (..)
  , srcSpanEndCol
  , srcSpanEndLine
  , srcSpanFile
  , srcSpanStartCol
  , srcSpanStartLine
  )
import GHC.Unit.Module (moduleName, moduleNameString, moduleUnitId, unitIdString)
import GHC.Utils.Outputable (ppr, showSDocUnsafe)
import GHCi.TH.Binary ()
import System.IO
  ( Handle
  , hSetBuffering
  , BufferMode (LineBuffering)
  )
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (..)
  , createProcess
  , proc
  )
import THCross.ParseFragment
  ( parseDeclarationFragments
  , parseExpressionFragment
  , parsePatternFragment
  , parseTypeFragment
  )
import THCross.Protocol
  ( SpliceDiagnostic (..)
  , SpliceForeignFile (..)
  , SpliceResult (..)
  , SourceSpan (..)
  , SpliceKind (..)
  , SpliceRequest (..)
  , SpliceResponse (..)
  , foreignSrcLangToStr
  , readResponse
  , sourceSpanKeyText
  , spliceKindToStr
  , writeRequest
  )
import THCross.SpliceKey
  ( SpliceKey
  , mkSpliceKey
  , unSpliceKey
  )

-- | Entry point discovered by GHC when @-fplugin=THCross.Plugin@ is used.
--
-- The plugin only mutates 'HscEnv' to install 'workerMetaHook'; it does not
-- alter Core, typechecking, or parsed/renamed module results.
plugin :: Plugin
plugin =
  defaultPlugin
    { driverPlugin = installHook
    , pluginRecompile = purePlugin
    }

-- | Install the custom 'runMetaHook' into the current compiler session.
--
-- GHC calls this once after loading the plugin. The hook is stored in
-- 'hsc_hooks', so all subsequent TH splice evaluation in this session goes
-- through 'workerMetaHook'.
installHook :: [CommandLineOption] -> HscEnv -> IO HscEnv
installHook opts hscEnv = do
  config <- parsePluginConfig opts
  workerState <- newMVar Nothing
  let hooks0 = hsc_hooks hscEnv
      hooks1 = hooks0 {runMetaHook = Just (workerMetaHook workerState config)}
  pure hscEnv {hsc_hooks = hooks1}

-- | Log metadata for every intercepted TH request and then evaluate it.
--
-- The hook always delegates splice execution to the configured external
-- worker. Debug logging is intentionally orthogonal to behavior: enabling
-- @debug@ only changes observability, not the evaluation path.
workerMetaHook :: WorkerState -> PluginConfig -> MetaHook TcM
workerMetaHook workerState config request spliceExpr = do
  tcGblEnv <- getGblEnv
  debugLog "th-cross: intercepted Template Haskell splice"
  debugLog ("module: " <> spliceModuleName tcGblEnv)
  debugLog ("kind: " <> spliceKindName)
  debugLog ("splice-key: " <> unSpliceKey (spliceKey tcGblEnv))
  debugLog ("location: " <> renderedSpan)
  debugLog ("expression: " <> renderedSpliceExpr)
  case request of
    MetaE wrap -> do
      generated <-
        evaluateWorkerSplice tcGblEnv parseExpressionFragment
      pure (wrap generated)
    MetaD wrap -> do
      generated <-
        evaluateWorkerDeclarationSplice tcGblEnv
      pure (wrap generated)
    MetaP wrap -> do
      generated <-
        evaluateWorkerSplice tcGblEnv parsePatternFragment
      pure (wrap generated)
    MetaT wrap -> do
      generated <-
        evaluateWorkerSplice tcGblEnv parseTypeFragment
      pure (wrap generated)
    MetaAW wrap -> do
      annotationWrapper <-
        evaluateWorkerAnnotationWrapper tcGblEnv
      pure (wrap annotationWrapper)
  where
    debugLog message =
      if pluginDebug config
        then liftIO (putStrLn message)
        else pure ()

    spliceModuleName tcGblEnv =
      moduleNameString (moduleName (tcg_mod tcGblEnv))

    spliceComponentUnitId tcGblEnv =
      unitIdString (moduleUnitId (tcg_mod tcGblEnv))

    spliceKind = metaRequestKind request
    spliceKindName = spliceKindToStr spliceKind
    sourceLoc = getLocA spliceExpr
    renderedSpan = showSDocUnsafe (ppr sourceLoc)
    renderedSpliceExpr = showSDocUnsafe (ppr spliceExpr)
    (_, protocolSpan) = protocolSourceSpan sourceLoc
    spliceKey tcGblEnv =
      mkSpliceKey (spliceModuleName tcGblEnv) spliceKindName (sourceSpanKeyText protocolSpan)

    evaluateWorkerSplice tcGblEnv parseFragment =
      do
        spliceResult <-
          requestWorker workerState config (spliceModuleName tcGblEnv) (spliceComponentUnitId tcGblEnv) spliceKind sourceLoc renderedSpan (spliceKey tcGblEnv) renderedSpliceExpr
        logSpliceResult spliceResult
        replayDependentFiles config (spliceResultDependentFiles spliceResult)
        replayForeignFiles config (spliceResultForeignFiles spliceResult)
        replayAddedTopDecls config (spliceResultAddedTopDecls spliceResult)
        replayDiagnostics (spliceResultDiagnostics spliceResult)
        parseFragment (spliceResultHaskell spliceResult)

    evaluateWorkerDeclarationSplice tcGblEnv =
      do
        spliceResult <-
          requestWorker workerState config (spliceModuleName tcGblEnv) (spliceComponentUnitId tcGblEnv) spliceKind sourceLoc renderedSpan (spliceKey tcGblEnv) renderedSpliceExpr
        logSpliceResult spliceResult
        replayDependentFiles config (spliceResultDependentFiles spliceResult)
        replayForeignFiles config (spliceResultForeignFiles spliceResult)
        replayDiagnostics (spliceResultDiagnostics spliceResult)
        parseDeclarationSpliceResult spliceResult

    parseDeclarationSpliceResult spliceResult = do
      addedDecls <- parseAddedTopDeclsForDeclarationSplice (spliceResultAddedTopDecls spliceResult)
      generatedDecls <- parseDeclarationFragments (spliceResultHaskell spliceResult)
      pure (addedDecls <> generatedDecls)

    parseAddedTopDeclsForDeclarationSplice addedTopDecls
      | null addedTopDecls = pure []
      | otherwise = do
          parsedDecls <- parseDeclarationFragments addedTopDecls
          debugLog ("th-cross: added top decls " <> show (length parsedDecls))
          pure parsedDecls

    evaluateWorkerAnnotationWrapper tcGblEnv =
      do
        spliceResult <-
          requestWorker workerState config (spliceModuleName tcGblEnv) (spliceComponentUnitId tcGblEnv) spliceKind sourceLoc renderedSpan (spliceKey tcGblEnv) renderedSpliceExpr
        logSpliceResult spliceResult
        replayDependentFiles config (spliceResultDependentFiles spliceResult)
        replayForeignFiles config (spliceResultForeignFiles spliceResult)
        replayAddedTopDecls config (spliceResultAddedTopDecls spliceResult)
        replayDiagnostics (spliceResultDiagnostics spliceResult)
        decodeAnnotationWrapper spliceResult

    logSpliceResult spliceResult =
      debugLog ("generated-haskell: " <> spliceResultHaskell spliceResult)

-- | Decode a same-version binary 'Serialized' annotation wrapper returned by
-- the host worker.
decodeAnnotationWrapper :: SpliceResult -> TcM Serialized
decodeAnnotationWrapper spliceResult =
  case spliceResultAnnotationWrapper spliceResult of
    Nothing ->
      fail "TH host worker did not return an annotation wrapper payload"
    Just bytes ->
      case decodeOrFail (LBS.pack bytes) of
        Left (_, _, err) ->
          fail ("TH host worker returned invalid annotation wrapper payload: " <> err)
        Right (_, _, serialized) ->
          pure serialized

-- | Runtime configuration selected by plugin options.
data PluginConfig = PluginConfig
  { pluginWorkerPath :: !FilePath
  , pluginHostPackageIds :: ![String]
  , pluginHostSourceDirs :: ![FilePath]
  , pluginHostGhcOptions :: ![String]
  , pluginDebug :: !Bool
  }
  deriving (Eq, Show)

-- | Persistent worker process state for one GHC session.
type WorkerState = MVar (Maybe WorkerHandle)

-- | Handles for the long-lived binary-protocol worker process.
data WorkerHandle = WorkerHandle
  { workerInput :: !Handle
  , workerOutput :: !Handle
  , workerProcess :: !ProcessHandle
  }

-- | Parse plugin behavior from command-line options.
--
-- Supported options:
--
-- @
-- -fplugin-opt=THCross.Plugin:worker=/path/to/th-host-worker
-- -fplugin-opt=THCross.Plugin:host-package-id=unit-id
-- -fplugin-opt=THCross.Plugin:host-source-dir=src
-- -fplugin-opt=THCross.Plugin:host-ghc-option=-DNAME
-- -fplugin-opt=THCross.Plugin:debug
-- @
--
-- When the plugin is loaded through @-fplugin-library@, pass the same option
-- strings in that flag's fourth field instead of separate @-fplugin-opt@
-- arguments.
parsePluginConfig :: [CommandLineOption] -> IO PluginConfig
parsePluginConfig opts =
  case findWorkerPath opts of
    Just workerPath ->
      pure
        PluginConfig
          { pluginWorkerPath = workerPath
          , pluginHostPackageIds = findHostPackageIds opts
          , pluginHostSourceDirs = findHostSourceDirs opts
          , pluginHostGhcOptions = findHostGhcOptions opts
          , pluginDebug = "debug" `elem` opts
          }
    Nothing ->
      ioError (userError "THCross.Plugin requires -fplugin-opt=THCross.Plugin:worker=/path/to/th-host-worker")

-- | Extract the external worker executable path from plugin options.
--
-- The expected option shape is @worker=/absolute/or/relative/path@. The plugin
-- intentionally does not resolve the path here; process creation reports any
-- missing executable error at splice evaluation time.
findWorkerPath :: [CommandLineOption] -> Maybe FilePath
findWorkerPath = listToMaybe . mapMaybe (stripPrefix "worker=")

-- | Extract exact host-side unit ids that the worker should expose while
-- loading the source module with native GHC.
findHostPackageIds :: [CommandLineOption] -> [String]
findHostPackageIds =
  mapMaybe (stripPrefix "host-package-id=")

-- | Extract extra source directories visible to the host-side GHC session.
findHostSourceDirs :: [CommandLineOption] -> [FilePath]
findHostSourceDirs =
  mapMaybe (stripPrefix "host-source-dir=")

-- | Extract extra GHC command-line options for the host-side module load.
findHostGhcOptions :: [CommandLineOption] -> [String]
findHostGhcOptions =
  mapMaybe (stripPrefix "host-ghc-option=")

-- | Emit a plugin debug line when @debug@ was passed in plugin options.
whenDebug :: PluginConfig -> String -> TcM ()
whenDebug config message =
  when (pluginDebug config) (liftIO (putStrLn message))

-- | Human-readable splice kind used in prototype logging.
metaRequestKind :: MetaRequest -> SpliceKind
metaRequestKind = \case
  MetaE{} -> ExpressionSplice
  MetaP{} -> PatternSplice
  MetaT{} -> TypeSplice
  MetaD{} -> DeclarationSplice
  MetaAW{} -> AnnotationWrapperSplice

-- | Build the protocol request sent to the host worker.
--
-- The request contains enough diagnostic and matching information for the
-- worker to load the source module, capture the corresponding splice, and return
-- textual generated Haskell.
mkSpliceRequest ::
  String ->
  String ->
  SpliceKind ->
  SrcSpan ->
  String ->
  SpliceKey ->
  String ->
  [String] ->
  [FilePath] ->
  [String] ->
  SpliceRequest
mkSpliceRequest spliceModuleName componentUnitId spliceKind sourceLoc renderedSpan spliceKey renderedSpliceExpr hostPackageIds hostSourceDirs hostGhcOptions =
  let (sourceFile, protocolSpan) = protocolSourceSpan sourceLoc
   in SpliceRequest
        { requestId = spliceModuleName <> ":" <> spliceKindToStr spliceKind <> ":" <> renderedSpan
        , requestModuleName = spliceModuleName
        , requestComponentUnitId = componentUnitId
        , requestSourceFile = sourceFile
        , requestSpliceKind = spliceKind
        , requestSourceSpan = protocolSpan
        , requestSpliceKey = spliceKey
        , requestSpliceExpression = renderedSpliceExpr
        , requestCrossGhcVersion = cProjectVersion
        , requestHostPackageIds = hostPackageIds
        , requestHostSourceDirs = hostSourceDirs
        , requestHostGhcOptions = hostGhcOptions
        }

-- | Convert GHC's source span into protocol data.
--
-- Real spans carry both the source file path and 1-based line/column bounds.
-- Unhelpful spans cannot identify a real source location, so the prototype uses
-- a synthetic placeholder that keeps the protocol total but will not match a
-- real worker capture.
protocolSourceSpan :: SrcSpan -> (FilePath, SourceSpan)
protocolSourceSpan = \case
  RealSrcSpan realSpan _ ->
    ( unpackFS (srcSpanFile realSpan)
    , SourceSpan
        { sourceSpanStartLine = srcSpanStartLine realSpan
        , sourceSpanStartColumn = srcSpanStartCol realSpan
        , sourceSpanEndLine = srcSpanEndLine realSpan
        , sourceSpanEndColumn = srcSpanEndCol realSpan
        }
    )
  UnhelpfulSpan _ ->
    ("<unknown>", SourceSpan 1 1 1 1)

-- | Ask the configured host worker to evaluate one splice.
--
-- This function is shared by expression and declaration splices. The caller is
-- responsible for parsing the returned textual Haskell into the result shape
-- required by the specific 'MetaRequest' constructor.
requestWorker ::
  WorkerState ->
  PluginConfig ->
  String ->
  String ->
  SpliceKind ->
  SrcSpan ->
  String ->
  SpliceKey ->
  String ->
  TcM SpliceResult
requestWorker workerState config spliceModuleName componentUnitId spliceKind sourceLoc renderedSpan spliceKey renderedSpliceExpr = do
  let workerRequest =
        mkSpliceRequest spliceModuleName componentUnitId spliceKind sourceLoc renderedSpan spliceKey renderedSpliceExpr (pluginHostPackageIds config) (pluginHostSourceDirs config) (pluginHostGhcOptions config)
  whenDebug config ("worker: " <> pluginWorkerPath config)
  callWorker config workerState (pluginWorkerPath config) workerRequest >>= \case
    Left err -> do
      whenDebug config ("worker-error: " <> err)
      fail err
    Right spliceResult ->
      pure spliceResult

-- | Replay host-side @addDependentFile@ effects in the cross-side GHC session.
replayDependentFiles :: PluginConfig -> [FilePath] -> TcM ()
replayDependentFiles config dependentFiles = do
  tcGblEnv <- getGblEnv
  updTcRef (tcg_dependent_files tcGblEnv) (dependentFiles <>)
  mapM_ (whenDebug config . ("th-cross: dependent file " <>)) dependentFiles

-- | Replay host-side @addForeignFilePath@ effects in the cross GHC session.
replayForeignFiles :: PluginConfig -> [SpliceForeignFile] -> TcM ()
replayForeignFiles config foreignFiles = do
  tcGblEnv <- getGblEnv
  updTcRef (tcg_th_foreign_files tcGblEnv) (foreignFileTuples <>)
  mapM_
    ( \foreignFile ->
        whenDebug config
          ( "th-cross: foreign file "
              <> foreignSrcLangToStr (spliceForeignFileLang foreignFile)
              <> " "
              <> spliceForeignFilePath foreignFile
          )
    )
    foreignFiles
  where
    foreignFileTuples =
      map
        ( \foreignFile ->
            (spliceForeignFileLang foreignFile, spliceForeignFilePath foreignFile)
        )
        foreignFiles

-- | Replay host-side @addTopDecls@ effects in the cross GHC session.
replayAddedTopDecls :: PluginConfig -> String -> TcM ()
replayAddedTopDecls config addedTopDecls
  | null addedTopDecls = pure ()
  | otherwise = do
      parsedDecls <- parseDeclarationFragments addedTopDecls
      tcGblEnv <- getGblEnv
      updTcRef (tcg_th_topdecls tcGblEnv) (parsedDecls <>)
      whenDebug config ("th-cross: added top decls " <> show (length parsedDecls))

-- | Replay host-side @reportWarning@ and @reportError@ effects in cross GHC.
replayDiagnostics :: [SpliceDiagnostic] -> TcM ()
replayDiagnostics =
  mapM_ replayDiagnostic
  where
    replayDiagnostic diagnostic =
      let message =
            TcRnTHError
              ( ReportCustomQuasiError
                  (spliceDiagnosticIsError diagnostic)
                  (spliceDiagnosticMessage diagnostic)
              )
       in if spliceDiagnosticIsError diagnostic
            then addErr message
            else addDiagnostic message

-- | Run one binary request/response exchange with the worker executable.
--
-- The worker process is started lazily on the first splice and then reused for
-- later splices in the same GHC session.
callWorker :: PluginConfig -> WorkerState -> FilePath -> SpliceRequest -> TcM (Either String SpliceResult)
callWorker config workerState workerPath request =
  liftIO $
    modifyMVar workerState $ \maybeWorker -> do
      worker <-
        case maybeWorker of
          Just existingWorker -> do
            when (pluginDebug config) (putStrLn "th-cross: reusing worker")
            pure existingWorker
          Nothing -> do
            when (pluginDebug config) (putStrLn ("th-cross: started worker " <> workerPath))
            startWorker workerPath
      result <- sendWorkerRequest worker request
      pure (Just worker, result)

-- | Start the binary-protocol worker and keep its stdin/stdout open.
startWorker :: FilePath -> IO WorkerHandle
startWorker workerPath = do
  (Just workerIn, Just workerOut, Nothing, workerProcessHandle) <-
    createProcess
      (proc workerPath [])
        { std_in = CreatePipe
        , std_out = CreatePipe
        , std_err = Inherit
        }
  hSetBuffering workerIn LineBuffering
  hSetBuffering workerOut LineBuffering
  pure
    WorkerHandle
      { workerInput = workerIn
      , workerOutput = workerOut
      , workerProcess = workerProcessHandle
      }

-- | Send one request over an already running worker process and read its response.
sendWorkerRequest :: WorkerHandle -> SpliceRequest -> IO (Either String SpliceResult)
sendWorkerRequest worker request = do
  output <- try $ do
    writeRequest (workerInput worker) request
    readResponse (workerOutput worker)
  pure $
    case output of
      Left err ->
        Left ("TH host worker communication failed: " <> show (err :: IOException))
      Right responseOrError ->
        case responseOrError of
          Left decodeErr ->
            Left ("TH host worker returned invalid binary response: " <> decodeErr)
          Right response ->
            handleWorkerResponse (requestId request) response

-- | Validate a worker response and extract the splice result.
--
-- A request id mismatch is treated as a hard protocol error because accepting a
-- fragment for the wrong splice would graft code into the wrong source location.
handleWorkerResponse :: String -> SpliceResponse -> Either String SpliceResult
handleWorkerResponse expectedRequestId response
  | responseRequestId response /= expectedRequestId =
      Left
        ( "TH host worker response requestId mismatch: expected "
            <> expectedRequestId
            <> ", got "
            <> responseRequestId response
        )
  | otherwise =
      case response of
        SpliceOk _ spliceResult ->
          Right spliceResult
        SpliceError _ message ->
          Left ("TH host worker error: " <> message)
