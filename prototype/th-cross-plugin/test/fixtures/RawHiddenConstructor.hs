{-# LANGUAGE TemplateHaskell #-}

module RawHiddenConstructor where

import Language.Haskell.TH (Exp (ConE))
import RawHiddenConstructorDef

value :: Hidden
value =
  $(pure (ConE hiddenConstructorName))
