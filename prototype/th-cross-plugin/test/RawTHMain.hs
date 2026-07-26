{-# LANGUAGE CPP #-}

module Main (main) where

import Integration.Harness
  ( CompileRunner (..)
  , TestEnv (..)
  , findProjectRoot
  )
import qualified Integration.RawTH as RawTH
import System.Directory (makeAbsolute)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>), takeDirectory)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = do
  projectRoot <- findProjectRoot
  workerPath <- requireEnv "TH_HOST_WORKER" "run raw TH tests through nix develop and th-cross-raw-test"
  fixturesDir <- makeAbsolute (takeDirectory __FILE__ </> "fixtures")
  let testEnv =
        TestEnv
          { testProjectRoot = projectRoot
          , testFixturesDir = fixturesDir
          , testWorkerPath = workerPath
          , testHostGhcLibDir = ""
          , testCompileRunner = DirectGhc "ghc-9.10.3"
          }
  defaultMain
    ( testGroup
        "raw-th"
        (RawTH.testTrees testEnv)
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
