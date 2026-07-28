{-# LANGUAGE TemplateHaskell #-}

module AddTopDeclsAnnotation where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (addTopDecls)

marker :: ()
marker =
  $( do
       -- Based on the annotation declaration shape covered by upstream GHC
       -- test T9738.
       declarations <- [d| {-# ANN module "th-cross addTopDecls annotation" #-} |]
       addTopDecls declarations
       [| () |]
   )
