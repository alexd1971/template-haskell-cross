{-# LANGUAGE TemplateHaskell #-}

module AddForeignSource where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (ForeignSrcLang (..), addForeignSource)

foo :: Int
foo =
  $( do
       addForeignSource LangC "int th_cross_foreign_source_probe(void) { return 42; }"
       [| 42 |]
   )
