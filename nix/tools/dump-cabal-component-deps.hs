import Distribution.Simple.Configure (getPersistBuildConfig)
import Distribution.Simple.LocalBuildInfo (allComponentsInBuildOrder)
import Distribution.Types.ComponentLocalBuildInfo
  ( componentLocalName
  , componentPackageDeps
  )
import Distribution.Types.ComponentName (showComponentName)
import Distribution.Types.MungedPackageId (mungedName)
import Distribution.Types.MungedPackageName (encodeCompatPackageName)
import Distribution.Types.PackageName (unPackageName)
import Distribution.Types.UnitId (unUnitId)

main :: IO ()
main = do
  localBuildInfo <- getPersistBuildConfig "dist"
  mapM_ printComponent (allComponentsInBuildOrder localBuildInfo)

printComponent component = do
  putStrLn ("component " <> showComponentName (componentLocalName component))
  mapM_ printDependency (componentPackageDeps component)

printDependency (unitId, packageId) =
  putStrLn
    ( "  "
        <> unPackageName (encodeCompatPackageName (mungedName packageId))
        <> " "
        <> unUnitId unitId
    )
