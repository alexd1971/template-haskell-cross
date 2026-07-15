{-# LANGUAGE TemplateHaskell #-}

module AddTopDeclsExactName where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (addTopDecls)

$( do
     generatedName <- newName "generated"
     let fooName = mkName "foo"
         intType = ConT ''Int
     addTopDecls
       [ SigD generatedName intType
       , ValD
           (VarP generatedName)
           (NormalB (LitE (IntegerL 42)))
           []
       ]
     pure
       [ SigD fooName intType
       , ValD
           (VarP fooName)
           (NormalB (VarE generatedName))
           []
       ]
 )
