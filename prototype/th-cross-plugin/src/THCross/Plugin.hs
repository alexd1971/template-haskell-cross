{-# LANGUAGE LambdaCase #-}

-- | Prototype GHC plugin for intercepting Template Haskell splice evaluation.
--
-- The plugin installs a custom 'runMetaHook' through the driver plugin hook.
-- By default it logs each splice and delegates to GHC's normal Template
-- Haskell evaluator. With @-fplugin-opt=THCross.Plugin:dummy-expr@ it replaces
-- expression splices with locally parsed @42@. With
-- @-fplugin-opt=THCross.Plugin:worker=PATH@ it asks an external JSON-lines
-- worker for generated Haskell text, parses that text locally, and returns the
-- resulting @GhcPs@ AST.
module THCross.Plugin (plugin) where

import Control.Concurrent.MVar
  ( MVar
  , modifyMVar
  , newMVar
  )
import Control.Exception (IOException, try)
import Data.Binary (decodeOrFail)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as BL
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
import GHC.Tc.Gen.Splice (defaultRunMeta)
import GHC.Tc.Errors.Types (THError (ReportCustomQuasiError), TcRnMessage (TcRnTHError))
import GHC.Tc.Types (TcGblEnv (..), TcM)
import GHC.Tc.Utils.Monad (addDiagnostic, addErr, getGblEnv, liftIO, updTcRef)
import GHC.Types.Meta (MetaHook, MetaRequest (..))
import GHC.Types.SrcLoc
  ( SrcSpan (..)
  , srcSpanEndCol
  , srcSpanEndLine
  , srcSpanFile
  , srcSpanStartCol
  , srcSpanStartLine
  )
import GHC.Unit.Module (moduleName, moduleNameString)
import GHC.Utils.Outputable (ppr, showSDocUnsafe)
import GHCi.TH.Binary ()
import System.IO
  ( Handle
  , hFlush
  , hGetLine
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
  , decodeResponseLine
  , encodeRequestLine
  , foreignSrcLangToStr
  , sourceSpanKeyText
  , spliceKindToStr
  )
import THCross.SpliceKey
  ( SpliceKey
  , mkSpliceKey
  , unSpliceKey
  )

-- | Entry point discovered by GHC when @-fplugin=THCross.Plugin@ is used.
--
-- The plugin only mutates 'HscEnv' to install 'loggingMetaHook'; it does not
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
-- through 'loggingMetaHook'.
installHook :: [CommandLineOption] -> HscEnv -> IO HscEnv
installHook opts hscEnv = do
  workerState <- newMVar Nothing
  let hooks0 = hsc_hooks hscEnv
      hooks1 = hooks0 {runMetaHook = Just (loggingMetaHook workerState (pluginMode opts))}
  pure hscEnv {hsc_hooks = hooks1}

-- | Log metadata for every intercepted TH request and then evaluate it.
--
-- In normal mode this delegates to 'defaultRunMeta', preserving stock GHC TH
-- behavior. In dummy expression mode, only 'MetaE' requests are replaced with
-- @42@. In worker mode, expression splices are delegated to the configured
-- external worker. Declaration splices are also delegated so declaration-group
-- ordering can be preserved for later expression splices.
loggingMetaHook :: WorkerState -> PluginMode -> MetaHook TcM
loggingMetaHook workerState mode request spliceExpr = do
  tcGblEnv <- getGblEnv
  liftIO $ putStrLn "th-cross: intercepted Template Haskell splice"
  liftIO $ putStrLn ("module: " <> spliceModuleName tcGblEnv)
  liftIO $ putStrLn ("kind: " <> spliceKindName)
  liftIO $ putStrLn ("splice-key: " <> unSpliceKey (spliceKey tcGblEnv))
  liftIO $ putStrLn ("location: " <> renderedSpan)
  liftIO $ putStrLn ("expression: " <> renderedSpliceExpr)
  case request of
    MetaE wrap
      | DummyExprMode <- mode -> do
          liftIO $ putStrLn "replacement: 42"
          generated <- parseExpressionFragment "42"
          pure (wrap generated)
      | WorkerMode{} <- mode -> do
          generated <-
            evaluateWorkerSplice tcGblEnv parseExpressionFragment
          pure (wrap generated)
    MetaD wrap
      | WorkerMode{} <- mode -> do
          generated <-
            evaluateWorkerDeclarationSplice tcGblEnv
          pure (wrap generated)
    MetaP wrap
      | WorkerMode{} <- mode -> do
          generated <-
            evaluateWorkerSplice tcGblEnv parsePatternFragment
          pure (wrap generated)
    MetaT wrap
      | WorkerMode{} <- mode -> do
          generated <-
            evaluateWorkerSplice tcGblEnv parseTypeFragment
          pure (wrap generated)
    MetaAW wrap
      | WorkerMode{} <- mode -> do
          annotationWrapper <-
            evaluateWorkerAnnotationWrapper tcGblEnv
          pure (wrap annotationWrapper)
    _ -> defaultRunMeta request spliceExpr
  where
    spliceModuleName tcGblEnv =
      moduleNameString (moduleName (tcg_mod tcGblEnv))

    spliceKind = metaRequestKind request
    spliceKindName = spliceKindToStr spliceKind
    sourceLoc = getLocA spliceExpr
    renderedSpan = showSDocUnsafe (ppr sourceLoc)
    renderedSpliceExpr = showSDocUnsafe (ppr spliceExpr)
    (_, protocolSpan) = protocolSourceSpan sourceLoc
    spliceKey tcGblEnv =
      mkSpliceKey (spliceModuleName tcGblEnv) spliceKindName (sourceSpanKeyText protocolSpan)

    evaluateWorkerSplice tcGblEnv parseFragment =
      case mode of
        WorkerMode workerPath -> do
          spliceResult <-
            requestWorker workerState workerPath (spliceModuleName tcGblEnv) spliceKind sourceLoc renderedSpan (spliceKey tcGblEnv) renderedSpliceExpr
          replayDependentFiles (spliceResultDependentFiles spliceResult)
          replayForeignFiles (spliceResultForeignFiles spliceResult)
          replayAddedTopDecls (spliceResultAddedTopDecls spliceResult)
          replayDiagnostics (spliceResultDiagnostics spliceResult)
          parseFragment (spliceResultHaskell spliceResult)
        _ ->
          fail "evaluateWorkerSplice called outside worker mode"

    evaluateWorkerDeclarationSplice tcGblEnv =
      case mode of
        WorkerMode workerPath -> do
          spliceResult <-
            requestWorker workerState workerPath (spliceModuleName tcGblEnv) spliceKind sourceLoc renderedSpan (spliceKey tcGblEnv) renderedSpliceExpr
          replayDependentFiles (spliceResultDependentFiles spliceResult)
          replayForeignFiles (spliceResultForeignFiles spliceResult)
          replayDiagnostics (spliceResultDiagnostics spliceResult)
          parseDeclarationSpliceResult spliceResult
        _ ->
          fail "evaluateWorkerDeclarationSplice called outside worker mode"

    parseDeclarationSpliceResult spliceResult = do
      addedDecls <- parseAddedTopDeclsForDeclarationSplice (spliceResultAddedTopDecls spliceResult)
      generatedDecls <- parseDeclarationFragments (spliceResultHaskell spliceResult)
      pure (addedDecls <> generatedDecls)

    parseAddedTopDeclsForDeclarationSplice addedTopDecls
      | null addedTopDecls = pure []
      | otherwise = do
          parsedDecls <- parseDeclarationFragments addedTopDecls
          liftIO $
            putStrLn
              ( "th-cross: added top decls "
                  <> show (length parsedDecls)
              )
          pure parsedDecls

    evaluateWorkerAnnotationWrapper tcGblEnv =
      case mode of
        WorkerMode workerPath -> do
          spliceResult <-
            requestWorker workerState workerPath (spliceModuleName tcGblEnv) spliceKind sourceLoc renderedSpan (spliceKey tcGblEnv) renderedSpliceExpr
          replayDependentFiles (spliceResultDependentFiles spliceResult)
          replayForeignFiles (spliceResultForeignFiles spliceResult)
          replayAddedTopDecls (spliceResultAddedTopDecls spliceResult)
          replayDiagnostics (spliceResultDiagnostics spliceResult)
          decodeAnnotationWrapper spliceResult
        _ ->
          fail "evaluateWorkerAnnotationWrapper called outside worker mode"

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

-- | Runtime behavior selected by plugin options.
data PluginMode
  = PassthroughMode
  | DummyExprMode
  | WorkerMode FilePath
  deriving (Eq, Show)

-- | Persistent worker process state for one GHC session.
type WorkerState = MVar (Maybe WorkerHandle)

-- | Handles for the long-lived JSON-lines worker process.
data WorkerHandle = WorkerHandle
  { workerInput :: !Handle
  , workerOutput :: !Handle
  , workerProcess :: !ProcessHandle
  }

-- | Select plugin behavior from command-line options.
--
-- Supported options:
--
-- @
-- -fplugin-opt=THCross.Plugin:dummy-expr
-- -fplugin-opt=THCross.Plugin:worker=/path/to/th-host-worker
-- @
pluginMode :: [CommandLineOption] -> PluginMode
pluginMode opts
  | "dummy-expr" `elem` opts = DummyExprMode
  | Just workerPath <- findWorkerPath opts = WorkerMode workerPath
  | otherwise = PassthroughMode

-- | Extract the external worker executable path from plugin options.
--
-- The expected option shape is @worker=/absolute/or/relative/path@. The plugin
-- intentionally does not resolve the path here; process creation reports any
-- missing executable error at splice evaluation time.
findWorkerPath :: [CommandLineOption] -> Maybe FilePath
findWorkerPath = listToMaybe . mapMaybe (stripPrefix "worker=")

-- | Human-readable splice kind used in prototype logging.
metaRequestKind :: MetaRequest -> SpliceKind
metaRequestKind = \case
  MetaE{} -> ExpressionSplice
  MetaP{} -> PatternSplice
  MetaT{} -> TypeSplice
  MetaD{} -> DeclarationSplice
  MetaAW{} -> AnnotationWrapperSplice

-- | Build the JSON-lines protocol request sent to the host worker.
--
-- The request contains enough diagnostic and matching information for the
-- worker to load the source module, capture the corresponding splice, and return
-- textual generated Haskell.
mkSpliceRequest ::
  String ->
  SpliceKind ->
  SrcSpan ->
  String ->
  SpliceKey ->
  String ->
  SpliceRequest
mkSpliceRequest spliceModuleName spliceKind sourceLoc renderedSpan spliceKey renderedSpliceExpr =
  let (sourceFile, protocolSpan) = protocolSourceSpan sourceLoc
   in SpliceRequest
        { requestId = spliceModuleName <> ":" <> spliceKindToStr spliceKind <> ":" <> renderedSpan
        , requestModuleName = spliceModuleName
        , requestSourceFile = sourceFile
        , requestSpliceKind = spliceKind
        , requestSourceSpan = protocolSpan
        , requestSpliceKey = spliceKey
        , requestSpliceExpression = renderedSpliceExpr
        , requestCrossGhcVersion = cProjectVersion
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
  FilePath ->
  String ->
  SpliceKind ->
  SrcSpan ->
  String ->
  SpliceKey ->
  String ->
  TcM SpliceResult
requestWorker workerState workerPath spliceModuleName spliceKind sourceLoc renderedSpan spliceKey renderedSpliceExpr = do
  let workerRequest =
        mkSpliceRequest spliceModuleName spliceKind sourceLoc renderedSpan spliceKey renderedSpliceExpr
  liftIO $ putStrLn ("worker: " <> workerPath)
  callWorker workerState workerPath workerRequest >>= \case
    Left err -> do
      liftIO $ putStrLn ("worker-error: " <> err)
      fail err
    Right spliceResult ->
      pure spliceResult

-- | Replay host-side @addDependentFile@ effects in the cross-side GHC session.
replayDependentFiles :: [FilePath] -> TcM ()
replayDependentFiles dependentFiles = do
  tcGblEnv <- getGblEnv
  updTcRef (tcg_dependent_files tcGblEnv) (dependentFiles <>)
  liftIO $
    mapM_
      (\filePath -> putStrLn ("th-cross: dependent file " <> filePath))
      dependentFiles

-- | Replay host-side @addForeignFilePath@ effects in the cross GHC session.
replayForeignFiles :: [SpliceForeignFile] -> TcM ()
replayForeignFiles foreignFiles = do
  tcGblEnv <- getGblEnv
  updTcRef (tcg_th_foreign_files tcGblEnv) (foreignFileTuples <>)
  liftIO $
    mapM_
      ( \foreignFile ->
          putStrLn
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
replayAddedTopDecls :: String -> TcM ()
replayAddedTopDecls addedTopDecls
  | null addedTopDecls = pure ()
  | otherwise = do
      parsedDecls <- parseDeclarationFragments addedTopDecls
      tcGblEnv <- getGblEnv
      updTcRef (tcg_th_topdecls tcGblEnv) (parsedDecls <>)
      liftIO $
        putStrLn
          ( "th-cross: added top decls "
              <> show (length parsedDecls)
          )

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

-- | Run one JSON-lines request/response exchange with the worker executable.
--
-- The worker process is started lazily on the first splice and then reused for
-- later splices in the same GHC session.
callWorker :: WorkerState -> FilePath -> SpliceRequest -> TcM (Either String SpliceResult)
callWorker workerState workerPath request =
  liftIO $
    modifyMVar workerState $ \maybeWorker -> do
      worker <-
        case maybeWorker of
          Just existingWorker -> do
            putStrLn "th-cross: reusing worker"
            pure existingWorker
          Nothing -> do
            putStrLn ("th-cross: started worker " <> workerPath)
            startWorker workerPath
      result <- sendWorkerRequest worker request
      pure (Just worker, result)

-- | Start the JSON-lines worker and keep its stdin/stdout open.
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
    BL.hPutStr (workerInput worker) (encodeRequestLine request)
    hFlush (workerInput worker)
    hGetLine (workerOutput worker)
  pure $
    case output of
      Left err ->
        Left ("TH host worker communication failed: " <> show (err :: IOException))
      Right out ->
        case decodeResponseLine (BL.pack out) of
          Left decodeErr ->
            Left ("TH host worker returned invalid JSON response: " <> decodeErr)
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
