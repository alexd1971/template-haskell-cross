{-# LANGUAGE TemplateHaskell #-}

module Example where

import Data.Aeson (decode, encode)
import Data.Aeson.TH (defaultOptions, deriveJSON)

data Address = Address
  { addressCity :: String
  , addressStreet :: String
  }
  deriving (Eq, Show)

data User = User
  { userName :: String
  , userAge :: Int
  , userAddress :: Address
  }
  deriving (Eq, Show)

$(foldMap (deriveJSON defaultOptions) [''Address, ''User])

exampleUser :: User
exampleUser =
  User
    { userName = "Ada"
    , userAge = 37
    , userAddress =
        Address
          { addressCity = "London"
          , addressStreet = "St James's Square"
          }
    }

roundtripUser :: Maybe User
roundtripUser =
  decode (encode exampleUser)
