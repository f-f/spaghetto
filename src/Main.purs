module Main where

import Spago.Prelude

import ArgParse.Basic (ArgParser)
import ArgParse.Basic as ArgParser
import Data.Array as Array
import Data.Array.NonEmpty as NonEmptyArray
import Data.Map as Map
import Effect.Aff as Aff
import Effect.Class.Console as Console
import Effect.Ref as Ref
import Node.Path as Path
import Node.Process as Process
import Registry.API as Registry.API
import Registry.Index as Index
import Registry.Json as RegistryJson
import Registry.PackageName (PackageName)
import Registry.PackageName as PackageName
import Registry.Schema (Manifest(..), Metadata)
import Registry.Schema as Registry
import Registry.Version (Version)
import Spago.Command.Build as Build
import Spago.Command.Bundle as Bundle
import Spago.Commands.Fetch as Fetch
import Spago.Config (Platform(..), BundleConfig)
import Spago.Config as Config
import Spago.FS as FS
import Spago.Git as Git
import Spago.Log (LogVerbosity(..), supportsColor)
import Spago.PackageSet (Package)
import Spago.PackageSet as PackageSet
import Spago.Paths as Paths

type GlobalArgs =
  { noColor :: Boolean
  , quiet :: Boolean
  , verbose :: Boolean
  }

type FetchArgs = { packages :: List String }
type InstallArgs = FetchArgs
type BuildArgs = {}
type BundleArgs =
  { minify :: Maybe Boolean
  , entrypoint :: Maybe FilePath
  , outfile :: Maybe FilePath
  , platform :: Maybe String
  }

data SpagoCmd = SpagoCmd GlobalArgs Command

data Command
  = Fetch FetchArgs
  | Install InstallArgs
  | Build BuildArgs
  | Bundle BundleArgs

argParser :: ArgParser SpagoCmd
argParser =
  ArgParser.choose "command"
    [ ArgParser.command [ "fetch" ]
        "Downloads all of the project's dependencies"
        do
          (SpagoCmd <$> globalArgsParser <*> (Fetch <$> fetchArgsParser)) <* ArgParser.flagHelp
    , ArgParser.command [ "install" ]
        "Compile the project's dependencies"
        do
          (SpagoCmd <$> globalArgsParser <*> (Install <$> installArgsParser)) <* ArgParser.flagHelp
    , ArgParser.command [ "build" ]
        "Compile the project"
        do
          (SpagoCmd <$> globalArgsParser <*> (Build <$> buildArgsParser)) <* ArgParser.flagHelp
    , ArgParser.command [ "bundle" ]
        "Bundle the project in a single file"
        do
          (SpagoCmd <$> globalArgsParser <*> (Bundle <$> bundleArgsParser)) <* ArgParser.flagHelp
    ]
    <* ArgParser.flagHelp
    <* ArgParser.flagInfo [ "--version", "-v" ] "Show the current version" "0.0.1" -- TODO: version. Like, with an embedded build meta module

{-

TODO: add flag for overriding the cache location

    buildOptions  = BuildOptions <$> watch <*> clearScreen <*> allowIgnored <*> sourcePaths <*> srcMapFlag <*> noInstall
                    <*> pursArgs <*> depsOnly <*> beforeCommands <*> thenCommands <*> elseCommands

-}

-- TODO: veryVerbose = CLI.switch "very-verbose" 'V' "Enable more verbosity: timestamps and source locations"
globalArgsParser :: ArgParser GlobalArgs
globalArgsParser =
  ArgParser.fromRecord
    { quiet:
        ArgParser.flag [ "--quiet", "-q" ]
          "Suppress all spago logging"
          # ArgParser.boolean
          # ArgParser.default false
    , verbose:
        ArgParser.flag [ "--verbose", "-v" ]
          "Enable additional debug logging, e.g. printing `purs` commands"
          # ArgParser.boolean
          # ArgParser.default false
    , noColor:
        ArgParser.flag [ "--no-color" ]
          "Force logging without ANSI color escape sequences"
          # ArgParser.boolean
          # ArgParser.default false
    }

fetchArgsParser :: ArgParser FetchArgs
fetchArgsParser =
  ArgParser.fromRecord
    { packages:
        ArgParser.anyNotFlag "PACKAGE"
          "Package name to add as dependency"
          # ArgParser.many
    }

installArgsParser :: ArgParser InstallArgs
installArgsParser = fetchArgsParser

buildArgsParser :: ArgParser BuildArgs
buildArgsParser = ArgParser.fromRecord {}

