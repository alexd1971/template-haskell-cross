{-# LANGUAGE TemplateHaskell #-}

module AesonConsumer
  ( Address (..)
  , AccountStatus (..)
  , User (..)
  , CreateUserRequest (..)
  , ServiceCommand (..)
  , consumerTag
  , exampleCommand
  , roundtripCommand
  ) where

import AesonConsumer.Api.Payload
  ( CreateUserRequest (..)
  , ServiceCommand (..)
  )
import AesonConsumer.Domain.Address (Address (..))
import AesonConsumer.Domain.User (AccountStatus (..), User (..))
import AesonConsumer.TH (declareConsumerTag)
import Data.Aeson (decode, encode)

$(declareConsumerTag "aeson-consumer")

exampleCommand :: ServiceCommand
exampleCommand =
  CreateUser
    CreateUserRequest
      { createUserRequestTraceId = "trace-001"
      , createUserRequestUser =
          User
            { userName = "Ada"
            , userAge = 37
            , userEmail = Just "ada@example.test"
            , userAddress =
                Address
                  { addressCity = "London"
                  , addressStreet = "St James's Square"
                  , addressPostalCode = Nothing
                  }
            , userRoles = ["admin", "author"]
            , userStatus = ActiveUser
            }
      }

roundtripCommand :: Maybe ServiceCommand
roundtripCommand =
  decode (encode exampleCommand)
