-- | Host-side Template Haskell evaluation through a native GHC session.
module Worker.Evaluate
  ( EvaluationCache
  , evaluateModuleSplice
  , newEvaluationCache
  ) where

import Control.Exception (SomeException, catch, displayException)
import Data.IORef (modifyIORef', readIORef)
import System.IO (hPutStrLn, stderr)
import THCross.Protocol
  ( SpliceRequest (..)
  , SpliceResponse (..)
  , SpliceResult
  )
import Worker.SpliceCache
  ( EvaluationCache
  , cacheModuleSplices
  , newEvaluationCache
  , selectCachedSplice
  , selectCapturedSpliceOrError
  )
import Worker.Capture (captureModuleSplices)

-- | Evaluate the requested splice and preserve the original request id.
evaluateModuleSplice :: EvaluationCache -> SpliceRequest -> IO SpliceResponse
evaluateModuleSplice cache request = do
  result <- evaluateModuleSpliceResult cache request `catch` handleEvalException
  pure $
    case result of
      Right spliceResult ->
        SpliceOk (requestId request) spliceResult
      Left err ->
        SpliceError (requestId request) err

-- | Convert unexpected GHC API/runtime exceptions into protocol errors.
handleEvalException :: SomeException -> IO (Either String SpliceResult)
handleEvalException =
  pure . Left . ("native GHC splice evaluation failed: " <>) . displayException

-- | Compile the source module with native GHC and capture splice expansions
-- produced by GHC's normal Template Haskell evaluator.
--
-- This is the host-side equivalent of normal module compilation. The worker
-- creates a native GHC session, adds the Cabal-derived source directories to
-- the import path, installs a capture hook, sets the requested source file as
-- the target, and calls 'load'. During 'load', GHC performs normal
-- declaration-group ordering and invokes the hook for each splice it encounters.
evaluateModuleSpliceResult :: EvaluationCache -> SpliceRequest -> IO (Either String SpliceResult)
evaluateModuleSpliceResult cache request = do
  cached <- selectCachedSplice request <$> readIORef cache
  case cached of
    Just spliceResult -> do
      hPutStrLn stderr ("th-host-worker: cache hit " <> requestSourceFile request)
      pure (Right spliceResult)
    Nothing -> do
      hPutStrLn stderr ("th-host-worker: cache miss " <> requestSourceFile request)
      capturesResult <- captureModuleSplices request
      case capturesResult of
        Left err ->
          pure (Left err)
        Right captures ->
          case selectCapturedSpliceOrError request captures of
            Left err ->
              pure (Left err)
            Right spliceResult -> do
              modifyIORef' cache (cacheModuleSplices request captures spliceResult)
              pure (Right spliceResult)
