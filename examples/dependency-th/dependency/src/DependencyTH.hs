{-# LANGUAGE TemplateHaskell #-}

module DependencyTH
  ( DependencyPayload (..)
  , dependencyGeneratedValue
  , samplePayload
  ) where

import Data.Aeson.TH (defaultOptions, deriveJSON)
import Language.Haskell.TH

data DependencyPayload = DependencyPayload
  { payloadName :: String
  , payloadValue :: Int
  }

$(deriveJSON defaultOptions ''DependencyPayload)

$( do
    let valueName = mkName "dependencyGeneratedValue"
    signature <- sigD valueName [t| String |]
    definition <- valD (varP valueName) (normalB [| "dependency-th" |]) []
    pure [signature, definition]
 )

samplePayload :: DependencyPayload
samplePayload =
  DependencyPayload
    { payloadName = dependencyGeneratedValue
    , payloadValue = 42
    }
