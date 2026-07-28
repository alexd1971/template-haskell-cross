{-# LANGUAGE TemplateHaskell #-}

module Main where

import ExecutableConsumer.Gen (makeUserLenses)
import Lens.Micro ((^.))

data User = User
  { _userName :: String
  }

makeUserLenses ''User

main :: IO ()
main =
  print (User "Ada" ^. userName)
