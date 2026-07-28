{-# LANGUAGE TemplateHaskell #-}

module ReifyExpr where

import Language.Haskell.TH (reify)

data User = User String

$(pure [])

foo :: Int
foo =
  $( do
       _ <- reify ''User
       [| 42 |]
   )