bundleArgsParser :: ArgParser BundleArgs
bundleArgsParser =
  ArgParser.fromRecord
    { minify:
        ArgParser.flag [ "--minify" ]
          "Minify the bundle"
          # ArgParser.boolean
          # ArgParser.optional
    , entrypoint:
        ArgParser.argument [ "--entrypoint" ]
          "The module to bundle as the entrypoint"
          # ArgParser.optional
    , outfile:
        ArgParser.argument [ "--outfile" ]
          "Destination path for the bundle"
          # ArgParser.optional
    , platform:
        ArgParser.argument [ "--platform" ]
          "The bundle platform. 'node' or 'browser'"
          # ArgParser.optional
    }

parseArgs :: Effect (Either ArgParser.ArgError SpagoCmd)
parseArgs = do
  cliArgs <- Array.drop 2 <$> Process.argv
  pure $ ArgParser.parseArgs "spago"
    "PureScript package manager and build tool"
    argParser
    cliArgs

main :: Effect Unit
main =
  parseArgs >>= case _ of
    Left err ->
      Console.error $ ArgParser.printArgError err
    Right c -> Aff.launchAff_ case c of
      SpagoCmd globalArgs command -> do
        logOptions <- mkLogOptions globalArgs
        runSpago { logOptions } case command of
          Fetch args -> do
            { env, packageNames } <- mkFetchEnv args
            void $ runSpago env (Fetch.run packageNames)
          Install args -> do
            { env, packageNames } <- mkFetchEnv args
            -- TODO: --no-fetch flag
            dependencies <- runSpago env (Fetch.run packageNames)
            env' <- runSpago env (mkBuildEnv dependencies)
            let options = { depsOnly: true }
            runSpago env' (Build.run options)
          Build args -> do
            { env, packageNames } <- mkFetchEnv { packages: mempty }
            -- TODO: --no-fetch flag
            dependencies <- runSpago env (Fetch.run packageNames)
            buildEnv <- runSpago env (mkBuildEnv dependencies)
            let options = { depsOnly: false }
            runSpago buildEnv (Build.run options)
          Bundle args -> do
            { env, packageNames } <- mkFetchEnv { packages: mempty }
            -- TODO: --no-fetch flag
            dependencies <- runSpago env (Fetch.run packageNames)
            -- TODO: --no-build flag
            buildEnv <- runSpago env (mkBuildEnv dependencies)
            let options = { depsOnly: false }
            runSpago buildEnv (Build.run options)
            { bundleEnv, bundleOptions } <- runSpago env (mkBundleEnv args)
            runSpago bundleEnv (Bundle.run bundleOptions)

-- FIXME: do the thing
mkLogOptions :: GlobalArgs -> Aff LogOptions
mkLogOptions { noColor, quiet, verbose } = do
  supports <- liftEffect supportsColor
  let color = and [ supports, not noColor ]
  let
    verbosity =
      if quiet then
        LogQuiet
      else if verbose then
        LogVerbose
      else LogNormal
  pure { color, verbosity }

mkBundleEnv :: forall a. BundleArgs -> Spago (Fetch.FetchEnv a) { bundleEnv :: (Bundle.BundleEnv ()), bundleOptions :: Bundle.BundleOptions }
mkBundleEnv bundleArgs = do
  { config, logOptions } <- ask
  logDebug $ "Bundle args: " <> show bundleArgs
  -- the reason why we don't have a default on the CLI is that we look some of these
  -- up in the config - though the flags take precedence
  let
    bundleConf :: forall x. (BundleConfig -> Maybe x) -> Maybe x
    bundleConf f = config.bundle >>= f
  let minify = fromMaybe false (bundleArgs.minify <|> bundleConf _.minify)
  let entrypoint = fromMaybe "main.js" (bundleArgs.entrypoint <|> bundleConf _.entrypoint)
  let outfile = fromMaybe "index.js" (bundleArgs.outfile <|> bundleConf _.outfile)
  let
    platform = fromMaybe PlatformNode
      ( (Config.parsePlatform =<< bundleArgs.platform)
          <|> bundleConf _.platform
      )
  let bundleOptions = { minify, entrypoint, outfile, platform }
  let bundleEnv = { esbuild: "esbuild", logOptions } -- TODO: which esbuild
  pure { bundleOptions, bundleEnv }

mkBuildEnv :: forall a. Map PackageName Package -> Spago (Fetch.FetchEnv a) (Build.BuildEnv ())
mkBuildEnv dependencies = do
  { logOptions } <- ask
  -- FIXME: find executables in path, parse compiler version, etc etc
  pure { logOptions, purs: "purs", git: "git", dependencies }

