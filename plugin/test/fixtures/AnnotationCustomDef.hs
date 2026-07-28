{-# LANGUAGE DeriveDataTypeable #-}

module AnnotationCustomDef
  ( Ann (..)
  ) where

import Data.Data (Data)

data Ann = Ann String Int
  deriving (Data, Show)
