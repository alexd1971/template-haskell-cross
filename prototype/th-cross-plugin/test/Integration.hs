{-# LANGUAGE CPP #-}

module Main (main) where

import Control.Monad (forM_, when)
import Data.List (stripPrefix)
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getCurrentDirectory
  , makeAbsolute
  )
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath
  ( (</>)
  , takeDirectory
  )
import System.Process
  ( CreateProcess (..)
  , proc
  , readCreateProcessWithExitCode
  )

data TestCase = TestCase
  { testName :: !String
  , testModulePath :: !FilePath
  , testPluginOptions :: ![String]
  , testStdoutOccurrences :: ![(String, Int)]
  , testStderrOccurrences :: ![(String, Int)]
  }

main :: IO ()
main = do
  projectRoot <- findProjectRoot
  cabalBuild projectRoot "th-host-worker"
  workerPath <- cabalListBin projectRoot "th-host-worker"
  fixturesDir <- makeAbsolute (takeDirectory __FILE__ </> "fixtures")
  let testCases =
        [ -- Proves that the plugin can replace an expression splice locally
          -- without executing the original Template Haskell expression.
          TestCase
            { testName = "dummy expression replacement"
            , testModulePath = "DummyExpr.hs"
            , testPluginOptions =
                [ "-fplugin=THCross.Plugin"
                , "-fplugin-opt=THCross.Plugin:dummy-expr"
                ]
            , testStdoutOccurrences = []
            , testStderrOccurrences = []
            }
          -- Exercises the first worker-backed expression splice path:
          -- plugin request -> worker evaluation -> textual fragment -> parser.
        , TestCase
            { testName = "worker expression splice"
            , testModulePath = "Example.hs"
            , testPluginOptions = workerPluginOptions workerPath
            , testStdoutOccurrences = []
            , testStderrOccurrences = []
            }
          -- Verifies module-aware host evaluation: the worker loads the source
          -- module before evaluating the splice, so reify can see local decls.
        , TestCase
            { testName = "worker module-aware reify"
            , testModulePath = "ReifyExpr.hs"
            , testPluginOptions = workerPluginOptions workerPath
            , testStdoutOccurrences = []
            , testStderrOccurrences = []
            }
          -- Keeps declaration splice ordering under test. The declaration
          -- splice is evaluated by the worker before the later expression splice.
        , TestCase
            { testName = "worker declaration ordering"
            , testModulePath = "DeclOrder.hs"
            , testPluginOptions = workerPluginOptions workerPath
            , testStdoutOccurrences = []
            , testStderrOccurrences = []
            }
          -- Confirms that two expression splices in one compiler session use
          -- one long-lived worker process, not two processes.
        , TestCase
            { testName = "persistent worker reuse"
            , testModulePath = "DuplicateSplices.hs"
            , testPluginOptions = workerPluginOptions workerPath
            , testStdoutOccurrences =
                [ ("th-cross: started worker", 1)
                , ("th-cross: reusing worker", 1)
                ]
            , testStderrOccurrences =
                [ ("th-host-worker: cache miss", 1)
                , ("th-host-worker: cache hit", 1)
                ]
            }
          -- Verifies that host-side addDependentFile effects are replayed into
          -- the cross-side GHC session by the plugin.
        , TestCase
            { testName = "dependent file propagation"
            , testModulePath = "DependentFile.hs"
            , testPluginOptions = workerPluginOptions workerPath
            , testStdoutOccurrences =
                [ ("th-cross: dependent file schema.json", 1)
                ]
            , testStderrOccurrences = []
            }
          -- Verifies that host-side reportWarning effects are replayed as
          -- cross-side GHC diagnostics instead of being visible only in the
          -- worker process.
        , TestCase
            { testName = "TH warning propagation"
            , testModulePath = "ReportWarning.hs"
            , testPluginOptions = workerPluginOptions workerPath
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
            , testStdoutOccurrences = []
            , testStderrOccurrences = []
            }
          -- Confirms that addTempFile allocates a usable host-side temporary
          -- file during splice evaluation. The temp file itself is not replayed
          -- into the cross-side compiler session.
        , TestCase
            { testName = "host addTempFile execution"
            , testModulePath = "AddTempFile.hs"
            , testPluginOptions = workerPluginOptions workerPath
            , testStdoutOccurrences = []
            , testStderrOccurrences = []
            }
          -- Verifies that recover discards errors from the failed branch and
          -- returns the recovery value inside host-side TH evaluation.
        , TestCase
            { testName = "TH recover semantics"
            , testModulePath = "Recover.hs"
            , testPluginOptions = workerPluginOptions workerPath
            , testStdoutOccurrences = []
            , testStderrOccurrences =
                [ ("expected recovered error", 0)
                ]
            }
        ]
  forM_ testCases (runCase projectRoot fixturesDir)

