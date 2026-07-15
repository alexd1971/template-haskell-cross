module Integration.Harness
  ( ExpectedExit (..)
  , TestCase (..)
  , cabalBuild
  , cabalListBin
  , findProjectRoot
  , mkTest
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
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase)

data TestCase = TestCase
  { testName :: !String
  , testModulePath :: !FilePath
  , testPluginOptions :: ![String]
  , testExpectedExit :: !ExpectedExit
  , testStdoutOccurrences :: ![(String, Int)]
  , testStderrOccurrences :: ![(String, Int)]
  }

data ExpectedExit
  = ExpectSuccess
  | ExpectFailure
  deriving (Eq, Show)

mkTest :: FilePath -> FilePath -> TestCase -> TestTree
mkTest projectRoot fixturesDir testInfo =
  testCase (testName testInfo) (runCase projectRoot fixturesDir testInfo)

runCase :: FilePath -> FilePath -> TestCase -> Assertion
runCase projectRoot fixturesDir testInfo = do
  let testBuildDir =
        projectRoot
          </> "dist-newstyle"
          </> "th-cross-integration"
          </> sanitizePathSegment (testName testInfo)
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
          <> testPluginOptions testInfo
          <> [testModulePath testInfo]
  (exitCode, out, err) <- readCreateProcessWithExitCode (inProject fixturesDir (proc "cabal" args)) ""
  checkExpectedExit testInfo exitCode out err
  checkOutputOccurrences "stdout" testInfo out (testStdoutOccurrences testInfo)
  checkOutputOccurrences "stderr" testInfo err (testStderrOccurrences testInfo)

checkExpectedExit :: TestCase -> ExitCode -> String -> String -> Assertion
checkExpectedExit testInfo exitCode out err =
  case (testExpectedExit testInfo, exitCode) of
    (ExpectSuccess, ExitSuccess) ->
      pure ()
    (ExpectFailure, ExitFailure _) ->
      pure ()
    (expected, actual) ->
      assertFailure
        ( testFailureMessage
            testInfo
            [ "expected exit: " <> show expected
            , "actual exit: " <> show actual
            , "stdout:"
            , out
            , "stderr:"
            , err
            ]
        )

checkOutputOccurrences :: String -> TestCase -> String -> [(String, Int)] -> Assertion
checkOutputOccurrences streamName testInfo output expectations =
  forM_ expectations $ \(needle, expected) -> do
    let actual = countOccurrences needle output
    when (actual /= expected) $
      assertFailure
        ( testFailureMessage
            testInfo
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

testFailureMessage :: TestCase -> [String] -> String
testFailureMessage testInfo details =
  unlines ("integration test failed: " <> testName testInfo : details)

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
