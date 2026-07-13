{-# LANGUAGE TemplateHaskell #-}

module DummyExpr where

foo :: Int
foo = $(error "must not execute")

