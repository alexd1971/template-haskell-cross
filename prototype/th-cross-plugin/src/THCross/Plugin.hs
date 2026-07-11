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
import GHC.Settings.Config (cProjectVersion)
import GHC.Tc.Gen.Splice (defaultRunMeta)
import GHC.Tc.Types (TcGblEnv (..), TcM)
import GHC.Tc.Utils.Monad (getGblEnv, liftIO)
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
import System.Exit (ExitCode (..))
import System.Process (proc, readCreateProcessWithExitCode)
import THCross.ParseFragment (parseDeclarationFragments, parseExpressionFragment)
import THCross.Protocol
  ( SourceSpan (..)
  , SpliceKind (..)
  , SpliceRequest (..)
  , SpliceResponse (..)
  , decodeResponseLine
  , encodeRequestLine
  , sourceSpanKeyText
  , spliceKindText
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
installHook opts hscEnv =
  let hooks0 = hsc_hooks hscEnv
      hooks1 = hooks0 {runMetaHook = Just (loggingMetaHook (pluginMode opts))}
   in pure hscEnv {hsc_hooks = hooks1}

-- | Log metadata for every intercepted TH request and then evaluate it.
--
-- In normal mode this delegates to 'defaultRunMeta', preserving stock GHC TH
-- behavior. In dummy expression mode, only 'MetaE' requests are replaced with
-- @42@. In worker mode, expression splices are delegated to the configured
-- external worker. Declaration splices are also delegated so declaration-group
-- ordering can be preserved for later expression splices.
loggingMetaHook :: PluginMode -> MetaHook TcM
loggingMetaHook mode request spliceExpr = do
  tcg <- getGblEnv
  let spliceModuleName = moduleNameString (moduleName (tcg_mod tcg))
      kind = metaRequestKind request
      kindText = spliceKindText kind
      sourceLoc = getLocA spliceExpr
      spanText = showSDocUnsafe (ppr (getLocA spliceExpr))
      exprText = showSDocUnsafe (ppr spliceExpr)
      (_, protocolSpan) = protocolSourceSpan sourceLoc
      spliceKey = mkSpliceKey spliceModuleName kindText (sourceSpanKeyText protocolSpan)
  liftIO $ putStrLn "th-cross: intercepted Template Haskell splice"
  liftIO $ putStrLn ("module: " <> spliceModuleName)
  liftIO $ putStrLn ("kind: " <> kindText)
  liftIO $ putStrLn ("splice-key: " <> unSpliceKey spliceKey)
  liftIO $ putStrLn ("location: " <> spanText)
  liftIO $ putStrLn ("expression: " <> exprText)
  case request of
    MetaE wrap
      | DummyExprMode <- mode -> do
          liftIO $ putStrLn "replacement: 42"
          generated <- parseExpressionFragment "42"
          pure (wrap generated)
      | WorkerMode workerPath <- mode -> do
          generatedText <- requestWorker workerPath spliceModuleName kind sourceLoc spanText spliceKey exprText
          generated <- parseExpressionFragment generatedText
          pure (wrap generated)
    MetaD wrap
      | WorkerMode workerPath <- mode -> do
          generatedText <- requestWorker workerPath spliceModuleName kind sourceLoc spanText spliceKey exprText
          generated <- parseDeclarationFragments generatedText
          pure (wrap generated)
    _
      | WorkerMode{} <- mode -> do
          let err =
                "worker mode currently supports only expression and declaration splices; got "
                  <> kindText
          liftIO $ putStrLn ("unsupported-splice-kind: " <> err)
          fail err
    _ -> defaultRunMeta request spliceExpr

-- | Runtime behavior selected by plugin options.
data PluginMode
  = PassthroughMode
  | DummyExprMode
  | WorkerMode FilePath
  deriving (Eq, Show)

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
mkSpliceRequest spliceModuleName kind sourceLoc spanText spliceKey exprText =
  let (sourceFile, protocolSpan) = protocolSourceSpan sourceLoc
   in SpliceRequest
        { requestId = spliceModuleName <> ":" <> spliceKindText kind <> ":" <> spanText
        , requestModuleName = spliceModuleName
        , requestSourceFile = sourceFile
        , requestSpliceKind = kind
        , requestSourceSpan = protocolSpan
        , requestSpliceKey = spliceKey
        , requestSpliceExpression = exprText
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
  FilePath ->
  String ->
  SpliceKind ->
  SrcSpan ->
  String ->
  SpliceKey ->
  String ->
  TcM String
requestWorker workerPath spliceModuleName kind sourceLoc spanText spliceKey exprText = do
  let workerRequest =
        mkSpliceRequest spliceModuleName kind sourceLoc spanText spliceKey exprText
  liftIO $ putStrLn ("worker: " <> workerPath)
  callWorker workerPath workerRequest >>= \case
    Left err -> do
      liftIO $ putStrLn ("worker-error: " <> err)
      fail err
    Right text ->
      pure text

-- | Run one JSON-lines request/response exchange with the worker executable.
--
-- The current prototype starts a fresh worker process for each splice. Persistent
-- worker mode in Task 12 should replace this with a long-lived connection while
-- preserving the same protocol-level validation.
callWorker :: FilePath -> SpliceRequest -> TcM (Either String String)
callWorker workerPath request = liftIO $ do
  let input = BL.unpack (encodeRequestLine request)
  (exitCode, out, err) <- readCreateProcessWithExitCode (proc workerPath []) input
  pure $
    case exitCode of
      ExitFailure code ->
        Left ("TH host worker failed with exit code " <> show code <> ": " <> err)
      ExitSuccess ->
        case decodeResponseLine (BL.pack out) of
          Left decodeErr ->
            Left ("TH host worker returned invalid JSON response: " <> decodeErr)
          Right response ->
            handleWorkerResponse (requestId request) response

-- | Validate a worker response and extract the generated Haskell fragment.
--
-- A request id mismatch is treated as a hard protocol error because accepting a
-- fragment for the wrong splice would graft code into the wrong source location.
handleWorkerResponse :: String -> SpliceResponse -> Either String String
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
        SpliceOk _ generated ->
          Right generated
        SpliceError _ message ->
          Left ("TH host worker error: " <> message)
