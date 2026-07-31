module DependencyConsumer
  ( consumerJson
  , consumerValue
  ) where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as LazyByteString
import DependencyTH (dependencyGeneratedValue, samplePayload)

consumerValue :: String
consumerValue = dependencyGeneratedValue

consumerJson :: LazyByteString.ByteString
consumerJson =
  Aeson.encode samplePayload
