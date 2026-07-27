-- | Worker-local cache for splice results captured by host-side GHC loads.
module Worker.SpliceCache
  ( CapturedSplice (..)
  , CapturedSplices
  , CachedSplices
  , EvaluationCache
  , attachModuleEffects
  , cacheModuleSplices
  , newEvaluationCache
  , selectCachedSplice
  , selectCapturedSpliceOrError
  ) where

import Data.IORef (IORef, newIORef)
import qualified Data.Map.Strict as Map
import THCross.Protocol
  ( SpliceForeignFile
  , SpliceKind (AnnotationWrapperSplice)
  , SpliceRequest (..)
  , SpliceResult (..)
  )
import THCross.SpliceKey (SpliceKey)

-- | Splice expansions captured while native GHC loaded the requested module.
type CapturedSplices = Map.Map SpliceKey CapturedSplice

-- | Captured expansion plus the splice kind used for fallback matching.
data CapturedSplice = CapturedSplice
  { capturedSpliceKind :: !SpliceKind
  , capturedSpliceResult :: !SpliceResult
  }

-- | Worker-local cache key for one evaluated splice result.
--
-- 'SpliceKey' identifies the source occurrence. The component unit id and
-- source file scope that occurrence to the Cabal/GHC component context that
-- produced the expansion.
data CacheKey = CacheKey
  { cacheKeyComponentUnitId :: !String
  , cacheKeySourceFile :: !FilePath
  , cacheKeySpliceKey :: !SpliceKey
  }
  deriving (Eq, Ord, Show)

-- | Cached expansion results across requests handled by one worker process.
type CachedSplices = Map.Map CacheKey CapturedSplice

-- | In-process cache of splice expansion results captured by whole-module loads.
--
-- The worker process is persistent, so this cache survives multiple requests
-- handled by one worker. It is intentionally not written to disk yet.
type EvaluationCache = IORef CachedSplices

-- | Create an empty worker-local expansion cache.
newEvaluationCache :: IO EvaluationCache
newEvaluationCache =
  newIORef Map.empty

-- | Insert all splices captured by one whole-module load into the worker cache.
--
-- The requested key is inserted too so fallback matches, such as annotation
-- wrappers with synthetic cross-side spans, become cache hits on later requests.
cacheModuleSplices :: SpliceRequest -> CapturedSplices -> SpliceResult -> CachedSplices -> CachedSplices
cacheModuleSplices request captures requestedSpliceResult cache =
  Map.insert (requestCacheKey request) requestedCapturedSplice $
    Map.union capturedCacheEntries cache
  where
    requestedCapturedSplice =
      CapturedSplice (requestSpliceKind request) requestedSpliceResult

    capturedCacheEntries =
      Map.fromList
        [ (cacheKeyFor request spliceKey, captured)
        | (spliceKey, captured) <- Map.toList captures
        ]

-- | Find a cached expansion for the request.
--
-- Annotation-wrapper requests can have synthetic cross-side spans after
-- declaration replay, so they retain the same single-wrapper fallback used for
-- freshly captured module results.
selectCachedSplice :: SpliceRequest -> CachedSplices -> Maybe SpliceResult
selectCachedSplice request cache =
  case Map.lookup (requestCacheKey request) cache of
    Just captured ->
      Just (capturedSpliceResult captured)
    Nothing ->
      selectCachedAnnotationWrapperFallback request cache

-- | Attach module-level replayable effects to each captured splice result.
attachModuleEffects :: [FilePath] -> [SpliceForeignFile] -> CapturedSplices -> CapturedSplices
attachModuleEffects dependentFiles foreignFiles =
  Map.map
    ( \captured ->
        captured
          { capturedSpliceResult =
              (capturedSpliceResult captured)
                { spliceResultDependentFiles = dependentFiles
                , spliceResultForeignFiles = foreignFiles
                }
          }
    )

-- | Select the host-side expansion corresponding to the cross-side request, or
-- produce a diagnostic error.
selectCapturedSpliceOrError :: SpliceRequest -> CapturedSplices -> Either String SpliceResult
selectCapturedSpliceOrError request captures =
  case selectCapturedSplice request captures of
    Just spliceResult -> Right spliceResult
    Nothing ->
      Left $
        "host GHC did not capture requested splice; request key "
          <> show (requestSpliceKey request)
          <> "; captured "
          <> show (Map.size captures)
          <> " splice(s): "
          <> show (Map.keys captures)

-- | Cache key for the exact splice requested by the cross-side compiler.
requestCacheKey :: SpliceRequest -> CacheKey
requestCacheKey request =
  cacheKeyFor request (requestSpliceKey request)

-- | Scope a source-level splice key to the component context that evaluated it.
cacheKeyFor :: SpliceRequest -> SpliceKey -> CacheKey
cacheKeyFor request spliceKey =
  CacheKey
    { cacheKeyComponentUnitId = requestComponentUnitId request
    , cacheKeySourceFile = requestSourceFile request
    , cacheKeySpliceKey = spliceKey
    }

-- | Fallback for annotation wrappers cached from a previous whole-module load.
selectCachedAnnotationWrapperFallback :: SpliceRequest -> CachedSplices -> Maybe SpliceResult
selectCachedAnnotationWrapperFallback request cache
  | requestSpliceKind request /= AnnotationWrapperSplice = Nothing
  | otherwise =
      case
        [ capturedSpliceResult captured
        | (cacheKey, captured) <- Map.toList cache
        , cacheKeyComponentUnitId cacheKey == requestComponentUnitId request
        , capturedSpliceKind captured == AnnotationWrapperSplice
        ]
      of
        [spliceResult] -> Just spliceResult
        _ -> Nothing

-- | Find the host-side expansion corresponding to the cross-side request.
--
-- Loading a module can execute several splices. The worker first selects by the
-- opaque splice key derived from module name, splice kind, and source span.
selectCapturedSplice :: SpliceRequest -> CapturedSplices -> Maybe SpliceResult
selectCapturedSplice request captures =
  case Map.lookup (requestSpliceKey request) captures of
    Just captured ->
      Just (capturedSpliceResult captured)
    Nothing ->
      selectAnnotationWrapperFallback request captures

-- | Replayed annotation declarations can trigger wrapper requests with source
-- spans that differ from the host capture. Fall back to the only captured
-- annotation wrapper in the module.
selectAnnotationWrapperFallback :: SpliceRequest -> CapturedSplices -> Maybe SpliceResult
selectAnnotationWrapperFallback request captures
  | requestSpliceKind request /= AnnotationWrapperSplice = Nothing
  | otherwise =
      case [capturedSpliceResult captured | captured <- Map.elems captures, capturedSpliceKind captured == AnnotationWrapperSplice] of
        [spliceResult] -> Just spliceResult
        _ -> Nothing
