module Integration.RawTH
  ( testTrees
  ) where

import Integration.Harness
  ( TestEnv
  , compileWithPluginOptions
  , expectSuccess
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)

testTrees :: TestEnv -> [TestTree]
testTrees testEnv =
  [ testGroup
      "raw-th"
      [ testCase "hidden constructor expression" $
          compileWithPluginOptions
            testEnv
            "RawHiddenConstructor.hs"
            ["-fplugin-opt=THCross.Plugin:wire-format=raw-th"]
            expectSuccess
      ]
  ]
