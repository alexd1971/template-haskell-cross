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
import THCross.ParseFragment (parseExpressionFragment)
import THCross.Protocol
  ( SourceSpan (..)
  , SpliceKind (..)
  , SpliceRequest (..)
  , SpliceResponse (..)
  , decodeResponseLine
  , encodeRequestLine
  , spliceKindText
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
-- external worker and all other request kinds still delegate to GHC.
loggingMetaHook :: PluginMode -> MetaHook TcM
loggingMetaHook mode request spliceExpr = do
  tcg <- getGblEnv
  let modText = moduleNameString (moduleName (tcg_mod tcg))
      kind = metaRequestKind request
      kindText = spliceKindText kind
      sourceLoc = getLocA spliceExpr
      spanText = showSDocUnsafe (ppr (getLocA spliceExpr))
      exprText = showSDocUnsafe (ppr spliceExpr)
  liftIO $ putStrLn "THCross.Plugin intercepted Template Haskell splice"
  liftIO $ putStrLn ("module: " <> modText)
  liftIO $ putStrLn ("kind: " <> kindText)
  liftIO $ putStrLn ("location: " <> spanText)
  liftIO $ putStrLn ("expression: " <> exprText)
  case request of
    MetaE wrap
      | DummyExprMode <- mode -> do
          liftIO $ putStrLn "replacement: 42"
          generated <- parseExpressionFragment "42"
          pure (wrap generated)
      | WorkerMode workerPath <- mode -> do
          let workerRequest =
                mkSpliceRequest modText kind sourceLoc spanText exprText
          liftIO $ putStrLn ("worker: " <> workerPath)
          generatedText <- callWorker workerPath workerRequest >>= \case
            Left err -> do
              liftIO $ putStrLn ("worker-error: " <> err)
              fail err
            Right text -> pure text
          generated <- parseExpressionFragment generatedText
          pure (wrap generated)
    _
      | WorkerMode{} <- mode -> do
          let err =
                "THCross worker mode currently supports only expression splices; got "
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

mkSpliceRequest ::
  String ->
  SpliceKind ->
  SrcSpan ->
  String ->
  String ->
  SpliceRequest
mkSpliceRequest modText kind sourceLoc spanText exprText =
  let (sourceFile, protocolSpan) = protocolSourceSpan sourceLoc
   in SpliceRequest
        { requestId = modText <> ":" <> spliceKindText kind <> ":" <> spanText
        , requestModuleName = modText
        , requestSourceFile = sourceFile
        , requestSpliceKind = kind
        , requestSourceSpan = protocolSpan
        , requestSpliceExpression = exprText
        , requestCrossGhcVersion = cProjectVersion
        }

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
