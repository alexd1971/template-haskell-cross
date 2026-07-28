{-# LANGUAGE TemplateHaskell #-}

module RunIO where

import Language.Haskell.TH

foo :: Int
foo =
  $( do
       n <- runIO (pure (42 :: Int))
       if n == 42
         then [| n |]
         else fail "runIO returned wrong value"
   )
