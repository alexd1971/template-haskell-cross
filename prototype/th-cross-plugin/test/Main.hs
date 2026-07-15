{-# LANGUAGE CPP #-}

module Main (main) where

import Integration.Cases (testTrees)
import Integration.Harness
  ( cabalBuild
  , cabalListBin
  , findProjectRoot
  )
import System.Directory (makeAbsolute)
import System.FilePath ((</>), takeDirectory)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = do
  projectRoot <- findProjectRoot
  cabalBuild projectRoot "th-host-worker"
  workerPath <- cabalListBin projectRoot "th-host-worker"
  fixturesDir <- makeAbsolute (takeDirectory __FILE__ </> "fixtures")
  defaultMain
    ( testGroup
        "integration"
        (testTrees projectRoot fixturesDir workerPath)
    )
