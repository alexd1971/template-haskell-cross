-- | Common helpers for extracting information from Cabal package descriptions.
--
-- Nix-side config generation needs to inspect every component from a parsed
-- 'GenericPackageDescription'. This module keeps that traversal separate from
-- command-line handling and plugin-specific rendering.
module ThCross.NixTools.Cabal
  ( extractFromAllComponents
  ) where

import Distribution.PackageDescription
  ( Benchmark (benchmarkBuildInfo)
  , BuildInfo
  , CondTree (condTreeData)
  , Executable (buildInfo)
  , GenericPackageDescription (..)
  , Library (libBuildInfo)
  , TestSuite (testBuildInfo)
  )

-- | Traverse every component in a generic package description and extract
-- values from each component's 'BuildInfo'.
--
-- The extraction function is applied to the 'BuildInfo' of the library (if
-- present), each executable, each test suite, and each benchmark. Results from
-- all components are concatenated in that order.
extractFromAllComponents :: (BuildInfo -> [a]) -> GenericPackageDescription -> [a]
extractFromAllComponents extract gpd =
  concat
    [ maybe [] (extract . libBuildInfo . condTreeData) (condLibrary gpd)
    , concatMap (extract . buildInfo . condTreeData . snd) (condExecutables gpd)
    , concatMap (extract . testBuildInfo . condTreeData . snd) (condTestSuites gpd)
    , concatMap (extract . benchmarkBuildInfo . condTreeData . snd) (condBenchmarks gpd)
    ]
