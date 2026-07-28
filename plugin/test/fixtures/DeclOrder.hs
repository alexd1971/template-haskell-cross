{-# LANGUAGE TemplateHaskell #-}

module DeclOrder where

import DeclOrderGen (genUser)
import Language.Haskell.TH (reify)

$(genUser)

$(pure [])

foo :: Int
foo =
  $( do
       _ <- reify ''GeneratedUser
       [| 42 |]
   )
