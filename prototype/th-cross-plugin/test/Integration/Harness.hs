module Integration.Harness
  ( CompileExpectation (..)
  , ExpectedExit (..)
  , TestEnv (..)
  , compileNatively
  , compileNativelyWithOptions
  , compileWithPlugin
  , compileWithPluginOptions
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
import System.Environment (getEnvironment)
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
  , testHostGhcLibDir :: !FilePath
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
  compileWithPluginOptions testEnv modulePath [] expectation

compileWithPluginOptions :: TestEnv -> FilePath -> [String] -> CompileExpectation -> Assertion
compileWithPluginOptions testEnv modulePath extraGhcOptions expectation =
  runCompileSpec testEnv $
    CompileSpec
      { specLabel = "plugin"
      , specModulePath = modulePath
      , specGhcOptions = workerPluginOptions testEnv <> extraGhcOptions
      , specExpectation = expectation
      }

compileNatively :: TestEnv -> FilePath -> CompileExpectation -> Assertion
compileNatively testEnv modulePath expectation =
  compileNativelyWithOptions testEnv modulePath [] expectation

compileNativelyWithOptions :: TestEnv -> FilePath -> [String] -> CompileExpectation -> Assertion
compileNativelyWithOptions testEnv modulePath extraGhcOptions expectation =
  runCompileSpec testEnv $
    CompileSpec
      { specLabel = "native"
      , specModulePath = modulePath
      , specGhcOptions = extraGhcOptions
      , specExpectation = expectation
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
        cabalGlobalArgs (testProjectRoot testEnv)
          <> [ "exec"
             ]
          <> cabalCommandArgs (testProjectRoot testEnv)
          <> [ "--"
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
  envVars <- getEnvironment
  let compileProcess =
        (inProject (testFixturesDir testEnv) (proc "cabal" args))
          { env = Just (("TH_HOST_GHC_LIBDIR", testHostGhcLibDir testEnv) : envVars)
          }
  (exitCode, out, err) <- readCreateProcessWithExitCode compileProcess ""
  let expectation = specExpectation spec
  checkExpectedExit (specLabel spec) (expectedExit expectation) exitCode out err
  checkOutputOccurrences "stdout" (specLabel spec) out (expectedStdout expectation)
  checkOutputOccurrences "stderr" (specLabel spec) err (expectedStderr expectation)

workerPluginOptions :: TestEnv -> [String]
workerPluginOptions testEnv =
  [ "-fplugin=THCross.Plugin"
  , "-fplugin-opt=THCross.Plugin:worker=" <> testWorkerPath testEnv
  , "-fplugin-opt=THCross.Plugin:debug"
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

cabalGlobalArgs :: FilePath -> [String]
cabalGlobalArgs projectRoot =
  [ "--store-dir"
  , takeDirectory projectRoot </> ".cabal-store-nix"
  ]

cabalCommandArgs :: FilePath -> [String]
cabalCommandArgs projectRoot =
  [ "--project-dir"
  , projectRoot
  , "--builddir"
  , "dist-newstyle-nix"
  , "--with-compiler"
  , "ghc-9.8.4"
  , "--with-hc-pkg"
  , "ghc-9.8.4-pkg"
  ]

sanitizePathSegment :: String -> FilePath
sanitizePathSegment =
  map replace
  where
    replace c
      | c `elem` allowed = c
      | otherwise = '-'

    allowed =
      ['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> "-_."
