-- | Trivial native host worker for the first end-to-end prototype.
--
-- The worker reads JSON-lines splice requests from stdin and writes JSON-lines
-- responses to stdout. It does not invoke GHC yet; expression splices always
-- expand to the Haskell fragment @42@.
module Main (main) where

import qualified Data.ByteString.Lazy.Char8 as BL
import System.IO
  ( BufferMode (LineBuffering)
  , hIsEOF
  , hSetBuffering
  , stderr
  , stdin
  , stdout
  )
import THCross.Protocol
  ( SpliceKind (..)
  , SpliceRequest (..)
  , SpliceResponse (..)
  , decodeRequestLine
  , encodeResponseLine
  )

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  workerLoop

workerLoop :: IO ()
workerLoop = do
  done <- hIsEOF stdin
  if done
    then pure ()
    else do
      line <- getLine
      BL.putStr (encodeResponseLine (handleLine (BL.pack line)))
      workerLoop

handleLine :: BL.ByteString -> SpliceResponse
handleLine line =
  case decodeRequestLine line of
    Left err ->
      SpliceError "<decode-error>" err
    Right request ->
      handleRequest request

handleRequest :: SpliceRequest -> SpliceResponse
handleRequest request =
  case requestSpliceKind request of
    ExpressionSplice ->
      SpliceOk (requestId request) "42"
    _ ->
      SpliceError
        (requestId request)
        "th-host-worker MVP only supports expression splices"
