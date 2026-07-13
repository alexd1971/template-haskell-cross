{-# LANGUAGE TemplateHaskell #-}

module DependentFile where

import Language.Haskell.TH.Syntax (addDependentFile)

foo :: Int
foo =
  $( do
       addDependentFile "th-cross-plugin/test/fixtures/schema.json"
       [| 42 |]
   )
