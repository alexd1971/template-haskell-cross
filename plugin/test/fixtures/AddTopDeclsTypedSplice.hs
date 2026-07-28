{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TemplateHaskell #-}

module AddTopDeclsTypedSplice where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (addTopDecls, unsafeCodeCoerce)

marker :: ()
marker =
  $$( unsafeCodeCoerce $ do
        probeName <- newName "th_cross_add_top_decls_typed_probe"
        let declarations =
              [ ForeignD
                  ( ImportF
                      CCall
                      Safe
                      "th_cross_add_top_decls_typed_probe"
                      probeName
                      (AppT (ConT (mkName "IO")) (ConT (mkName "Int")))
                  )
              ]
        addTopDecls declarations
        pure (TupE [])
    )
