{-# LANGUAGE TemplateHaskell #-}

module AddTopDeclsInvalidDecl where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (addTopDecls)

-- Mirrors the upstream GHC testsuite shape in TH_invalid_add_top_decl.hs:
-- an invalid declaration passed to addTopDecls must be rejected by GHC.
$( do
     invalidDecl <- valD (varP (mkName "emptyDo")) (normalB (doE [])) []
     addTopDecls [invalidDecl]
     pure []
 )
