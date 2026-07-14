{-# LANGUAGE TemplateHaskell #-}

module Recover where

import Language.Haskell.TH

foo :: Int
foo =
  $( do
       n <-
         recover
           (pure (42 :: Int))
           (reportError "expected recovered error" >> pure (0 :: Int))
       if n == 42
         then [| n |]
         else fail ("recover returned wrong value: " <> show n)
   )
