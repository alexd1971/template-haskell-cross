{-# LANGUAGE TemplateHaskell #-}

module AesonConsumer.Domain.Address
  ( Address (..)
  ) where

import Data.Aeson.TH
  ( Options (fieldLabelModifier)
  , defaultOptions
  , deriveJSON
  )

data Address = Address
  { addressCity :: String
  , addressStreet :: String
  , addressPostalCode :: Maybe String
  }
  deriving (Eq, Show)

$(deriveJSON defaultOptions {fieldLabelModifier = drop (length "address")} ''Address)
