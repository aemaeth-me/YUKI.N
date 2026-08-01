module Yuki.N.Journal
  ( Entry (..),
    EntryKind (..),
    Journal (..),
    JournalRead (..),
    RunSettings (..),
    journalFilePath,
    journalNewId,
    journalRunRetentionLimit,
    newFileJournal,
    newFileJournalWithLimit,
    newMemoryJournal,
    readJournalFile,
    recordMaybe,
    subJournal,
  )
where

import Control.Concurrent.MVar
import Control.Exception (IOException, displayException, try)
import Data.Aeson
import Data.Aeson.Types (Pair, Parser)
import Data.Bool (bool)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (toList, traverse_)
import Data.Functor ((<&>))
import Data.IORef
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Sequence ((|>))
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectoryIfMissing)
import System.IO
import System.IO.Error (isDoesNotExistError)
import Yuki.N.AGUI.Event (Event)
import Yuki.N.AGUI.Types (RunAgentInput)
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Artifact (SpliceConfig)
import Yuki.N.AtomicFile (atomicWriteLazy)
import Yuki.N.Context (ContextConfig)
import Yuki.N.Model

data Journal = Journal
  { journalWith :: [Text] -> EntryKind -> IO (),
    journalScope :: [Text],
    journalSnapshot :: IO [Entry]
  }

data JournalRead = JournalRead
  { journalReadEntries :: [Entry],
    journalReadWarning :: Maybe Text
  }
  deriving stock (Eq, Show)

data Entry = Entry
  { entrySeq :: Int,
    entryScope :: [Text],
    entryTime :: Maybe Integer,
    entryKind :: EntryKind
  }
  deriving stock (Eq, Show)

data EntryKind
  = RunBegin RunAgentInput RunSettings
  | ModelRequestEntry ModelRequest
  | ApiRequestEntry Value
  | ModelEventEntry ModelEvent
  | ModelFinishEntry FinishReason
  | ToolCallEntry Text Text Text ToolOutcome
  | IdEntry Text
  | AgentEventEntry Event
  | StoreBriefEntry Value
  | StoreFactsEntry Value
  | SteeringEntry Int [ChatMessage]
  | FollowUpEntry Int [ChatMessage]
  | ContextCompactEntry Int Int Int Int Int Bool Text
  deriving stock (Eq, Show)

data RunSettings = RunSettings
  { runSettingsMaxTurns :: Int,
    runSettingsToolExecution :: ToolExecution,
    runSettingsSystemPrompt :: Text,
    runSettingsDepth :: Int,
    runSettingsSplice :: Maybe SpliceConfig,
    runSettingsContext :: Maybe ContextConfig,
    runSettingsContextTokens :: Maybe Int
  }
  deriving stock (Eq, Show)

instance ToJSON RunSettings where
  toJSON settings =
    object
      ( [ "maxTurns" .= runSettingsMaxTurns settings,
          "toolExecution" .= runSettingsToolExecution settings,
          "systemPrompt" .= runSettingsSystemPrompt settings,
          "depth" .= runSettingsDepth settings,
          "splice" .= runSettingsSplice settings
        ]
          <> maybe [] (pure . ("context" .=)) (runSettingsContext settings)
          <> maybe [] (pure . ("contextTokens" .=)) (runSettingsContextTokens settings)
      )

instance FromJSON RunSettings where
  parseJSON = withObject "RunSettings" $ \fields ->
    RunSettings
      <$> fields .: "maxTurns"
      <*> fields .: "toolExecution"
      <*> fields .: "systemPrompt"
      <*> fields .: "depth"
      <*> fields .:? "splice"
      <*> fields .:? "context"
      <*> fields .:? "contextTokens"

instance ToJSON Entry where
  toJSON (Entry seqNo scope time kind) =
    object (["seq" .= seqNo, "scope" .= scope] <> timePair time <> kindPairs kind)

timePair :: Maybe Integer -> [Pair]
timePair = fromMaybe [] . fmap (\time -> ["time" .= time])

instance FromJSON Entry where
  parseJSON = withObject "Entry" $ \fields ->
    Entry
      <$> fields .: "seq"
      <*> fields .: "scope"
      <*> fields .:? "time"
      <*> (fields .: "kind" >>= parseKind fields)

