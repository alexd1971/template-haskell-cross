{-# LANGUAGE TemplateHaskell #-}

module TypeSplice where

import Language.Haskell.TH

type T = $(pure (ConT ''Int))

foo :: T
foo = 42
