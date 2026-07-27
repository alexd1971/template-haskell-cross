{-# LANGUAGE TemplateHaskell #-}

module AesonConsumer.TH
  ( declareConsumerTag
  ) where

import Language.Haskell.TH
  ( Dec
  , Exp (LitE)
  , Lit (StringL)
  , Q
  , mkName
  , normalB
  , sigD
  , valD
  , varP
  )

declareConsumerTag :: String -> Q [Dec]
declareConsumerTag value = do
  let tagName = mkName "consumerTag"
  signature <- sigD tagName [t|String|]
  binding <- valD (varP tagName) (normalB (normalString value)) []
  pure [signature, binding]

normalString :: String -> Q Exp
normalString value =
  pure (LitE (StringL value))
