{-# LANGUAGE TemplateHaskell #-}

module AesonConsumer.Domain.User
  ( AccountStatus (..)
  , User (..)
  ) where

import AesonConsumer.Domain.Address (Address)
import AesonConsumer.JsonOptions (dropSuffix)
import Data.Aeson.TH
  ( Options (constructorTagModifier, fieldLabelModifier)
  , defaultOptions
  , deriveJSON
  )

data AccountStatus
  = PendingReview
  | ActiveUser
  | SuspendedUser
  deriving (Eq, Show)

data User = User
  { userName :: String
  , userAge :: Int
  , userEmail :: Maybe String
  , userAddress :: Address
  , userRoles :: [String]
  , userStatus :: AccountStatus
  }
  deriving (Eq, Show)

$( foldMap
     (deriveJSON defaultOptions)
     [''AccountStatus]
 )

$( deriveJSON
     defaultOptions
       { fieldLabelModifier = drop (length "user")
       , constructorTagModifier = dropSuffix "User"
       }
     ''User
 )
