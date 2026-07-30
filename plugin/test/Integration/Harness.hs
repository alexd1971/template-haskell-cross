module Integration.Harness
  ( CompileExpectation (..)
  , CompileRunner (..)
  , ExpectedExit (..)
  , TestEnv (..)
  , compileNatively
  , compileNativelyWithOptions
  , compileWithPlugin
  , compileWithPluginOptions
  , expectSuccess
  , findProjectRoot
  ) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Monad (forM_, void, when)
import Data.List (stripPrefix)
import Data.Maybe (fromMaybe)
import Text.Read (readMaybe)
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
import System.IO (Handle, hClose, hGetContents, hPutStrLn, stderr)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (CreatePipe, NoStream)
  , createProcess
  , getProcessExitCode
  , interruptProcessGroupOf
  , proc
  , terminateProcess
  )
import Test.Tasty.HUnit (Assertion, assertFailure)

data TestEnv = TestEnv
  { testProjectRoot :: !FilePath
  , testFixturesDir :: !FilePath
  , testWorkerPath :: !FilePath
  , testHostGhcLibDir :: !FilePath
  , testCompileRunner :: !CompileRunner
  }

data CompileRunner
  = CabalExecGhc !FilePath !FilePath
  | DirectGhc !FilePath

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
        ghcArgs testEnv testBuildDir spec
  envVars <- getEnvironment
  let compileProcess =
        (inProject (testFixturesDir testEnv) (compileProc testEnv args))
          { env = Just (hostGhcLibDirEnv testEnv <> envVars)
          }
  compileTimeoutSeconds <- lookupTimeoutSeconds envVars
  (exitCode, out, err) <- readCreateProcessWithTimeout compileTimeoutSeconds compileProcess
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

hostGhcLibDirEnv :: TestEnv -> [(String, String)]
hostGhcLibDirEnv testEnv
  | null (testHostGhcLibDir testEnv) = []
  | otherwise = [("TH_HOST_GHC_LIBDIR", testHostGhcLibDir testEnv)]

compileProc :: TestEnv -> [String] -> CreateProcess
compileProc testEnv args =
  case testCompileRunner testEnv of
    DirectGhc ghc ->
      proc ghc args
    CabalExecGhc ghc ghcPkg ->
      proc "cabal" (cabalExecArgs testEnv ghc ghcPkg <> ["--", "ghc"] <> args)

ghcArgs :: TestEnv -> FilePath -> CompileSpec -> [String]
ghcArgs testEnv testBuildDir spec =
  [ "-v0"
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

cabalExecArgs :: TestEnv -> FilePath -> FilePath -> [String]
cabalExecArgs testEnv ghc ghcPkg =
  cabalGlobalArgs testEnv
    <> ["exec"]
    <> cabalCommandArgs testEnv
    <> cabalCompilerArgs ghc ghcPkg

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
inProject projectRoot createProcessSpec =
  createProcessSpec {cwd = Just projectRoot}

lookupTimeoutSeconds :: [(String, String)] -> IO Int
lookupTimeoutSeconds envVars =
  pure
    ( fromMaybe
        120
        (lookup "TH_CROSS_TEST_TIMEOUT_SECONDS" envVars >>= readMaybe)
    )

readCreateProcessWithTimeout :: Int -> CreateProcess -> IO (ExitCode, String, String)
readCreateProcessWithTimeout timeoutSeconds createProcessSpec = do
  (_, Just stdoutHandle, Just stderrHandle, processHandle) <-
    createProcess
      createProcessSpec
        { std_in = NoStream
        , std_out = CreatePipe
        , std_err = CreatePipe
        , create_group = True
        }
  stdoutVar <- newEmptyMVar
  stderrVar <- newEmptyMVar
  void (forkIO (hGetContentsStrict stdoutHandle >>= putMVar stdoutVar))
  void (forkIO (hGetContentsStrict stderrHandle >>= putMVar stderrVar))
  result <- waitForProcessWithTimeout timeoutSeconds processHandle
  case result of
    Just exitCode -> do
      out <- takeMVar stdoutVar
      err <- takeMVar stderrVar
      pure (exitCode, out, err)
    Nothing -> do
      hPutStrLn stderr ("integration harness: process timed out after " <> show timeoutSeconds <> "s")
      interruptProcessGroupOf processHandle
      terminateProcess processHandle
      hClose stdoutHandle
      hClose stderrHandle
      pure
        ( ExitFailure 124
        , ""
        , "process timed out after " <> show timeoutSeconds <> "s\n"
        )

waitForProcessWithTimeout :: Int -> ProcessHandle -> IO (Maybe ExitCode)
waitForProcessWithTimeout timeoutSeconds processHandle =
  go (timeoutSeconds * 10)
  where
    go remainingPolls = do
      result <- getProcessExitCode processHandle
      case result of
        Just exitCode ->
          pure (Just exitCode)
        Nothing
          | remainingPolls <= 0 ->
              pure Nothing
          | otherwise -> do
              threadDelay 100000
              go (remainingPolls - 1)

hGetContentsStrict :: Handle -> IO String
hGetContentsStrict handle = do
  text <- hGetContents handle
  length text `seq` pure text

cabalGlobalArgs :: TestEnv -> [String]
cabalGlobalArgs testEnv =
  [ "--store-dir"
  , takeDirectory (testProjectRoot testEnv) </> ".cabal-store-nix-" <> cabalPathSuffix testEnv
  ]

cabalCommandArgs :: TestEnv -> [String]
cabalCommandArgs testEnv =
  [ "--project-dir"
  , testProjectRoot testEnv
  , "--builddir"
  , "dist-newstyle-nix-" <> cabalPathSuffix testEnv
  ]

cabalCompilerArgs :: FilePath -> FilePath -> [String]
cabalCompilerArgs ghc ghcPkg =
  [ "--with-compiler"
  , ghc
  , "--with-hc-pkg"
  , ghcPkg
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

cabalPathSuffix :: TestEnv -> FilePath
cabalPathSuffix testEnv =
  sanitizePathSegment $
    case testCompileRunner testEnv of
      CabalExecGhc ghc _ ->
        ghc
      DirectGhc ghc ->
        ghc
