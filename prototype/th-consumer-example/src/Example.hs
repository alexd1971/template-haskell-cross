{-# LANGUAGE TemplateHaskell #-}

module Example where

import Gen (gen)

foo :: Int
foo = $(gen)
