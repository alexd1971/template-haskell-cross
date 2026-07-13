-- | JSON-lines entry point for the native host worker.
--
-- The worker reads splice requests from stdin and writes splice responses to
-- stdout. Host-side GHC evaluation lives in "Worker.Evaluate" so this
-- module stays focused on transport and request dispatch.
module Main (main) where

import qualified Data.ByteString.Lazy.Char8 as BL
import System.IO
  ( BufferMode (LineBuffering)
  , hSetBuffering
  , isEOF
  , stderr
  , stdout
  )
import THCross.Protocol
  ( SpliceKind (..)
  , SpliceRequest (..)
  , SpliceResponse (..)
  , decodeRequestLine
  , encodeResponseLine
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
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  cache <- newEvaluationCache
  workerLoop cache

-- | Process JSON-lines requests until stdin closes.
workerLoop :: EvaluationCache -> IO ()
workerLoop cache = do
  done <- isEOF
  if done
    then pure ()
    else do
      line <- getLine
      response <- handleLine cache (BL.pack line)
      BL.putStr (encodeResponseLine response)
      workerLoop cache

-- | Decode one protocol frame and convert decode failures into protocol errors.
handleLine :: EvaluationCache -> BL.ByteString -> IO SpliceResponse
handleLine cache line =
  case decodeRequestLine line of
    Left err ->
      pure (SpliceError "<decode-error>" err)
    Right request ->
      handleRequest cache request

-- | Dispatch by splice kind.
--
-- The prototype currently evaluates expression and declaration splices. Type,
-- pattern, and annotation-wrapper splices stay unsupported until the parser and
-- worker both handle their result shapes.
handleRequest :: EvaluationCache -> SpliceRequest -> IO SpliceResponse
handleRequest cache request =
  case requestSpliceKind request of
    ExpressionSplice ->
      evaluateModuleSplice cache request
    DeclarationSplice ->
      evaluateModuleSplice cache request
    _ ->
      pure $
        SpliceError
          (requestId request)
          "th-host-worker MVP only supports expression and declaration splices"
