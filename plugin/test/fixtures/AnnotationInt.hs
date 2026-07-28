{-# LANGUAGE TemplateHaskell #-}

module AnnotationInt where

{-# ANN module (42 :: Int) #-}

marker :: ()
marker = ()
