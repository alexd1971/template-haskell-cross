{-# LANGUAGE TemplateHaskell #-}

module RawHiddenPattern where

import qualified Language.Haskell.TH as TH
import RawHiddenConstructorDef

matchesHidden :: Hidden -> Bool
matchesHidden $(pure (TH.ConP hiddenConstructorName [] [])) = True
