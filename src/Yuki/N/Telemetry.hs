module Yuki.N.Telemetry
  ( ActivityFrame (..),
    ActiveTool (..),
    ContextSnapshot (..),
    DeliveryKind (..),
    DeliveryRecord (..),
    FsChangeOp (..),
    FsChangeOrigin (..),
    FsChangeRecord (..),
    Ledger (..),
    LiveStatus (..),
    RunPhase (..),
    Telemetry,
    liveRuns,
    newTelemetry,
    newTelemetryWithClock,
    noteCancelling,
    noteEvent,
    publish,
    seconds,
    subscribe,
    telemetryClock,
    telemetryDiffBytes,
    telemetryLedger,
    telemetryRunStarting,
    telemetryRunStopping,
  )
where

import Control.Concurrent (Chan, dupChan, newChan, writeChan)
import Control.Concurrent.MVar (MVar)
import Control.Monad (when)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Bool (bool)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Yuki.N.AGUI.Event (Event (..))
import Yuki.N.Dispatch.Types (DispatchDraft)
import Yuki.N.Runs

data RunPhase
  = PhaseRunning
  | PhaseAwaitingTool
  | PhaseCompacting
  | PhaseSleeping
  | PhaseCancelling
  deriving stock (Eq, Show)

instance ToJSON RunPhase where
  toJSON =
    String . \case
      PhaseRunning -> "running"
      PhaseAwaitingTool -> "awaiting-tool"
      PhaseCompacting -> "compacting"
      PhaseSleeping -> "sleeping"
      PhaseCancelling -> "cancelling"

