-- | Stable splice identity used by the cross-side plugin and host worker.
--
-- The key is derived from the source occurrence identity: module name, splice
-- kind, and source span. This assumes the host worker loads the same source view
-- that the cross-side compiler is compiling.
module THCross.SpliceKey
  ( SpliceKey
  , mkSpliceKey
  , unSpliceKey
  ) where

import Data.Binary (Binary (..))
import GHC.Fingerprint (fingerprintString)

-- | Opaque identity for one Template Haskell source splice occurrence.
--
-- The current value uses GHC's non-cryptographic fingerprint. The protocol
-- treats the value as opaque so a later implementation can replace it with
-- another digest format without changing the wire shape.
newtype SpliceKey = SpliceKey
  { unSpliceKey :: String
  }
  deriving (Eq, Ord, Show)

instance Binary SpliceKey where
  put =
    put . unSpliceKey
  get =
    SpliceKey <$> get

-- | Build a splice key from source occurrence metadata.
mkSpliceKey :: String -> String -> String -> SpliceKey
mkSpliceKey spliceModuleName spliceKindName sourceSpanKey =
  SpliceKey (show (fingerprintString payload))
  where
    payload =
      spliceModuleName <> ":" <> spliceKindName <> ":" <> sourceSpanKey
