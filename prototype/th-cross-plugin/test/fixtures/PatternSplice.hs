{-# LANGUAGE TemplateHaskell #-}

module PatternSplice where

import Language.Haskell.TH

foo :: Int -> Int
foo $(pure (LitP (IntegerL 42))) = 1
foo _ = 0
