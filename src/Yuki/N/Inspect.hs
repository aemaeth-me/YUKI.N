module Yuki.N.Inspect
  ( Inspection (..),
    RunSummary (..),
    UsageSum (..),
    emptyInspection,
    forRun,
    newInspection,
    runIds,
    runSummary,
    withCognition,
    withLiveJournal,
    withSessionService,
  )
where

import Data.Aeson (ToJSON (..), Value, object, withObject, (.:?), (.=))
import Data.Aeson.Types (Parser, parseMaybe, (.!=))
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Yuki.N.AGUI.Event (Event (..))
import qualified Yuki.N.AGUI.Types as AGUI
import Yuki.N.Artifact (ArtifactStore)
import Yuki.N.Cognition (Cognition)
import Yuki.N.Facts (FactStore)
import Yuki.N.Journal (Entry (..), EntryKind (..), Journal)
import Yuki.N.Memory (ThreadStore)
import Yuki.N.Sessions (SessionService)
import Yuki.N.Transcript (TranscriptStore)

data Inspection = Inspection
  { inspectionMemory :: Maybe (ThreadStore, FactStore),
    inspectionArtifacts :: Maybe ArtifactStore,
    inspectionJournal :: Maybe FilePath,
    inspectionLiveJournal :: Maybe Journal,
    inspectionTranscripts :: Maybe TranscriptStore,
    inspectionSessions :: Maybe SessionService,
    inspectionCognition :: Maybe Cognition
  }

newInspection :: Maybe (ThreadStore, FactStore) -> Maybe ArtifactStore -> Maybe FilePath -> Maybe TranscriptStore -> Inspection
newInspection memory artifacts journal transcripts = Inspection memory artifacts journal Nothing transcripts Nothing Nothing

emptyInspection :: Inspection
emptyInspection = Inspection Nothing Nothing Nothing Nothing Nothing Nothing Nothing

withLiveJournal :: Journal -> Inspection -> Inspection
withLiveJournal journal inspection = inspection {inspectionLiveJournal = Just journal}

withSessionService :: SessionService -> Inspection -> Inspection
withSessionService sessions inspection = inspection {inspectionSessions = Just sessions}

withCognition :: Cognition -> Inspection -> Inspection
withCognition cognition inspection = inspection {inspectionCognition = Just cognition}

runIds :: [Entry] -> [Text]
runIds entries = [AGUI.runId input | Entry _ scope _ (RunBegin input _) <- entries, length scope == 1]

forRun :: Maybe Text -> [Entry] -> [Entry]
forRun Nothing = id
forRun (Just runId) = filter ((== Just runId) . listToMaybe . entryScope)

data UsageSum = UsageSum
  { usagePrompt :: Int,
    usageCompletion :: Int,
    usageCacheHit :: Int
  }
  deriving stock (Eq, Show)

instance Semigroup UsageSum where
  UsageSum prompt completion hit <> UsageSum prompt' completion' hit' =
    UsageSum (prompt + prompt') (completion + completion') (hit + hit')

instance Monoid UsageSum where
  mempty = UsageSum 0 0 0

instance ToJSON UsageSum where
  toJSON (UsageSum prompt completion hit) =
    object ["prompt" .= prompt, "completion" .= completion, "cacheHit" .= hit]

data RunSummary = RunSummary
  { summaryRunId :: Text,
    summaryThreadId :: Text,
    summaryEntryCount :: Int,
    summaryTurns :: Int,
    summaryToolCalls :: Int,
    summaryAgentEvents :: Int,
    summaryApiRequests :: Int,
    summaryUsage :: UsageSum,
    summaryMemoryCalls :: Int,
    summaryStatus :: Text,
    summaryFirstSeq :: Int,
    summaryLastSeq :: Int,
    summaryFirstTime :: Maybe Integer,
    summaryLastTime :: Maybe Integer
  }
  deriving stock (Eq, Show)

instance ToJSON RunSummary where
  toJSON summary =
    object
      [ "runId" .= summaryRunId summary,
        "threadId" .= summaryThreadId summary,
        "entryCount" .= summaryEntryCount summary,
        "turns" .= summaryTurns summary,
        "toolCalls" .= summaryToolCalls summary,
        "agentEvents" .= summaryAgentEvents summary,
        "apiRequests" .= summaryApiRequests summary,
        "usage" .= summaryUsage summary,
        "memoryCalls" .= summaryMemoryCalls summary,
        "status" .= summaryStatus summary,
        "firstSeq" .= summaryFirstSeq summary,
        "lastSeq" .= summaryLastSeq summary,
        "firstTime" .= summaryFirstTime summary,
        "lastTime" .= summaryLastTime summary
      ]

runSummary :: Text -> [Entry] -> Maybe RunSummary
runSummary runId entries = summarize <$> listToMaybe begins
  where
    scoped = filter ((== Just runId) . listToMaybe . entryScope) entries
    begins = [input | Entry _ scope _ (RunBegin input _) <- scoped, length scope == 1]
    events = [event | Entry _ _ _ (AgentEventEntry event) <- scoped]
    firstEntry = listToMaybe scoped
    lastEntry = listToMaybe (reverse scoped)
    ofKind predicate = length (filter (predicate . entryKind) scoped)
    summarize input =
      RunSummary
        { summaryRunId = runId,
          summaryThreadId = AGUI.runThreadId input,
          summaryEntryCount = length scoped,
          summaryTurns = ofKind isModelRequest,
          summaryToolCalls = ofKind isToolCall,
          summaryAgentEvents = length events,
          summaryApiRequests = ofKind isApiRequest,
          summaryUsage = foldMap usageOf scoped,
          summaryMemoryCalls = length (filter (elem "memory" . entryScope) scoped),
          summaryStatus = statusOf events,
          summaryFirstSeq = maybe 0 entrySeq firstEntry,
          summaryLastSeq = maybe 0 entrySeq lastEntry,
          summaryFirstTime = firstEntry >>= entryTime,
          summaryLastTime = lastEntry >>= entryTime
        }
    isModelRequest (ModelRequestEntry _) = True
    isModelRequest _ = False
    isToolCall (ToolCallEntry {}) = True
    isToolCall _ = False
    isApiRequest (ApiRequestEntry _) = True
    isApiRequest _ = False

usageOf :: Entry -> UsageSum
usageOf = maybe mempty id . usageValue . entryKind
  where
    usageValue (AgentEventEntry (Custom "usage" value)) = parseMaybe usageParser value
    usageValue _ = Nothing
    usageParser :: Value -> Parser UsageSum
    usageParser =
      withObject "usage" $ \fields ->
        UsageSum
          <$> fields .:? "promptTokens" .!= 0
          <*> fields .:? "completionTokens" .!= 0
          <*> fields .:? "cacheHitTokens" .!= 0

statusOf :: [Event] -> Text
statusOf events
  | any isFinished events = "finished"
  | any isError events = "error"
  | otherwise = "open"
  where
    isFinished RunFinished {} = True
    isFinished _ = False
    isError RunError {} = True
    isError _ = False
