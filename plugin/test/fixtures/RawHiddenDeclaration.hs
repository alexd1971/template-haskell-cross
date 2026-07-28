{-# LANGUAGE TemplateHaskell #-}

module RawHiddenDeclaration where

import qualified Language.Haskell.TH as TH
import RawHiddenConstructorDef

$( pure
    [ TH.SigD (TH.mkName "declValue") (TH.ConT ''Hidden)
    , TH.ValD
        (TH.VarP (TH.mkName "declValue"))
        (TH.NormalB (TH.ConE hiddenConstructorName))
        []
    ]
 )
