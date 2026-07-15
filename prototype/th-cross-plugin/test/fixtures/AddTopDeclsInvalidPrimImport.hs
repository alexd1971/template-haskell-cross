{-# LANGUAGE GHCForeignImportPrim #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UnliftedFFITypes #-}

module AddTopDeclsInvalidPrimImport where

import GHC.Exts (Int#)
import Language.Haskell.TH
import Language.Haskell.TH.Syntax (addTopDecls)

-- Adapted from upstream GHC testsuite test T10638. The prim calling convention
-- does not accept the "static" keyword in the imported C identifier.
marker :: String
marker =
  $( do
       importType <- [t| Int# -> Int# |]
       importedName <- newName "cmm_test2"
       addTopDecls
         [ ForeignD
             (ImportF Prim Safe "static test2" importedName importType)
         ]
       [| "unreachable" |]
   )
