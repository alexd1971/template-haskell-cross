-- | Trivial native host worker for the first end-to-end prototype.
--
-- The worker reads JSON-lines splice requests from stdin and writes JSON-lines
-- responses to stdout. Expression splices are evaluated by a temporary native
-- @runghc@ runner and converted back to Haskell source with TH's 'pprint'.
module Main (main) where

import Control.Exception (IOException, bracket, catch)
import qualified Data.ByteString.Lazy.Char8 as BL
import System.Directory (getTemporaryDirectory, removeFile)
import System.Exit (ExitCode (..))
import System.IO
  ( BufferMode (LineBuffering)
  , Handle
  , hClose
  , hSetBuffering
  , hSetEncoding
  , isEOF
  , openTempFile
  , stderr
  , stdout
  , utf8
  )
import System.Process (proc, readCreateProcessWithExitCode)
import THCross.Protocol
  ( SpliceKind (..)
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
  result <- runExpressionRunner (requestSpliceExpression request)
  pure $
    case result of
      Right generated ->
        SpliceOk (requestId request) generated
      Left err ->
        SpliceError (requestId request) err

-- | Evaluate an expression splice as TH and return pretty-printed Haskell.
--
-- Normal expression splices have type @Q Exp@. The fallback accepts @Q (Q Exp)@
-- via 'join' only to cover simple experimental inputs such as @pure [| 42 |]@;
-- it is not a replacement for real GHC splice typechecking.
runExpressionRunner :: String -> IO (Either String String)
runExpressionRunner expression = do
  direct <- runSpliceEvalSource (spliceEvalSource DirectExpression expression)
  case direct of
    Right generated ->
      pure (Right generated)
    Left directErr -> do
      joined <- runSpliceEvalSource (spliceEvalSource JoinedExpression expression)
      pure $
        case joined of
          Right generated ->
            Right generated
          Left joinedErr ->
            Left
              ( "failed to evaluate expression splice as Q Exp:\n"
                  <> directErr
                  <> "\nfailed to evaluate expression splice as Q (Q Exp):\n"
                  <> joinedErr
              )

data SpliceEvalMode
  = DirectExpression
  | JoinedExpression

-- | Build a temporary Haskell program that evaluates one splice expression.
--
-- This isolated program has no context from the source module. That is the main
-- Task 7 limitation and the reason later tasks need module-aware GHC sessions.
spliceEvalSource :: SpliceEvalMode -> String -> String
spliceEvalSource mode expression =
  unlines
    [ "{-# LANGUAGE TemplateHaskell #-}"
    , "module Main where"
    , "import Control.Monad (join)"
    , "import Language.Haskell.TH"
    , "import Language.Haskell.TH.Ppr (pprint)"
    , "import Language.Haskell.TH.Syntax (runQ)"
    , "main :: IO ()"
    , "main = do"
    , "  generated <- runQ (" <> spliceEvalExpression mode expression <> ")"
    , "  putStrLn (pprint generated)"
    ]

-- | Wrap the user splice expression with the type expected by the eval module.
spliceEvalExpression :: SpliceEvalMode -> String -> String
spliceEvalExpression mode expression =
  case mode of
    DirectExpression ->
      "(" <> expression <> " :: Q Exp)"
    JoinedExpression ->
      "(join (" <> expression <> ") :: Q Exp)"

-- | Execute the generated splice evaluation source with native @runghc@.
runSpliceEvalSource :: String -> IO (Either String String)
runSpliceEvalSource source =
  withTempSpliceEvalFile source $ \sourcePath -> do
    (exitCode, out, err) <-
      readCreateProcessWithExitCode (proc "runghc" [sourcePath]) ""
    pure $
      case exitCode of
        ExitSuccess ->
          Right (trimTrailingNewline out)
        ExitFailure code ->
          Left ("runghc exited with code " <> show code <> ":\n" <> err)

-- | Write a temporary @.hs@ source file, run an action with its path, and remove
-- it afterwards.
--
-- 'openTempFile' chooses a unique file name atomically, so concurrent requests
-- do not collide on the temporary source path.
withTempSpliceEvalFile :: String -> (FilePath -> IO a) -> IO a
withTempSpliceEvalFile source action = do
  tempDir <- getTemporaryDirectory
  bracket
    (openSpliceEvalFile tempDir)
    closeAndRemove
    ( \(path, handle) -> do
        hSetEncoding handle utf8
        hClose handle
        writeFile path source
        action path
    )

-- | Create a uniquely named temporary Haskell source file.
openSpliceEvalFile :: FilePath -> IO (FilePath, Handle)
openSpliceEvalFile tempDir =
  openTempFile tempDir "th-cross-splice-eval-.hs"

-- | Best-effort cleanup for the temporary source handle and file.
closeAndRemove :: (FilePath, Handle) -> IO ()
closeAndRemove (path, handle) = do
  hClose handle `catch` ignoreIOException
  removeFile path `catch` ignoreIOException

ignoreIOException :: IOException -> IO ()
ignoreIOException _ = pure ()

-- | Drop the final line ending produced by the splice eval program.
trimTrailingNewline :: String -> String
trimTrailingNewline =
  reverse . dropWhile (`elem` ['\n', '\r']) . reverse
