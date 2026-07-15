{-# LANGUAGE TemplateHaskell #-}

module AddTopDeclsMultipleSplices where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (addTopDecls)

firstMarker :: ()
firstMarker =
  $( do
       declarations <- [d| firstGenerated :: Int; firstGenerated = 10 |]
       addTopDecls declarations
       [| () |]
   )

secondMarker :: ()
secondMarker =
  $( do
       declarations <- [d| secondGenerated :: Int; secondGenerated = 32 |]
       addTopDecls declarations
       [| () |]
   )
