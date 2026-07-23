import qualified Data.ByteString as ByteString
import qualified Data.List as List
import Distribution.PackageDescription
  ( Benchmark (benchmarkBuildInfo)
  , BuildInfo (cppOptions)
  , CondTree (condTreeData)
  , Executable (buildInfo)
  , GenericPackageDescription (..)
  , Library (libBuildInfo)
  , TestSuite (testBuildInfo)
  )
import Distribution.PackageDescription.Parsec (parseGenericPackageDescriptionMaybe)
import System.Directory (listDirectory)
import System.FilePath (takeExtension)

main :: IO ()
main = do
  cabalFiles <- filter ((== ".cabal") . takeExtension) <$> listDirectory "."
  case cabalFiles of
    [cabalFile] -> do
      cabalBytes <- ByteString.readFile cabalFile
      case parseGenericPackageDescriptionMaybe cabalBytes of
        Just packageDescription ->
          mapM_ putStrLn (cppOptionsForAllComponents packageDescription)
        Nothing ->
          fail ("failed to parse " <> cabalFile)
    [] ->
      fail "no .cabal file found"
    _ ->
      fail ("expected one .cabal file, found: " <> show cabalFiles)

cppOptionsForAllComponents :: GenericPackageDescription -> [String]
cppOptionsForAllComponents packageDescription =
  List.nub $
    concat
      [ maybe [] (cppOptions . libBuildInfo . condTreeData) (condLibrary packageDescription)
      , concatMap (cppOptions . buildInfo . condTreeData . snd) (condExecutables packageDescription)
      , concatMap (cppOptions . testBuildInfo . condTreeData . snd) (condTestSuites packageDescription)
      , concatMap (cppOptions . benchmarkBuildInfo . condTreeData . snd) (condBenchmarks packageDescription)
      ]
