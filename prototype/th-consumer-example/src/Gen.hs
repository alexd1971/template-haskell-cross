{-# LANGUAGE TemplateHaskell #-}

module Gen (gen) where

import Language.Haskell.TH (ExpQ)

gen :: ExpQ
gen = [| 42 |]
