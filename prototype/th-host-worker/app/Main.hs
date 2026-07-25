-- | Binary-protocol entry point for the native host worker.
--
-- The worker reads splice requests from stdin and writes splice responses to
-- stdout. Host-side GHC evaluation lives in "Worker.Evaluate" so this
-- module stays focused on transport and request dispatch.
module Main (main) where

import System.IO
  ( BufferMode (LineBuffering, NoBuffering)
  , stdin
  , hSetBuffering
  , isEOF
  , stderr
  , stdout
  )
import THCross.Protocol
  ( SpliceKind (..)
  , SpliceRequest (..)
  , SpliceResponse (..)
  , readRequest
  , writeResponse
  )
import Worker.Evaluate
  ( EvaluationCache
  , evaluateModuleSplice
  , newEvaluationCache
  )

-- | Start the line-oriented worker protocol.
--
-- stdout is protocol output, so diagnostics must go to stderr if added later.
main :: IO ()
main = do
  hSetBuffering stdin NoBuffering
  hSetBuffering stdout NoBuffering
  hSetBuffering stderr LineBuffering
  cache <- newEvaluationCache
  workerLoop cache

-- | Process framed binary requests until stdin closes.
workerLoop :: EvaluationCache -> IO ()
workerLoop cache = do
  done <- isEOF
  if done
    then pure ()
    else do
      response <- handleFrame cache
      writeResponse stdout response
      workerLoop cache

-- | Decode one protocol frame and convert decode failures into protocol errors.
handleFrame :: EvaluationCache -> IO SpliceResponse
handleFrame cache = do
  requestOrError <- readRequest stdin
  case requestOrError of
    Left err ->
      pure (SpliceError "<decode-error>" err)
    Right request ->
      handleRequest cache request

-- | Dispatch by splice kind.
--
-- The prototype currently evaluates all basic splice kinds. Annotation wrappers
-- are served from captures produced while replaying declaration splices with
-- AnnD; they are intentionally same-GHC-version only.
handleRequest :: EvaluationCache -> SpliceRequest -> IO SpliceResponse
handleRequest cache request =
  case requestSpliceKind request of
    ExpressionSplice ->
      evaluateModuleSplice cache request
    TypeSplice ->
      evaluateModuleSplice cache request
    PatternSplice ->
      evaluateModuleSplice cache request
    DeclarationSplice ->
      evaluateModuleSplice cache request
    AnnotationWrapperSplice ->
      evaluateModuleSplice cache request
