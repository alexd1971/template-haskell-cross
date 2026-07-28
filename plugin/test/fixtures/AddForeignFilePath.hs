{-# LANGUAGE TemplateHaskell #-}

module AddForeignFilePath where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (ForeignSrcLang (LangC), addForeignFilePath)

foo :: Int
foo =
  $( do
       addForeignFilePath LangC "cbits/th_foreign_file_path.c"
       [| 42 |]
   )
