{-# LANGUAGE TemplateHaskell #-}

module DependentFile where

import Language.Haskell.TH.Syntax (addDependentFile)

foo :: Int
foo =
  $( do
       addDependentFile "schema.json"
       [| 42 |]
   )
