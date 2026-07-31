module Yuki.N.Memory.Archive
  ( ArchiveEntry (..),
    ArchiveEntryCatalog (..),
    ArchiveEntryDraft (..),
    ArchiveEntrySlice (..),
    ArchiveGrepRequest (..),
    ArchiveGrepResult (..),
    ArchiveHit (..),
    ArchiveKind (..),
    ArchiveReadRequest (..),
    ArchiveReadResult (..),
    ArchiveRun (..),
    ArchiveRunDraft (..),
    ArchiveTaskSummary (..),
    TaskArchiveStore (..),
    archiveKindName,
    newMemoryTaskArchiveStore,
    newTaskArchiveStore,
  )
where

import Control.Concurrent.MVar
import Control.Exception (IOException, displayException, try)
import Control.Applicative ((<|>))
import Control.Monad ((>=>))
import Data.Aeson
import Data.Bool (bool)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (isAlphaNum)
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.List (findIndex, sortOn)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Ord (Down (..))
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import Yuki.N.AtomicFile (atomicEncodeFile)
import Yuki.N.Blob

data ArchiveKind
  = ArchiveInstruction
  | ArchiveUser
  | ArchiveReasoning
  | ArchiveAssistant
  | ArchiveToolCall
  | ArchiveToolResult
  | ArchiveWakePacket
  deriving stock (Eq, Ord, Show)

archiveKindName :: ArchiveKind -> Text
archiveKindName = \case
  ArchiveInstruction -> "instruction"
  ArchiveUser -> "user"
  ArchiveReasoning -> "reasoning"
  ArchiveAssistant -> "assistant"
  ArchiveToolCall -> "tool-call"
  ArchiveToolResult -> "tool-result"
  ArchiveWakePacket -> "wake-packet"

instance ToJSON ArchiveKind where
  toJSON = String . archiveKindName

instance FromJSON ArchiveKind where
  parseJSON = withText "ArchiveKind" $ \case
    "instruction" -> pure ArchiveInstruction
    "user" -> pure ArchiveUser
    "reasoning" -> pure ArchiveReasoning
    "assistant" -> pure ArchiveAssistant
    "tool-call" -> pure ArchiveToolCall
    "tool-result" -> pure ArchiveToolResult
    "wake-packet" -> pure ArchiveWakePacket
    other -> fail ("unknown task archive kind: " <> Text.unpack other)

data ArchiveEntryDraft = ArchiveEntryDraft
  { archiveEntryDraftSourceId :: Text,
    archiveEntryDraftKind :: ArchiveKind,
    archiveEntryDraftContent :: Text,
    archiveEntryDraftParentId :: Maybe Text,
    archiveEntryDraftCallId :: Maybe Text,
    archiveEntryDraftToolName :: Maybe Text
  }
  deriving stock (Eq, Show)

data ArchiveRunDraft = ArchiveRunDraft
  { archiveRunDraftIncarnationId :: Text,
    archiveRunDraftTaskId :: Text,
    archiveRunDraftRunId :: Text,
    archiveRunDraftIntentId :: Maybe Text,
    archiveRunDraftStatus :: Text,
    archiveRunDraftFailure :: Maybe Text,
    archiveRunDraftEntries :: [ArchiveEntryDraft]
  }
  deriving stock (Eq, Show)

