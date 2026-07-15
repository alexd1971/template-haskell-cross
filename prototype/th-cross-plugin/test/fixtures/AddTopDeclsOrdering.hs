{-# LANGUAGE TemplateHaskell #-}

module AddTopDeclsOrdering where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (addTopDecls)

sameGroupValue :: Int
sameGroupValue =
  40

marker :: ()
marker =
  $( do
       declarations <- [d| addedAfterSameGroup :: Int; addedAfterSameGroup = sameGroupValue + 2 |]
       addTopDecls declarations
       [| () |]
   )
