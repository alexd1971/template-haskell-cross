{-# LANGUAGE TemplateHaskell #-}

module AddTopDeclsTypeError where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (addTopDecls)

-- Mirrors upstream GHC testsuite compile-fail shapes such as T14627.hs:
-- declarations accepted by addTopDecls still go through normal typechecking.
marker :: ()
marker =
  $( do
       declarations <- [d| generated = Bool |]
       addTopDecls declarations
       [| () |]
   )
