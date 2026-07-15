{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TemplateHaskell #-}

module AddTopDeclsExpr where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (addTopDecls)

-- This is a local smoke fixture, not a copy of an upstream GHC test.
-- It uses the ForD/ForeignImport declaration shape accepted by qAddTopDecls
-- and covered by GHC tests such as T10638/T13587.
marker :: ()
marker =
  $( do
       generatedDecls <-
         [d|
           foreign import ccall "th_cross_add_top_decls_probe"
             th_cross_add_top_decls_probe :: IO Int
           |]
       addTopDecls generatedDecls
       [| () |]
   )
