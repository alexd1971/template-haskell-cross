{-# LANGUAGE TemplateHaskell #-}

module DeclOrderGen
  ( genUser
  ) where

import Language.Haskell.TH (Dec, Q)

genUser :: Q [Dec]
genUser =
  [d| data GeneratedUser = GeneratedUser String |]
