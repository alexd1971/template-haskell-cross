import qualified Data.ByteString as ByteString
import qualified Data.List as List
import Distribution.PackageDescription
  ( Benchmark (benchmarkBuildInfo)
  , BuildInfo (hsSourceDirs)
  , CondTree (condTreeData)
  , Executable (buildInfo)
  , GenericPackageDescription (..)
  , Library (libBuildInfo)
  , TestSuite (testBuildInfo)
  )
import Distribution.PackageDescription.Parsec (parseGenericPackageDescriptionMaybe)
import Distribution.Utils.Path (getSymbolicPath)
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
          mapM_ putStrLn (sourceDirs packageDescription)
        Nothing ->
          fail ("failed to parse " <> cabalFile)
    [] ->
      fail "no .cabal file found"
    _ ->
      fail ("expected one .cabal file, found: " <> show cabalFiles)

sourceDirs :: GenericPackageDescription -> [FilePath]
sourceDirs packageDescription =
  List.nub $
    filter (not . null) $
      map getSymbolicPath $
        concat
          [ maybe [] (hsSourceDirs . libBuildInfo . condTreeData) (condLibrary packageDescription)
          , concatMap (hsSourceDirs . buildInfo . condTreeData . snd) (condExecutables packageDescription)
          , concatMap (hsSourceDirs . testBuildInfo . condTreeData . snd) (condTestSuites packageDescription)
          , concatMap (hsSourceDirs . benchmarkBuildInfo . condTreeData . snd) (condBenchmarks packageDescription)
          ]
