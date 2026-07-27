{-# LANGUAGE TemplateHaskell #-}

module RawHiddenType where

import qualified Language.Haskell.TH as TH
import RawHiddenTypeDef

type Value = $(pure (TH.ConT hiddenTypeName))
