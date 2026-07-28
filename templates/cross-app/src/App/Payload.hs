{-# LANGUAGE TemplateHaskell #-}

module App.Payload
  ( Payload (..)
  , payloadJson
  ) where

import Data.Aeson (defaultOptions, encode)
import Data.Aeson.TH (deriveJSON)
import qualified Data.ByteString.Lazy.Char8 as BL

data Payload = Payload
  { payloadName :: String
  , payloadCount :: Int
  }
  deriving (Eq, Show)

foldMap (deriveJSON defaultOptions)
  [ ''Payload
  ]

payloadJson :: String
payloadJson =
  BL.unpack (encode (Payload "Ada" 42))
