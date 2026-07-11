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
import Worker.Evaluate (evaluateModuleSplice)

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
