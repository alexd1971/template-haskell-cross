module Integration.Harness
  ( CompileExpectation (..)
  , ExpectedExit (..)
  , TestEnv (..)
  , cabalBuild
  , cabalListBin
  , compileNatively
  , compileWithDummyExpr
  , compileWithPlugin
  , expectSuccess
  , findProjectRoot
  ) where

import Control.Monad (forM_, when)
import Data.List (stripPrefix)
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getCurrentDirectory
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
import Test.Tasty.HUnit (Assertion, assertFailure)

data TestEnv = TestEnv
  { testProjectRoot :: !FilePath
  , testFixturesDir :: !FilePath
  , testWorkerPath :: !FilePath
  }

data ExpectedExit
  = ExpectSuccess
  | ExpectFailure
  deriving (Eq, Show)

data CompileExpectation = CompileExpectation
  { expectedExit :: !ExpectedExit
  , expectedStdout :: ![(String, Int)]
  , expectedStderr :: ![(String, Int)]
  }

data CompileSpec = CompileSpec
  { specLabel :: !String
  , specModulePath :: !FilePath
  , specGhcOptions :: ![String]
  , specExpectation :: !CompileExpectation
  }

expectSuccess :: CompileExpectation
expectSuccess =
  CompileExpectation
    { expectedExit = ExpectSuccess
    , expectedStdout = []
    , expectedStderr = []
    }

compileWithPlugin :: TestEnv -> FilePath -> CompileExpectation -> Assertion
compileWithPlugin testEnv modulePath expectation =
  runCompileSpec testEnv $
    CompileSpec
      { specLabel = "plugin"
      , specModulePath = modulePath
      , specGhcOptions = workerPluginOptions testEnv
      , specExpectation = expectation
      }

compileNatively :: TestEnv -> FilePath -> CompileExpectation -> Assertion
compileNatively testEnv modulePath expectation =
  runCompileSpec testEnv $
    CompileSpec
      { specLabel = "native"
      , specModulePath = modulePath
      , specGhcOptions = []
      , specExpectation = expectation
      }

compileWithDummyExpr :: TestEnv -> FilePath -> Assertion
compileWithDummyExpr testEnv modulePath =
  runCompileSpec testEnv $
    CompileSpec
      { specLabel = "dummy-expr"
      , specModulePath = modulePath
      , specGhcOptions =
          [ "-fplugin=THCross.Plugin"
          , "-fplugin-opt=THCross.Plugin:dummy-expr"
          ]
      , specExpectation = expectSuccess
      }

runCompileSpec :: TestEnv -> CompileSpec -> Assertion
runCompileSpec
  testEnv
  spec = do
  let testBuildDir =
        testProjectRoot testEnv
          </> "dist-newstyle"
          </> "th-cross-integration"
          </> sanitizePathSegment (specLabel spec <> "-" <> specModulePath spec)
  createDirectoryIfMissing True testBuildDir
  let args =
        [ "exec"
        , "--project-dir"
        , testProjectRoot testEnv
        , "--"
        , "ghc"
        , "-v0"
        , "-fno-code"
        , "-fforce-recomp"
        , "-package"
        , "th-cross-plugin"
        , "-i" <> testFixturesDir testEnv
        , "-outputdir"
        , testBuildDir
        , "-hidir"
        , testBuildDir
        , "-odir"
        , testBuildDir
        , "-stubdir"
        , testBuildDir
        ]
          <> specGhcOptions spec
          <> [specModulePath spec]
  (exitCode, out, err) <- readCreateProcessWithExitCode (inProject (testFixturesDir testEnv) (proc "cabal" args)) ""
  let expectation = specExpectation spec
  checkExpectedExit (specLabel spec) (expectedExit expectation) exitCode out err
  checkOutputOccurrences "stdout" (specLabel spec) out (expectedStdout expectation)
  checkOutputOccurrences "stderr" (specLabel spec) err (expectedStderr expectation)

workerPluginOptions :: TestEnv -> [String]
workerPluginOptions testEnv =
  [ "-fplugin=THCross.Plugin"
  , "-fplugin-opt=THCross.Plugin:worker=" <> testWorkerPath testEnv
  ]

checkExpectedExit :: String -> ExpectedExit -> ExitCode -> String -> String -> Assertion
checkExpectedExit testName expectedExitStatus exitCode out err =
  case (expectedExitStatus, exitCode) of
    (ExpectSuccess, ExitSuccess) ->
      pure ()
    (ExpectFailure, ExitFailure _) ->
      pure ()
    (expected, actual) ->
      assertFailure
        ( testFailureMessage
            testName
            [ "expected exit: " <> show expected
            , "actual exit: " <> show actual
            , "stdout:"
            , out
            , "stderr:"
            , err
            ]
        )

checkOutputOccurrences :: String -> String -> String -> [(String, Int)] -> Assertion
checkOutputOccurrences streamName testName output expectations =
  forM_ expectations $ \(needle, expected) -> do
    let actual = countOccurrences needle output
    when (actual /= expected) $
      assertFailure
        ( testFailureMessage
            testName
            [ "expected "
                <> streamName
                <> " occurrence count for "
                <> show needle
                <> ": "
                <> show expected
                <> ", got "
                <> show actual
            , streamName <> ":"
            , output
            ]
        )

testFailureMessage :: String -> [String] -> String
testFailureMessage testName details =
  unlines ("integration test failed: " <> testName : details)

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
