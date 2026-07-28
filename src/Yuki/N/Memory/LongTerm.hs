module Yuki.N.Memory.LongTerm
  ( GrepRequest (..),
    LongMemory (..),
    LongTermStore (..),
    MemoryCatalogItem (..),
    MemoryGrepResult (..),
    MemoryReadReceipt (..),
    MemoryReadResult (..),
    MemoryRef (..),
    MemorySnippet (..),
    MemorySpace (..),
    MemoryStatus (..),
    MemoryVisibility (..),
    ReadRequest (..),
    RememberRequest (..),
    VoidRequest (..),
    memoryStatusName,
    memoryVisibilityName,
    newLongTermStore,
    newMemoryLongTermStore,
  )
where

import Control.Concurrent.MVar
import Control.Exception (IOException, displayException, try)
import Control.Monad (foldM, (>=>))
import Data.Aeson
import Data.Bool (bool)
import qualified Data.Char as Char
import Data.Foldable (traverse_)
import Data.Function ((&))
import Data.Functor ((<&>))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import Yuki.N.AtomicFile (atomicEncodeFile)
import Yuki.N.Blob (sha256)

data MemoryVisibility = MemoryPrivate | MemoryShared
  deriving stock (Eq, Ord, Show)

memoryVisibilityName :: MemoryVisibility -> Text
memoryVisibilityName = \case
  MemoryPrivate -> "private"
  MemoryShared -> "shared"

instance ToJSON MemoryVisibility where
  toJSON = String . memoryVisibilityName

instance FromJSON MemoryVisibility where
  parseJSON = withText "MemoryVisibility" $ \case
    "private" -> pure MemoryPrivate
    "shared" -> pure MemoryShared
    other -> fail ("unknown memory visibility: " <> Text.unpack other)

data MemoryStatus = MemoryActive | MemoryDormant | MemoryVoid
  deriving stock (Eq, Ord, Show)

memoryStatusName :: MemoryStatus -> Text
memoryStatusName = \case
  MemoryActive -> "active"
  MemoryDormant -> "dormant"
  MemoryVoid -> "void"

instance ToJSON MemoryStatus where
  toJSON = String . memoryStatusName

instance FromJSON MemoryStatus where
  parseJSON = withText "MemoryStatus" $ \case
    "active" -> pure MemoryActive
    "dormant" -> pure MemoryDormant
    "void" -> pure MemoryVoid
    other -> fail ("unknown memory status: " <> Text.unpack other)

data LongMemory = LongMemory
  { longMemoryId :: Text,
    longMemoryOwner :: Text,
    longMemoryVisibility :: MemoryVisibility,
    longMemoryKind :: Text,
    longMemoryContent :: Text,
    longMemoryKeywords :: [Text],
    longMemorySourceRefs :: [Text],
    longMemoryRevision :: Int,
    longMemoryCreated :: Integer,
    longMemoryRevised :: Integer,
    longMemoryStatus :: MemoryStatus
  }
  deriving stock (Eq, Show)

instance ToJSON LongMemory where
  toJSON memory =
    object
      [ "id" .= longMemoryId memory,
        "owner" .= longMemoryOwner memory,
        "visibility" .= longMemoryVisibility memory,
        "kind" .= longMemoryKind memory,
        "content" .= longMemoryContent memory,
        "keywords" .= longMemoryKeywords memory,
        "sourceRefs" .= longMemorySourceRefs memory,
        "revision" .= longMemoryRevision memory,
        "created" .= longMemoryCreated memory,
        "revised" .= longMemoryRevised memory,
        "status" .= longMemoryStatus memory
      ]

instance FromJSON LongMemory where
  parseJSON = withObject "LongMemory" $ \fields ->
    LongMemory
      <$> fields .: "id"
      <*> fields .: "owner"
      <*> fields .: "visibility"
      <*> fields .: "kind"
      <*> fields .: "content"
      <*> fields .:? "keywords" .!= []
      <*> fields .:? "sourceRefs" .!= []
      <*> fields .: "revision"
      <*> fields .: "created"
      <*> fields .: "revised"
      <*> fields .: "status"

data MemorySpace = MemorySpace
  { memorySpaceId :: Text,
    memorySpaceOwner :: Text,
    memorySpaceVisibility :: MemoryVisibility,
    memorySpaceRevision :: Int
  }
  deriving stock (Eq, Show)

instance ToJSON MemorySpace where
  toJSON space =
    object
      [ "id" .= memorySpaceId space,
        "owner" .= memorySpaceOwner space,
        "visibility" .= memorySpaceVisibility space,
        "revision" .= memorySpaceRevision space
      ]

instance FromJSON MemorySpace where
  parseJSON = withObject "MemorySpace" $ \fields ->
    MemorySpace
      <$> fields .: "id"
      <*> fields .: "owner"
      <*> fields .: "visibility"
      <*> fields .: "revision"

data MemoryRef = MemoryRef
  { memoryRefId :: Text,
    memoryRefRevision :: Int
  }
  deriving stock (Eq, Ord, Show)

instance ToJSON MemoryRef where
  toJSON ref = object ["id" .= memoryRefId ref, "revision" .= memoryRefRevision ref]

instance FromJSON MemoryRef where
  parseJSON = withObject "MemoryRef" $ \fields ->
    MemoryRef <$> fields .: "id" <*> fields .: "revision"

