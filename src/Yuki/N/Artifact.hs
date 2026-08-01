module Yuki.N.Artifact
  ( ArtifactMeta (..),
    ArtifactStore (..),
    SpliceConfig (..),
    artifactIdFor,
    artifactReadToolName,
    artifactRetentionLimit,
    artifactStub,
    fnv1a64,
    isArtifactStub,
    newArtifactStore,
    newArtifactStoreWithLimit,
    newMemoryArtifactStore,
    newMemoryArtifactStoreWithLimit,
    renderHash,
    stubThreshold,
  )
where

import Control.Concurrent.MVar
import Control.Exception (IOException, try)
import Data.Aeson
import Data.Bits (xor)
import Data.Bool (bool)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char qualified as Char
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word64)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing, removeFile)
import Yuki.N.AtomicFile (atomicWriteLazy, atomicWriteText)

data ArtifactStore = ArtifactStore
  { artifactSave :: Text -> Text -> IO Text,
    artifactFetch :: Text -> IO (Maybe Text),
    artifactList :: IO [ArtifactMeta]
  }

data ArtifactMeta = ArtifactMeta
  { artifactMetaId :: Text,
    artifactMetaToolName :: Text,
    artifactMetaPreview :: Text,
    artifactMetaChars :: Int,
    artifactMetaTime :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON ArtifactMeta where
  toJSON meta =
    object
      [ "id" .= artifactMetaId meta,
        "toolName" .= artifactMetaToolName meta,
        "preview" .= artifactMetaPreview meta,
        "chars" .= artifactMetaChars meta,
        "time" .= artifactMetaTime meta
      ]

instance FromJSON ArtifactMeta where
  parseJSON = withObject "ArtifactMeta" $ \fields ->
    ArtifactMeta
      <$> fields .: "id"
      <*> fields .: "toolName"
      <*> fields .:? "preview" .!= ""
      <*> fields .: "chars"
      <*> fields .: "time"

artifactReadToolName :: Text
artifactReadToolName = "artifact_read"

stubThreshold :: Int
stubThreshold = 256

data SpliceConfig = SpliceConfig
  { spliceChars :: Int,
    spliceKeep :: Int
  }
  deriving stock (Eq, Show)

instance ToJSON SpliceConfig where
  toJSON config = object ["chars" .= spliceChars config, "keep" .= spliceKeep config]

instance FromJSON SpliceConfig where
  parseJSON = withObject "SpliceConfig" $ \fields ->
    SpliceConfig <$> fields .: "chars" <*> fields .: "keep"

artifactIdFor :: Text -> Text
artifactIdFor = ("art-" <>) . renderHash . fnv1a64

fnv1a64 :: Text -> Word64
fnv1a64 = ByteString.foldl' step 14695981039346656037 . TextEncoding.encodeUtf8
 where
  step hash byte = (hash `xor` fromIntegral byte) * 1099511628211

renderHash :: Word64 -> Text
renderHash = Text.justifyRight 16 '0' . Text.pack . (`showHex` "")

stubMarker :: Text
stubMarker = "[duplicate result elided: "

artifactStub :: Text -> Text -> Text -> Text
artifactStub identifier toolName content =
  stubMarker
    <> "artifact="
    <> identifier
    <> ", tool="
    <> toolName
    <> ", chars="
    <> Text.pack (show (Text.length content))
    <> "]\n"
    <> Text.take 200 content

isArtifactStub :: Text -> Bool
isArtifactStub = Text.isPrefixOf stubMarker

newArtifactStore :: FilePath -> IO ArtifactStore
newArtifactStore = newArtifactStoreWithLimit artifactRetentionLimit

artifactRetentionLimit :: Int
artifactRetentionLimit = 1024

newArtifactStoreWithLimit :: Int -> FilePath -> IO ArtifactStore
newArtifactStoreWithLimit requestedLimit dir =
  createDirectoryIfMissing True (objectsPath dir)
    *> newMVar ()
    >>= \lock ->
      withMVar lock (const (compact dir limit))
        $> ArtifactStore (save lock) fetch (list lock)
 where
  limit = max 1 requestedLimit
  save lock toolName content =
    withMVar lock $ \_ ->
      place (fetchObject dir) (writeObject dir content) content >>= \identifier ->
        getPOSIXTime >>= \now ->
          readIndex dir >>= \metas ->
            let current = artifactMeta identifier toolName content (round now)
                retained = take limit (current : filter ((/= identifier) . artifactMetaId) metas)
             in writeIndex dir retained
                  *> removeArtifacts dir (drop limit (current : filter ((/= identifier) . artifactMetaId) metas))
                  $> identifier
  fetch identifier
    | Text.null identifier || not (Text.all safe identifier) = pure Nothing
    | otherwise = fetchObject dir identifier
  safe char = Char.isAsciiLower char || Char.isDigit char || char == '-'
  list lock =
    withMVar lock $ \_ ->
      readIndex dir >>= \metas ->
        traverse (enrich dir) metas >>= \enriched ->
          enriched <$ bool (pure ()) (writeIndex dir enriched) (metas /= enriched)

newMemoryArtifactStore :: IO ArtifactStore
newMemoryArtifactStore = newMemoryArtifactStoreWithLimit artifactRetentionLimit

newMemoryArtifactStoreWithLimit :: Int -> IO ArtifactStore
newMemoryArtifactStoreWithLimit requestedLimit =
  newIORef Map.empty <&> \objects -> ArtifactStore (save objects) (fetch objects) (list objects)
 where
  limit = max 1 requestedLimit
  save objects toolName content = place (fetch objects) (store objects toolName content) content
  store objects toolName content identifier =
    getPOSIXTime
      >>= \now ->
        modifyIORef'
          objects
          ( \current ->
              let inserted = Map.insert identifier (artifactMeta identifier toolName content (round now), content) current
                  retained = Set.fromList (take limit (identifier : filter (/= identifier) (Map.keys current)))
               in Map.restrictKeys inserted retained
          )
  fetch objects identifier = fmap snd . Map.lookup identifier <$> readIORef objects
  list objects = fmap fst . Map.elems <$> readIORef objects

artifactMeta :: Text -> Text -> Text -> Integer -> ArtifactMeta
artifactMeta identifier toolName content =
  ArtifactMeta identifier toolName (preview content) (Text.length content)

enrich :: FilePath -> ArtifactMeta -> IO ArtifactMeta
enrich dir meta
  | not (Text.null (artifactMetaPreview meta)) = pure meta
  | otherwise =
      fetchObject dir (artifactMetaId meta)
        <&> maybe meta (\content -> meta {artifactMetaPreview = preview content})

preview :: Text -> Text
preview content =
  Text.take
    180
    (bool "（空内容）" normalized (not (Text.null normalized)))
 where
  normalized = Text.unwords (Text.words content)

place :: (Text -> IO (Maybe Text)) -> (Text -> IO ()) -> Text -> IO Text
place fetch write content = attempt base 1
 where
  base = artifactIdFor content
  attempt :: Text -> Int -> IO Text
  attempt candidate n =
    fetch candidate >>= \case
      Nothing -> candidate <$ write candidate
      Just existing
        | existing == content -> pure candidate
        | otherwise -> attempt (base <> "-" <> Text.pack (show n)) (n + 1)

objectsPath :: FilePath -> FilePath
objectsPath dir = dir ++ "/objects"

objectPath :: FilePath -> Text -> FilePath
objectPath dir identifier = objectsPath dir ++ "/" ++ Text.unpack identifier

fetchObject :: FilePath -> Text -> IO (Maybe Text)
fetchObject dir identifier = readMaybe (objectPath dir identifier)

readMaybe :: FilePath -> IO (Maybe Text)
readMaybe path =
  either (const Nothing) Just <$> (try (TextIO.readFile path) :: IO (Either IOException Text))

writeObject :: FilePath -> Text -> Text -> IO ()
writeObject dir content identifier = atomicWriteText (objectPath dir identifier) content

readIndex :: FilePath -> IO [ArtifactMeta]
readIndex dir =
  either (const []) (foldl' insert [] . LazyByteString.split 10) <$> attempt
 where
  attempt = try (LazyByteString.readFile (dir ++ "/index.jsonl")) :: IO (Either IOException LazyByteString.ByteString)
  insert metas = maybe metas (\meta -> meta : filter ((/= artifactMetaId meta) . artifactMetaId) metas) . decode

writeIndex :: FilePath -> [ArtifactMeta] -> IO ()
writeIndex dir =
  atomicWriteLazy (dir ++ "/index.jsonl")
    . LazyByteString.concat
    . fmap ((<> "\n") . encode)
    . reverse

compact :: FilePath -> Int -> IO ()
compact dir limit =
  readIndex dir >>= \metas ->
    writeIndex dir (take limit metas)
      *> removeArtifacts dir (drop limit metas)

removeArtifacts :: FilePath -> [ArtifactMeta] -> IO ()
removeArtifacts dir = traverse_ (ignoringIO . removeFile . objectPath dir . artifactMetaId)

ignoringIO :: IO () -> IO ()
ignoringIO action = (try action :: IO (Either IOException ())) $> ()