kindPairs :: EntryKind -> [Pair]
kindPairs = \case
  RunBegin input settings ->
    ["kind" .= ("run.begin" :: Text), "input" .= input, "settings" .= settings]
  ModelRequestEntry request -> ["kind" .= ("model.request" :: Text), "request" .= request]
  ApiRequestEntry value -> ["kind" .= ("api.request" :: Text), "request" .= value]
  ModelEventEntry event -> ["kind" .= ("model.event" :: Text), "event" .= event]
  ModelFinishEntry reason -> ["kind" .= ("model.finish" :: Text), "reason" .= reason]
  ToolCallEntry callId name arguments outcome ->
    [ "kind" .= ("tool.call" :: Text),
      "callId" .= callId,
      "name" .= name,
      "arguments" .= arguments,
      "outcome" .= outcome
    ]
  IdEntry value -> ["kind" .= ("id" :: Text), "value" .= value]
  AgentEventEntry event -> ["kind" .= ("agent.event" :: Text), "event" .= event]
  StoreBriefEntry brief -> ["kind" .= ("store.brief" :: Text), "brief" .= brief]
  StoreFactsEntry hits -> ["kind" .= ("store.facts" :: Text), "facts" .= hits]
  SteeringEntry step messages ->
    ["kind" .= ("steering" :: Text), "step" .= step, "messages" .= messages]
  FollowUpEntry step messages ->
    ["kind" .= ("followup" :: Text), "step" .= step, "messages" .= messages]
  ContextCompactEntry step before after budget dropped emergency summary ->
    [ "kind" .= ("context.compact" :: Text),
      "step" .= step,
      "beforeTokens" .= before,
      "afterTokens" .= after,
      "budgetTokens" .= budget,
      "droppedMessages" .= dropped,
      "emergency" .= emergency,
      "summary" .= summary
    ]

parseKind :: Object -> Text -> Parser EntryKind
parseKind fields = \case
  "run.begin" -> RunBegin <$> fields .: "input" <*> fields .: "settings"
  "model.request" -> ModelRequestEntry <$> fields .: "request"
  "api.request" -> ApiRequestEntry <$> fields .: "request"
  "model.event" -> ModelEventEntry <$> fields .: "event"
  "model.finish" -> ModelFinishEntry <$> fields .: "reason"
  "tool.call" ->
    ToolCallEntry
      <$> fields .: "callId"
      <*> fields .: "name"
      <*> fields .: "arguments"
      <*> fields .: "outcome"
  "id" -> IdEntry <$> fields .: "value"
  "agent.event" -> AgentEventEntry <$> fields .: "event"
  "store.brief" -> StoreBriefEntry <$> fields .: "brief"
  "store.facts" -> StoreFactsEntry <$> fields .: "facts"
  "steering" -> SteeringEntry <$> fields .: "step" <*> fields .: "messages"
  "followup" -> FollowUpEntry <$> fields .: "step" <*> fields .: "messages"
  "context.compact" ->
    ContextCompactEntry
      <$> fields .: "step"
      <*> fields .: "beforeTokens"
      <*> fields .: "afterTokens"
      <*> fields .: "budgetTokens"
      <*> fields .: "droppedMessages"
      <*> fields .: "emergency"
      <*> fields .: "summary"
  other -> fail ("unknown journal entry kind: " <> Text.unpack other)

mkJournal :: MVar Int -> (Entry -> IO ()) -> IO [Entry] -> [Text] -> Journal
mkJournal counter sink snapshot scope = Journal record scope snapshot
 where
  record scoped kind =
    getPOSIXTime >>= \time ->
      modifyMVar counter (\seqNo -> pure (seqNo + 1, Entry seqNo scoped (Just (round time)) kind)) >>= sink

journalFilePath :: FilePath -> FilePath
journalFilePath dir = dir ++ "/journal.jsonl"

newFileJournal :: FilePath -> IO Journal
newFileJournal = newFileJournalWithLimit journalRunRetentionLimit

journalRunRetentionLimit :: Int
journalRunRetentionLimit = 256

