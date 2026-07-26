{-# LANGUAGE CPP #-}

module Main (main) where

import Integration.Cases (testTrees)
import Integration.Harness
  ( CompileRunner (..)
  , TestEnv (..)
  , findProjectRoot
  )
import System.Directory (makeAbsolute)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>), takeDirectory)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = do
  projectRoot <- findProjectRoot
  workerPath <- requireEnv "TH_HOST_WORKER" "run integration tests through nix develop and th-cross-test"
  hostGhcLibDir <- requireHostGhcLibDir
  fixturesDir <- makeAbsolute (takeDirectory __FILE__ </> "fixtures")
  let testEnv =
        TestEnv
          { testProjectRoot = projectRoot
          , testFixturesDir = fixturesDir
          , testWorkerPath = workerPath
          , testHostGhcLibDir = hostGhcLibDir
          , testCompileRunner = CabalExecGhc "ghc-9.8.4" "ghc-9.8.4-pkg"
          }
  defaultMain
    ( testGroup
        "integration"
        (testTrees testEnv)
    )

requireHostGhcLibDir :: IO FilePath
requireHostGhcLibDir =
  requireEnv "TH_HOST_GHC_LIBDIR" "run integration tests through nix develop"

requireEnv :: String -> String -> IO String
requireEnv name hint = do
  value <- lookupEnv name
  case value of
    Just text ->
      pure text
    Nothing -> do
      putStrLn (name <> " is not set; " <> hint <> ".")
      exitFailure
