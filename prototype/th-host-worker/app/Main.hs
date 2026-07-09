-- | Trivial native host worker for the first end-to-end prototype.
--
-- The worker reads JSON-lines splice requests from stdin and writes JSON-lines
-- responses to stdout. Expression splices are evaluated by loading the source
-- module in a native GHC session and wrapping GHC's normal TH evaluator.
{-# LANGUAGE LambdaCase #-}

module Main (main) where

import Control.Exception (SomeException, catch, displayException)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (find)
import Data.Maybe (fromMaybe)
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
import GHC.Driver.Session (GeneralFlag (Opt_ForceRecomp), gopt_set)
import GHC.Driver.Hooks (Hooks (..))
import GHC.Hs (GhcPs, GhcTc, LHsExpr)
import GHC.Parser.Annotation (getLocA)
import GHC.Tc.Gen.Splice (defaultRunMeta)
import GHC.Tc.Types (TcGblEnv (..), TcM)
import GHC.Tc.Utils.Monad (getGblEnv, liftIO)
import GHC.Types.Meta
  ( MetaHook
  , MetaRequest (..)
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
import GHC.Utils.Outputable (ppr, showSDocUnsafe)
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
-- The Task 7 MVP only evaluates expression splices; other splice kinds stay
-- unsupported until the parser and worker both handle their result shapes.
handleRequest :: SpliceRequest -> IO SpliceResponse
handleRequest request =
  case requestSpliceKind request of
    ExpressionSplice ->
      evaluateExpressionSplice request
    _ ->
      pure $
        SpliceError
          (requestId request)
          "th-host-worker MVP only supports expression splices"

-- | Evaluate the request expression and preserve the original request id.
evaluateExpressionSplice :: SpliceRequest -> IO SpliceResponse
evaluateExpressionSplice request = do
  result <- evaluateModuleExpressionSplice request `catch` handleEvalException
  pure $
    case result of
      Right generated ->
        SpliceOk (requestId request) generated
      Left err ->
        SpliceError (requestId request) err

handleEvalException :: SomeException -> IO (Either String String)
handleEvalException =
  pure . Left . ("native GHC splice evaluation failed: " <>) . displayException

-- | Compile the source module with native GHC and capture expression splice
-- expansions produced by GHC's normal Template Haskell evaluator.
evaluateModuleExpressionSplice :: SpliceRequest -> IO (Either String String)
evaluateModuleExpressionSplice request = do
  capturesRef <- newIORef []
  ghcLibDir <- getGhcLibDir
  result <- runGhc (Just ghcLibDir) $ do
    dflags <- getSessionDynFlags
    _ <- setSessionDynFlags (gopt_set dflags Opt_ForceRecomp)
    installCaptureHook capturesRef
    target <- guessTarget (requestSourceFile request) Nothing Nothing
    setTargets [target]
    load LoadAllTargets
  case result of
    Failed ->
      pure (Left ("host GHC failed to load " <> requestSourceFile request))
    Succeeded -> do
      captures <- readIORef capturesRef
      pure (selectCapturedExpression request captures)

getGhcLibDir :: IO FilePath
getGhcLibDir =
  trimTrailingNewline <$> readProcess "ghc" ["--print-libdir"] ""

-- | Install a host-only hook that delegates to the previous hook/default GHC
-- evaluator, records the generated expression, and returns it unchanged.
installCaptureHook :: IORef [CapturedExpression] -> Ghc ()
installCaptureHook capturesRef = do
  hscEnv <- getSession
  let hooks0 = hsc_hooks hscEnv
      previousHook = runMetaHook hooks0
      hooks1 = hooks0 {runMetaHook = Just (captureMetaHook capturesRef previousHook)}
  setSession hscEnv {hsc_hooks = hooks1}

captureMetaHook :: IORef [CapturedExpression] -> Maybe (MetaHook TcM) -> MetaHook TcM
captureMetaHook capturesRef previousHook request spliceExpr =
  case request of
    MetaE wrap -> do
      expanded <- metaRequestE selectedHook spliceExpr
      capture <- mkCapturedExpression spliceExpr expanded
      liftIO $ modifyIORef' capturesRef (capture :)
      pure (wrap expanded)
    _ ->
      selectedHook request spliceExpr
  where
    selectedHook = fromMaybe defaultRunMeta previousHook

data CapturedExpression = CapturedExpression
  { capturedModuleName :: !String
  , capturedSourceSpan :: !SourceSpan
  , capturedExpression :: !String
  , capturedGeneratedHaskell :: !String
  }
  deriving (Eq, Show)

mkCapturedExpression :: LHsExpr GhcTc -> LHsExpr GhcPs -> TcM CapturedExpression
mkCapturedExpression spliceExpr expanded = do
  tcg <- getGblEnv
  let modText = moduleNameString (moduleName (tcg_mod tcg))
      sourceSpan = protocolSourceSpan (getLocA spliceExpr)
      exprText = showSDocUnsafe (ppr spliceExpr)
      generatedText = showSDocUnsafe (ppr expanded)
  pure
    CapturedExpression
      { capturedModuleName = modText
      , capturedSourceSpan = sourceSpan
      , capturedExpression = exprText
      , capturedGeneratedHaskell = generatedText
      }

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

selectCapturedExpression :: SpliceRequest -> [CapturedExpression] -> Either String String
selectCapturedExpression request captures =
  case find (matchesRequest request) captures of
    Just capture ->
      Right (capturedGeneratedHaskell capture)
    Nothing ->
      Left $
        "host GHC did not capture requested expression splice; captured "
          <> show (length captures)
          <> " expression splice(s): "
          <> show captures

matchesRequest :: SpliceRequest -> CapturedExpression -> Bool
matchesRequest request capture =
  capturedModuleName capture == requestModuleName request
    && capturedSourceSpan capture == requestSourceSpan request

trimTrailingNewline :: String -> String
trimTrailingNewline =
  reverse . dropWhile (`elem` ['\n', '\r']) . reverse