data MemoryCatalogItem = MemoryCatalogItem
  { memoryCatalogId :: Text,
    memoryCatalogRevision :: Int,
    memoryCatalogOwner :: Text,
    memoryCatalogKind :: Text,
    memoryCatalogVisibility :: MemoryVisibility,
    memoryCatalogKeywords :: [Text],
    memoryCatalogPreview :: Text,
    memoryCatalogRevised :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON MemoryCatalogItem where
  toJSON item =
    object
      [ "id" .= memoryCatalogId item,
        "revision" .= memoryCatalogRevision item,
        "owner" .= memoryCatalogOwner item,
        "kind" .= memoryCatalogKind item,
        "visibility" .= memoryCatalogVisibility item,
        "keywords" .= memoryCatalogKeywords item,
        "preview" .= memoryCatalogPreview item,
        "revised" .= memoryCatalogRevised item
      ]

instance FromJSON MemoryCatalogItem where
  parseJSON = withObject "MemoryCatalogItem" $ \fields ->
    MemoryCatalogItem
      <$> fields .: "id"
      <*> fields .: "revision"
      <*> fields .: "owner"
      <*> fields .: "kind"
      <*> fields .: "visibility"
      <*> fields .:? "keywords" .!= []
      <*> fields .:? "preview" .!= ""
      <*> fields .: "revised"

data RememberRequest = RememberRequest
  { rememberOwner :: Text,
    rememberVisibility :: MemoryVisibility,
    rememberKind :: Text,
    rememberContent :: Text,
    rememberKeywords :: [Text],
    rememberSourceRefs :: [Text]
  }
  deriving stock (Eq, Show)

instance ToJSON RememberRequest where
  toJSON request =
    object
      [ "owner" .= rememberOwner request,
        "visibility" .= rememberVisibility request,
        "kind" .= rememberKind request,
        "content" .= rememberContent request,
        "keywords" .= rememberKeywords request,
        "sourceRefs" .= rememberSourceRefs request
      ]

instance FromJSON RememberRequest where
  parseJSON = withObject "RememberRequest" $ \fields ->
    RememberRequest
      <$> fields .: "owner"
      <*> fields .: "visibility"
      <*> fields .: "kind"
      <*> fields .: "content"
      <*> fields .:? "keywords" .!= []
      <*> fields .:? "sourceRefs" .!= []

data GrepRequest = GrepRequest
  { grepIncarnationId :: Text,
    grepQuery :: Text,
    grepVisibility :: Maybe MemoryVisibility,
    grepLimit :: Int
  }
  deriving stock (Eq, Show)

instance ToJSON GrepRequest where
  toJSON request =
    object
      [ "incarnationId" .= grepIncarnationId request,
        "query" .= grepQuery request,
        "visibility" .= grepVisibility request,
        "limit" .= grepLimit request
      ]

instance FromJSON GrepRequest where
  parseJSON = withObject "GrepRequest" $ \fields ->
    GrepRequest
      <$> fields .: "incarnationId"
      <*> fields .: "query"
      <*> fields .:? "visibility"
      <*> fields .:? "limit" .!= defaultGrepLimit

data ReadRequest = ReadRequest
  { readIncarnationId :: Text,
    readMemoryId :: Text,
    readMemoryRevision :: Maybe Int
  }
  deriving stock (Eq, Show)

instance ToJSON ReadRequest where
  toJSON request =
    object
      [ "incarnationId" .= readIncarnationId request,
        "id" .= readMemoryId request,
        "revision" .= readMemoryRevision request
      ]

instance FromJSON ReadRequest where
  parseJSON = withObject "ReadRequest" $ \fields ->
    ReadRequest
      <$> fields .: "incarnationId"
      <*> fields .: "id"
      <*> fields .:? "revision"

data VoidRequest = VoidRequest
  { voidIncarnationId :: Text,
    voidMemoryId :: Text,
    voidExpectedRevision :: Int
  }
  deriving stock (Eq, Show)

instance ToJSON VoidRequest where
  toJSON request =
    object
      [ "incarnationId" .= voidIncarnationId request,
        "id" .= voidMemoryId request,
        "expectedRevision" .= voidExpectedRevision request
      ]

instance FromJSON VoidRequest where
  parseJSON = withObject "VoidRequest" $ \fields ->
    VoidRequest
      <$> fields .: "incarnationId"
      <*> fields .: "id"
      <*> fields .: "expectedRevision"

data MemorySnippet = MemorySnippet
  { memorySnippetRef :: MemoryRef,
    memorySnippetOwner :: Text,
    memorySnippetVisibility :: MemoryVisibility,
    memorySnippetKind :: Text,
    memorySnippetText :: Text,
    memorySnippetKeywords :: [Text],
    memorySnippetSourceRefs :: [Text],
    memorySnippetMatches :: [Text]
  }
  deriving stock (Eq, Show)

instance ToJSON MemorySnippet where
  toJSON snippet =
    object
      [ "ref" .= memorySnippetRef snippet,
        "owner" .= memorySnippetOwner snippet,
        "visibility" .= memorySnippetVisibility snippet,
        "kind" .= memorySnippetKind snippet,
        "snippet" .= memorySnippetText snippet,
        "keywords" .= memorySnippetKeywords snippet,
        "sourceRefs" .= memorySnippetSourceRefs snippet,
        "matches" .= memorySnippetMatches snippet
      ]

instance FromJSON MemorySnippet where
  parseJSON = withObject "MemorySnippet" $ \fields ->
    MemorySnippet
      <$> fields .: "ref"
      <*> fields .: "owner"
      <*> fields .: "visibility"
      <*> fields .: "kind"
      <*> fields .: "snippet"
      <*> fields .:? "keywords" .!= []
      <*> fields .:? "sourceRefs" .!= []
      <*> fields .:? "matches" .!= []

data MemoryReadReceipt = MemoryReadReceipt
  { memoryReadReceiptId :: Text,
    memoryReadReceiptIncarnationId :: Text,
    memoryReadReceiptAction :: Text,
    memoryReadReceiptQuery :: Maybe Text,
    memoryReadReceiptSpaces :: [MemorySpace],
    memoryReadReceiptRecords :: [MemoryRef],
    memoryReadReceiptCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON MemoryReadReceipt where
  toJSON receipt =
    object
      [ "id" .= memoryReadReceiptId receipt,
        "incarnationId" .= memoryReadReceiptIncarnationId receipt,
        "action" .= memoryReadReceiptAction receipt,
        "query" .= memoryReadReceiptQuery receipt,
        "spaces" .= memoryReadReceiptSpaces receipt,
        "records" .= memoryReadReceiptRecords receipt,
        "created" .= memoryReadReceiptCreated receipt
      ]

instance FromJSON MemoryReadReceipt where
  parseJSON = withObject "MemoryReadReceipt" $ \fields ->
    MemoryReadReceipt
      <$> fields .: "id"
      <*> fields .: "incarnationId"
      <*> fields .: "action"
      <*> fields .:? "query"
      <*> fields .:? "spaces" .!= []
      <*> fields .:? "records" .!= []
      <*> fields .: "created"

data MemoryGrepResult = MemoryGrepResult
  { memoryGrepSnippets :: [MemorySnippet],
    memoryGrepReceipt :: MemoryReadReceipt
  }
  deriving stock (Eq, Show)

instance ToJSON MemoryGrepResult where
  toJSON result =
    object
      [ "snippets" .= memoryGrepSnippets result,
        "receipt" .= memoryGrepReceipt result
      ]

instance FromJSON MemoryGrepResult where
  parseJSON = withObject "MemoryGrepResult" $ \fields ->
    MemoryGrepResult <$> fields .:? "snippets" .!= [] <*> fields .: "receipt"

data MemoryReadResult = MemoryReadResult
  { memoryReadRecord :: LongMemory,
    memoryReadReceipt :: MemoryReadReceipt
  }
  deriving stock (Eq, Show)

instance ToJSON MemoryReadResult where
  toJSON result =
    object
      [ "record" .= memoryReadRecord result,
        "receipt" .= memoryReadReceipt result
      ]

instance FromJSON MemoryReadResult where
  parseJSON = withObject "MemoryReadResult" $ \fields ->
    MemoryReadResult <$> fields .: "record" <*> fields .: "receipt"

data LongTermStore = LongTermStore
  { longTermRemember :: RememberRequest -> IO (Either Text LongMemory),
    longTermGrep :: GrepRequest -> IO (Either Text MemoryGrepResult),
    longTermRead :: ReadRequest -> IO (Either Text MemoryReadResult),
    longTermVoid :: VoidRequest -> IO (Either Text LongMemory),
    longTermSpace :: Text -> MemoryVisibility -> IO (Either Text MemorySpace),
    longTermCatalog :: Text -> Int -> IO [MemoryCatalogItem],
    longTermReceipts :: Text -> IO [MemoryReadReceipt]
  }

data LongTermState = LongTermState
  { stateSpaces :: Map Text MemorySpace,
    stateMemories :: Map Text (Map Int LongMemory),
    stateReceipts :: Map Text MemoryReadReceipt
  }

data StoredState = StoredState
  { storedVersion :: Int,
    storedSpaces :: [MemorySpace],
    storedMemories :: [LongMemory],
    storedReceipts :: [MemoryReadReceipt]
  }

instance ToJSON StoredState where
  toJSON state =
    object
      [ "version" .= storedVersion state,
        "spaces" .= storedSpaces state,
        "memories" .= storedMemories state,
        "receipts" .= storedReceipts state
      ]

instance FromJSON StoredState where
  parseJSON = withObject "LongTermState" $ \fields ->
    StoredState
      <$> fields .: "version"
      <*> fields .:? "spaces" .!= []
      <*> fields .:? "memories" .!= []
      <*> fields .:? "receipts" .!= []

storeVersion :: Int
storeVersion = 1

defaultGrepLimit :: Int
defaultGrepLimit = 8

maximumGrepLimit :: Int
maximumGrepLimit = 100

maximumCatalogLimit :: Int
maximumCatalogLimit = 100

catalogPreviewLength :: Int
catalogPreviewLength = 640

emptyState :: LongTermState
emptyState = LongTermState Map.empty Map.empty Map.empty

newLongTermStore :: FilePath -> IO (Either Text LongTermStore)
newLongTermStore dir =
  prepareDirectory dir
    >>= either
      (pure . Left)
      (const (loadState path >>= traverse (newMVar >=> pure . makeStore (persistState path))))
  where
    path = dir </> "long-term.json"

newMemoryLongTermStore :: IO LongTermStore
newMemoryLongTermStore =
  newMVar emptyState <&> makeStore (const (pure (Right ())))

makeStore :: (LongTermState -> IO (Either Text ())) -> MVar LongTermState -> LongTermStore
makeStore persist lock =
  LongTermStore
    { longTermRemember = remember persist lock,
      longTermGrep = grep persist lock,
      longTermRead = readOne persist lock,
      longTermVoid = void persist lock,
      longTermSpace = inspectSpace lock,
      longTermCatalog = catalog lock,
      longTermReceipts = receipts lock
    }

prepareDirectory :: FilePath -> IO (Either Text ())
prepareDirectory dir =
  (try (createDirectoryIfMissing True dir) :: IO (Either IOException ()))
    <&> either
      (Left . ("cannot prepare long-term memory store: " <>) . Text.pack . displayException)
      Right

loadState :: FilePath -> IO (Either Text LongTermState)
loadState path =
  (try (eitherDecodeFileStrict path) :: IO (Either IOException (Either String StoredState)))
    <&> \case
      Left failure
        | isDoesNotExistError failure -> Right emptyState
        | otherwise -> Left ("cannot read long-term memory store: " <> Text.pack (displayException failure))
      Right (Left failure) -> Left ("invalid long-term memory store: " <> Text.pack failure)
      Right (Right stored) -> stateFromStored stored

persistState :: FilePath -> LongTermState -> IO (Either Text ())
persistState path state =
  (try (atomicEncodeFile path (stateToStored state)) :: IO (Either IOException ()))
    <&> either
      (Left . ("cannot persist long-term memory store: " <>) . Text.pack . displayException)
      Right

stateToStored :: LongTermState -> StoredState
stateToStored state =
  StoredState
    storeVersion
    (sortOn memorySpaceId (Map.elems (stateSpaces state)))
    ( sortOn ((,) <$> longMemoryId <*> longMemoryRevision)
        (concatMap Map.elems (Map.elems (stateMemories state)))
    )
    (sortOn ((,) <$> memoryReadReceiptCreated <*> memoryReadReceiptId) (Map.elems (stateReceipts state)))

stateFromStored :: StoredState -> Either Text LongTermState
stateFromStored stored
  | storedVersion stored /= storeVersion =
      Left ("unsupported long-term memory store version: " <> Text.pack (show (storedVersion stored)))
  | otherwise =
      foldM insertSpace Map.empty (storedSpaces stored) >>= \spaces ->
        foldM (insertMemory spaces) Map.empty (storedMemories stored) >>= \memories ->
          validateHistories memories
            *> foldM (insertReceipt memories) Map.empty (storedReceipts stored)
            <&> LongTermState spaces memories

insertSpace :: Map Text MemorySpace -> MemorySpace -> Either Text (Map Text MemorySpace)
insertSpace spaces space =
  validateSpace space
    *> case Map.lookup key spaces of
      Nothing -> Right (Map.insert key space spaces)
      Just _ -> Left ("duplicate memory space: " <> memorySpaceId space)
  where
    key = spaceKey (memorySpaceOwner space) (memorySpaceVisibility space)

validateSpace :: MemorySpace -> Either Text ()
validateSpace space
  | Text.null (Text.strip (memorySpaceId space)) = Left "memory space id must not be empty"
  | Text.null (Text.strip (memorySpaceOwner space)) = Left "memory space owner must not be empty"
  | memorySpaceRevision space < 0 = Left ("invalid memory space revision: " <> memorySpaceId space)
  | otherwise = Right ()

insertMemory ::
  Map Text MemorySpace ->
  Map Text (Map Int LongMemory) ->
  LongMemory ->
  Either Text (Map Text (Map Int LongMemory))
insertMemory spaces memories memory =
  validateMemory spaces memory
    *> case Map.lookup (longMemoryRevision memory) history of
      Nothing ->
        Right
          ( Map.insert
              (longMemoryId memory)
              (Map.insert (longMemoryRevision memory) memory history)
              memories
          )
      Just _ ->
        Left
          ( "duplicate long-term memory revision: "
              <> longMemoryId memory
              <> "@"
              <> Text.pack (show (longMemoryRevision memory))
          )
  where
    history = Map.findWithDefault Map.empty (longMemoryId memory) memories

validateMemory :: Map Text MemorySpace -> LongMemory -> Either Text ()
validateMemory spaces memory
  | Text.null (Text.strip (longMemoryId memory)) = Left "long-term memory id must not be empty"
  | Text.null (Text.strip (longMemoryOwner memory)) = Left ("long-term memory owner must not be empty: " <> longMemoryId memory)
  | Text.null (Text.strip (longMemoryKind memory)) = Left ("long-term memory kind must not be empty: " <> longMemoryId memory)
  | Text.null (Text.strip (longMemoryContent memory)) = Left ("long-term memory content must not be empty: " <> longMemoryId memory)
  | longMemoryRevision memory < 1 = Left ("invalid long-term memory revision: " <> longMemoryId memory)
  | longMemoryCreated memory < 0 || longMemoryRevised memory < longMemoryCreated memory =
      Left ("invalid long-term memory timestamps: " <> longMemoryId memory)
  | Map.notMember key spaces = Left ("missing memory space for: " <> longMemoryId memory)
  | otherwise = Right ()
  where
    key = spaceKey (longMemoryOwner memory) (longMemoryVisibility memory)

validateHistories :: Map Text (Map Int LongMemory) -> Either Text ()
validateHistories = traverse_ validateHistory

insertReceipt ::
  Map Text (Map Int LongMemory) ->
  Map Text MemoryReadReceipt ->
  MemoryReadReceipt ->
  Either Text (Map Text MemoryReadReceipt)
insertReceipt memories stored receipt =
  validateReceipt memories receipt
    *> case Map.lookup identifier stored of
      Nothing -> Right (Map.insert identifier receipt stored)
      Just _ -> Left ("duplicate long-term memory receipt: " <> identifier)
  where
    identifier = memoryReadReceiptId receipt

validateReceipt :: Map Text (Map Int LongMemory) -> MemoryReadReceipt -> Either Text ()
validateReceipt memories receipt =
  sequence_
    [ nonEmpty "memory receipt id" (memoryReadReceiptId receipt),
      nonEmpty "memory receipt incarnation id" (memoryReadReceiptIncarnationId receipt),
      nonEmpty "memory receipt action" (memoryReadReceiptAction receipt),
      bool (Left ("invalid memory receipt timestamp: " <> memoryReadReceiptId receipt)) (Right ()) (memoryReadReceiptCreated receipt >= 0),
      traverse_ validateSpace (memoryReadReceiptSpaces receipt),
      traverse_ knownRef (memoryReadReceiptRecords receipt)
    ]
  where
    knownRef ref =
      bool
        (Left ("unknown memory receipt record: " <> memoryRefId ref <> "@" <> Text.pack (show (memoryRefRevision ref))))
        (Right ())
        (maybe False (Map.member (memoryRefRevision ref)) (Map.lookup (memoryRefId ref) memories))

validateHistory :: Map Int LongMemory -> Either Text ()
validateHistory history =
  case Map.elems history of
    [] -> Left "empty long-term memory history"
    first : rest
      | fmap longMemoryRevision (first : rest) /= [1 .. Map.size history] ->
          Left ("non-contiguous long-term memory history: " <> longMemoryId first)
      | any (not . sameIdentity first) rest ->
          Left ("inconsistent long-term memory history: " <> longMemoryId first)
      | not (voidIsFinal (fmap longMemoryStatus (first : rest))) ->
          Left ("long-term memory revived after void: " <> longMemoryId first)
      | otherwise -> Right ()

sameIdentity :: LongMemory -> LongMemory -> Bool
sameIdentity first memory =
  longMemoryId memory == longMemoryId first
    && longMemoryOwner memory == longMemoryOwner first
    && longMemoryVisibility memory == longMemoryVisibility first
    && longMemoryContent memory == longMemoryContent first
    && longMemoryCreated memory == longMemoryCreated first

voidIsFinal :: [MemoryStatus] -> Bool
voidIsFinal statuses =
  case dropWhile (/= MemoryVoid) statuses of
    [] -> True
    voided -> all (== MemoryVoid) voided

remember ::
  (LongTermState -> IO (Either Text ())) ->
  MVar LongTermState ->
  RememberRequest ->
  IO (Either Text LongMemory)
remember persist lock request =
  either
    (pure . Left)
    (\clean -> timestamp >>= \now -> mutate persist lock (rememberAt now clean))
    (cleanRemember request)

rememberAt :: Integer -> RememberRequest -> LongTermState -> Either Text (LongTermState, LongMemory)
rememberAt now request state =
  maybe (createMemory now request state) (reviseMemory now request state) (duplicateOf request state)

createMemory :: Integer -> RememberRequest -> LongTermState -> Either Text (LongTermState, LongMemory)
createMemory now request state =
  let memory =
        LongMemory
          { longMemoryId = memoryIdFor request,
            longMemoryOwner = rememberOwner request,
            longMemoryVisibility = rememberVisibility request,
            longMemoryKind = rememberKind request,
            longMemoryContent = rememberContent request,
            longMemoryKeywords = rememberKeywords request,
            longMemorySourceRefs = rememberSourceRefs request,
            longMemoryRevision = 1,
            longMemoryCreated = now,
            longMemoryRevised = now,
            longMemoryStatus = MemoryActive
          }
   in Right (commitRevision memory state, memory)

reviseMemory ::
  Integer ->
  RememberRequest ->
  LongTermState ->
  LongMemory ->
  Either Text (LongTermState, LongMemory)
reviseMemory now request state current
  | longMemoryStatus current == MemoryVoid =
      Left ("long-term memory is void: " <> longMemoryId current)
  | unchanged = Right (state, current)
  | otherwise =
      let revised =
            current
              { longMemoryKind = rememberKind request,
                longMemoryKeywords = keywords,
                longMemorySourceRefs = sources,
                longMemoryRevision = longMemoryRevision current + 1,
                longMemoryRevised = now,
                longMemoryStatus = MemoryActive
              }
       in Right (commitRevision revised state, revised)
  where
    keywords = mergeTexts (longMemoryKeywords current) (rememberKeywords request)
    sources = mergeTexts (longMemorySourceRefs current) (rememberSourceRefs request)
    unchanged =
      longMemoryKind current == rememberKind request
        && longMemoryKeywords current == keywords
        && longMemorySourceRefs current == sources
        && longMemoryStatus current == MemoryActive

cleanRemember :: RememberRequest -> Either Text RememberRequest
cleanRemember request
  | Text.null owner = Left "memory owner must not be empty"
  | Text.null kind = Left "memory kind must not be empty"
  | Text.null content = Left "memory content must not be empty"
  | otherwise =
      Right
        request
          { rememberOwner = owner,
            rememberKind = kind,
            rememberContent = content,
            rememberKeywords = cleanTexts (rememberKeywords request),
            rememberSourceRefs = cleanTexts (rememberSourceRefs request)
          }
  where
    owner = Text.strip (rememberOwner request)
    kind = Text.strip (rememberKind request)
    content = Text.strip (rememberContent request)

duplicateOf :: RememberRequest -> LongTermState -> Maybe LongMemory
duplicateOf request =
  listToMaybe
    . filter ((== canonicalContent (rememberContent request)) . canonicalContent . longMemoryContent)
    . filter ((== scope) . memoryScope)
    . latestMemories
  where
    scope = (rememberOwner request, rememberVisibility request)

latestMemories :: LongTermState -> [LongMemory]
latestMemories = mapMaybe (fmap snd . Map.lookupMax) . Map.elems . stateMemories

memoryIdFor :: RememberRequest -> Text
memoryIdFor request =
  "memory-sha256-"
    <> digestText
      [ rememberOwner request,
        memoryVisibilityName (rememberVisibility request),
        canonicalContent (rememberContent request)
      ]

commitRevision :: LongMemory -> LongTermState -> LongTermState
commitRevision memory state =
  state
    { stateSpaces = Map.insert key revisedSpace (stateSpaces state),
      stateMemories =
        Map.insert
          (longMemoryId memory)
          (Map.insert (longMemoryRevision memory) memory history)
          (stateMemories state)
    }
  where
    key = spaceKey (longMemoryOwner memory) (longMemoryVisibility memory)
    space = spaceAt state (longMemoryOwner memory) (longMemoryVisibility memory)
    revisedSpace = space {memorySpaceRevision = memorySpaceRevision space + 1}
    history = Map.findWithDefault Map.empty (longMemoryId memory) (stateMemories state)

grep ::
  (LongTermState -> IO (Either Text ())) ->
  MVar LongTermState ->
  GrepRequest ->
  IO (Either Text MemoryGrepResult)
grep persist lock request =
  getPOSIXTime >>= \now ->
    modifyMVar lock $ \state ->
      persistReceipt persist state memoryGrepReceipt (grepAt now request state)

grepAt :: POSIXTime -> GrepRequest -> LongTermState -> Either Text MemoryGrepResult
grepAt now request state =
  cleanGrep request >>= \clean ->
    queryTerms (grepQuery clean) <&> \terms ->
      let ranked =
            take (grepLimit clean)
              . sortOn (Down . rankKey)
              . mapMaybe (matched terms)
              . filter (grepVisible clean)
              $ latestMemories state
          snippets = fmap (\(_, memory, matches) -> snippetFor memory matches) ranked
          refs = fmap (memoryRef . (\(_, memory, _) -> memory)) ranked
          receipt =
            makeReceipt
              now
              "grep"
              (grepIncarnationId clean)
              (Just (grepQuery clean))
              (grepSpaces clean state)
              refs
       in MemoryGrepResult snippets receipt

cleanGrep :: GrepRequest -> Either Text GrepRequest
cleanGrep request
  | Text.null incarnation = Left "grep incarnation id must not be empty"
  | Text.null query = Left "memory grep query must not be empty"
  | grepLimit request < 1 = Left "memory grep limit must be positive"
  | grepLimit request > maximumGrepLimit =
      Left ("memory grep limit exceeds " <> Text.pack (show maximumGrepLimit))
  | otherwise =
      Right request {grepIncarnationId = incarnation, grepQuery = query}
  where
    incarnation = Text.strip (grepIncarnationId request)
    query = Text.strip (grepQuery request)

grepVisible :: GrepRequest -> LongMemory -> Bool
grepVisible request memory =
  longMemoryStatus memory == MemoryActive
    && visibleTo (grepIncarnationId request) memory
    && maybe True (== longMemoryVisibility memory) (grepVisibility request)

visibleTo :: Text -> LongMemory -> Bool
visibleTo incarnation memory =
  longMemoryVisibility memory == MemoryShared
    || longMemoryOwner memory == incarnation

data QueryTerms = QueryTerms
  { queryAscii :: Set Text,
    queryUnicode :: [Text],
    queryWhole :: Text
  }

queryTerms :: Text -> Either Text QueryTerms
queryTerms query
  | Set.null ascii && null unicode = Left "memory grep query has no searchable terms"
  | otherwise = Right (QueryTerms ascii unicode (canonicalContent query))
  where
    ascii = Set.fromList (tokensBy asciiToken query)
    unicode = cleanTexts (tokensBy unicodeToken query)
    asciiToken char = Char.isAscii char && (Char.isAlphaNum char || char == '_')
    unicodeToken char = not (Char.isAscii char) && (Char.isLetter char || Char.isNumber char)

tokensBy :: (Char -> Bool) -> Text -> [Text]
tokensBy wanted =
  filter (not . Text.null)
    . fmap Text.toCaseFold
    . Text.split (not . wanted)

matched :: QueryTerms -> LongMemory -> Maybe (Int, LongMemory, [Text])
matched terms memory
  | score == 0 = Nothing
  | otherwise = Just (score, memory, matches)
  where
    content = longMemoryContent memory
    keywords = longMemoryKeywords memory
    haystack = Text.toCaseFold (content <> "\n" <> Text.unwords keywords)
    asciiHaystack = Set.fromList (tokensBy (\char -> Char.isAscii char && (Char.isAlphaNum char || char == '_')) haystack)
    asciiMatches = Set.toList (Set.intersection (queryAscii terms) asciiHaystack)
    unicodeMatches = filter (`Text.isInfixOf` haystack) (queryUnicode terms)
    matches = unicodeMatches <> asciiMatches
    keywordHaystack = Text.toCaseFold (Text.unwords keywords)
    keywordHits = length (filter (`Text.isInfixOf` keywordHaystack) matches)
    wholeHit =
      not (null matches)
        && not (Text.null (queryWhole terms))
        && queryWhole terms `Text.isInfixOf` haystack
    score =
      16 * fromEnum wholeHit
        + 8 * length unicodeMatches
        + 4 * length asciiMatches
        + 3 * keywordHits

rankKey :: (Int, LongMemory, [Text]) -> (Int, Integer, Int)
rankKey (score, memory, _) =
  (score, longMemoryRevised memory, longMemoryRevision memory)

snippetFor :: LongMemory -> [Text] -> MemorySnippet
snippetFor memory matches =
  MemorySnippet
    { memorySnippetRef = memoryRef memory,
      memorySnippetOwner = longMemoryOwner memory,
      memorySnippetVisibility = longMemoryVisibility memory,
      memorySnippetKind = longMemoryKind memory,
      memorySnippetText = snippetAround matches (longMemoryContent memory),
      memorySnippetKeywords = longMemoryKeywords memory,
      memorySnippetSourceRefs = longMemorySourceRefs memory,
      memorySnippetMatches = matches
    }

snippetAround :: [Text] -> Text -> Text
snippetAround matches content =
  prefix <> Text.take snippetLength (Text.drop start content) <> suffix
  where
    folded = Text.toCaseFold content
    position =
      mapMaybe
        (\needle -> nonEmptyPosition (Text.breakOn needle folded))
        matches
        & minimumMaybe
        & maybe 0 id
    start = max 0 (position - snippetLead)
    prefix = bool "" "…" (start > 0)
    suffix = bool "" "…" (start + snippetLength < Text.length content)

nonEmptyPosition :: (Text, Text) -> Maybe Int
nonEmptyPosition (before, after)
  | Text.null after = Nothing
  | otherwise = Just (Text.length before)

minimumMaybe :: Ord value => [value] -> Maybe value
minimumMaybe = \case
  [] -> Nothing
  values -> Just (minimum values)

snippetLength :: Int
snippetLength = 240

snippetLead :: Int
snippetLead = 60

readOne ::
  (LongTermState -> IO (Either Text ())) ->
  MVar LongTermState ->
  ReadRequest ->
  IO (Either Text MemoryReadResult)
readOne persist lock request =
  getPOSIXTime >>= \now ->
    modifyMVar lock $ \state ->
      persistReceipt persist state memoryReadReceipt (readAt now request state)

readAt :: POSIXTime -> ReadRequest -> LongTermState -> Either Text MemoryReadResult
readAt now request state =
  cleanRead request >>= \clean ->
    findRevision clean state >>= \memory ->
      visibleResult clean memory
  where
    visibleResult clean memory
      | not (visibleTo (readIncarnationId clean) memory) =
          Left ("long-term memory is not visible to incarnation: " <> readMemoryId clean)
      | otherwise =
          Right
            ( MemoryReadResult
                memory
                ( makeReceipt
                    now
                    "read"
                    (readIncarnationId clean)
                    Nothing
                    [spaceAt state (longMemoryOwner memory) (longMemoryVisibility memory)]
                    [memoryRef memory]
                )
            )

cleanRead :: ReadRequest -> Either Text ReadRequest
cleanRead request
  | Text.null incarnation = Left "read incarnation id must not be empty"
  | Text.null identifier = Left "memory id must not be empty"
  | maybe False (< 1) (readMemoryRevision request) = Left "memory revision must be positive"
  | otherwise =
      Right request {readIncarnationId = incarnation, readMemoryId = identifier}
  where
    incarnation = Text.strip (readIncarnationId request)
    identifier = Text.strip (readMemoryId request)

findRevision :: ReadRequest -> LongTermState -> Either Text LongMemory
findRevision request state =
  maybe
    (Left ("unknown long-term memory: " <> readMemoryId request))
    select
    (Map.lookup (readMemoryId request) (stateMemories state))
  where
    select history =
      case readMemoryRevision request of
        Nothing ->
          maybe
            (Left ("empty long-term memory history: " <> readMemoryId request))
            (Right . snd)
            (Map.lookupMax history)
        Just revision ->
          maybe
            (Left ("unknown long-term memory revision: " <> readMemoryId request <> "@" <> Text.pack (show revision)))
            Right
            (Map.lookup revision history)

void ::
  (LongTermState -> IO (Either Text ())) ->
  MVar LongTermState ->
  VoidRequest ->
  IO (Either Text LongMemory)
void persist lock request =
  either
    (pure . Left)
    (\clean -> timestamp >>= \now -> mutate persist lock (voidAt now clean))
    (cleanVoid request)

voidAt :: Integer -> VoidRequest -> LongTermState -> Either Text (LongTermState, LongMemory)
voidAt now request state =
  latestById (voidMemoryId request) state >>= \current ->
    owned current >>= \memory ->
      Right (commitRevision memory state, memory)
  where
    owned current
      | longMemoryOwner current /= voidIncarnationId request =
          Left ("only the owning incarnation may void memory: " <> voidMemoryId request)
      | otherwise = compareRevision current
    compareRevision current
      | longMemoryRevision current /= voidExpectedRevision request =
          Left
            ( "long-term memory revision conflict: expected "
                <> Text.pack (show (voidExpectedRevision request))
                <> ", current "
                <> Text.pack (show (longMemoryRevision current))
            )
      | longMemoryStatus current == MemoryVoid =
          Left ("long-term memory is already void: " <> voidMemoryId request)
      | otherwise =
          Right
            current
              { longMemoryRevision = longMemoryRevision current + 1,
                longMemoryRevised = now,
                longMemoryStatus = MemoryVoid
              }

cleanVoid :: VoidRequest -> Either Text VoidRequest
cleanVoid request
  | Text.null incarnation = Left "void incarnation id must not be empty"
  | Text.null identifier = Left "memory id must not be empty"
  | voidExpectedRevision request < 1 = Left "expected memory revision must be positive"
  | otherwise =
      Right request {voidIncarnationId = incarnation, voidMemoryId = identifier}
  where
    incarnation = Text.strip (voidIncarnationId request)
    identifier = Text.strip (voidMemoryId request)

latestById :: Text -> LongTermState -> Either Text LongMemory
latestById identifier state =
  maybe
    (Left ("unknown long-term memory: " <> identifier))
    ( maybe
        (Left ("empty long-term memory history: " <> identifier))
        (Right . snd)
        . Map.lookupMax
    )
    (Map.lookup identifier (stateMemories state))

inspectSpace :: MVar LongTermState -> Text -> MemoryVisibility -> IO (Either Text MemorySpace)
inspectSpace lock rawOwner visibility
  | Text.null owner = pure (Left "memory space owner must not be empty")
  | otherwise = readMVar lock <&> Right . (\state -> spaceAt state owner visibility)
  where
    owner = Text.strip rawOwner

catalog :: MVar LongTermState -> Text -> Int -> IO [MemoryCatalogItem]
catalog lock rawIncarnation requested
  | Text.null incarnation || requested <= 0 = pure []
  | otherwise =
      readMVar lock
        <&> take (min maximumCatalogLimit requested)
          . fmap catalogItem
          . sortOn (Down . catalogOrder)
          . filter ((&&) <$> ((== MemoryActive) . longMemoryStatus) <*> visibleTo incarnation)
          . latestMemories
  where
    incarnation = Text.strip rawIncarnation

catalogOrder :: LongMemory -> (Integer, Int, Text)
catalogOrder memory =
  (longMemoryRevised memory, longMemoryRevision memory, longMemoryId memory)

catalogItem :: LongMemory -> MemoryCatalogItem
catalogItem memory =
  MemoryCatalogItem
    { memoryCatalogId = longMemoryId memory,
      memoryCatalogRevision = longMemoryRevision memory,
      memoryCatalogOwner = longMemoryOwner memory,
      memoryCatalogKind = longMemoryKind memory,
      memoryCatalogVisibility = longMemoryVisibility memory,
      memoryCatalogKeywords = longMemoryKeywords memory,
      memoryCatalogPreview =
        Text.take catalogPreviewLength (Text.unwords (Text.words (longMemoryContent memory))),
      memoryCatalogRevised = longMemoryRevised memory
    }

receipts :: MVar LongTermState -> Text -> IO [MemoryReadReceipt]
receipts lock rawIncarnation
  | Text.null incarnation = pure []
  | otherwise =
      readMVar lock
        <&> sortOn (Down . receiptOrder)
          . filter ((== incarnation) . memoryReadReceiptIncarnationId)
          . Map.elems
          . stateReceipts
  where
    incarnation = Text.strip rawIncarnation

receiptOrder :: MemoryReadReceipt -> (Integer, Text)
receiptOrder receipt =
  (memoryReadReceiptCreated receipt, memoryReadReceiptId receipt)

persistReceipt ::
  (LongTermState -> IO (Either Text ())) ->
  LongTermState ->
  (value -> MemoryReadReceipt) ->
  Either Text value ->
  IO (LongTermState, Either Text value)
persistReceipt persist state receiptOf =
  either
    (pure . (state,) . Left)
    ( \value ->
        let receipt = receiptOf value
            updated =
              state
                { stateReceipts =
                    Map.insert
                      (memoryReadReceiptId receipt)
                      receipt
                      (stateReceipts state)
                }
         in persist updated
              <&> either
                ((state,) . Left)
                (const (updated, Right value))
    )

mutate ::
  (LongTermState -> IO (Either Text ())) ->
  MVar LongTermState ->
  (LongTermState -> Either Text (LongTermState, value)) ->
  IO (Either Text value)
mutate persist lock transition =
  modifyMVar lock $ \state ->
    either
      (pure . (state,) . Left)
      ( \(updated, value) ->
          persist updated
            <&> either
              ((state,) . Left)
              (const (updated, Right value))
      )
      (transition state)

spaceAt :: LongTermState -> Text -> MemoryVisibility -> MemorySpace
spaceAt state owner visibility =
  Map.findWithDefault
    (MemorySpace (spaceIdFor owner visibility) owner visibility 0)
    (spaceKey owner visibility)
    (stateSpaces state)

spaceKey :: Text -> MemoryVisibility -> Text
spaceKey owner visibility =
  owner <> "\NUL" <> memoryVisibilityName visibility

spaceIdFor :: Text -> MemoryVisibility -> Text
spaceIdFor owner visibility =
  "memory-space-sha256-"
    <> digestText [owner, memoryVisibilityName visibility]

memoryScope :: LongMemory -> (Text, MemoryVisibility)
memoryScope = (,) <$> longMemoryOwner <*> longMemoryVisibility

memoryRef :: LongMemory -> MemoryRef
memoryRef = MemoryRef <$> longMemoryId <*> longMemoryRevision

grepSpaces :: GrepRequest -> LongTermState -> [MemorySpace]
grepSpaces request state =
  sortOn memorySpaceId
    . filter allowed
    . Map.elems
    $ withPrivate
  where
    private = spaceAt state (grepIncarnationId request) MemoryPrivate
    withPrivate =
      Map.insert
        (spaceKey (memorySpaceOwner private) MemoryPrivate)
        private
        (stateSpaces state)
    allowed space =
      case grepVisibility request of
        Just MemoryPrivate ->
          memorySpaceVisibility space == MemoryPrivate
            && memorySpaceOwner space == grepIncarnationId request
        Just MemoryShared ->
          memorySpaceVisibility space == MemoryShared
        Nothing ->
          memorySpaceVisibility space == MemoryShared
            || ( memorySpaceVisibility space == MemoryPrivate
                   && memorySpaceOwner space == grepIncarnationId request
               )

makeReceipt ::
  POSIXTime ->
  Text ->
  Text ->
  Maybe Text ->
  [MemorySpace] ->
  [MemoryRef] ->
  MemoryReadReceipt
makeReceipt now action incarnation query spaces refs =
  MemoryReadReceipt
    { memoryReadReceiptId =
        "memory-receipt-sha256-"
          <> digestText
            [ action,
              incarnation,
              maybe "" id query,
              Text.pack (show now),
              Text.intercalate "\US" (fmap renderRef refs)
            ],
      memoryReadReceiptIncarnationId = incarnation,
      memoryReadReceiptAction = action,
      memoryReadReceiptQuery = query,
      memoryReadReceiptSpaces = spaces,
      memoryReadReceiptRecords = refs,
      memoryReadReceiptCreated = round now
    }
  where
    renderRef ref =
      memoryRefId ref <> "@" <> Text.pack (show (memoryRefRevision ref))

digestText :: [Text] -> Text
digestText = sha256 . TextEncoding.encodeUtf8 . Text.intercalate "\NUL"

canonicalContent :: Text -> Text
canonicalContent = Text.toCaseFold . Text.unwords . Text.words

cleanTexts :: [Text] -> [Text]
cleanTexts = uniqueTexts . filter (not . Text.null) . fmap Text.strip

mergeTexts :: [Text] -> [Text] -> [Text]
mergeTexts first = uniqueTexts . (first <>)

uniqueTexts :: [Text] -> [Text]
uniqueTexts =
  reverse
    . snd
    . foldl'
      insert
      (Set.empty, [])
  where
    insert current@(seen, _) value
      | Set.member value seen = current
    insert (seen, values) value = (Set.insert value seen, value : values)

nonEmpty :: Text -> Text -> Either Text ()
nonEmpty label =
  bool (Right ()) (Left (label <> " must not be empty"))
    . Text.null
    . Text.strip

timestamp :: IO Integer
timestamp = round <$> getPOSIXTime
