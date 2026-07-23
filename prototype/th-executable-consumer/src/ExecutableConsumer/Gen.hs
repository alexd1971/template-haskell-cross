{-# LANGUAGE TemplateHaskell #-}

module ExecutableConsumer.Gen
  ( makeUserLenses
  ) where

import Language.Haskell.TH (DecsQ, Name)
import Lens.Micro.TH (makeLenses)

makeUserLenses :: Name -> DecsQ
makeUserLenses =
  makeLenses
