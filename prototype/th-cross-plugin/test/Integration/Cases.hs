module Integration.Cases
  ( testTrees
  ) where

import Integration.Harness
  ( CompileExpectation (..)
  , ExpectedExit (ExpectFailure, ExpectSuccess)
  , TestEnv
  , compileNatively
  , compileWithDummyExpr
  , compileWithPlugin
  , expectSuccess
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)

testTrees :: TestEnv -> [TestTree]
testTrees testEnv =
  [ testGroup
      "basic"
      [ testCase "dummy expression replacement" $
          compileWithDummyExpr testEnv "DummyExpr.hs"
      , testCase "worker expression splice" $
          compileWithPlugin testEnv "Example.hs" expectSuccess
      , testCase "worker module-aware reify" $
          compileWithPlugin testEnv "ReifyExpr.hs" expectSuccess
      , testCase "worker declaration ordering" $
          compileWithPlugin testEnv "DeclOrder.hs" expectSuccess
      ]
  , testGroup
      "worker lifecycle"
      [ testCase "persistent worker reuse" $
          compileWithPlugin
            testEnv
            "DuplicateSplices.hs"
            CompileExpectation
              { expectedExit = ExpectSuccess
              , expectedStdout =
                  [ ("th-cross: started worker", 1)
                  , ("th-cross: reusing worker", 1)
                  ]
              , expectedStderr =
                  [ ("th-host-worker: cache miss", 1)
                  , ("th-host-worker: cache hit", 1)
                  ]
              }
      ]
  , testGroup
      "q effects"
      [ testCase "dependent file propagation" $
          compileWithPlugin
            testEnv
            "DependentFile.hs"
            expectSuccess
              { expectedStdout =
                  [("th-cross: dependent file schema.json", 1)]
              }
      , testCase "TH warning propagation" $
          compileWithPlugin
            testEnv
            "ReportWarning.hs"
            expectSuccess
              { expectedStderr =
                  [("host-side TH warning", 1)]
              }
      , testCase "host runIO execution" $
          compileWithPlugin testEnv "RunIO.hs" expectSuccess
      , testCase "host addTempFile execution" $
          compileWithPlugin testEnv "AddTempFile.hs" expectSuccess
      , testCase "TH recover semantics" $
          compileWithPlugin
            testEnv
            "Recover.hs"
            expectSuccess
              { expectedStderr =
                  [("expected recovered error", 0)]
              }
      , testCase "host Q state" $
          compileWithPlugin testEnv "GetPutQ.hs" expectSuccess
      , testCase "foreign file propagation" $
          compileWithPlugin
            testEnv
            "AddForeignFilePath.hs"
            expectSuccess
              { expectedStdout =
                  [("th-cross: foreign file c cbits/th_foreign_file_path.c", 1)]
              }
      ]
  , addTopDeclsTests testEnv
  ]

addTopDeclsTests :: TestEnv -> TestTree
addTopDeclsTests testEnv =
  testGroup
    "addTopDecls"
    [ -- Each scenario compiles the same fixture through the plugin path and
      -- native GHC. The native case is the baseline: if it fails too, the
      -- fixture is testing GHC semantics rather than plugin behavior.
      testGroup
        "propagation"
        [ testCase "plugin" $
            compileWithPlugin
              testEnv
              "AddTopDeclsExpr.hs"
              expectSuccess
                { expectedStdout =
                    [("th-cross: added top decls 1", 1)]
                }
        , testCase "native" $
            compileNatively testEnv "AddTopDeclsExpr.hs" expectSuccess
        ]
    , testGroup
        "multiple declarations"
        [ testCase "plugin" $
            compileWithPlugin
              testEnv
              "AddTopDeclsMultipleDecls.hs"
              expectSuccess
                { expectedStdout =
                    [("th-cross: added top decls 4", 1)]
                }
        , testCase "native" $
            compileNatively testEnv "AddTopDeclsMultipleDecls.hs" expectSuccess
        ]
    , testGroup
        "multiple splices"
        [ testCase "plugin" $
            compileWithPlugin
              testEnv
              "AddTopDeclsMultipleSplices.hs"
              expectSuccess
                { expectedStdout =
                    [("th-cross: added top decls 2", 2)]
                }
        , testCase "native" $
            compileNatively testEnv "AddTopDeclsMultipleSplices.hs" expectSuccess
        ]
    , testGroup
        "source before added declarations"
        [ testCase "plugin" $
            compileWithPlugin
              testEnv
              "AddTopDeclsOrdering.hs"
              expectSuccess
                { expectedStdout =
                    [("th-cross: added top decls 2", 1)]
                }
        , testCase "native" $
            compileNatively testEnv "AddTopDeclsOrdering.hs" expectSuccess
        ]
    , testGroup
        "annotation declaration"
        [ testCase "plugin" $
            compileWithPlugin
              testEnv
              "AddTopDeclsAnnotation.hs"
              expectSuccess
                { expectedStdout =
                    [("th-cross: added top decls 1", 1)]
                }
        , testCase "native" $
            compileNatively testEnv "AddTopDeclsAnnotation.hs" expectSuccess
        ]
    , testGroup
        "typed expression splice"
        [ testCase "plugin" $
            compileWithPlugin
              testEnv
              "AddTopDeclsTypedSplice.hs"
              expectSuccess
                { expectedStdout =
                    [("th-cross: added top decls 1", 1)]
                }
        , testCase "native" $
            compileNatively testEnv "AddTopDeclsTypedSplice.hs" expectSuccess
        ]
    , testGroup
        "invalid declaration"
        [ testCase "plugin" $
            compileWithPlugin
              testEnv
              "AddTopDeclsInvalidDecl.hs"
              CompileExpectation
                { expectedExit = ExpectFailure
                , expectedStdout =
                    [("worker-error: TH host worker error", 1)]
                , expectedStderr =
                    [("Error in a declaration passed to", 1)]
                }
        , testCase "native" $
            compileNatively
              testEnv
              "AddTopDeclsInvalidDecl.hs"
              CompileExpectation
                { expectedExit = ExpectFailure
                , expectedStdout = []
                , expectedStderr =
                    [("Error in a declaration passed to", 1)]
                }
        ]
    , testGroup
        "type error"
        [ testCase "plugin" $
            compileWithPlugin
              testEnv
              "AddTopDeclsTypeError.hs"
              CompileExpectation
                { expectedExit = ExpectFailure
                , expectedStdout =
                    [("worker-error: TH host worker error", 1)]
                , expectedStderr =
                    [("Illegal term-level use", 1)]
                }
        , testCase "native" $
            compileNatively
              testEnv
              "AddTopDeclsTypeError.hs"
              CompileExpectation
                { expectedExit = ExpectFailure
                , expectedStdout = []
                , expectedStderr =
                    [("Illegal term-level use", 1)]
                }
        ]
    , testGroup
        "invalid prim import"
        [ testCase "plugin" $
            compileWithPlugin
              testEnv
              "AddTopDeclsInvalidPrimImport.hs"
              CompileExpectation
                { expectedExit = ExpectFailure
                , expectedStdout =
                    [("worker-error: TH host worker error", 1)]
                , expectedStderr =
                    [("is not a valid C identifier", 1)]
                }
        , testCase "native" $
            compileNatively
              testEnv
              "AddTopDeclsInvalidPrimImport.hs"
              CompileExpectation
                { expectedExit = ExpectFailure
                , expectedStdout = []
                , expectedStderr =
                    [("is not a valid C identifier", 1)]
                }
        ]
    ]
