module Main (main) where

import Integration.Cases (testTrees)
import Integration.Harness
  ( CompileRunner (DirectGhc)
  , TestEnv (..)
  , findProjectRoot
  )
import System.Directory (makeAbsolute)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = do
  projectRoot <- findProjectRoot
  workerPath <- requireEnv "TH_HOST_WORKER" "run integration tests through nix develop and th-cross-test"
  testGhc <- lookupEnvDefault "TH_CROSS_TEST_GHC" "ghc-9.10.3"
  fixturesDir <- makeAbsolute (projectRoot </> "plugin" </> "test" </> "fixtures")
  let testEnv =
        TestEnv
          { testProjectRoot = projectRoot
          , testFixturesDir = fixturesDir
          , testWorkerPath = workerPath
          , testHostGhcLibDir = ""
          , testCompileRunner = DirectGhc testGhc
          }
  defaultMain
    ( testGroup
        "integration"
        (testTrees testEnv)
    )

requireEnv :: String -> String -> IO String
requireEnv name hint = do
  value <- lookupEnv name
  case value of
    Just text ->
      pure text
    Nothing -> do
      putStrLn (name <> " is not set; " <> hint <> ".")
      exitFailure

lookupEnvDefault :: String -> String -> IO String
lookupEnvDefault name fallback = do
  value <- lookupEnv name
  pure (maybe fallback id value)
