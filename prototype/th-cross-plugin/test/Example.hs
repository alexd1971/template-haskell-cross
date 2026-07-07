{-# LANGUAGE TemplateHaskell #-}

module Example where

foo :: Int
foo = $([| 42 |])
