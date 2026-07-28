{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

module CppTargetContext where

import Language.Haskell.TH

#ifdef TH_CROSS_TARGET_CONTEXT
data Platform = TargetPlatform
#else
data Platform = HostPlatform
#endif

$(pure [])

platformValue :: Platform
platformValue =
  $( do
       TyConI (DataD _ _ _ _ [NormalC constructorName []] _) <- reify ''Platform
       conE constructorName
   )
