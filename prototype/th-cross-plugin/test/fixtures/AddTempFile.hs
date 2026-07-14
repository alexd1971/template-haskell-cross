{-# LANGUAGE TemplateHaskell #-}

module AddTempFile where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (addTempFile)

foo :: Int
foo =
  $( do
       tempFile <- addTempFile "txt"
       value <-
         runIO $ do
           writeFile tempFile "42"
           readFile tempFile
       if value == "42"
         then [| 42 |]
         else fail ("addTempFile roundtrip returned " <> show value)
   )
