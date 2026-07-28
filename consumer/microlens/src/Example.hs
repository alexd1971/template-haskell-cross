{-# LANGUAGE TemplateHaskell #-}

module Example where

import Lens.Micro ((^.))
import Lens.Micro.TH (makeLenses)

data User = User
  { _userName :: String
  , _userAge :: Int
  }

makeLenses ''User

exampleName :: String
exampleName = User "alexey" 42 ^. userName
