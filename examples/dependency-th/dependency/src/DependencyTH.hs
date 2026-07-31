{-# LANGUAGE TemplateHaskell #-}

module DependencyTH
  ( dependencyGeneratedValue
  ) where

import Language.Haskell.TH

$( do
    let valueName = mkName "dependencyGeneratedValue"
    signature <- sigD valueName [t| String |]
    definition <- valD (varP valueName) (normalB [| "dependency-th" |]) []
    pure [signature, definition]
 )
