{-# LANGUAGE TemplateHaskell #-}

module Gen (gen) where

import Language.Haskell.TH
  ( Con (NormalC)
  , Dec (DataD)
  , ExpQ
  , Info (TyConI)
  , Name
  , conE
  , reify
  )

gen :: Name -> ExpQ
gen typeName = do
  TyConI (DataD _ _ _ _ [NormalC constructorName []] _) <- reify typeName
  conE constructorName