workerPluginOptions :: FilePath -> [String]
workerPluginOptions workerPath =
  [ "-fplugin=THCross.Plugin"
  , "-fplugin-opt=THCross.Plugin:worker=" <> workerPath
  ]

runCase :: FilePath -> FilePath -> TestCase -> IO ()
runCase projectRoot fixturesDir testCase = do
  putStrLn ("integration: " <> testName testCase)
  let testBuildDir =
        projectRoot
          </> "dist-newstyle"
          </> "th-cross-integration"
          </> sanitizePathSegment (testName testCase)
  createDirectoryIfMissing True testBuildDir
  let args =
        [ "exec"
        , "--project-dir"
        , projectRoot
        , "--"
        , "ghc"
        , "-v0"
        , "-fno-code"
        , "-fforce-recomp"
        , "-package"
        , "th-cross-plugin"
        , "-i" <> fixturesDir
        , "-outputdir"
        , testBuildDir
        , "-hidir"
        , testBuildDir
        , "-odir"
        , testBuildDir
        , "-stubdir"
        , testBuildDir
        ]
          <> testPluginOptions testCase
          <> [testModulePath testCase]
  (exitCode, out, err) <- readCreateProcessWithExitCode (inProject fixturesDir (proc "cabal" args)) ""
  case exitCode of
    ExitSuccess ->
      checkOutputOccurrences "stdout" testCase out (testStdoutOccurrences testCase)
        >> checkOutputOccurrences "stderr" testCase err (testStderrOccurrences testCase)
    ExitFailure code -> do
      putStrLn ("integration test failed: " <> testName testCase)
      putStrLn ("exit code: " <> show code)
      putStrLn "stdout:"
      putStr out
      putStrLn "stderr:"
      putStr err
      exitFailure

checkOutputOccurrences :: String -> TestCase -> String -> [(String, Int)] -> IO ()
checkOutputOccurrences streamName testCase output expectations =
  forM_ expectations $ \(needle, expected) -> do
    let actual = countOccurrences needle output
    when (actual /= expected) $ do
      putStrLn ("integration test failed: " <> testName testCase)
      putStrLn
        ( "expected "
            <> streamName
            <> " occurrence count for "
            <> show needle
            <> ": "
            <> show expected
            <> ", got "
            <> show actual
        )
      putStrLn (streamName <> ":")
      putStr output
      exitFailure

countOccurrences :: String -> String -> Int
countOccurrences needle haystack
  | null needle = 0
  | otherwise = go haystack
  where
    go input =
      case stripPrefix needle input of
        Just rest ->
          1 + go rest
        Nothing ->
          case input of
            [] -> 0
            _ : rest -> go rest

cabalBuild :: FilePath -> String -> IO ()
cabalBuild projectRoot target = do
  (exitCode, out, err) <-
    readCreateProcessWithExitCode
      (inProject projectRoot (proc "cabal" ["build", target]))
      ""
  case exitCode of
    ExitSuccess ->
      pure ()
    ExitFailure code -> do
      putStrLn ("cabal build failed with exit code " <> show code)
      putStrLn "stdout:"
      putStr out
      putStrLn "stderr:"
      putStr err
      exitFailure

cabalListBin :: FilePath -> String -> IO FilePath
cabalListBin projectRoot executableName = do
  (exitCode, out, err) <-
    readCreateProcessWithExitCode
      (inProject projectRoot (proc "cabal" ["list-bin", executableName]))
      ""
  case exitCode of
    ExitSuccess ->
      pure (trimTrailingNewline out)
    ExitFailure code -> do
      putStrLn ("cabal list-bin failed with exit code " <> show code)
      putStrLn "stdout:"
      putStr out
      putStrLn "stderr:"
      putStr err
      exitFailure

findProjectRoot :: IO FilePath
findProjectRoot = do
  currentDir <- getCurrentDirectory
  go currentDir
  where
    go dir = do
      let marker = dir </> "cabal.project"
      hasMarker <- doesFileExist marker
      if hasMarker
        then pure dir
        else do
          let parent = takeDirectory dir
          if parent == dir
            then do
              putStrLn "could not find cabal.project in current directory or parents"
              exitFailure
            else go parent

inProject :: FilePath -> CreateProcess -> CreateProcess
inProject projectRoot createProcess =
  createProcess {cwd = Just projectRoot}

trimTrailingNewline :: String -> String
trimTrailingNewline =
  reverse . dropWhile (`elem` ['\n', '\r']) . reverse

sanitizePathSegment :: String -> FilePath
sanitizePathSegment =
  map replace
  where
    replace c
      | c `elem` allowed = c
      | otherwise = '-'

    allowed =
      ['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> "-_."
