module Yuki.N.Blob
  ( BlobMeta (..),
    BlobRef (..),
    BlobStore (..),
    newBlobStore,
    newMemoryBlobStore,
    sha256,
  )
where

import Control.Concurrent.MVar
import Control.Exception (IOException, displayException, try)
import Control.Monad ((>=>))
import Data.Aeson
import Data.Bits
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor (($>), (<&>))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word32, Word64, Word8)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import Yuki.N.AtomicFile (atomicEncodeFile, atomicWriteLazy)

data BlobMeta = BlobMeta
  { blobId :: Text,
    blobBytes :: Int,
    blobMediaType :: Text,
    blobCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON BlobMeta where
  toJSON meta =
    object
      [ "id" .= blobId meta,
        "bytes" .= blobBytes meta,
        "mediaType" .= blobMediaType meta,
        "created" .= blobCreated meta
      ]

instance FromJSON BlobMeta where
  parseJSON = withObject "BlobMeta" $ \fields ->
    BlobMeta
      <$> fields .: "id"
      <*> fields .: "bytes"
      <*> fields .: "mediaType"
      <*> fields .: "created"

data BlobRef = BlobRef
  { blobRefId :: Text,
    blobRefBlobId :: Text,
    blobRefIncarnationId :: Text,
    blobRefPurpose :: Text,
    blobRefSource :: Text,
    blobRefCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON BlobRef where
  toJSON ref =
    object
      [ "id" .= blobRefId ref,
        "blobId" .= blobRefBlobId ref,
        "incarnationId" .= blobRefIncarnationId ref,
        "purpose" .= blobRefPurpose ref,
        "source" .= blobRefSource ref,
        "created" .= blobRefCreated ref
      ]

instance FromJSON BlobRef where
  parseJSON = withObject "BlobRef" $ \fields ->
    BlobRef
      <$> fields .: "id"
      <*> fields .: "blobId"
      <*> fields .: "incarnationId"
      <*> fields .: "purpose"
      <*> fields .: "source"
      <*> fields .: "created"

data BlobStore = BlobStore
  { blobPut :: Text -> LazyByteString.ByteString -> IO BlobMeta,
    blobFetch :: Text -> IO (Either Text LazyByteString.ByteString),
    blobAttach :: Text -> Text -> Text -> Text -> Text -> IO (Either Text BlobRef),
    blobList :: IO [BlobMeta],
    blobRefList :: Text -> IO [BlobRef]
  }

data BlobIndex = BlobIndex
  { indexMetas :: Map Text BlobMeta,
    indexRefs :: Map Text BlobRef
  }
  deriving stock (Eq, Show)

instance ToJSON BlobIndex where
  toJSON index = object ["blobs" .= indexMetas index, "refs" .= indexRefs index]

instance FromJSON BlobIndex where
  parseJSON = withObject "BlobIndex" $ \fields ->
    BlobIndex
      <$> fields .:? "blobs" .!= Map.empty
      <*> fields .:? "refs" .!= Map.empty

emptyIndex :: BlobIndex
emptyIndex = BlobIndex Map.empty Map.empty

newBlobStore :: FilePath -> IO (Either Text BlobStore)
newBlobStore dir =
  createDirectoryIfMissing True (payloadPath dir)
    *> loadIndex (indexPath dir)
    >>= traverse (newMVar >=> pure . fileStore dir)

newMemoryBlobStore :: IO BlobStore
newMemoryBlobStore =
  newMVar Map.empty >>= \payloads ->
    newMVar emptyIndex <&> memoryStore payloads

fileStore :: FilePath -> MVar BlobIndex -> BlobStore
fileStore dir = store persist write fetch
 where
  persist = atomicEncodeFile (indexPath dir)
  write identifier = atomicWriteLazy (objectPath dir identifier)
  fetch identifier =
    (try (LazyByteString.readFile (objectPath dir identifier)) :: IO (Either IOException LazyByteString.ByteString))
      <&> either
        (Left . (\failure -> "cannot read blob " <> identifier <> ": " <> failure) . Text.pack . displayException)
        Right

memoryStore :: MVar (Map Text LazyByteString.ByteString) -> MVar BlobIndex -> BlobStore
memoryStore payloads = store (const (pure ())) write fetch
 where
  write identifier bytes = modifyMVar_ payloads (pure . Map.insert identifier bytes)
  fetch identifier =
    maybe (Left ("unknown blob: " <> identifier)) Right . Map.lookup identifier <$> readMVar payloads

store ::
  (BlobIndex -> IO ()) ->
  (Text -> LazyByteString.ByteString -> IO ()) ->
  (Text -> IO (Either Text LazyByteString.ByteString)) ->
  MVar BlobIndex ->
  BlobStore
store persist write fetch lock =
  BlobStore
    { blobPut = put,
      blobFetch = fetch,
      blobAttach = attach,
      blobList = Map.elems . indexMetas <$> readMVar lock,
      blobRefList = \incarnation ->
        filter ((== incarnation) . blobRefIncarnationId)
          . Map.elems
          . indexRefs
          <$> readMVar lock
    }
 where
  put mediaType bytes =
    getPOSIXTime >>= \now ->
      let identifier = "sha256-" <> sha256 (LazyByteString.toStrict bytes)
          meta = BlobMeta identifier (fromIntegral (LazyByteString.length bytes)) mediaType (round now)
       in modifyMVar lock $ \index ->
            case Map.lookup identifier (indexMetas index) of
              Just existing -> pure (index, existing)
              Nothing ->
                write identifier bytes
                  *> let updated = index {indexMetas = Map.insert identifier meta (indexMetas index)}
                      in persist updated $> (updated, meta)
  attach refId identifier incarnation purpose source =
    getPOSIXTime >>= \now ->
      modifyMVar lock $ \index ->
        case Map.lookup identifier (indexMetas index) of
          Nothing -> pure (index, Left ("unknown blob: " <> identifier))
          Just _ ->
            let ref = BlobRef refId identifier incarnation purpose source (round now)
                updated = index {indexRefs = Map.insert refId ref (indexRefs index)}
             in persist updated $> (updated, Right ref)

loadIndex :: FilePath -> IO (Either Text BlobIndex)
loadIndex path =
  (try (eitherDecodeFileStrict path) :: IO (Either IOException (Either String BlobIndex)))
    <&> \case
      Left failure
        | isDoesNotExistError failure -> Right emptyIndex
        | otherwise -> Left ("cannot read blob index: " <> Text.pack (displayException failure))
      Right (Left failure) -> Left ("invalid blob index: " <> Text.pack failure)
      Right (Right index) -> Right index

payloadPath :: FilePath -> FilePath
payloadPath dir = dir </> "payloads" </> "sha256"

indexPath :: FilePath -> FilePath
indexPath dir = dir </> "blob-index.json"

objectPath :: FilePath -> Text -> FilePath
objectPath dir identifier =
  payloadPath dir </> Text.unpack (Text.take 2 digest) </> Text.unpack digest
 where
  digest = Text.drop 7 identifier

sha256 :: ByteString.ByteString -> Text
sha256 =
  Text.pack
    . concatMap hex32
    . foldl' compress initialHash
    . chunksOf 64
    . pad
    . ByteString.unpack

pad :: [Word8] -> [Word8]
pad bytes = bytes <> [0x80] <> replicate zeros 0 <> word64be bits
 where
  bits = fromIntegral (length bytes) * 8
  zeros = (56 - (length bytes + 1) `mod` 64) `mod` 64

word64be :: Word64 -> [Word8]
word64be word =
  [ fromIntegral (word `shiftR` bitShift)
  | bitShift <- [56, 48 .. 0]
  ]

chunksOf :: Int -> [value] -> [[value]]
chunksOf _ [] = []
chunksOf count values = take count values : chunksOf count (drop count values)

compress :: [Word32] -> [Word8] -> [Word32]
compress state block =
  zipWith (+) state (foldl' roundHash state (zip roundConstants schedule))
 where
  schedule = extend (fmap word32be (chunksOf 4 block)) 16
  extend scheduleWords index
    | index >= 64 = scheduleWords
    | otherwise =
        extend
          ( scheduleWords
              <> [ small1 (scheduleWords !! (index - 2))
                     + scheduleWords !! (index - 7)
                     + small0 (scheduleWords !! (index - 15))
                     + scheduleWords !! (index - 16)
                 ]
          )
          (index + 1)
  roundHash [a', b', c', d', e', f', g', h'] (constant, word) =
    [ t1 + t2,
      a',
      b',
      c',
      d' + t1,
      e',
      f',
      g'
    ]
   where
    t1 = h' + big1 e' + choose e' f' g' + constant + word
    t2 = big0 a' + majority a' b' c'
  roundHash hash _ = hash

word32be :: [Word8] -> Word32
word32be = foldl' (\word byte -> word `shiftL` 8 .|. fromIntegral byte) 0

choose :: Word32 -> Word32 -> Word32 -> Word32
choose x y z = (x .&. y) `xor` (complement x .&. z)

majority :: Word32 -> Word32 -> Word32 -> Word32
majority x y z = (x .&. y) `xor` (x .&. z) `xor` (y .&. z)

big0, big1, small0, small1 :: Word32 -> Word32
big0 x = rotateR x 2 `xor` rotateR x 13 `xor` rotateR x 22
big1 x = rotateR x 6 `xor` rotateR x 11 `xor` rotateR x 25
small0 x = rotateR x 7 `xor` rotateR x 18 `xor` shiftR x 3
small1 x = rotateR x 17 `xor` rotateR x 19 `xor` shiftR x 10

hex32 :: Word32 -> String
hex32 word = replicate (8 - length rendered) '0' <> rendered
 where
  rendered = showHex word ""

initialHash :: [Word32]
initialHash =
  [ 0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19
  ]

roundConstants :: [Word32]
roundConstants =
  [ 0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2
  ]
