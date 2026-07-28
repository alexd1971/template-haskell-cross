{-# LANGUAGE TemplateHaskell #-}

module AnnotationCustom where

import AnnotationCustomDef (Ann (..))

{-# ANN module (Ann "th-cross" 42) #-}

marker :: ()
marker = ()
