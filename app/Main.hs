{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Main where

import qualified Control.Foldl as Foldl
import Control.Lens (ix, traversed, (^..), (^?))
import Control.Monad (forM, join)
import qualified Crypto.Hash as Crypto
import Crypto.Hash.Algorithms (SHA256)
import Data.Aeson.Lens
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.Either (partitionEithers)
import Data.List (singleton)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import Network.HTTP.Client (defaultManagerSettings, httpLbs, managerSetProxy, newManager, parseRequest, proxyEnvironment, responseBody)
import System.Directory (doesFileExist, listDirectory)
import System.FilePath (dropFileName, (</>))
import System.IO (hPutStrLn, stderr)
import System.Posix.Files (getSymbolicLinkStatus, isSymbolicLink, readSymbolicLink)
import System.ProgressBar (Progress (Progress), Style (stylePostfix), defStyle, exact, incProgress, newProgressBar, remainingTime, renderDuration)
import Text.Read (readMaybe)
import Text.Regex

type ExternalRunId = Integer

type InternalRunId = Integer

retrieveExternalToInternalIdMap :: Int -> IO (Map.Map ExternalRunId Integer)
retrieveExternalToInternalIdMap beamtimeInternalId = do
  let settings = managerSetProxy (proxyEnvironment Nothing) defaultManagerSettings
  man <- newManager settings
  let reqUrl = ("http://cfeld-web02:6020/api/runs/" <> show beamtimeInternalId)
  req <- parseRequest reqUrl
  hPutStrLn stderr ("making request " <> show reqUrl)
  response <- httpLbs req man
  let runObjects = responseBody response ^.. key "runs" . _Array . traversed . _Object
      externalToInternalId :: Map.Map Integer Integer
      externalToInternalId = Map.fromList (runObjects >>= (\runObject -> maybe [] singleton ((,) <$> (runObject ^? ix "external_id" . _Integer) <*> (runObject ^? ix "id" . _Integer))))
  pure externalToInternalId

polishCommandLine :: T.Text -> T.Text
polishCommandLine cli =
  let (_, actualCli) = T.breakOn "indexamajig" cli
      regexReplace :: Regex -> T.Text -> T.Text -> T.Text
      regexReplace needle haystack replacement = T.pack (subRegex needle (T.unpack haystack) (T.unpack replacement))
      regexRemove :: Regex -> T.Text -> T.Text
      regexRemove needle haystack = regexReplace needle haystack ""
      regexRemovals =
        mkRegex
          <$> [ "-j [0-9]+",
                "--data-format=[^ ]+",
                "-p [^ ]+",
                "--asapo-[^ =]*[ =][^ ]*",
                "-g [^ ]+",
                "-j[0-9]+",
                "--temp-dir=[^ ]+",
                "--no-data-timeout=[^ ]+",
                "--mille-dir=[^ ]+",
                "--cpu-pin",
                "--profile",
                "-o [^ ]+",
                "indexamajig"
              ]
      afterRemovals = foldr regexRemove actualCli regexRemovals
   in T.strip (regexReplace (mkRegex "[ ]+") afterRemovals " ")

extractGeometryFromCommandLine :: T.Text -> Maybe FilePath
extractGeometryFromCommandLine cli =
  case matchRegex (mkRegex "-g ([^ ]+)") (T.unpack cli) of
    Just (geometry : _) -> Just geometry
    _ -> Nothing

data StreamFileDirectInformation = StreamFileDirectInformation
  { rawCrystfelVersion :: !T.Text,
    rawCommandLine :: !T.Text,
    rawFoms :: !(Int, Int, Int)
  }
  deriving (Show)

data StreamFileInformation = StreamFileInformation
  { streamFileCrystfelVersion :: T.Text,
    streamFileCommandLine :: T.Text,
    streamFileGeometry :: T.Text,
    streamFileGeometryHash :: T.Text,
    streamFileFoms :: (Int, Int, Int)
  }
  deriving (Show)

versionPrefix :: BS.ByteString
versionPrefix = "Generated by CrystFEL"

extractVersion :: T.Text -> T.Text
extractVersion = T.drop (BS.length "Generated by CrystFEL" + 1)

-- conduitForStreamDirectInformation = do
--   dropWhileC (\line -> not (versionPrefix `BS.isPrefixOf` line))
--   generatedByCrystFel <- headC
--   dropWhileC (\line -> not ("indexamajig" `BS.isInfixOf` line))
--   indexamajig <- headC
--   imagesAndHits <-
--     getZipSink
--       ( (,,)
--           <$> ZipSink (lengthIfC (\line -> line == "----- Begin chunk -----"))
--           <*> ZipSink (lengthIfC (\line -> line == "hit = 1"))
--           <*> ZipSink (lengthIfC (\line -> "indexed_by = a" `BS.isPrefixOf` line))
--       )
--   -- let imagesAndHits = (0, 0, 0)
--   pure
--     ( StreamFileDirectInformation
--         (TE.decodeUtf8 <$> generatedByCrystFel)
--         (TE.decodeUtf8 <$> indexamajig)
--         imagesAndHits
--     )

-- extractStreamFileDirectInformation :: FilePath -> IO StreamFileDirectInformation
-- extractStreamFileDirectInformation fileName =
--   runConduitRes $
--     sourceFile fileName
--       .| linesUnboundedAsciiC
--       .| conduitForStreamDirectInformation

data StreamFileLine = BeginChunk | HitEqualOne | IndexedBy | Other deriving (Eq)

countIf :: (a -> Bool) -> Foldl.Fold a Int
countIf f = Foldl.Fold step begin done
  where
    begin = 0
    step prior new
      | f new = prior + 1
      | otherwise = prior
    done prior = prior

transformFind :: (a -> Maybe b) -> Foldl.Fold a (Maybe b)
transformFind f = Foldl.Fold step begin done
  where
    begin = Nothing
    step Nothing new = f new
    step x _ = x
    done prior = prior

extractStreamFileDirectInformationTextBased :: FilePath -> IO (Either T.Text StreamFileDirectInformation)
extractStreamFileDirectInformationTextBased fileName = do
  fileContents <- BSL.readFile fileName
  let fileLines = BSL.lines fileContents
      decodeLine :: BSL.ByteString -> StreamFileLine
      decodeLine line =
        if "----- Begin chunk" `BSL.isPrefixOf` line
          then BeginChunk
          else
            if "hit = 1" `BSL.isPrefixOf` line
              then HitEqualOne
              else
                if "indexed_by = a" `BSL.isPrefixOf` line
                  then IndexedBy
                  else Other

  case break ("Generated by CrystFEL" `BSL.isPrefixOf`) fileLines of
    (_beforeGeneratedBy, generatedByCrystfel : afterGeneratedBy) ->
      case break (("indexamajig" `BS.isInfixOf`) . BSL.toStrict) afterGeneratedBy of
        (_beforeIndexamajig, indexamajig : afterIndexamajig) ->
          let (images, hits, indexed) = Foldl.fold ((,,) <$> countIf (\x -> x == BeginChunk) <*> countIf (\x -> x == HitEqualOne) <*> countIf (\x -> x == IndexedBy)) (decodeLine <$> afterIndexamajig)
           in pure $
                Right $
                  StreamFileDirectInformation
                    (TE.decodeUtf8 (BSL.toStrict generatedByCrystfel))
                    (TE.decodeUtf8 (BSL.toStrict indexamajig))
                    (images, hits, indexed)
        _ -> pure $ Left $ "couldn't find an indexamajig command line"
    _ -> pure $ Left $ "couldn't find a generated by line"

readSymlinkOrDoNothing :: FilePath -> IO FilePath
readSymlinkOrDoNothing fp = do
  status <- getSymbolicLinkStatus fp
  if isSymbolicLink status
    then do
      resolvedLink <- readSymbolicLink fp
      let finalPath = dropFileName fp </> resolvedLink
      exists <- doesFileExist finalPath
      if exists
        then pure finalPath
        else error $ "path " <> finalPath <> " does not exist"
    else pure fp

extractStreamFileInformation :: FilePath -> IO (Either T.Text StreamFileInformation)
extractStreamFileInformation fileName = do
  output <- extractStreamFileDirectInformationTextBased fileName
  case output of
    Left e -> pure $ Left $ "error reading " <> T.pack fileName <> ": " <> e
    Right (StreamFileDirectInformation {rawCrystfelVersion, rawCommandLine, rawFoms}) ->
      case extractGeometryFromCommandLine rawCommandLine of
        Nothing -> pure (Left "couldn't extract geometry file from command line")
        Just geometryFile' -> do
          symlink <- readSymlinkOrDoNothing geometryFile'
          geometryFileContents <- BS.readFile geometryFile'
          let geometryHash = sha256HashAsText geometryFileContents
          pure $
            Right $
              StreamFileInformation
                (extractVersion rawCrystfelVersion)
                (polishCommandLine rawCommandLine)
                (T.pack symlink)
                geometryHash
                rawFoms

sha256HashAsText :: BS.ByteString -> T.Text
sha256HashAsText bs = T.pack (show (Crypto.hash bs :: Crypto.Digest SHA256))

defaultStreamRegex :: String
defaultStreamRegex = "run_([0-9]+).*\\.stream"

retrieveStreamFiles :: Maybe String -> FilePath -> IO [(FilePath, ExternalRunId)]
retrieveStreamFiles regexToUse baseDir = do
  files <- listDirectory baseDir
  let parsePath :: FilePath -> Maybe (FilePath, ExternalRunId)
      parsePath fp = (fp,) <$> (matchRegex (mkRegex (fromMaybe defaultStreamRegex regexToUse)) fp >>= listToMaybe >>= readMaybe)
  pure (mapMaybe parsePath files)

processBeamTimeStream ::
  (Ord a1, Show a1) =>
  Map.Map a1 a2 ->
  String ->
  (FilePath, a1) ->
  IO (Either T.Text (a2, StreamFileInformation))
processBeamTimeStream externalToInternalRunId baseDir (streamFileName, externalRunId) = do
  let streamFile = baseDir </> streamFileName
  -- TIO.putStrLn $ "reading data for run " <> T.pack (show externalRunId)
  case Map.lookup externalRunId externalToInternalRunId of
    Nothing -> pure $ Left $ "couldn't find internal run ID for run " <> T.pack (show externalRunId)
    Just internalRunId -> do
      output <- extractStreamFileInformation streamFile
      case output of
        Left e -> pure $ Left $ "error reading stream file " <> T.pack streamFile <> ": " <> e
        Right v -> pure $ Right $ (internalRunId, v)

printParams :: StreamFileInformation -> T.Text
printParams params =
  let pairs =
        [ ("crystfel_version", streamFileCrystfelVersion params),
          ("geometry_file", streamFileGeometry params),
          ("geometry_hash", streamFileGeometryHash params),
          ("command_line", streamFileCommandLine params)
        ]
      quote x = "\"" <> x <> "\""
      makePair (a, b) = quote a <> ": " <> quote b
   in T.intercalate "," (makePair <$> pairs)

printRange :: (Integer, Integer) -> T.Text
printRange (from, to) = "(" <> T.pack (show from) <> ", " <> T.pack (show to) <> ")"

printRunsWithParameters :: [(Integer, Integer)] -> StreamFileInformation -> T.Text
printRunsWithParameters runRanges parameters = "{" <> "\"run_ranges\": [" <> T.intercalate "," (printRange <$> runRanges) <> "], " <> printParams parameters <> "}"

foldIntervals :: NE.NonEmpty Integer -> [(Integer, Integer)]
foldIntervals list@(x NE.:| _) =
  let (pairs, lastPair) = foldl f ([], (x, x)) list
   in lastPair : pairs
  where
    f :: ([(Integer, Integer)], (Integer, Integer)) -> Integer -> ([(Integer, Integer)], (Integer, Integer))
    f (oldPairs, (startSequence, endSequence)) newNumber =
      if newNumber == endSequence
        then (oldPairs, (startSequence, endSequence))
        else
          if newNumber == endSequence + 1
            then (oldPairs, (startSequence, endSequence + 1))
            else ((startSequence, endSequence) : oldPairs, (newNumber, newNumber))

data MigrationResult = MigrationResult
  { migrationRunGroups :: ![T.Text],
    migrationRunDetails :: ![T.Text]
  }

migrateDefault :: Maybe String -> FilePath -> Int -> IO MigrationResult
migrateDefault streamFileRegex baseDir internalId = do
  externalToInternalRunId <- retrieveExternalToInternalIdMap internalId
  streamFiles <- retrieveStreamFiles streamFileRegex baseDir
  let numberOfStreamFiles = length streamFiles
  pb <- newProgressBar (defStyle {stylePostfix = exact <> " " <> remainingTime renderDuration "N/A"}) 10 (Progress 0 numberOfStreamFiles ())
  infos <-
    forM streamFiles \thisStreamFile -> do
      incProgress pb 1
      processBeamTimeStream externalToInternalRunId baseDir thisStreamFile
  let (_, infos') = partitionEithers infos
      groups :: [NE.NonEmpty (InternalRunId, StreamFileInformation)]
      groups =
        NE.groupAllWith
          (\(_, info) -> (streamFileCrystfelVersion info, streamFileCommandLine info, streamFileGeometry info))
          infos'
      mapGroup :: NE.NonEmpty (InternalRunId, StreamFileInformation) -> T.Text
      mapGroup g =
        let runRanges :: [(Integer, Integer)]
            runRanges = foldIntervals (NE.sort (fst <$> g))
            parameters = snd (NE.head g)
         in printRunsWithParameters runRanges parameters
      mapFoms :: (InternalRunId, StreamFileInformation) -> T.Text
      mapFoms (rid, (StreamFileInformation {streamFileFoms = (images, hits, indexed)})) =
        T.pack (show rid) <> ": {\"images\": " <> T.pack (show images) <> ", " <> ", \"hits\": " <> T.pack (show hits) <> ", " <> ", \"indexed\": " <> T.pack (show indexed) <> "}"

  pure $ MigrationResult (mapGroup <$> groups) (mapFoms <$> infos')

migrate110 :: IO MigrationResult
migrate110 = migrateDefault Nothing "/asap3/petra3/gpfs/p11/2022/data/11014381/processed/" 110

migrate111 :: IO MigrationResult
migrate111 = migrateDefault Nothing "/asap3/petra3/gpfs/p11/2022/data/11014380/processed/" 111

migrate112 :: IO MigrationResult
migrate112 = migrateDefault Nothing "/asap3/petra3/gpfs/p11/2022/data/11014376/processed/" 112

migrate113 :: IO MigrationResult
migrate113 = migrateDefault Nothing "/asap3/petra3/gpfs/p11/2022/data/11015430/processed/streams/" 113

migrate114 :: IO MigrationResult
migrate114 = migrateDefault Nothing "/asap3/petra3/gpfs/p11/2022/data/11015490/processed/streams/" 114

migrate115 :: IO MigrationResult
migrate115 = migrateDefault Nothing "/asap3/petra3/gpfs/p11/2023/data/11016853/processed/" 115

migrate116 :: IO MigrationResult
migrate116 = migrateDefault Nothing "/asap3/petra3/gpfs/p11/2023/data/11016848/processed/" 116

migrate120 :: IO MigrationResult
migrate120 = migrateDefault (Just "run-([0-9]+).*\\.stream") "/asap3/petra3/gpfs/p11/2024/data/11017935/processed/indexing-results" 120

migrate121 :: IO MigrationResult
migrate121 = migrateDefault (Just "run-([0-9]+).*\\.stream") "/asap3/petra3/gpfs/p11/2024/data/11019260/processed/indexing-results" 121

migrate122 :: IO MigrationResult
migrate122 = migrateDefault (Just "run-([0-9]+).*\\.stream") "/asap3/petra3/gpfs/p11/2024/data/11019287/processed/indexing-results" 122

-- main :: IO ()
-- main = do
--   let fileName = "/asap3/petra3/gpfs/p11/2024/data/11019260/processed/indexing-results/run-3-indexing-10251.stream"
--   putStrLn "starting"
--   results <- extractStreamFileDirectInformationTextBased fileName
--   -- results <- extractStreamFileDirectInformation fileName
--   print results

main :: IO ()
main = do
  let migrations =
        [ migrate110,
          migrate111,
          migrate112,
          migrate113,
          migrate114,
          migrate115,
          migrate116,
          migrate120,
          migrate121,
          migrate122
        ]
      numMigrations = length migrations
  pb <- newProgressBar (defStyle {stylePostfix = exact <> " " <> remainingTime renderDuration "N/A"}) 10 (Progress 0 numMigrations ())
  allMigrationResults <- forM migrations \migration -> do
    TIO.hPutStrLn stderr "next migration"
    result <- migration
    incProgress pb 1
    pure result
  TIO.putStrLn "RUN_RANGES_WITH_PARAMETERS = ["
  TIO.putStrLn (T.intercalate ",\n  " (join (migrationRunGroups <$> allMigrationResults)))
  TIO.putStrLn "\n]"
  TIO.putStrLn "INDEXING_RESULTS_WITH_PARAMETERS = {"
  TIO.putStrLn (T.intercalate ",\n  " (join (migrationRunDetails <$> allMigrationResults)))
  TIO.putStrLn "\n}"
