{-# LANGUAGE TemplateHaskell #-}

module RawHiddenTypeDef (hiddenTypeName) where

import Language.Haskell.TH (Name)

data HiddenType = HiddenTypeConstructor

hiddenTypeName :: Name
hiddenTypeName = ''HiddenType
