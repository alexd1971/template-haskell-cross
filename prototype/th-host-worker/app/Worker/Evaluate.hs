{-# LANGUAGE LambdaCase #-}

-- | Host-side Template Haskell evaluation through a native GHC session.
module Worker.Evaluate
  ( evaluateModuleSplice
  ) where

import Control.Exception (SomeException, catch, displayException)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import System.Directory (createDirectoryIfMissing)
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
  , gopt_set
  , hiDir
  , importPaths
  , objectDir
  , stubDir
  )
import GHC.Hs (GhcPs, GhcTc, LHsDecl, LHsExpr)
import GHC.Parser.Annotation (getLocA)
import GHC.Tc.Gen.Splice (defaultRunMeta)
import GHC.Tc.Types (TcGblEnv (..), TcM)
import GHC.Tc.Utils.Monad (getGblEnv, liftIO)
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
  ( SourceSpan (..)
  , SpliceKind (..)
  , SpliceRequest (..)
  , SpliceResponse (..)
  , sourceSpanKeyText
  , spliceKindText
  )
import THCross.SpliceKey
  ( SpliceKey
  , mkSpliceKey
  )

-- | Evaluate the requested splice and preserve the original request id.
evaluateModuleSplice :: SpliceRequest -> IO SpliceResponse
evaluateModuleSplice request = do
  result <- evaluateModuleSpliceText request `catch` handleEvalException
  pure $
    case result of
      Right generated ->
        SpliceOk (requestId request) generated
      Left err ->
        SpliceError (requestId request) err

-- | Convert unexpected GHC API/runtime exceptions into protocol errors.
handleEvalException :: SomeException -> IO (Either String String)
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
evaluateModuleSpliceText :: SpliceRequest -> IO (Either String String)
evaluateModuleSpliceText request = do
  capturesRef <- newIORef Map.empty
  ghcLibDir <- getGhcLibDir
  createDirectoryIfMissing True hostWorkerBuildDir
  result <- runGhc (Just ghcLibDir) $ do
    dflags <- getSessionDynFlags
    let sourceDir = takeDirectory (requestSourceFile request)
        dflagsWithSourceDir =
          (gopt_set dflags Opt_ForceRecomp)
            { importPaths = sourceDir : importPaths dflags
            , objectDir = Just hostWorkerBuildDir
            , hiDir = Just hostWorkerBuildDir
            , stubDir = Just hostWorkerBuildDir
            }
    setSessionDynFlags dflagsWithSourceDir
    installCaptureHook capturesRef
    target <- guessTarget (requestSourceFile request) Nothing Nothing
    setTargets [target]
    load LoadAllTargets
  case result of
    Failed ->
      pure (Left ("host GHC failed to load " <> requestSourceFile request))
    Succeeded -> do
      captures <- readIORef capturesRef
      pure (selectCapturedSplice request captures)

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

-- | Splice expansions captured while native GHC loaded the requested module.
type CapturedSplices = Map.Map SpliceKey String

-- | Install a host-only hook that delegates to the previous hook/default GHC
-- evaluator, records the generated splice, and returns it unchanged.
installCaptureHook :: IORef CapturedSplices -> Ghc ()
installCaptureHook capturesRef = do
  hscEnv <- getSession
  let hooks0 = hsc_hooks hscEnv
      previousRunMeta = runMetaHook hooks0
      hooks1 = hooks0 {runMetaHook = Just (captureMetaHook capturesRef previousRunMeta)}
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
  Maybe (MetaHook TcM) ->
  MetaHook TcM
captureMetaHook capturesRef previousRunMeta request spliceExpr =
  case request of
    MetaE wrap -> do
      expanded <- metaRequestE runMeta spliceExpr
      generatedText <- prettyExpandedExpression expanded
      spliceKey <- mkCapturedSpliceKey ExpressionSplice spliceExpr
      liftIO $ modifyIORef' capturesRef (Map.insert spliceKey generatedText)
      pure (wrap expanded)
    MetaD wrap -> do
      expanded <- metaRequestD runMeta spliceExpr
      generatedText <- prettyExpandedDeclarations expanded
      spliceKey <- mkCapturedSpliceKey DeclarationSplice spliceExpr
      liftIO $ modifyIORef' capturesRef (Map.insert spliceKey generatedText)
      pure (wrap expanded)
    _ ->
      runMeta request spliceExpr
  where
    runMeta = fromMaybe defaultRunMeta previousRunMeta

-- | Attach the source-occurrence splice key to a captured expansion.
--
-- This runs in 'TcM' inside the host compiler, so it can read the current
-- 'TcGblEnv' to discover which module is being compiled when the splice fires.
mkCapturedSpliceKey ::
  SpliceKind ->
  LHsExpr GhcTc ->
  TcM SpliceKey
mkCapturedSpliceKey spliceKind spliceExpr = do
  tcg <- getGblEnv
  let spliceModuleName = moduleNameString (moduleName (tcg_mod tcg))
      sourceSpan = protocolSourceSpan (getLocA spliceExpr)
      kindText = spliceKindText spliceKind
  pure (mkSpliceKey spliceModuleName kindText (sourceSpanKeyText sourceSpan))

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
selectCapturedSplice :: SpliceRequest -> CapturedSplices -> Either String String
selectCapturedSplice request captures =
  case Map.lookup (requestSpliceKey request) captures of
    Just generatedText ->
      Right generatedText
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
