{-# LANGUAGE TemplateHaskell #-}

module Main where

import Lens.Micro (Lens', (^.))
import Lens.Micro.TH (makeLenses)

data User = User
  { _userName :: String
  }

makeLenses ''User

main :: IO ()
main =
  print (User "Ada" ^. userName)
