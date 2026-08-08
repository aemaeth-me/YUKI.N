module Yuki.N.Artifact
  ( ArtifactStore (..),
    SpliceConfig (..),
    artifactIdFor,
    artifactReadToolName,
    artifactStub,
    isArtifactStub,
    newArtifactStore,
    stubThreshold,
  )
where

import Control.Concurrent.MVar
import Control.Exception (IOException, try)
import Data.Bits (xor)
import Data.ByteString qualified as ByteString
import Data.Char qualified as Char
import Data.Functor ((<&>))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Word (Word64)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing)
import Yuki.N.AtomicFile (atomicWriteText)

data ArtifactStore = ArtifactStore
  { artifactSave :: Text -> IO Text,
    artifactFetch :: Text -> IO (Maybe Text)
  }

artifactReadToolName :: Text
artifactReadToolName = "artifact_read"

stubThreshold :: Int
stubThreshold = 256

data SpliceConfig = SpliceConfig
  { spliceChars :: Int,
    spliceKeep :: Int
  }
  deriving stock (Eq, Show)

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
newArtifactStore dir =
  createDirectoryIfMissing True (objectsPath dir)
    *> newMVar ()
    <&> store
 where
  store lock = ArtifactStore (save lock) fetch
  save lock content =
    withMVar lock (const (place (fetchObject dir) (writeObject dir content) content))
  fetch identifier
    | not (validIdentifier identifier) = pure Nothing
    | otherwise = fetchObject dir identifier

place :: (Text -> IO (Maybe Text)) -> (Text -> IO ()) -> Text -> IO Text
place fetch write content = attempt base 1
 where
  base = artifactIdFor content
  attempt :: Text -> Int -> IO Text
  attempt candidate n = fetch candidate >>= decide candidate n
  decide candidate _ Nothing = candidate <$ write candidate
  decide candidate n (Just existing)
    | existing == content = pure candidate
    | otherwise = attempt (base <> "-" <> Text.pack (show n)) (n + 1)

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

validIdentifier :: Text -> Bool
validIdentifier identifier = not (Text.null identifier) && Text.all safe identifier
 where
  safe char = Char.isAsciiLower char || Char.isDigit char || char == '-'
