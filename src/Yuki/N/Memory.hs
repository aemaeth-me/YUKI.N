module Yuki.N.Memory
  ( Episode (..),
    MemoryState,
    ThreadBrief (..),
    ThreadStore (..),
    WatcherState (..),
    briefingMarker,
    candidatesMarker,
    complete,
    memoryHooks,
    memoryTransientCounts,
    newMemoryState,
    newMemoryThreadStore,
    newThreadStore,
    readOnlyThreadStore,
    sanitizeThreadId,
    seedWatcher,
  )
where

import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (void, (>=>))
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Bool (bool)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char qualified as Char
import Data.Either (fromRight)
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import System.Directory (createDirectoryIfMissing)
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent
import Yuki.N.Artifact (fnv1a64, renderHash)
import Yuki.N.AtomicFile (atomicEncodeFile)
import Yuki.N.Facts
import Yuki.N.Journal
import Yuki.N.Model

data ThreadStore = ThreadStore
  { threadSaveEpisode :: Text -> Episode -> IO (),
    threadBrief :: Text -> IO (Maybe ThreadBrief)
  }

data ThreadBrief = ThreadBrief
  { briefRollingSummary :: Text,
    briefEpisodes :: [Episode]
  }
  deriving stock (Eq, Show)

data Episode = Episode
  { episodeRunId :: Text,
    episodeSummary :: Text,
    episodeTime :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON Episode where
  toJSON (Episode runId summary time) =
    object ["runId" .= runId, "summary" .= summary, "time" .= time]

instance FromJSON Episode where
  parseJSON = withObject "Episode" $ \fields ->
    Episode <$> fields .: "runId" <*> fields .: "summary" <*> fields .: "time"

instance ToJSON ThreadBrief where
  toJSON (ThreadBrief rollingSummary episodes) =
    object ["rollingSummary" .= rollingSummary, "episodes" .= episodes]

instance FromJSON ThreadBrief where
  parseJSON = withObject "ThreadBrief" $ \fields ->
    ThreadBrief <$> fields .: "rollingSummary" <*> fields .: "episodes"

data WatcherState = WatcherState
  { watcherRollingSummary :: Text,
    watcherLastSeen :: Int,
    watcherRound :: Int,
    watcherSpent :: Map Text Int,
    watcherCooldowns :: Map Text Int
  }
  deriving stock (Eq, Show)

emptyWatcher :: WatcherState
emptyWatcher = WatcherState "" 0 0 Map.empty Map.empty

data MemoryState = MemoryState
  { memoryWatchers :: Map Text WatcherState,
    memoryBriefings :: Map Text (Maybe Text),
    memoryCandidates :: Map Text [Fact]
  }

newMemoryState :: IO (IORef MemoryState)
newMemoryState = newIORef (MemoryState Map.empty Map.empty Map.empty)

briefingMarker :: Text
briefingMarker = "[thread brief]"

candidatesMarker :: Text
candidatesMarker = "[memory candidates]"

briefingSummaryCap :: Int
briefingSummaryCap = 2000

briefingEpisodeCount :: Int
briefingEpisodeCount = 3

candidatesCap :: Int
candidatesCap = 1200

retrievalRunBudget :: Int
retrievalRunBudget = 3

cooldownRounds :: Int
cooldownRounds = 5

memoryHooks :: Model -> ThreadStore -> FactStore -> Maybe Journal -> IORef MemoryState -> AgentHooks
memoryHooks model store facts journal state =
  defaultHooks
    { transformContext = \input messages ->
        insulate (watcherStep model facts journal state input messages)
          *> shield messages ((injectBriefing store journal state input >=> injectCandidates facts state input) messages),
      afterRun = \input _ ->
        insulate (closeEpisode store state input)
          *> clearRunState state input
    }

watcherStep :: Model -> FactStore -> Maybe Journal -> IORef MemoryState -> AGUI.RunAgentInput -> [ChatMessage] -> IO ()
watcherStep model facts journal state input messages =
  readIORef state >>= refresh . Map.findWithDefault emptyWatcher threadId . memoryWatchers
 where
  threadId = AGUI.runThreadId input
  runId = AGUI.runId input
  refresh seen
    | null delta = pure ()
    | otherwise =
        complete (journaledModel runId journal model) (watcherPrompt (watcherRollingSummary seen) delta)
          >>= applyDecision seen . flip parseDecision (watcherRollingSummary seen)
   where
    delta = filter (not . injected) (drop (watcherLastSeen seen) messages)
  injected message = markedWith briefingMarker message || markedWith candidatesMarker message
  applyDecision seen decision =
    traverse_ memorize (decisionMemorize decision)
      *> traverse_ invalidate (decisionInvalidate decision)
      *> seek
   where
    memorize (Memorandum content kind _) = factAdd facts content kind runId
    invalidate (Invalidation content _) = void (factInvalidate facts content)
    round' = watcherRound seen + 1
    base =
      seen
        { watcherRollingSummary = decisionSummary decision,
          watcherLastSeen = length messages,
          watcherRound = round',
          watcherCooldowns = Map.filter (> round') (watcherCooldowns seen)
        }
    seek = case decisionRetrieve decision of
      Nothing -> commit base Nothing
      Just (Retrieval query _)
        | spent >= retrievalRunBudget || cooling query -> commit base Nothing
        | otherwise ->
            factSearch facts query >>= commit (spend query base) . Just
    spent = Map.findWithDefault 0 runId (watcherSpent seen)
    cooling query =
      maybe False (watcherRound seen <) (Map.lookup (queryHash query) (watcherCooldowns seen))
    spend query watcher =
      watcher
        { watcherSpent = Map.insert runId (spent + 1) (watcherSpent watcher),
          watcherCooldowns =
            Map.insert (queryHash query) (round' + cooldownRounds) (watcherCooldowns watcher)
        }
    commit watcher hits =
      recordMaybe (subJournal runId <$> journal) (StoreFactsEntry (toJSON hits))
        *> modifyIORef' state (insertWatcher threadId watcher . maybe id (insertCandidates runId) hits)

markedWith :: Text -> ChatMessage -> Bool
markedWith marker (ChatSystem text) = marker `Text.isInfixOf` text
markedWith _ _ = False

queryHash :: Text -> Text
queryHash = renderHash . fnv1a64

insertWatcher :: Text -> WatcherState -> MemoryState -> MemoryState
insertWatcher threadId seen state = state {memoryWatchers = Map.insert threadId seen (memoryWatchers state)}

closeEpisode :: ThreadStore -> IORef MemoryState -> AGUI.RunAgentInput -> IO ()
closeEpisode store state input =
  readIORef state >>= traverse_ save . Map.lookup threadId . memoryWatchers
 where
  threadId = AGUI.runThreadId input
  save seen =
    getPOSIXTime
      >>= threadSaveEpisode store threadId . Episode (AGUI.runId input) (watcherRollingSummary seen) . round

injectBriefing :: ThreadStore -> Maybe Journal -> IORef MemoryState -> AGUI.RunAgentInput -> [ChatMessage] -> IO [ChatMessage]
injectBriefing store journal state input messages
  | any (markedWith briefingMarker) messages = pure messages
  | otherwise = cached >>= maybe (pure messages) (pure . (: messages) . ChatSystem)
 where
  runId = AGUI.runId input
  cached = readIORef state >>= maybe render pure . Map.lookup runId . memoryBriefings
  render = threadBrief store (AGUI.runThreadId input) >>= renderBrief
  renderBrief brief =
    let rendered = renderBriefing <$> (brief >>= inhabited)
     in recordMaybe (subJournal runId <$> journal) (StoreBriefEntry (toJSON brief))
          *> modifyIORef' state (insertBriefing runId rendered)
          $> rendered

insertBriefing :: Text -> Maybe Text -> MemoryState -> MemoryState
insertBriefing runId rendered state = state {memoryBriefings = Map.insert runId rendered (memoryBriefings state)}

injectCandidates :: FactStore -> IORef MemoryState -> AGUI.RunAgentInput -> [ChatMessage] -> IO [ChatMessage]
injectCandidates facts state input messages
  | any (markedWith candidatesMarker) messages = pure messages
  | otherwise =
      readIORef state
        >>= maybe (pure messages) materialize . Map.lookup (AGUI.runId input) . memoryCandidates
 where
  materialize hits = case renderCandidates hits of
    ([], _) -> pure messages
    (included, block) ->
      factTouch facts included $> slotAfterBriefing (ChatSystem block) messages

slotAfterBriefing :: ChatMessage -> [ChatMessage] -> [ChatMessage]
slotAfterBriefing slot messages = case messages of
  (first : rest) | markedWith briefingMarker first -> first : slot : rest
  _ -> slot : messages

renderCandidates :: [Fact] -> ([Fact], Text)
renderCandidates hits = (included, render included)
 where
  included = foldl' pick [] hits
  pick chosen fact =
    bool chosen candidate (Text.length (render candidate) <= candidatesCap)
   where
    candidate = chosen <> [fact]
  render facts = Text.intercalate "\n" (candidatesMarker : fmap candidateLine facts)

candidateLine :: Fact -> Text
candidateLine fact = "- " <> factKindName (factKind fact) <> ": " <> factContent fact

insertCandidates :: Text -> [Fact] -> MemoryState -> MemoryState
insertCandidates runId hits state =
  state {memoryCandidates = Map.insert runId hits (memoryCandidates state)}

clearRunState :: IORef MemoryState -> AGUI.RunAgentInput -> IO ()
clearRunState state input =
  modifyIORef' state $ \memory ->
    memory
      { memoryWatchers = Map.adjust clearBudget (AGUI.runThreadId input) (memoryWatchers memory),
        memoryBriefings = Map.delete runId (memoryBriefings memory),
        memoryCandidates = Map.delete runId (memoryCandidates memory)
      }
 where
  runId = AGUI.runId input
  clearBudget watcher = watcher {watcherSpent = Map.delete runId (watcherSpent watcher)}

memoryTransientCounts :: IORef MemoryState -> IO (Int, Int, Int, Int)
memoryTransientCounts = fmap counts . readIORef
 where
  counts =
    (,,,)
      <$> Map.size . memoryBriefings
      <*> Map.size . memoryCandidates
      <*> sum . fmap (Map.size . watcherSpent) . Map.elems . memoryWatchers
      <*> sum . fmap (Map.size . watcherCooldowns) . Map.elems . memoryWatchers

inhabited :: ThreadBrief -> Maybe ThreadBrief
inhabited brief = bool (Just brief) Nothing (Text.null (briefRollingSummary brief) && null (briefEpisodes brief))

renderBriefing :: ThreadBrief -> Text
renderBriefing brief =
  Text.intercalate
    "\n"
    ( [briefingMarker]
        <> ["summary: " <> summary | not (Text.null summary)]
        <> fmap episodeLine recent
        <> maybe [] (pure . asOfLine) asOf
    )
 where
  summary = Text.take briefingSummaryCap (briefRollingSummary brief)
  recent = reverse (take briefingEpisodeCount (reverse (briefEpisodes brief)))
  asOf = listToMaybe (reverse (briefEpisodes brief))
  episodeLine (Episode _ text time) =
    "episode " <> iso8601 (posixSecondsToUTCTime (fromIntegral time)) <> ": " <> text
  asOfLine (Episode _ _ time) =
    "as of " <> iso8601 (posixSecondsToUTCTime (fromIntegral time))

iso8601 :: UTCTime -> Text
iso8601 = Text.pack . iso8601Show

complete :: Model -> [ChatMessage] -> IO Text
complete model messages =
  newIORef "" >>= run
 where
  run text = streamModel model (ModelRequest messages []) (gather text) *> readIORef text
  gather text = \case
    ModelTextDelta delta -> modifyIORef' text (<> delta)
    _ -> pure ()

journaledModel :: Text -> Maybe Journal -> Model -> Model
journaledModel runId journal model = maybe model wrap scoped
 where
  scoped = subJournal "memory" . subJournal runId <$> journal
  wrap watched =
    model
      { streamModel = \request emit ->
          record (ModelRequestEntry request)
            *> streamModel model request (\event -> record (ModelEventEntry event) *> emit event)
            >>= finish
      }
   where
    record = recordMaybe (Just watched)
    finish reason = record (ModelFinishEntry reason) $> reason

watcherPrompt :: Text -> [ChatMessage] -> [ChatMessage]
watcherPrompt previous delta =
  [ ChatSystem instruction,
    ChatUser
      ( "previous summary:\n"
          <> bool previous "(none)" (Text.null previous)
          <> "\n\nnew messages:\n"
          <> renderMessages delta
      )
  ]

instruction :: Text
instruction =
  "You maintain the memory of a conversation thread. \
  \Reply with one JSON object and nothing else: \
  \{\"summary\": string, \"memorize\": [{\"content\": string, \"kind\": \"user\"|\"project\"|\"preference\"|\"decision\", \"reason\": string}], \"retrieve\": {\"query\": string, \"reason\": string} or null, \"invalidate\": [{\"content\": string, \"reason\": string}]}. \
  \summary: merge the new messages into the previous summary; keep decisions, facts and open questions; drop noise. \
  \memorize: durable facts worth recalling in later runs, each with its reason; empty when nothing qualifies. \
  \retrieve: a query for long-term facts the conversation now needs, with its reason; null by default. \
  \invalidate: the exact content of an old fact overturned by newer information, each with its reason; empty by default."

data WatcherDecision = WatcherDecision
  { decisionSummary :: Text,
    decisionMemorize :: [Memorandum],
    decisionRetrieve :: Maybe Retrieval,
    decisionInvalidate :: [Invalidation]
  }

data Memorandum = Memorandum Text FactKind Text

data Retrieval = Retrieval Text Text

data Invalidation = Invalidation Text Text

instance FromJSON Memorandum where
  parseJSON = withObject "Memorandum" $ \fields ->
    Memorandum <$> fields .: "content" <*> fields .: "kind" <*> fields .: "reason"

instance FromJSON Retrieval where
  parseJSON = withObject "Retrieval" $ \fields ->
    Retrieval <$> fields .: "query" <*> fields .: "reason"

instance FromJSON Invalidation where
  parseJSON = withObject "Invalidation" $ \fields ->
    Invalidation <$> fields .: "content" <*> fields .: "reason"

parseDecision :: Text -> Text -> WatcherDecision
parseDecision raw previous = maybe unparsed structured decoded
 where
  decoded = decode (LazyByteString.fromStrict (TextEncoding.encodeUtf8 raw)) :: Maybe Value
  structured value =
    WatcherDecision
      (fromMaybe previous (parseMaybe (withObject "decision" (.: "summary")) value))
      (maybe [] (mapMaybe (parseMaybe parseJSON)) memoranda)
      (fromMaybe Nothing (parseMaybe (withObject "decision" (.:? "retrieve")) value))
      (maybe [] (mapMaybe (parseMaybe parseJSON)) invalidations)
   where
    memoranda = parseMaybe (withObject "decision" (.: "memorize")) value :: Maybe [Value]
    invalidations = parseMaybe (withObject "decision" (.: "invalidate")) value :: Maybe [Value]
  unparsed = WatcherDecision fallback [] Nothing []
   where
    stripped = Text.strip raw
    fallback = bool previous raw (not (Text.null stripped) && not ("{" `Text.isPrefixOf` stripped))

renderMessages :: [ChatMessage] -> Text
renderMessages = Text.intercalate "\n" . fmap renderMessage

renderMessage :: ChatMessage -> Text
renderMessage = \case
  ChatSystem text -> "system: " <> text
  ChatUser text -> "user: " <> text
  ChatAssistant turn ->
    "assistant: "
      <> fromMaybe "" (turnText turn)
      <> Text.concat (map (\call -> " [tool: " <> modelToolName call <> "]") (turnToolCalls turn))
  ChatToolResult _ content -> "tool: " <> content

insulate :: IO () -> IO ()
insulate = shield ()

shield :: a -> IO a -> IO a
shield fallback action =
  attempt action >>= either recover pure
 where
  attempt :: IO a -> IO (Either SomeException a)
  attempt = try
  recover exception =
    maybe (pure fallback) throwIO (fromException exception :: Maybe SomeAsyncException)

newThreadStore :: FilePath -> IO ThreadStore
newThreadStore dir =
  createDirectoryIfMissing True (threadsPath dir)
    *> newMVar ()
    <&> flip ThreadStore (readBrief dir) . save
 where
  save lock threadId episode =
    withMVar lock (const (persist dir threadId episode))

persist :: FilePath -> Text -> Episode -> IO ()
persist dir threadId episode =
  readBrief dir threadId
    >>= atomicEncodeFile (threadPath dir threadId) . extendBrief episode . fromMaybe emptyBrief

readBrief :: FilePath -> Text -> IO (Maybe ThreadBrief)
readBrief dir threadId =
  fromRight Nothing
    <$> (try (decodeFileStrict (threadPath dir threadId)) :: IO (Either IOException (Maybe ThreadBrief)))

newMemoryThreadStore :: IO ThreadStore
newMemoryThreadStore =
  newIORef Map.empty
    <&> liftA2 ThreadStore save brief
 where
  save threads threadId episode =
    modifyIORef' threads (Map.alter (Just . extendBrief episode . fromMaybe emptyBrief) threadId)
  brief threads threadId = Map.lookup threadId <$> readIORef threads

extendBrief :: Episode -> ThreadBrief -> ThreadBrief
extendBrief episode current =
  ThreadBrief
    (episodeSummary episode)
    (takeEnd episodeRetention (briefEpisodes current <> [episode]))

episodeRetention :: Int
episodeRetention = 64

takeEnd :: Int -> [value] -> [value]
takeEnd count values = drop (length values - count) values

emptyBrief :: ThreadBrief
emptyBrief = ThreadBrief "" []

threadsPath :: FilePath -> FilePath
threadsPath dir = dir ++ "/threads"

threadPath :: FilePath -> Text -> FilePath
threadPath dir threadId = threadsPath dir ++ "/" ++ Text.unpack (sanitizeThreadId threadId) ++ ".json"

sanitizeThreadId :: Text -> Text
sanitizeThreadId raw = bool cleaned "thread" (Text.null cleaned)
 where
  cleaned = Text.map safe raw
  safe char
    | Char.isAsciiLower char || Char.isAsciiUpper char || Char.isDigit char || char == '-' || char == '_' || char == '.' = char
    | otherwise = '-'

readOnlyThreadStore :: ThreadStore -> ThreadStore
readOnlyThreadStore store = store {threadSaveEpisode = \_ _ -> pure ()}

seedWatcher :: Text -> WatcherState -> IORef MemoryState -> IO ()
seedWatcher threadId watcher state = modifyIORef' state (insertWatcher threadId watcher)
