{-# LANGUAGE TemplateHaskell #-}

module RawHiddenConstructorDef
  ( Hidden
  , hiddenConstructorName
  ) where

import Language.Haskell.TH (Name)

data Hidden = HiddenConstructor

hiddenConstructorName :: Name
hiddenConstructorName =
  'HiddenConstructor
