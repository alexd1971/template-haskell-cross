{-# LANGUAGE TemplateHaskell #-}

module ReportWarning where

import Language.Haskell.TH

foo :: Int
foo =
  $( do
       reportWarning "host-side TH warning"
       [| 42 |]
   )
