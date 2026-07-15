{-# LANGUAGE TemplateHaskell #-}

module AddTopDeclsMultipleDecls where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (addTopDecls)

marker :: ()
marker =
  $( do
       declarations <-
         [d|
           generatedOne :: Int
           generatedOne = 1

           generatedTwo :: Int
           generatedTwo = generatedOne + 1
           |]
       addTopDecls declarations
       [| () |]
   )