newFileJournalWithLimit :: Int -> FilePath -> IO Journal
newFileJournalWithLimit requestedLimit dir =
  createDirectoryIfMissing True dir
    *> readJournalFile path
    >>= either (ioError . userError . Text.unpack) initialize
 where
  limit = max 1 requestedLimit
  path = journalFilePath dir
  initialize snapshot =
    repair snapshot retained
      *> newMVar (nextSeq (journalReadEntries snapshot))
      >>= \counter ->
        newMVar () >>= \lock ->
          newIORef (Seq.fromList retained) >>= \cache ->
            pure (mkJournal counter (sink lock cache) (toList <$> readIORef cache) [])
   where
    retained = retainRuns limit (journalReadEntries snapshot)
  repair snapshot retained =
    bool
      (pure ())
      ( atomicWriteLazy path (renderEntries retained)
          *> traverse_
            (TextIO.hPutStrLn stderr . ("YUKI.N journal recovery: " <>))
            (journalReadWarning snapshot)
      )
      (isJust (journalReadWarning snapshot) || length retained /= length (journalReadEntries snapshot))
  sink lock cache entry =
    withMVar lock $ \_ ->
      readIORef cache >>= \current ->
        let expanded = current |> entry
            retained = Seq.fromList (retainRuns limit (toList expanded))
            compact = isRunBegin entry && Seq.length retained < Seq.length expanded
            persist =
              bool
                (append entry)
                (atomicWriteLazy path (renderEntries (toList retained)))
                compact
         in persist *> writeIORef cache (bool expanded retained compact)
  append entry =
    withFile
      path
      AppendMode
      (\handle -> LazyByteString.hPutStr handle (encode entry <> "\n") *> hFlush handle)
  nextSeq entries = maximum (-1 : fmap entrySeq entries) + 1
  renderEntries = LazyByteString.concat . fmap ((<> "\n") . encode)

isRunBegin :: Entry -> Bool
isRunBegin (Entry _ scope _ RunBegin {}) = length scope == 1
isRunBegin _ = False

retainRuns :: Int -> [Entry] -> [Entry]
retainRuns limit entries = filter keep entries
 where
  roots =
    [ AGUI.runId input
    | Entry _ scope _ (RunBegin input _) <- entries,
      length scope == 1
    ]
  known = Set.fromList roots
  retained = Set.fromList (takeEnd limit roots)
  keep entry =
    maybe True (\runId -> Set.notMember runId known || Set.member runId retained) (listToMaybe (entryScope entry))
  takeEnd count values = drop (length values - count) values

readJournalFile :: FilePath -> IO (Either Text JournalRead)
readJournalFile path =
  (try (LazyByteString.readFile path) :: IO (Either IOException LazyByteString.ByteString))
    <&> either absent parseBytes
 where
  absent failure
    | isMissing failure = Right (JournalRead [] Nothing)
    | otherwise = Left ("cannot read journal: " <> Text.pack (displayException failure))
  isMissing = isDoesNotExistError

parseBytes :: LazyByteString.ByteString -> Either Text JournalRead
parseBytes bytes = parseLines [] numbered
 where
  unterminated = not (LazyByteString.null bytes) && not ("\n" `LazyByteString.isSuffixOf` bytes)
  chunks = LazyByteString.split 10 bytes
  content = bool chunks (take (length chunks - 1) chunks) (not unterminated && not (LazyByteString.null bytes))
  numbered = filter (not . LazyByteString.null . snd) (zip [1 ..] content)
  parseLines entries [] =
    Right
      ( JournalRead
          (reverse entries)
          (bool Nothing (Just "accepted unterminated final record") unterminated)
      )
  parseLines entries ((lineNo, line) : rest) =
    case eitherDecode line of
      Right entry -> parseLines (entry : entries) rest
      Left message
        | unterminated && null rest ->
            Right
              ( JournalRead
                  (reverse entries)
                  (Just ("ignored incomplete final line " <> Text.pack (show (lineNo :: Int)) <> ": " <> Text.pack message))
              )
        | otherwise ->
            Left ("journal line " <> Text.pack (show (lineNo :: Int)) <> ": " <> Text.pack message)

newMemoryJournal :: IO (Journal, IO [Entry])
newMemoryJournal =
  newMVar 0 >>= \counter ->
    newIORef Seq.empty >>= \store ->
      pure
        ( mkJournal counter (\entry -> modifyIORef' store (|> entry)) (toList <$> readIORef store) [],
          toList <$> readIORef store
        )

subJournal :: Text -> Journal -> Journal
subJournal runId journal = journal {journalScope = journalScope journal <> [runId]}

journalRecord :: Journal -> EntryKind -> IO ()
journalRecord journal = journalWith journal (journalScope journal)

recordMaybe :: Maybe Journal -> EntryKind -> IO ()
recordMaybe journal kind = traverse_ (\j -> journalRecord j kind) journal

journalNewId :: Journal -> IO Text -> IO Text
journalNewId journal action =
  action >>= \value -> value <$ journalRecord journal (IdEntry value)