data ArchiveEntry = ArchiveEntry
  { archiveEntryId :: Text,
    archiveEntryIncarnationId :: Text,
    archiveEntryTaskId :: Text,
    archiveEntryRunId :: Text,
    archiveEntrySeq :: Int,
    archiveEntryRunSeq :: Int,
    archiveEntrySourceId :: Text,
    archiveEntryKind :: ArchiveKind,
    archiveEntryContentRef :: Text,
    archiveEntryContentHash :: Text,
    archiveEntryContentChars :: Int,
    archiveEntryPreview :: Text,
    archiveEntryParentId :: Maybe Text,
    archiveEntryCallId :: Maybe Text,
    archiveEntryToolName :: Maybe Text,
    archiveEntryCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON ArchiveEntry where
  toJSON entry =
    object
      [ "entryId" .= archiveEntryId entry,
        "incarnationId" .= archiveEntryIncarnationId entry,
        "taskId" .= archiveEntryTaskId entry,
        "runId" .= archiveEntryRunId entry,
        "seq" .= archiveEntrySeq entry,
        "runSeq" .= archiveEntryRunSeq entry,
        "sourceId" .= archiveEntrySourceId entry,
        "kind" .= archiveEntryKind entry,
        "contentRef" .= archiveEntryContentRef entry,
        "contentHash" .= archiveEntryContentHash entry,
        "contentChars" .= archiveEntryContentChars entry,
        "preview" .= archiveEntryPreview entry,
        "parentId" .= archiveEntryParentId entry,
        "callId" .= archiveEntryCallId entry,
        "toolName" .= archiveEntryToolName entry,
        "created" .= archiveEntryCreated entry
      ]

instance FromJSON ArchiveEntry where
  parseJSON = withObject "ArchiveEntry" $ \fields ->
    ArchiveEntry
      <$> fields .: "entryId"
      <*> fields .: "incarnationId"
      <*> fields .: "taskId"
      <*> fields .: "runId"
      <*> fields .: "seq"
      <*> fields .: "runSeq"
      <*> fields .: "sourceId"
      <*> fields .: "kind"
      <*> fields .: "contentRef"
      <*> fields .: "contentHash"
      <*> fields .: "contentChars"
      <*> fields .:? "preview" .!= ""
      <*> fields .:? "parentId"
      <*> fields .:? "callId"
      <*> fields .:? "toolName"
      <*> fields .: "created"

data ArchiveRun = ArchiveRun
  { archiveRunId :: Text,
    archiveRunIncarnationId :: Text,
    archiveRunTaskId :: Text,
    archiveRunSourceRunId :: Text,
    archiveRunIntentId :: Maybe Text,
    archiveRunStatus :: Text,
    archiveRunFailure :: Maybe Text,
    archiveRunEntryIds :: [Text],
    archiveRunCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON ArchiveRun where
  toJSON run =
    object
      [ "id" .= archiveRunId run,
        "incarnationId" .= archiveRunIncarnationId run,
        "taskId" .= archiveRunTaskId run,
        "runId" .= archiveRunSourceRunId run,
        "intentId" .= archiveRunIntentId run,
        "status" .= archiveRunStatus run,
        "failure" .= archiveRunFailure run,
        "entryIds" .= archiveRunEntryIds run,
        "created" .= archiveRunCreated run
      ]

instance FromJSON ArchiveRun where
  parseJSON = withObject "ArchiveRun" $ \fields ->
    ArchiveRun
      <$> fields .: "id"
      <*> fields .: "incarnationId"
      <*> fields .: "taskId"
      <*> fields .: "runId"
      <*> fields .:? "intentId"
      <*> fields .: "status"
      <*> fields .:? "failure"
      <*> fields .:? "entryIds" .!= []
      <*> fields .: "created"

data ArchiveTaskSummary = ArchiveTaskSummary
  { archiveTaskIncarnationId :: Text,
    archiveTaskId :: Text,
    archiveTaskRunCount :: Int,
    archiveTaskEntryCount :: Int,
    archiveTaskCreated :: Integer,
    archiveTaskUpdated :: Integer,
    archiveTaskPreview :: Text
  }
  deriving stock (Eq, Show)

instance ToJSON ArchiveTaskSummary where
  toJSON summary =
    object
      [ "incarnationId" .= archiveTaskIncarnationId summary,
        "taskId" .= archiveTaskId summary,
        "runCount" .= archiveTaskRunCount summary,
        "entryCount" .= archiveTaskEntryCount summary,
        "created" .= archiveTaskCreated summary,
        "updated" .= archiveTaskUpdated summary,
        "preview" .= archiveTaskPreview summary
      ]

data ArchiveEntryCatalog = ArchiveEntryCatalog
  { archiveCatalogEntryId :: Text,
    archiveCatalogTaskId :: Text,
    archiveCatalogRunId :: Text,
    archiveCatalogSeq :: Int,
    archiveCatalogKind :: ArchiveKind,
    archiveCatalogPreview :: Text,
    archiveCatalogCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON ArchiveEntryCatalog where
  toJSON item =
    object
      [ "entryId" .= archiveCatalogEntryId item,
        "taskId" .= archiveCatalogTaskId item,
        "runId" .= archiveCatalogRunId item,
        "seq" .= archiveCatalogSeq item,
        "kind" .= archiveCatalogKind item,
        "preview" .= archiveCatalogPreview item,
        "created" .= archiveCatalogCreated item
      ]

data ArchiveGrepRequest = ArchiveGrepRequest
  { archiveGrepIncarnationId :: Text,
    archiveGrepQuery :: Text,
    archiveGrepTaskId :: Maybe Text,
    archiveGrepKinds :: [ArchiveKind],
    archiveGrepCaseSensitive :: Bool,
    archiveGrepLimit :: Int,
    archiveGrepOffset :: Int,
    archiveGrepIncludeProcess :: Bool
  }
  deriving stock (Eq, Show)

instance ToJSON ArchiveGrepRequest where
  toJSON request =
    object
      [ "incarnationId" .= archiveGrepIncarnationId request,
        "query" .= archiveGrepQuery request,
        "taskId" .= archiveGrepTaskId request,
        "kinds" .= archiveGrepKinds request,
        "caseSensitive" .= archiveGrepCaseSensitive request,
        "limit" .= archiveGrepLimit request,
        "offset" .= archiveGrepOffset request,
        "includeProcess" .= archiveGrepIncludeProcess request
      ]

instance FromJSON ArchiveGrepRequest where
  parseJSON = withObject "ArchiveGrepRequest" $ \fields ->
    ArchiveGrepRequest
      <$> fields .: "incarnationId"
      <*> fields .: "query"
      <*> fields .:? "taskId"
      <*> fields .:? "kinds" .!= []
      <*> fields .:? "caseSensitive" .!= False
      <*> fields .:? "limit" .!= defaultGrepLimit
      <*> fields .:? "offset" .!= 0
      <*> fields .:? "includeProcess" .!= False

data ArchiveHit = ArchiveHit
  { archiveHitEntryId :: Text,
    archiveHitTaskId :: Text,
    archiveHitRunId :: Text,
    archiveHitSeq :: Int,
    archiveHitKind :: ArchiveKind,
    archiveHitSourceId :: Text,
    archiveHitToolName :: Maybe Text,
    archiveHitCallId :: Maybe Text,
    archiveHitEvidenceClass :: Text,
    archiveHitSourceCompleteness :: Text,
    archiveHitArtifactIds :: [Text],
    archiveHitLineNumber :: Int,
    archiveHitMatchOffset :: Int,
    archiveHitEntryMatchIndex :: Int,
    archiveHitEntryMatchCount :: Int,
    archiveHitExcerpt :: Text,
    archiveHitCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON ArchiveHit where
  toJSON hit =
    object
      [ "entryId" .= archiveHitEntryId hit,
        "taskId" .= archiveHitTaskId hit,
        "runId" .= archiveHitRunId hit,
        "seq" .= archiveHitSeq hit,
        "kind" .= archiveHitKind hit,
        "sourceId" .= archiveHitSourceId hit,
        "toolName" .= archiveHitToolName hit,
        "callId" .= archiveHitCallId hit,
        "evidenceClass" .= archiveHitEvidenceClass hit,
        "sourceCompleteness" .= archiveHitSourceCompleteness hit,
        "artifactIds" .= archiveHitArtifactIds hit,
        "lineNumber" .= archiveHitLineNumber hit,
        "matchOffset" .= archiveHitMatchOffset hit,
        "entryMatchIndex" .= archiveHitEntryMatchIndex hit,
        "entryMatchCount" .= archiveHitEntryMatchCount hit,
        "excerpt" .= archiveHitExcerpt hit,
        "created" .= archiveHitCreated hit
      ]

data ArchiveGrepResult = ArchiveGrepResult
  { archiveGrepResultQuery :: Text,
    archiveGrepResultMode :: Text,
    archiveGrepResultCaseSensitive :: Bool,
    archiveGrepResultScannedTasks :: Int,
    archiveGrepResultScannedEntries :: Int,
    archiveGrepResultMatchedEntries :: Int,
    archiveGrepResultTotalHits :: Int,
    archiveGrepResultReturnedHits :: Int,
    archiveGrepResultOffset :: Int,
    archiveGrepResultLimit :: Int,
    archiveGrepResultNextOffset :: Maybe Int,
    archiveGrepResultHasMore :: Bool,
    archiveGrepResultTruncated :: Bool,
    archiveGrepResultHits :: [ArchiveHit]
  }
  deriving stock (Eq, Show)

instance ToJSON ArchiveGrepResult where
  toJSON result =
    object
      [ "query" .= archiveGrepResultQuery result,
        "mode" .= archiveGrepResultMode result,
        "caseSensitive" .= archiveGrepResultCaseSensitive result,
        "scannedTasks" .= archiveGrepResultScannedTasks result,
        "scannedEntries" .= archiveGrepResultScannedEntries result,
        "scannedCandidates" .= archiveGrepResultScannedEntries result,
        "matchedEntries" .= archiveGrepResultMatchedEntries result,
        "totalHits" .= archiveGrepResultTotalHits result,
        "returnedHits" .= archiveGrepResultReturnedHits result,
        "offset" .= archiveGrepResultOffset result,
        "limit" .= archiveGrepResultLimit result,
        "nextOffset" .= archiveGrepResultNextOffset result,
        "hasMore" .= archiveGrepResultHasMore result,
        "truncated" .= archiveGrepResultTruncated result,
        "hits" .= archiveGrepResultHits result
      ]

data ArchiveReadRequest = ArchiveReadRequest
  { archiveReadIncarnationId :: Text,
    archiveReadEntryId :: Text,
    archiveReadBefore :: Int,
    archiveReadAfter :: Int,
    archiveReadOffset :: Int,
    archiveReadChars :: Int
  }
  deriving stock (Eq, Show)

instance ToJSON ArchiveReadRequest where
  toJSON request =
    object
      [ "incarnationId" .= archiveReadIncarnationId request,
        "entryId" .= archiveReadEntryId request,
        "before" .= archiveReadBefore request,
        "after" .= archiveReadAfter request,
        "offset" .= archiveReadOffset request,
        "chars" .= archiveReadChars request
      ]

instance FromJSON ArchiveReadRequest where
  parseJSON = withObject "ArchiveReadRequest" $ \fields ->
    ArchiveReadRequest
      <$> fields .: "incarnationId"
      <*> fields .: "entryId"
      <*> fields .:? "before" .!= defaultReadBefore
      <*> fields .:? "after" .!= defaultReadAfter
      <*> fields .:? "offset" .!= 0
      <*> fields .:? "chars" .!= defaultReadChars

data ArchiveEntrySlice = ArchiveEntrySlice
  { archiveSliceEntryId :: Text,
    archiveSliceTaskId :: Text,
    archiveSliceRunId :: Text,
    archiveSliceSeq :: Int,
    archiveSliceKind :: ArchiveKind,
    archiveSliceSourceId :: Text,
    archiveSliceToolName :: Maybe Text,
    archiveSliceCallId :: Maybe Text,
    archiveSliceEvidenceClass :: Text,
    archiveSliceSourceCompleteness :: Text,
    archiveSliceArtifactIds :: [Text],
    archiveSliceContent :: Text,
    archiveSliceContentOffset :: Int,
    archiveSliceContentTotal :: Int,
    archiveSliceTruncatedBefore :: Bool,
    archiveSliceTruncatedAfter :: Bool,
    archiveSliceCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON ArchiveEntrySlice where
  toJSON slice =
    object
      [ "entryId" .= archiveSliceEntryId slice,
        "taskId" .= archiveSliceTaskId slice,
        "runId" .= archiveSliceRunId slice,
        "seq" .= archiveSliceSeq slice,
        "kind" .= archiveSliceKind slice,
        "sourceId" .= archiveSliceSourceId slice,
        "toolName" .= archiveSliceToolName slice,
        "callId" .= archiveSliceCallId slice,
        "evidenceClass" .= archiveSliceEvidenceClass slice,
        "sourceCompleteness" .= archiveSliceSourceCompleteness slice,
        "artifactIds" .= archiveSliceArtifactIds slice,
        "content" .= archiveSliceContent slice,
        "contentOffset" .= archiveSliceContentOffset slice,
        "contentTotal" .= archiveSliceContentTotal slice,
        "truncatedBefore" .= archiveSliceTruncatedBefore slice,
        "truncatedAfter" .= archiveSliceTruncatedAfter slice,
        "created" .= archiveSliceCreated slice
      ]

data ArchiveReadResult = ArchiveReadResult
  { archiveReadResultTaskId :: Text,
    archiveReadResultAnchorEntryId :: Text,
    archiveReadResultEntries :: [ArchiveEntrySlice]
  }
  deriving stock (Eq, Show)

instance ToJSON ArchiveReadResult where
  toJSON result =
    object
      [ "taskId" .= archiveReadResultTaskId result,
        "anchorEntryId" .= archiveReadResultAnchorEntryId result,
        "entries" .= archiveReadResultEntries result
      ]

data TaskArchiveStore = TaskArchiveStore
  { taskArchiveAppend :: ArchiveRunDraft -> IO (Either Text ArchiveRun),
    taskArchiveImportLegacy :: Text -> Text -> [ArchiveEntryDraft] -> IO (Either Text (Maybe ArchiveRun)),
    taskArchiveTasks :: Text -> Int -> IO [ArchiveTaskSummary],
    taskArchiveRecent :: Text -> Int -> IO [ArchiveEntryCatalog],
    taskArchiveGrep :: ArchiveGrepRequest -> IO (Either Text ArchiveGrepResult),
    taskArchiveRead :: ArchiveReadRequest -> IO (Either Text ArchiveReadResult),
    taskArchiveRuns :: Text -> Maybe Text -> IO [ArchiveRun]
  }

data ArchiveState = ArchiveState
  { stateRuns :: Map Text ArchiveRun,
    stateEntries :: Map Text ArchiveEntry,
    stateHeads :: Map Text Int,
    stateLegacyImports :: Set Text
  }

data StoredArchive = StoredArchive
  { storedArchiveVersion :: Int,
    storedArchiveRuns :: [ArchiveRun],
    storedArchiveEntries :: [ArchiveEntry],
    storedArchiveLegacyImports :: [Text]
  }

instance ToJSON StoredArchive where
  toJSON stored =
    object
      [ "version" .= storedArchiveVersion stored,
        "runs" .= storedArchiveRuns stored,
        "entries" .= storedArchiveEntries stored,
        "legacyImports" .= storedArchiveLegacyImports stored
      ]

instance FromJSON StoredArchive where
  parseJSON = withObject "TaskArchive" $ \fields ->
    StoredArchive
      <$> fields .: "version"
      <*> fields .:? "runs" .!= []
      <*> fields .:? "entries" .!= []
      <*> fields .:? "legacyImports" .!= []

data PreparedEntry = PreparedEntry
  { preparedId :: Text,
    preparedContentRef :: Text,
    preparedContentHash :: Text,
    preparedContentChars :: Int,
    preparedPreview :: Text,
    preparedDraft :: ArchiveEntryDraft
  }

archiveVersion :: Int
archiveVersion = 1

defaultGrepLimit, maximumGrepLimit, defaultReadBefore, defaultReadAfter, maximumReadWindow, defaultReadChars, maximumReadChars :: Int
defaultGrepLimit = 20
maximumGrepLimit = 100
defaultReadBefore = 2
defaultReadAfter = 2
maximumReadWindow = 20
defaultReadChars = 6000
maximumReadChars = 20000

emptyState :: ArchiveState
emptyState = ArchiveState Map.empty Map.empty Map.empty Set.empty

newTaskArchiveStore :: FilePath -> BlobStore -> IO (Either Text TaskArchiveStore)
newTaskArchiveStore dir blobs =
  prepareDirectory path
    >>= either
      (pure . Left)
      (const (loadState index >>= traverse (newMVar >=> pure . makeStore (persistState index) blobs)))
  where
    path = dir </> "task-archive"
    index = path </> "index.json"

newMemoryTaskArchiveStore :: BlobStore -> IO TaskArchiveStore
newMemoryTaskArchiveStore blobs =
  newMVar emptyState <&> makeStore (const (pure (Right ()))) blobs

makeStore :: (ArchiveState -> IO (Either Text ())) -> BlobStore -> MVar ArchiveState -> TaskArchiveStore
makeStore persist blobs lock =
  TaskArchiveStore
    { taskArchiveAppend = appendRun persist blobs lock Nothing,
      taskArchiveImportLegacy = importLegacy persist blobs lock,
      taskArchiveTasks = catalogTasks lock,
      taskArchiveRecent = recentEntries lock,
      taskArchiveGrep = grepArchive blobs lock,
      taskArchiveRead = readArchive blobs lock,
      taskArchiveRuns = listRuns lock
    }

prepareDirectory :: FilePath -> IO (Either Text ())
prepareDirectory dir =
  (try (createDirectoryIfMissing True dir) :: IO (Either IOException ()))
    <&> either
      (Left . ("cannot prepare task archive: " <>) . Text.pack . displayException)
      Right

loadState :: FilePath -> IO (Either Text ArchiveState)
loadState path =
  (try (eitherDecodeFileStrict path) :: IO (Either IOException (Either String StoredArchive)))
    <&> \case
      Left failure
        | isDoesNotExistError failure -> Right emptyState
        | otherwise -> Left ("cannot read task archive: " <> Text.pack (displayException failure))
      Right (Left failure) -> Left ("invalid task archive: " <> Text.pack failure)
      Right (Right stored) -> stateFromStored stored

persistState :: FilePath -> ArchiveState -> IO (Either Text ())
persistState path state =
  (try (atomicEncodeFile path (stateToStored state)) :: IO (Either IOException ()))
    <&> either
      (Left . ("cannot persist task archive: " <>) . Text.pack . displayException)
      Right

stateToStored :: ArchiveState -> StoredArchive
stateToStored state =
  StoredArchive
    archiveVersion
    (sortOn archiveRunCreated (Map.elems (stateRuns state)))
    (sortOn ((,,) <$> archiveEntryTaskId <*> archiveEntrySeq <*> archiveEntryId) (Map.elems (stateEntries state)))
    (Set.toAscList (stateLegacyImports state))

stateFromStored :: StoredArchive -> Either Text ArchiveState
stateFromStored stored
  | storedArchiveVersion stored /= archiveVersion =
      Left ("unsupported task archive version: " <> shown (storedArchiveVersion stored))
  | otherwise =
      unique "task archive entry" archiveEntryId entries
        *> unique "task archive run" archiveRunId runs
        *> unique "task archive run scope" runScope runs
        *> traverse_ validateEntry entries
        *> traverse_ (validateRun entryMap) runs
        *> validateSequences entries
        $> ArchiveState runMap entryMap heads (Set.fromList (storedArchiveLegacyImports stored))
  where
    runs = storedArchiveRuns stored
    entries = storedArchiveEntries stored
    runMap = Map.fromList [(archiveRunId run, run) | run <- runs]
    entryMap = Map.fromList [(archiveEntryId entry, entry) | entry <- entries]
    heads = Map.fromListWith max [(entryScope entry, archiveEntrySeq entry) | entry <- entries]

validateEntry :: ArchiveEntry -> Either Text ()
validateEntry entry =
  sequence_
    [ nonEmpty "task archive entry id" (archiveEntryId entry),
      nonEmpty "task archive incarnation id" (archiveEntryIncarnationId entry),
      nonEmpty "task archive task id" (archiveEntryTaskId entry),
      nonEmpty "task archive run id" (archiveEntryRunId entry),
      nonEmpty "task archive source id" (archiveEntrySourceId entry),
      nonEmpty "task archive content ref" (archiveEntryContentRef entry),
      nonEmpty "task archive content hash" (archiveEntryContentHash entry),
      require (archiveEntrySeq entry > 0) ("task archive seq must be positive: " <> archiveEntryId entry),
      require (archiveEntryRunSeq entry > 0) ("task archive run seq must be positive: " <> archiveEntryId entry),
      require (archiveEntryContentChars entry >= 0) ("task archive content size is invalid: " <> archiveEntryId entry),
      require (archiveEntryCreated entry >= 0) ("task archive timestamp is invalid: " <> archiveEntryId entry)
    ]

validateRun :: Map Text ArchiveEntry -> ArchiveRun -> Either Text ()
validateRun entries run =
  sequence_
    [ nonEmpty "task archive run id" (archiveRunId run),
      nonEmpty "task archive run incarnation id" (archiveRunIncarnationId run),
      nonEmpty "task archive run task id" (archiveRunTaskId run),
      nonEmpty "task archive source run id" (archiveRunSourceRunId run),
      nonEmpty "task archive run status" (archiveRunStatus run),
      uniqueText "task archive run entry" (archiveRunEntryIds run),
      traverse_ known (archiveRunEntryIds run)
    ]
  where
    known identifier =
      maybe
        (Left ("task archive run references unknown entry: " <> identifier))
        ( \entry ->
            require
              ( entryScope entry
                  == scopeKey (archiveRunIncarnationId run) (archiveRunTaskId run)
                  && archiveEntryRunId entry == archiveRunSourceRunId run
              )
              ("task archive run/entry scope mismatch: " <> identifier)
        )
        (Map.lookup identifier entries)

validateSequences :: [ArchiveEntry] -> Either Text ()
validateSequences =
  traverse_ contiguous
    . Map.toList
    . Map.fromListWith (<>)
    . fmap (\entry -> (entryScope entry, [archiveEntrySeq entry]))
  where
    contiguous (scope, seqs) =
      require
        (sortOn id seqs == [1 .. length seqs])
        ("non-contiguous task archive sequence: " <> scope)

appendRun ::
  (ArchiveState -> IO (Either Text ())) ->
  BlobStore ->
  MVar ArchiveState ->
  Maybe Text ->
  ArchiveRunDraft ->
  IO (Either Text ArchiveRun)
appendRun persist blobs lock legacy draft =
  either
    (pure . Left)
    (\clean -> prepareEntries blobs clean >>= either (pure . Left) (commitPrepared persist lock legacy clean))
    (cleanRunDraft draft)

importLegacy ::
  (ArchiveState -> IO (Either Text ())) ->
  BlobStore ->
  MVar ArchiveState ->
  Text ->
  Text ->
  [ArchiveEntryDraft] ->
  IO (Either Text (Maybe ArchiveRun))
importLegacy persist blobs lock incarnation task entries =
  readMVar lock >>= \state ->
    if Set.member marker (stateLegacyImports state)
      then pure (Right Nothing)
      else
        case entries of
          [] -> markImported persist lock marker <&> fmap (const Nothing)
          _ ->
            appendRun persist blobs lock (Just marker) draft
              <&> fmap Just
  where
    marker = legacyMarker incarnation task
    draft =
      ArchiveRunDraft
        incarnation
        task
        ("legacy-import-" <> Text.take 24 (digest [incarnation, task]))
        Nothing
        "legacy"
        Nothing
        entries

markImported :: (ArchiveState -> IO (Either Text ())) -> MVar ArchiveState -> Text -> IO (Either Text ())
markImported persist lock marker =
  modifyMVar lock $ \state ->
    let updated = state {stateLegacyImports = Set.insert marker (stateLegacyImports state)}
     in persist updated
          <&> either
            ((state,) . Left)
            (const (updated, Right ()))

cleanRunDraft :: ArchiveRunDraft -> Either Text ArchiveRunDraft
cleanRunDraft draft =
  sequence_
    [ nonEmpty "archive incarnation id" incarnation,
      nonEmpty "archive task id" task,
      nonEmpty "archive run id" run,
      nonEmpty "archive run status" status,
      require (status `elem` ["running", "completed", "failed", "cancelled", "legacy"]) ("invalid archive run status: " <> status),
      traverse_ validateDraft entries,
      unique "archive entry source" archiveEntryDraftSourceId entries
    ]
    $> draft
      { archiveRunDraftIncarnationId = incarnation,
        archiveRunDraftTaskId = task,
        archiveRunDraftRunId = run,
        archiveRunDraftStatus = status,
        archiveRunDraftEntries = entries
      }
  where
    incarnation = Text.strip (archiveRunDraftIncarnationId draft)
    task = Text.strip (archiveRunDraftTaskId draft)
    run = Text.strip (archiveRunDraftRunId draft)
    status = Text.strip (archiveRunDraftStatus draft)
    entries = archiveRunDraftEntries draft
    validateDraft entry =
      nonEmpty "archive entry source id" (archiveEntryDraftSourceId entry)
        *> require
          (not (Text.null (Text.strip (archiveEntryDraftContent entry))))
          ("archive entry content must not be empty: " <> archiveEntryDraftSourceId entry)

prepareEntries :: BlobStore -> ArchiveRunDraft -> IO (Either Text [PreparedEntry])
prepareEntries blobs run =
  traverse prepare (archiveRunDraftEntries run) <&> sequence
  where
    prepare entry =
      let content = archiveEntryDraftContent entry
          bytes = TextEncoding.encodeUtf8 content
          contentHash = sha256 bytes
          identifier =
            "task-entry-"
              <> Text.take
                40
                ( digest
                    [ archiveRunDraftIncarnationId run,
                      archiveRunDraftTaskId run,
                      archiveRunDraftRunId run,
                      archiveEntryDraftSourceId entry,
                      archiveKindName (archiveEntryDraftKind entry),
                      contentHash
                    ]
                )
       in blobPut blobs "text/plain; charset=utf-8" (LazyByteString.fromStrict bytes) >>= \meta ->
            blobAttach
              blobs
              identifier
              (blobId meta)
              (archiveRunDraftIncarnationId run)
              "task-archive"
              (archiveRunDraftTaskId run <> "/" <> archiveRunDraftRunId run <> "/" <> archiveEntryDraftSourceId entry)
              <&> fmap
                ( const
                    ( PreparedEntry
                        identifier
                        (blobId meta)
                        contentHash
                        (Text.length content)
                        (preview content)
                        entry
                    )
                )

commitPrepared ::
  (ArchiveState -> IO (Either Text ())) ->
  MVar ArchiveState ->
  Maybe Text ->
  ArchiveRunDraft ->
  [PreparedEntry] ->
  IO (Either Text ArchiveRun)
commitPrepared persist lock legacy draft prepared =
  getPOSIXTime >>= \now ->
    modifyMVar lock $ \state ->
      either
        (pure . (state,) . Left)
        ( \(updated, run) ->
            persist updated
              <&> either
                ((state,) . Left)
                (const (updated, Right run))
        )
        (transition (round now) state)
  where
    identifier = runIdFor draft
    transition stamp snapshot =
      case Map.lookup identifier (stateRuns snapshot) of
        Just current -> merge stamp snapshot current
        Nothing
          | null prepared -> Left "archive run must contain at least one entry"
          | otherwise ->
              let start = Map.findWithDefault 0 scope (stateHeads snapshot)
                  entries = zipWith (materialize stamp start 0) [1 ..] prepared
                  run =
                    ArchiveRun
                      identifier
                      (archiveRunDraftIncarnationId draft)
                      (archiveRunDraftTaskId draft)
                      (archiveRunDraftRunId draft)
                      (archiveRunDraftIntentId draft)
                      (archiveRunDraftStatus draft)
                      (archiveRunDraftFailure draft)
                      (fmap archiveEntryId entries)
                      stamp
                  updated =
                    mark
                      snapshot
                        { stateRuns = Map.insert identifier run (stateRuns snapshot),
                          stateEntries = foldr (\entry -> Map.insert (archiveEntryId entry) entry) (stateEntries snapshot) entries,
                          stateHeads = Map.insert scope (start + length entries) (stateHeads snapshot)
                        }
               in Right (updated, run)
      where
        mark state' =
          maybe state' (\marker -> state' {stateLegacyImports = Set.insert marker (stateLegacyImports state')}) legacy
        merge stamp' snapshot' current =
          validateIdentity current
            *> validateTransition current
            *> traverse_ (validatePrepared current snapshot') prepared
            *> let currentEntries = mapMaybe (\entryId -> Map.lookup entryId (stateEntries snapshot')) (archiveRunEntryIds current)
                   known = Set.fromList (fmap entryDraftKey currentEntries)
                   novel = filter ((`Set.notMember` known) . preparedKey) prepared
                   taskStart = Map.findWithDefault 0 scope (stateHeads snapshot')
                   runStart = length (archiveRunEntryIds current)
                   entries = zipWith (materialize stamp' taskStart runStart) [1 ..] novel
                   revised =
                     current
                       { archiveRunStatus = archiveRunDraftStatus draft,
                         archiveRunFailure = archiveRunDraftFailure draft,
                         archiveRunEntryIds = archiveRunEntryIds current <> fmap archiveEntryId entries
                       }
                   updated =
                     mark
                       snapshot'
                         { stateRuns = Map.insert identifier revised (stateRuns snapshot'),
                           stateEntries = foldr (\entry -> Map.insert (archiveEntryId entry) entry) (stateEntries snapshot') entries,
                           stateHeads = Map.insert scope (taskStart + length entries) (stateHeads snapshot')
                         }
                in Right (updated, revised)
        validateIdentity current =
          require
            ( archiveRunIncarnationId current == archiveRunDraftIncarnationId draft
                && archiveRunTaskId current == archiveRunDraftTaskId draft
                && archiveRunSourceRunId current == archiveRunDraftRunId draft
                && compatibleIntent (archiveRunIntentId current) (archiveRunDraftIntentId draft)
            )
            ("task archive run conflict: " <> archiveRunDraftRunId draft)
        validateTransition current =
          require
            ( archiveRunStatus current == "running"
                || ( archiveRunStatus current == archiveRunDraftStatus draft
                       && archiveRunFailure current == archiveRunDraftFailure draft
                   )
            )
            ("task archive run is already sealed: " <> archiveRunDraftRunId draft)
        validatePrepared current snapshot' preparedEntry =
          case
              filter
                ((== preparedKey preparedEntry) . entryDraftKey)
                (mapMaybe (\entryId -> Map.lookup entryId (stateEntries snapshot')) (archiveRunEntryIds current))
            of
            [] -> Right ()
            existing : _ ->
              require
                ( archiveEntryContentHash existing == preparedContentHash preparedEntry
                    || ( archiveEntryKind existing == ArchiveToolResult
                           && archiveEntryContentChars existing >= preparedContentChars preparedEntry
                       )
                )
                ("task archive source changed content: " <> archiveEntryDraftSourceId (preparedDraft preparedEntry))
        compatibleIntent Nothing _ = True
        compatibleIntent _ Nothing = True
        compatibleIntent left right = left == right
    scope = draftScope draft
    materialize now taskStart runStart localSeq preparedEntry =
      let entry = preparedDraft preparedEntry
       in ArchiveEntry
            (preparedId preparedEntry)
            (archiveRunDraftIncarnationId draft)
            (archiveRunDraftTaskId draft)
            (archiveRunDraftRunId draft)
            (taskStart + localSeq)
            (runStart + localSeq)
            (archiveEntryDraftSourceId entry)
            (archiveEntryDraftKind entry)
            (preparedContentRef preparedEntry)
            (preparedContentHash preparedEntry)
            (preparedContentChars preparedEntry)
            (preparedPreview preparedEntry)
            (archiveEntryDraftParentId entry)
            (archiveEntryDraftCallId entry)
            (archiveEntryDraftToolName entry)
            now
    preparedKey preparedEntry =
      (archiveEntryDraftSourceId entry, archiveEntryDraftKind entry)
      where
        entry = preparedDraft preparedEntry
    entryDraftKey entry = (archiveEntrySourceId entry, archiveEntryKind entry)

catalogTasks :: MVar ArchiveState -> Text -> Int -> IO [ArchiveTaskSummary]
catalogTasks lock rawIncarnation requested
  | Text.null incarnation || requested <= 0 = pure []
  | otherwise =
      readMVar lock
        <&> take (min 1000 requested)
          . sortOn (Down . ((,) <$> archiveTaskUpdated <*> archiveTaskId))
          . mapMaybe summary
          . Map.toList
          . Map.fromListWith (<>)
          . fmap (\entry -> (archiveEntryTaskId entry, [entry]))
          . filter ((== incarnation) . archiveEntryIncarnationId)
          . Map.elems
          . stateEntries
  where
    incarnation = Text.strip rawIncarnation
    summary (task, entries) =
      case sortOn archiveEntrySeq entries of
        [] -> Nothing
        first : rest ->
          let last' = foldl (\_ entry -> entry) first rest
              ordered = first : rest
           in Just
                ( ArchiveTaskSummary
                    incarnation
                    task
                    (Set.size (Set.fromList (fmap archiveEntryRunId ordered)))
                    (length ordered)
                    (archiveEntryCreated first)
                    (archiveEntryCreated last')
                    (archiveEntryPreview last')
                )

recentEntries :: MVar ArchiveState -> Text -> Int -> IO [ArchiveEntryCatalog]
recentEntries lock rawIncarnation requested
  | Text.null incarnation || requested <= 0 = pure []
  | otherwise =
      readMVar lock
        <&> take (min 256 requested)
          . fmap catalogEntry
          . sortOn (Down . entryOrder)
          . filter ((== incarnation) . archiveEntryIncarnationId)
          . Map.elems
          . stateEntries
  where
    incarnation = Text.strip rawIncarnation

catalogEntry :: ArchiveEntry -> ArchiveEntryCatalog
catalogEntry entry =
  ArchiveEntryCatalog
    (archiveEntryId entry)
    (archiveEntryTaskId entry)
    (archiveEntryRunId entry)
    (archiveEntrySeq entry)
    (archiveEntryKind entry)
    (archiveEntryPreview entry)
    (archiveEntryCreated entry)

grepArchive :: BlobStore -> MVar ArchiveState -> ArchiveGrepRequest -> IO (Either Text ArchiveGrepResult)
grepArchive blobs lock request =
  case cleanGrep request of
    Left failure -> pure (Left failure)
    Right clean ->
      readMVar lock >>= \state ->
        let candidates =
              sortOn (\entry -> (evidenceRank entry, Down (entryOrder entry)))
                . filter (grepEntry state clean)
                . Map.elems
                $ stateEntries state
         in scanEntries blobs state clean candidates <&> fmap (result clean candidates)
  where
    result clean candidates hits =
      let offset = archiveGrepOffset clean
          limit = archiveGrepLimit clean
          selected = take limit (drop offset hits)
          next = offset + length selected
          more = next < length hits
       in ArchiveGrepResult
            (archiveGrepQuery clean)
            "fixed"
            (archiveGrepCaseSensitive clean)
            (Set.size (Set.fromList (fmap archiveEntryTaskId candidates)))
            (length candidates)
            (Set.size (Set.fromList (fmap archiveHitEntryId hits)))
            (length hits)
            (length selected)
            offset
            limit
            (bool Nothing (Just next) more)
            more
            more
            selected

cleanGrep :: ArchiveGrepRequest -> Either Text ArchiveGrepRequest
cleanGrep request =
  sequence_
    [ nonEmpty "task archive incarnation id" incarnation,
      nonEmpty "task archive grep query" query,
      require (not ("\n" `Text.isInfixOf` query)) "task archive grep query must be one line",
      require (archiveGrepLimit request > 0) "task archive grep limit must be positive",
      require (archiveGrepLimit request <= maximumGrepLimit) ("task archive grep limit exceeds " <> shown maximumGrepLimit),
      require (archiveGrepOffset request >= 0) "task archive grep offset must not be negative"
    ]
    $> request
      { archiveGrepIncarnationId = incarnation,
        archiveGrepQuery = query,
        archiveGrepTaskId = nonBlank =<< archiveGrepTaskId request,
        archiveGrepKinds = Set.toList (Set.fromList (archiveGrepKinds request))
      }
  where
    incarnation = Text.strip (archiveGrepIncarnationId request)
    query = Text.strip (archiveGrepQuery request)

grepEntry :: ArchiveState -> ArchiveGrepRequest -> ArchiveEntry -> Bool
grepEntry state request entry =
  archiveEntryIncarnationId entry == archiveGrepIncarnationId request
    && maybe True (== archiveEntryTaskId entry) (archiveGrepTaskId request)
    && archiveEntryKind entry `elem` kinds
    && (archiveGrepIncludeProcess request || not (processEntry state entry))
  where
    kinds = bool (archiveGrepKinds request) defaultSearchKinds (null (archiveGrepKinds request))

defaultSearchKinds :: [ArchiveKind]
defaultSearchKinds = [ArchiveUser, ArchiveAssistant, ArchiveToolCall, ArchiveToolResult]

evidenceRank :: ArchiveEntry -> Int
evidenceRank entry =
  case archiveEntryKind entry of
    ArchiveUser -> 0
    ArchiveToolResult -> 0
    ArchiveAssistant -> 1
    ArchiveReasoning -> 1
    ArchiveInstruction -> 1
    ArchiveWakePacket -> 1
    ArchiveToolCall -> 2

evidenceClass :: ArchiveState -> ArchiveEntry -> Text
evidenceClass state entry
  | processEntry state entry = "process"
  | archiveEntryKind entry `elem` [ArchiveUser, ArchiveToolResult] = "source"
  | otherwise = "derived"

processEntry :: ArchiveState -> ArchiveEntry -> Bool
processEntry state entry =
  archiveEntryKind entry == ArchiveToolCall
    || maybe False (`Set.member` memoryProcessTools) (resolvedToolName state entry)
    || (archiveEntryKind entry == ArchiveToolResult && looksMemoryProcess (archiveEntryPreview entry))

memoryProcessTools :: Set Text
memoryProcessTools = Set.fromList ["memory_grep", "memory_read", "self_inspect"]

looksMemoryProcess :: Text -> Bool
looksMemoryProcess content =
  ("\"scannedEntries\":" `Text.isInfixOf` content && "\"hits\":" `Text.isInfixOf` content)
    || ("\"anchorEntryId\":" `Text.isInfixOf` content && "\"entries\":" `Text.isInfixOf` content)
    || ("\"activePrompt\":" `Text.isInfixOf` content && "\"workingMemory\":" `Text.isInfixOf` content)

resolvedToolName :: ArchiveState -> ArchiveEntry -> Maybe Text
resolvedToolName state entry =
  archiveEntryToolName entry <|> (archiveEntryCallId entry >>= lookupCall)
  where
    lookupCall call =
      listToMaybe
        [ name
          | candidate <- Map.elems (stateEntries state),
            archiveEntryKind candidate == ArchiveToolCall,
            archiveEntryCallId candidate == Just call,
            name <- maybe [] pure (archiveEntryToolName candidate)
        ]

sourceCompleteness :: ArchiveState -> ArchiveEntry -> Text -> Text
sourceCompleteness state entry content
  | archiveEntryKind entry /= ArchiveToolResult = "complete-record"
  | "[…truncated…]" `Text.isInfixOf` content = "truncated-record"
  | "[artifact " `Text.isInfixOf` content = "artifact-backed"
  | resolvedToolName state entry `elem` fmap Just ["shell", "shell_bg", "shell_output", "artifact_read", "fs_read"] = "unknown-source"
  | otherwise = "complete-record"

artifactIds :: Text -> [Text]
artifactIds = Set.toAscList . Set.fromList . go
  where
    go text =
      case Text.breakOn "art-" text of
        (_, suffix)
          | Text.null suffix -> []
          | otherwise ->
              let identifier = Text.takeWhile (\char -> isAlphaNum char || char == '-') suffix
                  rest = Text.drop (max 1 (Text.length identifier)) suffix
               in bool (go rest) (identifier : go rest) (Text.length identifier > 4)

scanEntries :: BlobStore -> ArchiveState -> ArchiveGrepRequest -> [ArchiveEntry] -> IO (Either Text [ArchiveHit])
scanEntries blobs state request = go []
  where
    go hits [] = pure (Right hits)
    go hits (entry : rest) =
      fetchContent blobs entry >>= \case
        Left failure -> pure (Left failure)
        Right content ->
          let found = lineHits state request entry content
           in go (hits <> found) rest

lineHits :: ArchiveState -> ArchiveGrepRequest -> ArchiveEntry -> Text -> [ArchiveHit]
lineHits state request entry content =
  zipWith build [1 ..] matches
  where
    matches = indexedLines content >>= lineMatches
    count = length matches
    needle = normalized (archiveGrepQuery request)
    normalized = bool Text.toCaseFold id (archiveGrepCaseSensitive request)
    lineMatches (lineNumber, offset, line) =
      fmap (\column -> (lineNumber, offset, line, column)) (occurrenceColumns needle (normalized line))
    build index (lineNumber, offset, line, column) =
      ArchiveHit
        (archiveEntryId entry)
        (archiveEntryTaskId entry)
        (archiveEntryRunId entry)
        (archiveEntrySeq entry)
        (archiveEntryKind entry)
        (archiveEntrySourceId entry)
        (resolvedToolName state entry)
        (archiveEntryCallId entry)
        (evidenceClass state entry)
        (sourceCompleteness state entry content)
        (artifactIds content)
        lineNumber
        (offset + column)
        index
        count
        (excerptAt column line)
        (archiveEntryCreated entry)

occurrenceColumns :: Text -> Text -> [Int]
occurrenceColumns needle = go 0
  where
    width = Text.length needle
    go offset text =
      let (before, after) = Text.breakOn needle text
       in if Text.null after
            then []
            else
              let column = offset + Text.length before
               in column : go (column + width) (Text.drop width after)

indexedLines :: Text -> [(Int, Int, Text)]
indexedLines = snd . foldl' next (0, []) . zip [1 ..] . Text.splitOn "\n"
  where
    next (offset, rows) (lineNumber, line) =
      (offset + Text.length line + 1, rows <> [(lineNumber, offset, line)])

excerptAt :: Int -> Text -> Text
excerptAt column line =
  prefix <> Text.take excerptChars (Text.drop start line) <> suffix
  where
    start = max 0 (column - excerptLead)
    prefix = bool "" "…" (start > 0)
    suffix = bool "" "…" (start + excerptChars < Text.length line)

excerptLead, excerptChars :: Int
excerptLead = 100
excerptChars = 700

readArchive :: BlobStore -> MVar ArchiveState -> ArchiveReadRequest -> IO (Either Text ArchiveReadResult)
readArchive blobs lock request =
  case cleanRead request of
    Left failure -> pure (Left failure)
    Right clean ->
      readMVar lock >>= \state ->
        case Map.lookup (archiveReadEntryId clean) (stateEntries state) of
          Nothing -> pure (Left ("unknown task archive entry: " <> archiveReadEntryId clean))
          Just anchor
            | archiveEntryIncarnationId anchor /= archiveReadIncarnationId clean ->
                pure (Left ("task archive entry is not owned by incarnation: " <> archiveReadEntryId clean))
            | otherwise ->
                let entries =
                      sortOn archiveEntrySeq
                        . filter ((== entryScope anchor) . entryScope)
                        . Map.elems
                        $ stateEntries state
                 in maybe
                      (pure (Left ("task archive anchor is missing from its task: " <> archiveReadEntryId clean)))
                      (renderWindow blobs state clean anchor entries)
                      (findIndex ((== archiveEntryId anchor) . archiveEntryId) entries)

cleanRead :: ArchiveReadRequest -> Either Text ArchiveReadRequest
cleanRead request =
  sequence_
    [ nonEmpty "task archive read incarnation id" incarnation,
      nonEmpty "task archive read entry id" identifier,
      require (archiveReadBefore request >= 0 && archiveReadBefore request <= maximumReadWindow) "task archive before window is invalid",
      require (archiveReadAfter request >= 0 && archiveReadAfter request <= maximumReadWindow) "task archive after window is invalid",
      require (archiveReadOffset request >= 0) "task archive read offset must not be negative",
      require (archiveReadChars request >= 1 && archiveReadChars request <= maximumReadChars) "task archive read character limit is invalid"
    ]
    $> request
      { archiveReadIncarnationId = incarnation,
        archiveReadEntryId = identifier
      }
  where
    incarnation = Text.strip (archiveReadIncarnationId request)
    identifier = Text.strip (archiveReadEntryId request)

renderWindow ::
  BlobStore ->
  ArchiveState ->
  ArchiveReadRequest ->
  ArchiveEntry ->
  [ArchiveEntry] ->
  Int ->
  IO (Either Text ArchiveReadResult)
renderWindow blobs state request anchor entries index =
  traverse load selected
    <&> ( fmap
            ( ArchiveReadResult
                (archiveEntryTaskId anchor)
                (archiveEntryId anchor)
                . renderLoaded
            )
            . sequence
        )
  where
    start = max 0 (index - archiveReadBefore request)
    end = min (length entries) (index + archiveReadAfter request + 1)
    selected = closeEntryGroups entries (take (end - start) (drop start entries))
    load entry = fetchContent blobs entry <&> fmap (entry,)
    renderLoaded loaded =
      zipWith
        ( \(entry, content) budget ->
            sliceEntry
              state
              budget
              (bool 0 (archiveReadOffset request) (archiveEntryId entry == archiveEntryId anchor))
              entry
              content
        )
        loaded
        (readBudgets (archiveReadChars request) (archiveEntryId anchor) (fmap fst loaded))

closeEntryGroups :: [ArchiveEntry] -> [ArchiveEntry] -> [ArchiveEntry]
closeEntryGroups available seed =
  sortOn archiveEntrySeq (expand (Set.fromList (fmap archiveEntryId seed)) seed)
  where
    expand seen selected =
      let groups = Set.unions (fmap entryGroups selected)
          related =
            [ entry
              | entry <- available,
                archiveEntryId entry `Set.notMember` seen,
                not (Set.disjoint groups (entryGroups entry))
            ]
       in case related of
            [] -> selected
            _ -> expand (Set.union seen (Set.fromList (fmap archiveEntryId related))) (selected <> related)

entryGroups :: ArchiveEntry -> Set Text
entryGroups entry =
  Set.fromList
    ( maybe [] (\group -> [prefix <> "/turn/" <> group]) (archiveEntryParentId entry)
        <> maybe [] (\group -> [prefix <> "/call/" <> group]) (archiveEntryCallId entry)
    )
  where
    prefix = archiveEntryRunId entry

readBudgets :: Int -> Text -> [ArchiveEntry] -> [Int]
readBudgets wanted anchor entries =
  snd (foldl allocate (extra, []) entries)
  where
    neighbours = max 0 (length entries - 1)
    anchorBudget =
      bool
        wanted
        (max 1 (max (wanted `div` 2) (wanted - neighbours * 400)))
        (neighbours > 0)
    remaining = max 0 (wanted - anchorBudget)
    base = bool 0 (remaining `div` neighbours) (neighbours > 0)
    extra = bool 0 (remaining `mod` neighbours) (neighbours > 0)
    allocate (left, budgets) entry
      | archiveEntryId entry == anchor = (left, budgets <> [anchorBudget])
      | left > 0 = (left - 1, budgets <> [base + 1])
      | otherwise = (left, budgets <> [base])

sliceEntry :: ArchiveState -> Int -> Int -> ArchiveEntry -> Text -> ArchiveEntrySlice
sliceEntry state wanted anchor entry content =
  ArchiveEntrySlice
    (archiveEntryId entry)
    (archiveEntryTaskId entry)
    (archiveEntryRunId entry)
    (archiveEntrySeq entry)
    (archiveEntryKind entry)
    (archiveEntrySourceId entry)
    (resolvedToolName state entry)
    (archiveEntryCallId entry)
    (evidenceClass state entry)
    (sourceCompleteness state entry content)
    (artifactIds content)
    visible
    start
    total
    (start > 0)
    (start + Text.length visible < total)
    (archiveEntryCreated entry)
  where
    total = Text.length content
    maximumStart = max 0 (total - wanted)
    start = min maximumStart (max 0 (anchor - wanted `div` 3))
    visible = Text.take wanted (Text.drop start content)

fetchContent :: BlobStore -> ArchiveEntry -> IO (Either Text Text)
fetchContent blobs entry =
  blobFetch blobs (archiveEntryContentRef entry)
    <&> fmap (TextEncoding.decodeUtf8 . LazyByteString.toStrict)

listRuns :: MVar ArchiveState -> Text -> Maybe Text -> IO [ArchiveRun]
listRuns lock rawIncarnation task =
  readMVar lock
    <&> sortOn archiveRunCreated
      . filter
        ( \run ->
            archiveRunIncarnationId run == Text.strip rawIncarnation
              && maybe True ((== archiveRunTaskId run)) (task >>= nonBlank)
        )
      . Map.elems
      . stateRuns

entryOrder :: ArchiveEntry -> (Integer, Text, Int)
entryOrder entry =
  (archiveEntryCreated entry, archiveEntryTaskId entry, archiveEntrySeq entry)

entryScope :: ArchiveEntry -> Text
entryScope entry =
  scopeKey (archiveEntryIncarnationId entry) (archiveEntryTaskId entry)

draftScope :: ArchiveRunDraft -> Text
draftScope draft =
  scopeKey (archiveRunDraftIncarnationId draft) (archiveRunDraftTaskId draft)

runScope :: ArchiveRun -> Text
runScope run =
  Text.intercalate
    "\NUL"
    [ archiveRunIncarnationId run,
      archiveRunTaskId run,
      archiveRunSourceRunId run
    ]

scopeKey :: Text -> Text -> Text
scopeKey incarnation task = Text.intercalate "\NUL" [incarnation, task]

legacyMarker :: Text -> Text -> Text
legacyMarker incarnation task = "legacy/" <> digest [incarnation, task]

runIdFor :: ArchiveRunDraft -> Text
runIdFor draft =
  "task-run-"
    <> Text.take
      40
      ( digest
          [ archiveRunDraftIncarnationId draft,
            archiveRunDraftTaskId draft,
            archiveRunDraftRunId draft
          ]
      )

digest :: [Text] -> Text
digest = sha256 . TextEncoding.encodeUtf8 . Text.intercalate "\NUL"

preview :: Text -> Text
preview = Text.take 360 . Text.unwords . Text.words

unique :: Ord key => Text -> (value -> key) -> [value] -> Either Text ()
unique label key values =
  require
    (Set.size (Set.fromList (fmap key values)) == length values)
    ("duplicate " <> label)

uniqueText :: Text -> [Text] -> Either Text ()
uniqueText label = unique label id

nonEmpty :: Text -> Text -> Either Text ()
nonEmpty label value =
  require (not (Text.null (Text.strip value))) (label <> " must not be empty")

nonBlank :: Text -> Maybe Text
nonBlank value
  | Text.null clean = Nothing
  | otherwise = Just clean
  where
    clean = Text.strip value

require :: Bool -> Text -> Either Text ()
require condition failure = bool (Left failure) (Right ()) condition

shown :: Show value => value -> Text
shown = Text.pack . show