data ActiveTool = ActiveTool
  { activeCallId :: Text,
    activeToolName :: Text,
    activeToolAt :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON ActiveTool where
  toJSON tool =
    object ["callId" .= activeCallId tool, "name" .= activeToolName tool, "startedAt" .= activeToolAt tool]

data ContextSnapshot = ContextSnapshot
  { contextEstimated :: Int,
    contextBudget :: Int,
    contextWindow :: Int
  }
  deriving stock (Eq, Show)

instance ToJSON ContextSnapshot where
  toJSON snapshot =
    object
      [ "estimatedTokens" .= contextEstimated snapshot,
        "budgetTokens" .= contextBudget snapshot,
        "windowTokens" .= contextWindow snapshot
      ]

data DeliveryKind
  = DeliveryAnswer
  | DeliveryArtifact
  | DeliveryFileWrite
  deriving stock (Eq, Show)

instance ToJSON DeliveryKind where
  toJSON =
    String . \case
      DeliveryAnswer -> "answer"
      DeliveryArtifact -> "artifact"
      DeliveryFileWrite -> "file_write"

instance FromJSON DeliveryKind where
  parseJSON = withText "DeliveryKind" $ \case
    "answer" -> pure DeliveryAnswer
    "artifact" -> pure DeliveryArtifact
    "file_write" -> pure DeliveryFileWrite
    other -> fail ("unknown delivery kind: " <> Text.unpack other)

data DeliveryRecord = DeliveryRecord
  { deliveryId :: Text,
    deliveryRunId :: Text,
    deliveryThreadId :: Text,
    deliveryIncarnation :: Text,
    deliveryRunKind :: RunKind,
    deliveryKind :: DeliveryKind,
    deliveryTitle :: Text,
    deliveryRef :: Text,
    deliveryBytes :: Maybe Int,
    deliveryAt :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON DeliveryRecord where
  toJSON record =
    object
      [ "id" .= deliveryId record,
        "runId" .= deliveryRunId record,
        "threadId" .= deliveryThreadId record,
        "incarnationId" .= deliveryIncarnation record,
        "runKind" .= deliveryRunKind record,
        "kind" .= deliveryKind record,
        "title" .= deliveryTitle record,
        "ref" .= deliveryRef record,
        "bytes" .= deliveryBytes record,
        "at" .= deliveryAt record
      ]

instance FromJSON DeliveryRecord where
  parseJSON = withObject "DeliveryRecord" $ \fields ->
    DeliveryRecord
      <$> fields .: "id"
      <*> fields .: "runId"
      <*> fields .: "threadId"
      <*> fields .: "incarnationId"
      <*> fields .: "runKind"
      <*> fields .: "kind"
      <*> fields .: "title"
      <*> fields .: "ref"
      <*> fields .:? "bytes"
      <*> fields .: "at"

data FsChangeOp
  = FsCreated
  | FsModified
  | FsDeleted
  deriving stock (Eq, Ord, Show)

instance ToJSON FsChangeOp where
  toJSON =
    String . \case
      FsCreated -> "created"
      FsModified -> "modified"
      FsDeleted -> "deleted"

instance FromJSON FsChangeOp where
  parseJSON = withText "FsChangeOp" $ \case
    "created" -> pure FsCreated
    "modified" -> pure FsModified
    "deleted" -> pure FsDeleted
    other -> fail ("unknown fs change op: " <> Text.unpack other)

data FsChangeOrigin
  = OriginTool {toolName :: Text, callId :: Text}
  | OriginGit
  deriving stock (Eq, Ord, Show)

instance ToJSON FsChangeOrigin where
  toJSON (OriginTool name call) = object ["kind" .= ("tool" :: Text), "toolName" .= name, "callId" .= call]
  toJSON OriginGit = object ["kind" .= ("git" :: Text)]

instance FromJSON FsChangeOrigin where
  parseJSON = withObject "FsChangeOrigin" $ \fields ->
    fields .: "kind" >>= parseOrigin fields
   where
    parseOrigin fields "tool" = OriginTool <$> fields .: "toolName" <*> fields .: "callId"
    parseOrigin _ "git" = pure OriginGit
    parseOrigin _ other = fail ("unknown fs change origin: " <> Text.unpack other)

data FsChangeRecord = FsChangeRecord
  { fsChangeId :: Text,
    fsChangeRunId :: Text,
    fsChangeThreadId :: Text,
    fsChangeIncarnation :: Text,
    fsChangePath :: Text,
    fsChangeOp :: FsChangeOp,
    fsChangeOrigin :: FsChangeOrigin,
    fsChangeDiff :: Maybe Text,
    fsChangeStat :: Maybe Text,
    fsChangeAt :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON FsChangeRecord where
  toJSON record =
    object
      [ "id" .= fsChangeId record,
        "runId" .= fsChangeRunId record,
        "threadId" .= fsChangeThreadId record,
        "incarnationId" .= fsChangeIncarnation record,
        "path" .= fsChangePath record,
        "op" .= fsChangeOp record,
        "origin" .= fsChangeOrigin record,
        "diff" .= fsChangeDiff record,
        "stat" .= fsChangeStat record,
        "at" .= fsChangeAt record
      ]

instance FromJSON FsChangeRecord where
  parseJSON = withObject "FsChangeRecord" $ \fields ->
    FsChangeRecord
      <$> fields .: "id"
      <*> fields .: "runId"
      <*> fields .: "threadId"
      <*> fields .: "incarnationId"
      <*> fields .: "path"
      <*> fields .: "op"
      <*> fields .: "origin"
      <*> fields .:? "diff"
      <*> fields .:? "stat"
      <*> fields .: "at"

data Ledger = Ledger
  { ledgerDeliveriesFile :: FilePath,
    ledgerFsChangesFile :: FilePath,
    ledgerLock :: MVar ()
  }

data LiveStatus = LiveStatus
  { liveRunId :: Text,
    liveThreadId :: Text,
    liveIncarnation :: Text,
    liveParent :: Maybe Text,
    liveKind :: RunKind,
    livePhase :: RunPhase,
    liveObjective :: Maybe Text,
    liveStartedAt :: Integer,
    liveLastEventAt :: Integer,
    liveTurn :: Int,
    liveMaxTurns :: Int,
    liveModel :: Text,
    liveUsagePrompt :: Int,
    liveUsageCompletion :: Int,
    liveContext :: Maybe ContextSnapshot,
    liveActiveTools :: [ActiveTool],
    liveWorkers :: Int,
    liveLastActivity :: Maybe Text
  }
  deriving stock (Eq, Show)

instance ToJSON LiveStatus where
  toJSON status =
    object
      [ "runId" .= liveRunId status,
        "threadId" .= liveThreadId status,
        "incarnationId" .= liveIncarnation status,
        "parentRunId" .= liveParent status,
        "kind" .= kindName (liveKind status),
        "phase" .= livePhase status,
        "objective" .= liveObjective status,
        "startedAt" .= liveStartedAt status,
        "lastEventAt" .= liveLastEventAt status,
        "turn" .= liveTurn status,
        "maxTurns" .= liveMaxTurns status,
        "model" .= liveModel status,
        "usage"
          .= object
            [ "promptTokens" .= liveUsagePrompt status,
              "completionTokens" .= liveUsageCompletion status
            ],
        "context" .= liveContext status,
        "activeTools" .= liveActiveTools status,
        "workers" .= liveWorkers status,
        "lastActivity" .= liveLastActivity status
      ]

data ActivityFrame
  = FrameStatus LiveStatus
  | FrameRunEnd Text Text
  | FrameDelivery DeliveryRecord
  | FrameFsChange FsChangeRecord
  | FrameDraft DispatchDraft
  | FrameDraftResolved Text Text (Maybe Text)
  | FramePing
  deriving stock (Eq, Show)

instance ToJSON ActivityFrame where
  toJSON (FrameStatus status) = object ["frame" .= ("status" :: Text), "status" .= status]
  toJSON (FrameRunEnd runId outcome) =
    object ["frame" .= ("run.end" :: Text), "runId" .= runId, "outcome" .= outcome]
  toJSON (FrameDelivery record) = object ["frame" .= ("delivery" :: Text), "delivery" .= record]
  toJSON (FrameFsChange record) = object ["frame" .= ("fschange" :: Text), "fschange" .= record]
  toJSON (FrameDraft draft) = object ["frame" .= ("draft" :: Text), "draft" .= draft]
  toJSON (FrameDraftResolved identifier status threadId) =
    object ["frame" .= ("draft.resolved" :: Text), "dispatchId" .= identifier, "status" .= status, "threadId" .= threadId]
  toJSON FramePing = object ["frame" .= ("ping" :: Text)]

data Telemetry = Telemetry
  { telemetryLive :: IORef (Map Text LiveStatus),
    telemetryHub :: Chan ActivityFrame,
    telemetryPublished :: IORef (Map Text Integer),
    telemetryLedger :: IORef (Maybe Ledger),
    telemetryDiffBytes :: Int,
    telemetryClock :: IO Integer
  }

newTelemetry :: Int -> IO Telemetry
newTelemetry diffBytes = newTelemetryWithClock diffBytes clockMicros

newTelemetryWithClock :: Int -> IO Integer -> IO Telemetry
newTelemetryWithClock diffBytes clock =
  Telemetry <$> newIORef Map.empty <*> newChan <*> newIORef Map.empty <*> newIORef Nothing <*> pure diffBytes <*> pure clock

clockMicros :: IO Integer
clockMicros = round . (* 1000000) <$> getPOSIXTime

seconds :: Integer -> Integer
seconds micros = micros `div` 1000000

subscribe :: Telemetry -> IO (Chan ActivityFrame)
subscribe = dupChan . telemetryHub

publish :: Telemetry -> ActivityFrame -> IO ()
publish telemetry = writeChan (telemetryHub telemetry)

liveRuns :: Telemetry -> IO [LiveStatus]
liveRuns telemetry = Map.elems <$> readIORef (telemetryLive telemetry)

telemetryRunStarting :: Telemetry -> Text -> RunDescriptor -> Int -> Text -> IO ()
telemetryRunStarting telemetry runId descriptor maxTurns model =
  telemetryClock telemetry >>= startAt
 where
  startAt now =
    atomicModifyIORef' (telemetryLive telemetry) (\live -> (Map.insert runId (fresh (seconds now)) (bump 1 descriptor live), ()))
      *> forceStatus telemetry runId now
  fresh startedAt =
    LiveStatus
      runId
      (descriptorTaskId descriptor)
      (descriptorIncarnation descriptor)
      (descriptorParent descriptor)
      (descriptorKind descriptor)
      PhaseRunning
      (descriptorObjective descriptor)
      startedAt
      startedAt
      0
      maxTurns
      model
      0
      0
      Nothing
      []
      0
      Nothing
  bump delta child = maybe id (\parent -> Map.adjust (workers delta) parent) (descriptorParent child)
  workers delta status = status {liveWorkers = max 0 (liveWorkers status + delta)}

telemetryRunStopping :: Telemetry -> Text -> IO ()
telemetryRunStopping telemetry runId = finalize telemetry runId "failed"

noteCancelling :: Telemetry -> Text -> IO ()
noteCancelling telemetry runId =
  telemetryClock telemetry >>= cancelAt
 where
  cancelAt now =
    mutate telemetry runId (\status -> status {livePhase = PhaseCancelling, liveLastActivity = Just "cancelling"})
      *> forceStatus telemetry runId now

noteEvent :: Telemetry -> Text -> Event -> IO ()
noteEvent telemetry runId event =
  telemetryClock telemetry >>= noteAt
 where
  noteAt now = maybe (project now) (finalize telemetry runId) (terminalOutcome event)
  project now =
    mutate telemetry runId (apply now event) *> throttled telemetry runId now

terminalOutcome :: Event -> Maybe Text
terminalOutcome = \case
  RunFinished {} -> Just "completed"
  RunError {} -> Just "failed"
  Custom "run.cancelled" _ -> Just "cancelled"
  _ -> Nothing

apply :: Integer -> Event -> LiveStatus -> LiveStatus
apply micros event status =
  touched (step status)
 where
  now = seconds micros
  touched next = next {liveLastEventAt = now}
  step = case event of
    StepStarted _ ->
      \current ->
        current
          { livePhase = PhaseRunning,
            liveTurn = liveTurn current + 1,
            liveLastActivity = Just "step"
          }
    ToolCallStarted callId name _ ->
      \current ->
        current
          { livePhase = PhaseAwaitingTool,
            liveActiveTools = ActiveTool callId name now : liveActiveTools current,
            liveLastActivity = Just ("tool:" <> name)
          }
    ToolCallEnded callId -> settle callId
    ToolCallResult _ callId _ -> settle callId
    TextMessageStarted _ -> \current -> current {livePhase = PhaseRunning}
    ReasoningStarted _ -> \current -> current {livePhase = PhaseRunning}
    Custom "context.status" value ->
      \current -> maybe current (\snapshot -> current {liveContext = Just snapshot}) (parseSnapshot value)
    Custom "context.compact" _ ->
      \current -> current {livePhase = PhaseCompacting, liveLastActivity = Just "context.compact"}
    Custom "context.sleep" _ ->
      \current -> current {livePhase = PhaseSleeping, liveLastActivity = Just "context.sleep"}
    Custom "usage" value ->
      \current -> maybe current (credit current) (parseUsage value)
    _ -> id
  settle callId current =
    let remaining = filter ((/= callId) . activeCallId) (liveActiveTools current)
     in current
          { liveActiveTools = remaining,
            livePhase = bool PhaseAwaitingTool PhaseRunning (null remaining)
          }
  credit current (prompt, completion) =
    current
      { liveUsagePrompt = liveUsagePrompt current + prompt,
        liveUsageCompletion = liveUsageCompletion current + completion
      }

parseSnapshot :: Value -> Maybe ContextSnapshot
parseSnapshot =
  parseMaybe $
    withObject "context.status" $ \fields ->
      ContextSnapshot
        <$> fields .: "tokens"
        <*> fields .: "budgetTokens"
        <*> fields .: "windowTokens"

parseUsage :: Value -> Maybe (Int, Int)
parseUsage =
  parseMaybe $
    withObject "usage" $ \fields ->
      liftA2
        (,)
        (fromMaybe 0 <$> fields .: "promptTokens")
        (fromMaybe 0 <$> fields .: "completionTokens")

mutate :: Telemetry -> Text -> (LiveStatus -> LiveStatus) -> IO ()
mutate telemetry runId change =
  atomicModifyIORef' (telemetryLive telemetry) (\live -> (Map.adjust change runId live, ()))

finalize :: Telemetry -> Text -> Text -> IO ()
finalize telemetry runId outcome =
  atomicModifyIORef' (telemetryLive telemetry) (\live -> (Map.delete runId live, Map.lookup runId live)) >>= finish
 where
  finish existed =
    when (isJust existed) (adjustParent existed *> cleanup *> publish telemetry (FrameRunEnd runId outcome))
  adjustParent =
    maybe (pure ()) (\parent -> atomicModifyIORef' (telemetryLive telemetry) (\live -> (Map.adjust discount parent live, ())))
      . (liveParent =<<)
  discount status = status {liveWorkers = max 0 (liveWorkers status - 1)}
  cleanup = atomicModifyIORef' (telemetryPublished telemetry) (\published -> (Map.delete runId published, ()))

throttleMicros :: Integer
throttleMicros = 200000

throttled :: Telemetry -> Text -> Integer -> IO ()
throttled telemetry runId now =
  readIORef (telemetryPublished telemetry) >>= publishIfDue
 where
  publishIfDue published =
    when (maybe True (\lastSeen -> now - lastSeen >= throttleMicros) (Map.lookup runId published)) (forceStatus telemetry runId now)

forceStatus :: Telemetry -> Text -> Integer -> IO ()
forceStatus telemetry runId now =
  readIORef (telemetryLive telemetry) >>= publishStatus
 where
  publishStatus live =
    maybe (pure ()) (\status -> publish telemetry (FrameStatus status)) (Map.lookup runId live)
      *> atomicModifyIORef' (telemetryPublished telemetry) (\published -> (Map.insert runId now published, ()))
