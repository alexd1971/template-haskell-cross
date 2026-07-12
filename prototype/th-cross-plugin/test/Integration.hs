module Main (main) where

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

data TestCase = TestCase
  { testName :: !String
  , testModulePath :: !FilePath
  , testPluginOptions :: ![String]
  , testStdoutOccurrences :: ![(String, Int)]
  }

main :: IO ()
main = do
  projectRoot <- findProjectRoot
  cabalBuild projectRoot "th-host-worker"
  workerPath <- cabalListBin projectRoot "th-host-worker"
  let testCases =
        [ -- Proves that the plugin can replace an expression splice locally
          -- without executing the original Template Haskell expression.
          TestCase
            { testName = "dummy expression replacement"
            , testModulePath = "th-cross-plugin/test/DummyExpr.hs"
            , testPluginOptions =
                [ "-fplugin=THCross.Plugin"
                , "-fplugin-opt=THCross.Plugin:dummy-expr"
                ]
            , testStdoutOccurrences = []
            }
          -- Exercises the first worker-backed expression splice path:
          -- plugin request -> worker evaluation -> textual fragment -> parser.
        , TestCase
            { testName = "worker expression splice"
            , testModulePath = "th-cross-plugin/test/Example.hs"
            , testPluginOptions = workerPluginOptions workerPath
            , testStdoutOccurrences = []
            }
          -- Verifies module-aware host evaluation: the worker loads the source
          -- module before evaluating the splice, so reify can see local decls.
        , TestCase
            { testName = "worker module-aware reify"
            , testModulePath = "th-cross-plugin/test/ReifyExpr.hs"
            , testPluginOptions = workerPluginOptions workerPath
            , testStdoutOccurrences = []
            }
          -- Keeps declaration splice ordering under test. The declaration
          -- splice is evaluated by the worker before the later expression splice.
        , TestCase
            { testName = "worker declaration ordering"
            , testModulePath = "th-cross-plugin/test/DeclOrder.hs"
            , testPluginOptions = workerPluginOptions workerPath
            , testStdoutOccurrences = []
            }
          -- Confirms that two expression splices in one compiler session use
          -- one long-lived worker process, not two processes.
        , TestCase
            { testName = "persistent worker reuse"
            , testModulePath = "th-cross-plugin/test/DuplicateSplices.hs"
            , testPluginOptions = workerPluginOptions workerPath
            , testStdoutOccurrences =
                [ ("th-cross: started worker", 1)
                , ("th-cross: reusing worker", 1)
                ]
            }
        ]
  forM_ testCases (runCase projectRoot)

workerPluginOptions :: FilePath -> [String]
workerPluginOptions workerPath =
  [ "-fplugin=THCross.Plugin"
  , "-fplugin-opt=THCross.Plugin:worker=" <> workerPath
  ]

runCase :: FilePath -> TestCase -> IO ()
runCase projectRoot testCase = do
  putStrLn ("integration: " <> testName testCase)
  let testBuildDir =
        projectRoot
          </> "dist-newstyle"
          </> "th-cross-integration"
          </> sanitizePathSegment (testName testCase)
  createDirectoryIfMissing True testBuildDir
  let args =
        [ "exec"
        , "--"
        , "ghc"
        , "-v0"
        , "-fno-code"
        , "-fforce-recomp"
        , "-package"
        , "th-cross-plugin"
        , "-ith-cross-plugin/test"
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
  (exitCode, out, err) <- readCreateProcessWithExitCode (inProject projectRoot (proc "cabal" args)) ""
  case exitCode of
    ExitSuccess ->
      checkStdoutOccurrences testCase out
    ExitFailure code -> do
      putStrLn ("integration test failed: " <> testName testCase)
      putStrLn ("exit code: " <> show code)
      putStrLn "stdout:"
      putStr out
      putStrLn "stderr:"
      putStr err
      exitFailure

checkStdoutOccurrences :: TestCase -> String -> IO ()
checkStdoutOccurrences testCase out =
  forM_ (testStdoutOccurrences testCase) $ \(needle, expected) -> do
    let actual = countOccurrences needle out
    when (actual /= expected) $ do
      putStrLn ("integration test failed: " <> testName testCase)
      putStrLn
        ( "expected stdout occurrence count for "
            <> show needle
            <> ": "
            <> show expected
            <> ", got "
            <> show actual
        )
      putStrLn "stdout:"
      putStr out
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
