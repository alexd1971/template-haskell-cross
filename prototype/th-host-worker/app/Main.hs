-- | Trivial native host worker for the first end-to-end prototype.
--
-- The worker reads JSON-lines splice requests from stdin and writes JSON-lines
-- responses to stdout. Supported splices are evaluated by loading the source
-- module in a native GHC session and wrapping GHC's normal TH evaluator.
{-# LANGUAGE LambdaCase #-}

module Main (main) where

import Control.Exception (SomeException, catch, displayException)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (find)
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
import GHC.Driver.Session
  ( GeneralFlag (Opt_ForceRecomp)
  , gopt_set
  , hiDir
  , importPaths
  , objectDir
  , stubDir
  )
import GHC.Driver.Hooks (Hooks (..))
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
  , showSDocUnsafe
  )
import System.FilePath ((</>), takeDirectory)
import System.IO
  ( BufferMode (LineBuffering)
  , hSetBuffering
  , isEOF
  , stderr
  , stdout
  )
import System.Process (readProcess)
import THCross.Protocol
  ( SourceSpan (..)
  , SpliceKind (..)
  , SpliceRequest (..)
  , SpliceResponse (..)
  , decodeRequestLine
  , encodeResponseLine
  )

-- | Start the line-oriented worker protocol.
--
-- stdout is protocol output, so diagnostics must go to stderr if added later.
main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  workerLoop

-- | Process JSON-lines requests until stdin closes.
workerLoop :: IO ()
workerLoop = do
  done <- isEOF
  if done
    then pure ()
    else do
      line <- getLine
      response <- handleLine (BL.pack line)
      BL.putStr (encodeResponseLine response)
      workerLoop

-- | Decode one protocol frame and convert decode failures into protocol errors.
handleLine :: BL.ByteString -> IO SpliceResponse
handleLine line =
  case decodeRequestLine line of
    Left err ->
      pure (SpliceError "<decode-error>" err)
    Right request ->
      handleRequest request

-- | Dispatch by splice kind.
--
-- The prototype currently evaluates expression and declaration splices. Type,
-- pattern, and annotation-wrapper splices stay unsupported until the parser and
-- worker both handle their result shapes.
handleRequest :: SpliceRequest -> IO SpliceResponse
handleRequest request =
  case requestSpliceKind request of
    ExpressionSplice ->
      evaluateModuleSplice request
    DeclarationSplice ->
      evaluateModuleSplice request
    _ ->
      pure $
        SpliceError
          (requestId request)
          "th-host-worker MVP only supports expression and declaration splices"

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
  capturesRef <- newIORef []
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

-- | Install a host-only hook that delegates to the previous hook/default GHC
-- evaluator, records the generated splice, and returns it unchanged.
installCaptureHook :: IORef [CapturedSplice] -> Ghc ()
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
captureMetaHook :: IORef [CapturedSplice] -> Maybe (MetaHook TcM) -> MetaHook TcM
captureMetaHook capturesRef previousRunMeta request spliceExpr =
  case request of
    MetaE wrap -> do
      expanded <- metaRequestE runMeta spliceExpr
      generatedText <- prettyExpandedExpression expanded
      capture <- mkCapturedSplice ExpressionSplice spliceExpr generatedText
      liftIO $ modifyIORef' capturesRef (capture :)
      pure (wrap expanded)
    MetaD wrap -> do
      expanded <- metaRequestD runMeta spliceExpr
      generatedText <- prettyExpandedDeclarations expanded
      capture <- mkCapturedSplice DeclarationSplice spliceExpr generatedText
      liftIO $ modifyIORef' capturesRef (capture :)
      pure (wrap expanded)
    _ ->
      runMeta request spliceExpr
  where
    runMeta = fromMaybe defaultRunMeta previousRunMeta

-- | One splice expansion observed while native GHC loaded the requested module.
--
-- The generated Haskell text is the payload returned to the cross-side plugin.
-- The remaining fields are the current MVP matching key. Task 11 should replace
-- source-span matching with a stable splice identity.
data CapturedSplice = CapturedSplice
  { capturedModuleName :: !String
  , capturedSpliceKind :: !SpliceKind
  , capturedSourceSpan :: !SourceSpan
  , capturedExpression :: !String
  , capturedGeneratedHaskell :: !String
  }
  deriving (Eq, Show)

-- | Attach module, kind, source span, and original expression text to a captured
-- expansion.
--
-- This runs in 'TcM' inside the host compiler, so it can read the current
-- 'TcGblEnv' to discover which module is being compiled when the splice fires.
mkCapturedSplice :: SpliceKind -> LHsExpr GhcTc -> String -> TcM CapturedSplice
mkCapturedSplice spliceKind spliceExpr generatedText = do
  tcg <- getGblEnv
  let modText = moduleNameString (moduleName (tcg_mod tcg))
      sourceSpan = protocolSourceSpan (getLocA spliceExpr)
      exprText = showSDocUnsafe (ppr spliceExpr)
  pure
    CapturedSplice
      { capturedModuleName = modText
      , capturedSpliceKind = spliceKind
      , capturedSourceSpan = sourceSpan
      , capturedExpression = exprText
      , capturedGeneratedHaskell = generatedText
      }

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
-- Loading a module can execute several splices. The worker currently selects by
-- module name, splice kind, and source span, then returns only the requested
-- generated fragment.
selectCapturedSplice :: SpliceRequest -> [CapturedSplice] -> Either String String
selectCapturedSplice request captures =
  case find (matchesRequest request) captures of
    Just capture ->
      Right (capturedGeneratedHaskell capture)
    Nothing ->
      Left $
        "host GHC did not capture requested splice; captured "
          <> show (length captures)
          <> " splice(s): "
          <> show captures

-- | MVP splice matcher shared by expression and declaration splices.
matchesRequest :: SpliceRequest -> CapturedSplice -> Bool
matchesRequest request capture =
  capturedModuleName capture == requestModuleName request
    && capturedSpliceKind capture == requestSpliceKind request
    && capturedSourceSpan capture == requestSourceSpan request

-- | Remove trailing newlines from command output such as @ghc --print-libdir@.
trimTrailingNewline :: String -> String
trimTrailingNewline =
  reverse . dropWhile (`elem` ['\n', '\r']) . reverse
