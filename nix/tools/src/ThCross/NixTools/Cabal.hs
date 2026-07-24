-- | Common helpers for extracting information from Cabal package descriptions.
--
-- The dump-cabal-* executables share the same structure: find a `.cabal` file,
-- parse its 'GenericPackageDescription', traverse all components, and apply a
-- 'BuildInfo' projection. This module extracts the shared infrastructure.
module ThCross.NixTools.Cabal
  ( -- * Generic component traversal
    extractFromAllComponents

    -- * Convenience entry point for dump-cabal-* executables
  , dumpCabalField
  ) where

import qualified Data.ByteString as ByteString
import Distribution.PackageDescription
  ( Benchmark (benchmarkBuildInfo)
  , BuildInfo
  , CondTree (condTreeData)
  , Executable (buildInfo)
  , GenericPackageDescription (..)
  , Library (libBuildInfo)
  , TestSuite (testBuildInfo)
  )
import Distribution.PackageDescription.Parsec (parseGenericPackageDescriptionMaybe)
import System.Directory (listDirectory)
import System.FilePath (takeExtension)

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

-- | Discover the single @.cabal@ file in the current directory, parse it, apply
-- an extraction function, and print each result on its own line.
--
-- Fails if zero or more than one @.cabal@ file is found, or if the file cannot
-- be parsed.
dumpCabalField :: (GenericPackageDescription -> [String]) -> IO ()
dumpCabalField extract = do
  cabalFiles <- filter ((== ".cabal") . takeExtension) <$> listDirectory "."
  case cabalFiles of
    [cabalFile] -> do
      cabalBytes <- ByteString.readFile cabalFile
      case parseGenericPackageDescriptionMaybe cabalBytes of
        Just gpd ->
          mapM_ putStrLn (extract gpd)
        Nothing ->
          fail ("failed to parse " <> cabalFile)
    [] ->
      fail "no .cabal file found"
    _ ->
      fail ("expected one .cabal file, found: " <> show cabalFiles)
