{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module GetPutQ where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (getQ, putQ)

foo :: Int
foo =
  $( putQ (41 :: Int) >> [| 1 |]
   )

bar :: Int
bar =
  $( do
       value :: Maybe Int <- getQ
       case value of
         Just 41 -> [| 42 |]
         Just other -> fail ("unexpected Q state: " <> show other)
         Nothing -> fail "missing Q state"
   )