mkFetchEnv :: forall a. FetchArgs -> Spago (LogEnv a) { env :: Fetch.FetchEnv (), packageNames :: Array PackageName }
mkFetchEnv args = do
  let { right: packageNames, left: failedPackageNames } = partitionMap PackageName.parse (Array.fromFoldable args.packages)
  unless (Array.null failedPackageNames) do
    die $ "Failed to parse some package name: " <> show failedPackageNames

  logDebug $ "CWD: " <> Paths.cwd

  -- Take care of the caches
  liftAff do
    FS.mkdirp Paths.globalCachePath
    FS.mkdirp Paths.localCachePath
    FS.mkdirp Paths.localCachePackagesPath
  logDebug $ "Global cache: " <> show Paths.globalCachePath
  logDebug $ "Local cache: " <> show Paths.localCachePath
  let registryPath = Path.concat [ Paths.globalCachePath, "registry" ]
  let registryIndexPath = Path.concat [ Paths.globalCachePath, "registry-index" ]

  -- we make a Ref for the Index so that we can memoize the lookup of packages
  -- and we don't have to read it all together
  indexRef <- liftEffect $ Ref.new (Map.empty :: Map PackageName (Map Version Manifest))
  let
    getManifestFromIndex :: PackageName -> Version -> Spago (LogEnv ()) (Maybe Manifest)
    getManifestFromIndex name version = do
      indexMap <- liftEffect (Ref.read indexRef)
      case Map.lookup name indexMap of
        Just meta -> pure (Map.lookup version meta)
        Nothing -> do
          -- if we don't have it we try reading it from file
          logDebug $ "Reading package from Index: " <> show name
          maybeManifests <- liftAff $ Index.readPackage registryIndexPath name
          let manifests = map (\m@(Manifest m') -> Tuple m'.version m) $ fromMaybe [] $ map NonEmptyArray.toUnfoldable maybeManifests
          let versions = Map.fromFoldable manifests
          liftEffect (Ref.write (Map.insert name versions indexMap) indexRef)
          pure (Map.lookup version versions)

  -- same deal for the metadata files
  metadataRef <- liftEffect $ Ref.new (Map.empty :: Map PackageName Metadata)
  let
    getMetadata :: PackageName -> Spago (LogEnv ()) (Either String Metadata)
    getMetadata name = do
      metadataMap <- liftEffect (Ref.read metadataRef)
      case Map.lookup name metadataMap of
        Just meta -> pure (Right meta)
        Nothing -> do
          -- if we don't have it we try reading it from file
          let metadataFilePath = Registry.API.metadataFile registryPath name
          logDebug $ "Reading metadata from file: " <> metadataFilePath
          liftAff (RegistryJson.readJsonFile metadataFilePath) >>= case _ of
            Left e -> pure (Left e)
            Right m -> do
              -- and memoize it
              liftEffect (Ref.write (Map.insert name m metadataMap) metadataRef)
              pure (Right m)

  -- clone the registry and index repo, or update them
  try (Git.fetchRepo { git: "https://github.com/purescript/registry-index.git", ref: "main" } registryIndexPath) >>= case _ of
    Right _ -> pure unit
    Left _err -> logWarn "Couldn't refresh the registry-index, will proceed anyways"
  try (Git.fetchRepo { git: "https://github.com/purescript/registry-preview.git", ref: "main" } registryPath) >>= case _ of
    Right _ -> pure unit
    Left _err -> logWarn "Couldn't refresh the registry, will proceed anyways"

  Config.readConfig "spago.yaml" >>= case _ of
    Left err -> die $ "Couldn't parse Spago config, error:\n  " <> err
    Right config -> do
      -- read in the package set
      -- TODO: try to parse that field, it might be a URL instead of a version number
      -- FIXME: this makes us support old package sets too
      logDebug "Reading the package set"
      let packageSetPath = Path.concat [ registryPath, "package-sets", config.packages_db.set <> ".json" ]
      liftAff (RegistryJson.readJsonFile packageSetPath) >>= case _ of
        Left err -> die $ "Couldn't read the package set: " <> err
        Right (Registry.PackageSet registryPackageSet) -> do
          logInfo "Read the package set from the registry"

          -- Mix in the package set the ExtraPackages from the config
          -- Note: if there are duplicate packages we prefer the ones from the extra_packages
          let
            packageSet = Map.union
              (map PackageSet.GitPackage (fromMaybe Map.empty config.packages_db.extra_packages))
              (map PackageSet.Version registryPackageSet.packages)

          { logOptions } <- ask
          pure
            { packageNames
            , env:
                { getManifestFromIndex
                , getMetadata
                , config
                , packageSet
                , logOptions
                }
            }
