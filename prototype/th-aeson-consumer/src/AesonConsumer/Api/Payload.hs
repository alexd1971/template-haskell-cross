{-# LANGUAGE TemplateHaskell #-}

module AesonConsumer.Api.Payload
  ( CreateUserRequest (..)
  , ServiceCommand (..)
  ) where

import AesonConsumer.Domain.User (User)
import AesonConsumer.JsonOptions (dropSuffix)
import Data.Aeson.TH
  ( Options
      ( constructorTagModifier
      , fieldLabelModifier
      , sumEncoding
      )
  , SumEncoding (TaggedObject)
  , defaultOptions
  , deriveJSON
  )

data CreateUserRequest = CreateUserRequest
  { createUserRequestTraceId :: String
  , createUserRequestUser :: User
  }
  deriving (Eq, Show)

data ServiceCommand
  = CreateUser CreateUserRequest
  | DisableUser String
  | ReplaceRoles String [String]
  deriving (Eq, Show)

$( deriveJSON
     defaultOptions
       { fieldLabelModifier = drop (length "createUserRequest")
       }
     ''CreateUserRequest
 )

$( deriveJSON
     defaultOptions
       { constructorTagModifier = dropSuffix "User"
       , sumEncoding = TaggedObject "command" "payload"
       }
     ''ServiceCommand
 )
