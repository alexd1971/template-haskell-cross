{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

module Example where

import Gen (gen)

#ifdef TH_CONSUMER_TARGET_CONTEXT
data Platform = TargetPlatform
#else
data Platform = HostPlatform
#endif

$(pure [])

platformValue :: Platform
platformValue = $(gen ''Platform)
