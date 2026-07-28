{-# LANGUAGE TemplateHaskell #-}

module DuplicateSplices where

foo :: Int
foo = $([| 42 |])

bar :: Int
bar = $([| 42 |])
