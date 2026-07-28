{-# LANGUAGE LambdaCase #-}

-- | GHC plugin for intercepting Template Haskell splice evaluation.
--
-- The plugin installs a custom 'runMetaHook' through the driver plugin hook.
-- With @-fplugin-opt=THCross.Plugin:worker=PATH@ it asks an external binary
-- worker for raw Template Haskell AST values, converts them locally, and
-- returns the resulting @GhcPs@ AST.
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
import Data.Char (isSpace)
import Data.Data (Data, gmapT)
import Data.List (dropWhileEnd, isPrefixOf, stripPrefix)
import Data.Maybe (isJust, listToMaybe, mapMaybe)
import Data.Typeable (cast)
import GHC.Data.FastString (unpackFS)
import GHC.Driver.Env.Types (HscEnv (..))
import GHC.Driver.Hooks (Hooks (..))
import GHC.Driver.Plugins
  ( CommandLineOption
  , Plugin (..)
  , defaultPlugin
  , purePlugin
  )
import GHC.Hs
import GHC.Serialized (Serialized)
import GHC.Settings.Config (cProjectVersion)
import GHC.Tc.Errors.Types
  ( AddTopDeclsError (InvalidTopDecl)
  , THError (AddTopDeclsError, ReportCustomQuasiError, THNameError)
  , THNameError (NonExactName)
  , TcRnMessage (TcRnTHError)
  )
import GHC.Tc.Types (TcGblEnv (..), TcM)
import GHC.Tc.Utils.Monad
  ( addDiagnostic
  , addErr
  , getGblEnv
  , liftIO
  , updTcRef
  )
import GHC.ThToHs (convertToHsDecls, convertToHsExpr, convertToHsType, convertToPat)
import GHC.Types.Basic (Origin (FromSource))
import GHC.Types.Meta (MetaHook, MetaRequest (..))
import GHC.Types.SrcLoc
  ( GenLocated (L)
  , SrcSpan (..)
  , srcSpanEndCol
  , srcSpanEndLine
  , srcSpanFile
  , srcSpanStartCol
  , srcSpanStartLine
  , unLoc
  )
import GHC.Types.Name.Reader (RdrName (Exact))
import GHC.Types.Name.Set (extendNameSet)
import GHC.Unit.Module (moduleName, moduleUnitId, unitIdString)
import GHC.Utils.Outputable (ppr, showSDocUnsafe)
import GHCi.TH.Binary ()
import qualified Language.Haskell.TH as TH
import qualified Language.Haskell.TH.Syntax as TH.Syntax
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
        evaluateWorkerExpressionSplice tcGblEnv
      pure (wrap generated)
    MetaD wrap -> do
      generated <-
        evaluateWorkerDeclarationSplice tcGblEnv
      pure (wrap generated)
    MetaP wrap -> do
      generated <-
        evaluateWorkerPatternSplice tcGblEnv
      pure (wrap generated)
    MetaT wrap -> do
      generated <-
        evaluateWorkerTypeSplice tcGblEnv
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

    evaluateWorkerExpressionSplice tcGblEnv =
      do
        spliceResult <-
          requestWorker workerState config (spliceModuleName tcGblEnv) (spliceComponentUnitId tcGblEnv) spliceKind sourceLoc renderedSpan (spliceKey tcGblEnv) renderedSpliceExpr
        replayDependentFiles config (spliceResultDependentFiles spliceResult)
        replayForeignFiles config (spliceResultForeignFiles spliceResult)
        replayAddedTopDecls config (spliceComponentUnitId tcGblEnv) sourceLoc (spliceResultAddedTopDecls spliceResult)
        replayDiagnostics (spliceResultDiagnostics spliceResult)
        convertExpressionSplice config (spliceComponentUnitId tcGblEnv) sourceLoc spliceResult

    evaluateWorkerPatternSplice tcGblEnv =
      do
        spliceResult <-
          requestWorker workerState config (spliceModuleName tcGblEnv) (spliceComponentUnitId tcGblEnv) spliceKind sourceLoc renderedSpan (spliceKey tcGblEnv) renderedSpliceExpr
        replayDependentFiles config (spliceResultDependentFiles spliceResult)
        replayForeignFiles config (spliceResultForeignFiles spliceResult)
        replayAddedTopDecls config (spliceComponentUnitId tcGblEnv) sourceLoc (spliceResultAddedTopDecls spliceResult)
        replayDiagnostics (spliceResultDiagnostics spliceResult)
        convertPatternSplice config (spliceComponentUnitId tcGblEnv) sourceLoc spliceResult

    evaluateWorkerTypeSplice tcGblEnv =
      do
        spliceResult <-
          requestWorker workerState config (spliceModuleName tcGblEnv) (spliceComponentUnitId tcGblEnv) spliceKind sourceLoc renderedSpan (spliceKey tcGblEnv) renderedSpliceExpr
        replayDependentFiles config (spliceResultDependentFiles spliceResult)
        replayForeignFiles config (spliceResultForeignFiles spliceResult)
        replayAddedTopDecls config (spliceComponentUnitId tcGblEnv) sourceLoc (spliceResultAddedTopDecls spliceResult)
        replayDiagnostics (spliceResultDiagnostics spliceResult)
        convertTypeSplice config (spliceComponentUnitId tcGblEnv) sourceLoc spliceResult

    evaluateWorkerDeclarationSplice tcGblEnv =
      do
        spliceResult <-
          requestWorker workerState config (spliceModuleName tcGblEnv) (spliceComponentUnitId tcGblEnv) spliceKind sourceLoc renderedSpan (spliceKey tcGblEnv) renderedSpliceExpr
        replayDependentFiles config (spliceResultDependentFiles spliceResult)
        replayForeignFiles config (spliceResultForeignFiles spliceResult)
        replayDiagnostics (spliceResultDiagnostics spliceResult)
        convertDeclarationSplice config (spliceComponentUnitId tcGblEnv) sourceLoc spliceResult

    evaluateWorkerAnnotationWrapper tcGblEnv =
      do
        spliceResult <-
          requestWorker workerState config (spliceModuleName tcGblEnv) (spliceComponentUnitId tcGblEnv) spliceKind sourceLoc renderedSpan (spliceKey tcGblEnv) renderedSpliceExpr
        replayDependentFiles config (spliceResultDependentFiles spliceResult)
        replayForeignFiles config (spliceResultForeignFiles spliceResult)
        replayAddedTopDecls config (spliceComponentUnitId tcGblEnv) sourceLoc (spliceResultAddedTopDecls spliceResult)
        replayDiagnostics (spliceResultDiagnostics spliceResult)
        decodeAnnotationWrapper spliceResult

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

convertExpressionSplice :: PluginConfig -> String -> SrcSpan -> SpliceResult -> TcM (LHsExpr GhcPs)
convertExpressionSplice config componentUnitId sourceLoc spliceResult =
  case spliceResultExpression spliceResult of
    Nothing ->
      fail "TH host worker did not return an expression payload"
    Just thExp ->
      case convertToHsExpr generatedOrigin sourceLoc (rewriteTHUnitIds (effectiveUnitIdMap config componentUnitId) thExp) of
        Left _err ->
          fail "TH host worker returned an expression payload that GHC could not convert"
        Right hsExp ->
          pure hsExp

convertPatternSplice :: PluginConfig -> String -> SrcSpan -> SpliceResult -> TcM (LPat GhcPs)
convertPatternSplice config componentUnitId sourceLoc spliceResult =
  case spliceResultPattern spliceResult of
    Nothing ->
      fail "TH host worker did not return a pattern payload"
    Just thPat ->
      case convertToPat generatedOrigin sourceLoc (rewriteTHUnitIds (effectiveUnitIdMap config componentUnitId) thPat) of
        Left _err ->
          fail "TH host worker returned a pattern payload that GHC could not convert"
        Right hsPat ->
          pure hsPat

convertTypeSplice :: PluginConfig -> String -> SrcSpan -> SpliceResult -> TcM (LHsType GhcPs)
convertTypeSplice config componentUnitId sourceLoc spliceResult =
  case spliceResultType spliceResult of
    Nothing ->
      fail "TH host worker did not return a type payload"
    Just thType ->
      case convertToHsType generatedOrigin sourceLoc (rewriteTHUnitIds (effectiveUnitIdMap config componentUnitId) thType) of
        Left _err ->
          fail "TH host worker returned a type payload that GHC could not convert"
        Right hsType ->
          pure hsType

convertDeclarationSplice :: PluginConfig -> String -> SrcSpan -> SpliceResult -> TcM [LHsDecl GhcPs]
convertDeclarationSplice config componentUnitId sourceLoc spliceResult = do
  addedDecls <- convertAddedTopDecls config componentUnitId sourceLoc (spliceResultAddedTopDecls spliceResult)
  generatedDecls <-
    case spliceResultDeclarations spliceResult of
      Nothing ->
        fail "TH host worker did not return a declaration payload"
      Just thDecls ->
        case convertToHsDecls generatedOrigin sourceLoc (rewriteTHUnitIds (effectiveUnitIdMap config componentUnitId) thDecls) of
          Left _err ->
            fail "TH host worker returned a declaration payload that GHC could not convert"
          Right hsDecls ->
            pure hsDecls
  pure (addedDecls <> generatedDecls)

convertAddedTopDecls :: PluginConfig -> String -> SrcSpan -> [TH.Dec] -> TcM [LHsDecl GhcPs]
convertAddedTopDecls config componentUnitId sourceLoc addedTopDecls
  | null addedTopDecls = pure []
  | otherwise =
      case convertToHsDecls generatedOrigin sourceLoc (rewriteTHUnitIds (effectiveUnitIdMap config componentUnitId) addedTopDecls) of
        Left _err ->
          fail "TH host worker returned addTopDecls payload that GHC could not convert"
        Right hsDecls ->
          pure hsDecls

effectiveUnitIdMap :: PluginConfig -> String -> [(String, String)]
effectiveUnitIdMap config componentUnitId =
  ("main", componentUnitId) : pluginUnitIdMap config

rewriteTHUnitIds :: Data a => [(String, String)] -> a -> a
rewriteTHUnitIds unitIdMap =
  rewrite
  where
    rewrite :: Data b => b -> b
    rewrite value =
      case cast value :: Maybe TH.Name of
        Just name ->
          case cast (rewriteName name) of
            Just rewritten ->
              rewritten
            Nothing ->
              value
        Nothing ->
          gmapT rewrite value

    rewriteName (TH.Syntax.Name occ (TH.Syntax.NameG namespace packageName nameModule)) =
      TH.Syntax.Name occ (TH.Syntax.NameG namespace (rewritePackageName packageName) nameModule)
    rewriteName name =
      name

    rewritePackageName packageName@(TH.Syntax.PkgName packageNameText) =
      case lookup packageNameText unitIdMap of
        Just targetUnitId ->
          TH.Syntax.PkgName targetUnitId
        Nothing ->
          packageName

generatedOrigin :: Origin
generatedOrigin =
  FromSource

-- | Runtime configuration selected by plugin options.
data PluginConfig = PluginConfig
  { pluginWorkerPath :: !FilePath
  , pluginHostPackageIds :: ![String]
  , pluginUnitIdMap :: ![(String, String)]
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
-- -fplugin-opt=THCross.Plugin:unit-id-map=host-unit-id=target-unit-id
-- -fplugin-opt=THCross.Plugin:host-source-dir=src
-- -fplugin-opt=THCross.Plugin:host-ghc-option=-DNAME
-- -fplugin-opt=THCross.Plugin:debug
-- @
--
-- When the plugin is loaded through @-fplugin-library@, pass the same option
-- strings in that flag's fourth field instead of separate @-fplugin-opt@
-- arguments.
parsePluginConfig :: [CommandLineOption] -> IO PluginConfig
parsePluginConfig rawOpts = do
  opts <- expandConfigOptions rawOpts
  rejectRemovedWireFormatOption opts
  unitIdMap <-
    case findUnitIdMap opts of
      Left err ->
        ioError (userError err)
      Right mappings ->
        pure mappings
  case findWorkerPath opts of
    Just workerPath ->
      pure
        PluginConfig
          { pluginWorkerPath = workerPath
          , pluginHostPackageIds = findHostPackageIds opts
          , pluginUnitIdMap = unitIdMap
          , pluginHostSourceDirs = findHostSourceDirs opts
          , pluginHostGhcOptions = findHostGhcOptions opts
          , pluginDebug = "debug" `elem` opts
          }
    Nothing ->
      ioError (userError "THCross.Plugin requires -fplugin-opt=THCross.Plugin:worker=/path/to/th-host-worker")

expandConfigOptions :: [CommandLineOption] -> IO [CommandLineOption]
expandConfigOptions opts = do
  fileOptions <- traverse readConfigFile (mapMaybe (stripPrefix "config=") opts)
  pure (filter (not . isConfigOption) opts <> concat fileOptions)
  where
    isConfigOption =
      isJust . stripPrefix "config="

readConfigFile :: FilePath -> IO [CommandLineOption]
readConfigFile path = do
  contents <- readFile path
  pure (filter isOptionLine (map stripLine (lines contents)))
  where
    isOptionLine line =
      not (null line) && not ("#" `isPrefixOf` line)

stripLine :: String -> String
stripLine =
  dropWhileEnd isSpace . dropWhile isSpace

rejectRemovedWireFormatOption :: [CommandLineOption] -> IO ()
rejectRemovedWireFormatOption opts =
  case listToMaybe (mapMaybe (stripPrefix "wire-format=") opts) of
    Nothing ->
      pure ()
    Just _ ->
      ioError (userError "THCross.Plugin no longer supports wire-format; raw TH is the only protocol")

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

-- | Extract host-to-target unit id remappings for raw TH exact names.
findUnitIdMap :: [CommandLineOption] -> Either String [(String, String)]
findUnitIdMap opts =
  traverse parseMapping (mapMaybe (stripPrefix "unit-id-map=") opts)
  where
    parseMapping text =
      case break (== '=') text of
        (hostUnitId, '=' : targetUnitId)
          | not (null hostUnitId) && not (null targetUnitId) ->
              Right (hostUnitId, targetUnitId)
        _ ->
          Left ("invalid unit-id-map option: " <> text)

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

-- | Human-readable splice kind used in plugin logging.
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
-- worker to load the source module, capture the corresponding splice, and
-- return raw Template Haskell AST.
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
-- Unhelpful spans cannot identify a real source location, so the plugin uses a
-- synthetic placeholder that keeps the protocol total but will not match a real
-- worker capture.
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
-- This function is shared by all splice kinds. The caller is responsible for
-- selecting the raw payload that matches the specific 'MetaRequest' constructor.
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
replayAddedTopDecls :: PluginConfig -> String -> SrcSpan -> [TH.Dec] -> TcM ()
replayAddedTopDecls config componentUnitId sourceLoc addedTopDecls
  | null addedTopDecls = pure ()
  | otherwise = do
      parsedDecls <- convertAddedTopDecls config componentUnitId sourceLoc addedTopDecls
      recordAddedTopDecls parsedDecls
      whenDebug config ("th-cross: added top decls " <> show (length parsedDecls))

recordAddedTopDecls :: [LHsDecl GhcPs] -> TcM ()
recordAddedTopDecls declarations = do
  mapM_ (checkTopDecl . unLoc) declarations
  tcGblEnv <- getGblEnv
  updTcRef (tcg_th_topdecls tcGblEnv) (declarations <>)
  where
    checkTopDecl (ValD _ binds) =
      mapM_ bindName (collectHsBindBinders CollNoDictBinders binds)
    checkTopDecl (SigD _ _) =
      pure ()
    checkTopDecl (AnnD _ _) =
      pure ()
    checkTopDecl (ForD _ (ForeignImport {fd_name = L _ name})) =
      bindName name
    checkTopDecl declaration =
      addErr (TcRnTHError (AddTopDeclsError (InvalidTopDecl declaration)))

    bindName (Exact name) = do
      tcGblEnv <- getGblEnv
      updTcRef (tcg_th_topnames tcGblEnv) (`extendNameSet` name)
    bindName name =
      addErr (TcRnTHError (THNameError (NonExactName name)))

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
