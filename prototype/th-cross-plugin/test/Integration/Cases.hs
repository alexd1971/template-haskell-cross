module Integration.Cases
  ( testCases
  ) where

import Integration.Harness
  ( ExpectedExit (ExpectSuccess)
  , TestCase (..)
  )

testCases :: FilePath -> [TestCase]
testCases workerPath =
  [ -- Proves that the plugin can replace an expression splice locally
    -- without executing the original Template Haskell expression.
    TestCase
      { testName = "dummy expression replacement"
      , testModulePath = "DummyExpr.hs"
      , testPluginOptions =
          [ "-fplugin=THCross.Plugin"
          , "-fplugin-opt=THCross.Plugin:dummy-expr"
          ]
      , testExpectedExit = ExpectSuccess
      , testStdoutOccurrences = []
      , testStderrOccurrences = []
      }
    -- Exercises the first worker-backed expression splice path:
    -- plugin request -> worker evaluation -> textual fragment -> parser.
  , TestCase
      { testName = "worker expression splice"
      , testModulePath = "Example.hs"
      , testPluginOptions = workerPluginOptions workerPath
      , testExpectedExit = ExpectSuccess
      , testStdoutOccurrences = []
      , testStderrOccurrences = []
      }
    -- Verifies module-aware host evaluation: the worker loads the source
    -- module before evaluating the splice, so reify can see local decls.
  , TestCase
      { testName = "worker module-aware reify"
      , testModulePath = "ReifyExpr.hs"
      , testPluginOptions = workerPluginOptions workerPath
      , testExpectedExit = ExpectSuccess
      , testStdoutOccurrences = []
      , testStderrOccurrences = []
      }
    -- Keeps declaration splice ordering under test. The declaration splice is
    -- evaluated by the worker before the later expression splice.
  , TestCase
      { testName = "worker declaration ordering"
      , testModulePath = "DeclOrder.hs"
      , testPluginOptions = workerPluginOptions workerPath
      , testExpectedExit = ExpectSuccess
      , testStdoutOccurrences = []
      , testStderrOccurrences = []
      }
    -- Confirms that two expression splices in one compiler session use one
    -- long-lived worker process, not two processes.
  , TestCase
      { testName = "persistent worker reuse"
      , testModulePath = "DuplicateSplices.hs"
      , testPluginOptions = workerPluginOptions workerPath
      , testExpectedExit = ExpectSuccess
      , testStdoutOccurrences =
          [ ("th-cross: started worker", 1)
          , ("th-cross: reusing worker", 1)
          ]
      , testStderrOccurrences =
          [ ("th-host-worker: cache miss", 1)
          , ("th-host-worker: cache hit", 1)
          ]
      }
    -- Verifies that host-side addDependentFile effects are replayed into the
    -- cross-side GHC session by the plugin.
  , TestCase
      { testName = "dependent file propagation"
      , testModulePath = "DependentFile.hs"
      , testPluginOptions = workerPluginOptions workerPath
      , testExpectedExit = ExpectSuccess
      , testStdoutOccurrences =
          [ ("th-cross: dependent file schema.json", 1)
          ]
      , testStderrOccurrences = []
      }
    -- Verifies that host-side reportWarning effects are replayed as cross-side
    -- GHC diagnostics instead of being visible only in the worker process.
  , TestCase
      { testName = "TH warning propagation"
      , testModulePath = "ReportWarning.hs"
      , testPluginOptions = workerPluginOptions workerPath
      , testExpectedExit = ExpectSuccess
      , testStdoutOccurrences = []
      , testStderrOccurrences =
          [ ("host-side TH warning", 1)
          ]
      }
    -- Confirms that runIO executes inside the host worker and that the
    -- cross-side compiler only receives the generated expression.
  , TestCase
      { testName = "host runIO execution"
      , testModulePath = "RunIO.hs"
      , testPluginOptions = workerPluginOptions workerPath
      , testExpectedExit = ExpectSuccess
      , testStdoutOccurrences = []
      , testStderrOccurrences = []
      }
    -- Confirms that addTempFile allocates a usable host-side temporary file
    -- during splice evaluation. The temp file itself is not replayed into the
    -- cross-side compiler session.
  , TestCase
      { testName = "host addTempFile execution"
      , testModulePath = "AddTempFile.hs"
      , testPluginOptions = workerPluginOptions workerPath
      , testExpectedExit = ExpectSuccess
      , testStdoutOccurrences = []
      , testStderrOccurrences = []
      }
    -- Verifies that recover discards errors from the failed branch and returns
    -- the recovery value inside host-side TH evaluation.
  , TestCase
      { testName = "TH recover semantics"
      , testModulePath = "Recover.hs"
      , testPluginOptions = workerPluginOptions workerPath
      , testExpectedExit = ExpectSuccess
      , testStdoutOccurrences = []
      , testStderrOccurrences =
          [ ("expected recovered error", 0)
          ]
      }
    -- Verifies that getQ/putQ state is preserved between splices while the
    -- worker performs one whole-module host evaluation.
  , TestCase
      { testName = "host Q state"
      , testModulePath = "GetPutQ.hs"
      , testPluginOptions = workerPluginOptions workerPath
      , testExpectedExit = ExpectSuccess
      , testStdoutOccurrences = []
      , testStderrOccurrences = []
      }
    -- Verifies that host-side addForeignFilePath effects are replayed into the
    -- cross-side GHC session by the plugin.
  , TestCase
      { testName = "foreign file propagation"
      , testModulePath = "AddForeignFilePath.hs"
      , testPluginOptions = workerPluginOptions workerPath
      , testExpectedExit = ExpectSuccess
      , testStdoutOccurrences =
          [ ("th-cross: foreign file c cbits/th_foreign_file_path.c", 1)
          ]
      , testStderrOccurrences = []
      }
  ]

workerPluginOptions :: FilePath -> [String]
workerPluginOptions workerPath =
  [ "-fplugin=THCross.Plugin"
  , "-fplugin-opt=THCross.Plugin:worker=" <> workerPath
  ]
