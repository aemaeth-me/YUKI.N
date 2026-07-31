module Yuki.N.Memory.Working
  ( FocusFrame (..),
    FocusStatus (..),
    ForgetDecision (..),
    SleepCycle (..),
    SleepCycleStatus (..),
    SleepTrigger (..),
    WakePacket (..),
    WorkingMemoryCheckpoint (..),
    WorkingMemoryHead (..),
    WorkingStatus (..),
    WorkingStore (..),
    wakePacketMarker,
    newMemoryWorkingStore,
    newWorkingStore,
  )
where

import Control.Concurrent.MVar
import Control.Exception (IOException, displayException, try)
import Control.Monad ((>=>))
import Data.Aeson
import Data.Bool (bool)
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import Yuki.N.AtomicFile (atomicEncodeFile)
import Yuki.N.Experience (ExperienceCursor (..))

wakePacketMarker :: Text
wakePacketMarker = "[wake packet — derived working memory]"

data WorkingStatus
  = WorkingAwake
  | WorkingQuiescing
  | WorkingAsleep
  | WorkingWaking
  | WorkingDegraded
  deriving stock (Eq, Show)

instance ToJSON WorkingStatus where
  toJSON = String . statusName

instance FromJSON WorkingStatus where
  parseJSON = withText "WorkingStatus" $ \case
    "awake" -> pure WorkingAwake
    "quiescing" -> pure WorkingQuiescing
    "asleep" -> pure WorkingAsleep
    "waking" -> pure WorkingWaking
    "degraded" -> pure WorkingDegraded
    value -> fail ("unknown working status: " <> Text.unpack value)

data FocusStatus
  = FocusActive
  | FocusParked
  | FocusClosed
  deriving stock (Eq, Show)

instance ToJSON FocusStatus where
  toJSON = String . \case
    FocusActive -> "active"
    FocusParked -> "parked"
    FocusClosed -> "closed"

instance FromJSON FocusStatus where
  parseJSON = withText "FocusStatus" $ \case
    "active" -> pure FocusActive
    "parked" -> pure FocusParked
    "closed" -> pure FocusClosed
    value -> fail ("unknown focus status: " <> Text.unpack value)

data SleepTrigger
  = SleepSoftLimit
  | SleepProviderOverflow
  | SleepManual
  | SleepSelfRequested
  | SleepSuspend
  deriving stock (Eq, Show)

instance ToJSON SleepTrigger where
  toJSON = String . \case
    SleepSoftLimit -> "soft_limit"
    SleepProviderOverflow -> "provider_overflow"
    SleepManual -> "manual"
    SleepSelfRequested -> "self_requested"
    SleepSuspend -> "suspend"

instance FromJSON SleepTrigger where
  parseJSON = withText "SleepTrigger" $ \case
    "soft_limit" -> pure SleepSoftLimit
    "provider_overflow" -> pure SleepProviderOverflow
    "manual" -> pure SleepManual
    "self_requested" -> pure SleepSelfRequested
    "suspend" -> pure SleepSuspend
    value -> fail ("unknown sleep trigger: " <> Text.unpack value)

data SleepCycleStatus
  = CycleQuiescing
  | CyclePrepared
  | CycleAsleep
  | CycleWaking
  | CycleAwake
  | CycleDegraded
  deriving stock (Eq, Show)

instance ToJSON SleepCycleStatus where
  toJSON = String . cycleStatusName

instance FromJSON SleepCycleStatus where
  parseJSON = withText "SleepCycleStatus" $ \case
    "quiescing" -> pure CycleQuiescing
    "prepared" -> pure CyclePrepared
    "asleep" -> pure CycleAsleep
    "waking" -> pure CycleWaking
    "awake" -> pure CycleAwake
    "degraded" -> pure CycleDegraded
    value -> fail ("unknown sleep cycle status: " <> Text.unpack value)

data FocusFrame = FocusFrame
  { focusFrameId :: Text,
    focusFrameIncarnationId :: Text,
    focusFrameTaskId :: Text,
    focusFrameRevision :: Int,
    focusFrameStatus :: FocusStatus,
    focusFrameEpochId :: Text,
    focusFrameObjective :: Text,
    focusFrameActiveItems :: [Text],
    focusFrameOpenLoops :: [Text],
    focusFrameProvisionalClaims :: [Text],
    focusFrameRecentOutcomeRefs :: [Text],
    focusFrameArtifactRefs :: [Text],
    focusFrameCursor :: ExperienceCursor,
    focusFrameUpdated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON FocusFrame where
  toJSON frame =
    object
      [ "id" .= focusFrameId frame,
        "incarnationId" .= focusFrameIncarnationId frame,
        "taskId" .= focusFrameTaskId frame,
        "revision" .= focusFrameRevision frame,
        "status" .= focusFrameStatus frame,
        "epochId" .= focusFrameEpochId frame,
        "objective" .= focusFrameObjective frame,
        "activeItems" .= focusFrameActiveItems frame,
        "openLoops" .= focusFrameOpenLoops frame,
        "provisionalClaims" .= focusFrameProvisionalClaims frame,
        "recentOutcomeRefs" .= focusFrameRecentOutcomeRefs frame,
        "artifactRefs" .= focusFrameArtifactRefs frame,
        "cursor" .= focusFrameCursor frame,
        "updated" .= focusFrameUpdated frame
      ]

instance FromJSON FocusFrame where
  parseJSON = withObject "FocusFrame" $ \fields ->
    FocusFrame
      <$> fields .: "id"
      <*> fields .: "incarnationId"
      <*> fields .: "taskId"
      <*> fields .: "revision"
      <*> fields .: "status"
      <*> fields .: "epochId"
      <*> fields .: "objective"
      <*> fields .:? "activeItems" .!= []
      <*> fields .:? "openLoops" .!= []
      <*> fields .:? "provisionalClaims" .!= []
      <*> fields .:? "recentOutcomeRefs" .!= []
      <*> fields .:? "artifactRefs" .!= []
      <*> fields .: "cursor"
      <*> fields .: "updated"

data ForgetDecision = ForgetDecision
  { forgetSubject :: Text,
    forgetReason :: Text,
    forgetSourceSegmentIds :: [Text]
  }
  deriving stock (Eq, Show)

instance ToJSON ForgetDecision where
  toJSON decision =
    object
      [ "subject" .= forgetSubject decision,
        "reason" .= forgetReason decision,
        "sourceSegmentIds" .= forgetSourceSegmentIds decision
      ]

instance FromJSON ForgetDecision where
  parseJSON = withObject "ForgetDecision" $ \fields ->
    ForgetDecision
      <$> fields .: "subject"
      <*> fields .: "reason"
      <*> fields .:? "sourceSegmentIds" .!= []

data WakePacket = WakePacket
  { wakePacketId :: Text,
    wakePacketIncarnationId :: Text,
    wakePacketTaskId :: Text,
    wakePacketRunId :: Maybe Text,
    wakePacketBaseEpochId :: Text,
    wakePacketTrigger :: SleepTrigger,
    wakePacketContinuation :: Text,
    wakePacketActiveItems :: [Text],
    wakePacketOpenLoops :: [Text],
    wakePacketForgotten :: [ForgetDecision],
    wakePacketRetainedSegmentIds :: [Text],
    wakePacketPayloadRef :: Text,
    wakePacketGeneratorRevision :: Text,
    wakePacketInvocationRef :: Text,
    wakePacketCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON WakePacket where
  toJSON packet =
    object
      [ "id" .= wakePacketId packet,
        "incarnationId" .= wakePacketIncarnationId packet,
        "taskId" .= wakePacketTaskId packet,
        "runId" .= wakePacketRunId packet,
        "baseEpochId" .= wakePacketBaseEpochId packet,
        "trigger" .= wakePacketTrigger packet,
        "continuation" .= wakePacketContinuation packet,
        "activeItems" .= wakePacketActiveItems packet,
        "openLoops" .= wakePacketOpenLoops packet,
        "forgotten" .= wakePacketForgotten packet,
        "retainedSegmentIds" .= wakePacketRetainedSegmentIds packet,
        "payloadRef" .= wakePacketPayloadRef packet,
        "generatorRevision" .= wakePacketGeneratorRevision packet,
        "invocationRef" .= wakePacketInvocationRef packet,
        "created" .= wakePacketCreated packet
      ]

instance FromJSON WakePacket where
  parseJSON = withObject "WakePacket" $ \fields ->
    WakePacket
      <$> fields .: "id"
      <*> fields .: "incarnationId"
      <*> fields .: "taskId"
      <*> fields .:? "runId"
      <*> fields .: "baseEpochId"
      <*> fields .: "trigger"
      <*> fields .: "continuation"
      <*> fields .:? "activeItems" .!= []
      <*> fields .:? "openLoops" .!= []
      <*> fields .:? "forgotten" .!= []
      <*> fields .:? "retainedSegmentIds" .!= []
      <*> fields .: "payloadRef"
      <*> fields .: "generatorRevision"
      <*> fields .: "invocationRef"
      <*> fields .: "created"

data WorkingMemoryCheckpoint = WorkingMemoryCheckpoint
  { workingCheckpointId :: Text,
    workingCheckpointIncarnationId :: Text,
    workingCheckpointBaseRevision :: Int,
    workingCheckpointCoveredThrough :: ExperienceCursor,
    workingCheckpointFocusFrames :: Map Text FocusFrame,
    workingCheckpointActiveTaskId :: Maybe Text,
    workingCheckpointStateRef :: Text,
    workingCheckpointSourceClosureHash :: Text,
    workingCheckpointWakePacketId :: Text,
    workingCheckpointGeneratorRevision :: Text,
    workingCheckpointCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON WorkingMemoryCheckpoint where
  toJSON checkpoint =
    object
      [ "id" .= workingCheckpointId checkpoint,
        "incarnationId" .= workingCheckpointIncarnationId checkpoint,
        "baseRevision" .= workingCheckpointBaseRevision checkpoint,
        "coveredThrough" .= workingCheckpointCoveredThrough checkpoint,
        "focusFrames" .= workingCheckpointFocusFrames checkpoint,
        "activeTaskId" .= workingCheckpointActiveTaskId checkpoint,
        "stateRef" .= workingCheckpointStateRef checkpoint,
        "sourceClosureHash" .= workingCheckpointSourceClosureHash checkpoint,
        "wakePacketId" .= workingCheckpointWakePacketId checkpoint,
        "generatorRevision" .= workingCheckpointGeneratorRevision checkpoint,
        "created" .= workingCheckpointCreated checkpoint
      ]

instance FromJSON WorkingMemoryCheckpoint where
  parseJSON = withObject "WorkingMemoryCheckpoint" $ \fields ->
    WorkingMemoryCheckpoint
      <$> fields .: "id"
      <*> fields .: "incarnationId"
      <*> fields .: "baseRevision"
      <*> fields .: "coveredThrough"
      <*> fields .:? "focusFrames" .!= Map.empty
      <*> fields .:? "activeTaskId"
      <*> fields .: "stateRef"
      <*> fields .: "sourceClosureHash"
      <*> fields .: "wakePacketId"
      <*> fields .: "generatorRevision"
      <*> fields .: "created"

data WorkingMemoryHead = WorkingMemoryHead
  { workingMemoryId :: Text,
    workingMemoryIncarnationId :: Text,
    workingMemoryRevision :: Int,
    workingMemoryStatus :: WorkingStatus,
    workingMemoryCursor :: ExperienceCursor,
    workingMemoryCheckpointId :: Maybe Text,
    workingMemoryWakePacketId :: Maybe Text,
    workingMemoryActiveTaskId :: Maybe Text,
    workingMemoryFocusFrames :: Map Text FocusFrame,
    workingMemoryDegradedReason :: Maybe Text,
    workingMemoryCreated :: Integer,
    workingMemoryUpdated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON WorkingMemoryHead where
  toJSON head' =
    object
      [ "id" .= workingMemoryId head',
        "incarnationId" .= workingMemoryIncarnationId head',
        "revision" .= workingMemoryRevision head',
        "status" .= workingMemoryStatus head',
        "cursor" .= workingMemoryCursor head',
        "checkpointId" .= workingMemoryCheckpointId head',
        "wakePacketId" .= workingMemoryWakePacketId head',
        "activeTaskId" .= workingMemoryActiveTaskId head',
        "focusFrames" .= workingMemoryFocusFrames head',
        "degradedReason" .= workingMemoryDegradedReason head',
        "created" .= workingMemoryCreated head',
        "updated" .= workingMemoryUpdated head'
      ]

instance FromJSON WorkingMemoryHead where
  parseJSON = withObject "WorkingMemoryHead" $ \fields ->
    WorkingMemoryHead
      <$> fields .: "id"
      <*> fields .: "incarnationId"
      <*> fields .: "revision"
      <*> fields .: "status"
      <*> fields .: "cursor"
      <*> fields .:? "checkpointId"
      <*> fields .:? "wakePacketId"
      <*> fields .:? "activeTaskId"
      <*> fields .:? "focusFrames" .!= Map.empty
      <*> fields .:? "degradedReason"
      <*> fields .: "created"
      <*> fields .: "updated"

data SleepCycle = SleepCycle
  { sleepCycleId :: Text,
    sleepCycleIncarnationId :: Text,
    sleepCycleTaskId :: Text,
    sleepCycleRunId :: Maybe Text,
    sleepCycleBaseEpochId :: Text,
    sleepCycleTrigger :: SleepTrigger,
    sleepCycleStatus :: SleepCycleStatus,
    sleepCycleExpectedRevision :: Int,
    sleepCycleFrozenCursor :: ExperienceCursor,
    sleepCycleForgotten :: [ForgetDecision],
    sleepCycleCheckpointId :: Maybe Text,
    sleepCycleWakePacketId :: Maybe Text,
    sleepCycleReplayCursor :: Maybe ExperienceCursor,
    sleepCycleFailure :: Maybe Text,
    sleepCycleCreated :: Integer,
    sleepCycleUpdated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON SleepCycle where
  toJSON cycle' =
    object
      [ "id" .= sleepCycleId cycle',
        "incarnationId" .= sleepCycleIncarnationId cycle',
        "taskId" .= sleepCycleTaskId cycle',
        "runId" .= sleepCycleRunId cycle',
        "baseEpochId" .= sleepCycleBaseEpochId cycle',
        "trigger" .= sleepCycleTrigger cycle',
        "status" .= sleepCycleStatus cycle',
        "expectedRevision" .= sleepCycleExpectedRevision cycle',
        "frozenCursor" .= sleepCycleFrozenCursor cycle',
        "forgotten" .= sleepCycleForgotten cycle',
        "checkpointId" .= sleepCycleCheckpointId cycle',
        "wakePacketId" .= sleepCycleWakePacketId cycle',
        "replayCursor" .= sleepCycleReplayCursor cycle',
        "failure" .= sleepCycleFailure cycle',
        "created" .= sleepCycleCreated cycle',
        "updated" .= sleepCycleUpdated cycle'
      ]

instance FromJSON SleepCycle where
  parseJSON = withObject "SleepCycle" $ \fields ->
    SleepCycle
      <$> fields .: "id"
      <*> fields .: "incarnationId"
      <*> fields .: "taskId"
      <*> fields .:? "runId"
      <*> fields .: "baseEpochId"
      <*> fields .: "trigger"
      <*> fields .: "status"
      <*> fields .: "expectedRevision"
      <*> fields .: "frozenCursor"
      <*> fields .:? "forgotten" .!= []
      <*> fields .:? "checkpointId"
      <*> fields .:? "wakePacketId"
      <*> fields .:? "replayCursor"
      <*> fields .:? "failure"
      <*> fields .: "created"
      <*> fields .: "updated"

data WorkingStore = WorkingStore
  { workingList :: IO [WorkingMemoryHead],
    workingRead :: Text -> IO (Maybe WorkingMemoryHead),
    workingReadFocus :: Text -> Text -> IO (Maybe FocusFrame),
    workingCreate :: Text -> ExperienceCursor -> IO (Either Text WorkingMemoryHead),
    workingAppendCursor :: Text -> Int -> ExperienceCursor -> IO (Either Text WorkingMemoryHead),
    workingPutFocus :: Text -> Int -> FocusFrame -> IO (Either Text WorkingMemoryHead),
    workingRequestSleep :: Text -> Int -> Text -> Text -> Maybe Text -> Text -> SleepTrigger -> IO (Either Text (WorkingMemoryHead, SleepCycle)),
    workingAbortSleep :: Text -> Int -> Text -> Text -> IO (Either Text (WorkingMemoryHead, SleepCycle)),
    workingPrepareCheckpoint :: Text -> Int -> Text -> WorkingMemoryCheckpoint -> WakePacket -> IO (Either Text SleepCycle),
    workingCommitSleep :: Text -> Int -> Text -> IO (Either Text (WorkingMemoryHead, SleepCycle)),
    workingBeginWake :: Text -> Int -> Text -> IO (Either Text (WorkingMemoryHead, SleepCycle)),
    workingCommitWake :: Text -> Int -> Text -> ExperienceCursor -> IO (Either Text (WorkingMemoryHead, SleepCycle)),
    workingCommitWakeFocus :: Text -> Int -> Text -> ExperienceCursor -> FocusFrame -> IO (Either Text (WorkingMemoryHead, SleepCycle)),
    workingDegradeWake :: Text -> Int -> Text -> Text -> IO (Either Text (WorkingMemoryHead, SleepCycle)),
    workingReadCheckpoint :: Text -> IO (Maybe WorkingMemoryCheckpoint),
    workingReadWakePacket :: Text -> IO (Maybe WakePacket),
    workingReadSleepCycle :: Text -> IO (Maybe SleepCycle),
    workingSleepCycles :: Text -> IO [SleepCycle],
    workingRecover :: Text -> ExperienceCursor -> IO (Either Text WorkingMemoryHead),
    workingDelete :: Text -> IO ()
  }

data WorkingState = WorkingState
  { stateHeads :: Map Text WorkingMemoryHead,
    stateCheckpoints :: Map Text WorkingMemoryCheckpoint,
    stateWakePackets :: Map Text WakePacket,
    stateSleepCycles :: Map Text SleepCycle
  }
  deriving stock (Eq, Show)

instance ToJSON WorkingState where
  toJSON state =
    object
      [ "heads" .= stateHeads state,
        "checkpoints" .= stateCheckpoints state,
        "wakePackets" .= stateWakePackets state,
        "sleepCycles" .= stateSleepCycles state
      ]

instance FromJSON WorkingState where
  parseJSON = withObject "WorkingState" $ \fields ->
    WorkingState
      <$> fields .:? "heads" .!= Map.empty
      <*> fields .:? "checkpoints" .!= Map.empty
      <*> fields .:? "wakePackets" .!= Map.empty
      <*> fields .:? "sleepCycles" .!= Map.empty

emptyState :: WorkingState
emptyState = WorkingState Map.empty Map.empty Map.empty Map.empty

newWorkingStore :: FilePath -> IO (Either Text WorkingStore)
newWorkingStore dir =
  createDirectoryIfMissing True (workingPath dir)
    *> loadState (statePath dir)
    >>= traverse (newMVar >=> pure . mkStore (atomicEncodeFile (statePath dir)))

newMemoryWorkingStore :: IO WorkingStore
newMemoryWorkingStore = newMVar emptyState <&> mkStore (const (pure ()))

mkStore :: (WorkingState -> IO ()) -> MVar WorkingState -> WorkingStore
mkStore persist lock =
  WorkingStore
    { workingList = Map.elems . stateHeads <$> readMVar lock,
      workingRead = \incarnation -> Map.lookup incarnation . stateHeads <$> readMVar lock,
      workingReadFocus = \incarnation task ->
        readMVar lock
          <&> (Map.lookup incarnation . stateHeads >=> Map.lookup task . workingMemoryFocusFrames),
      workingCreate = create,
      workingAppendCursor = appendCursor,
      workingPutFocus = putFocus,
      workingRequestSleep = requestSleep,
      workingAbortSleep = abortSleep,
      workingPrepareCheckpoint = prepareCheckpoint,
      workingCommitSleep = commitSleep,
      workingBeginWake = beginWake,
      workingCommitWake = \incarnation expected cycleId replayed ->
        commitWake incarnation expected cycleId replayed Nothing,
      workingCommitWakeFocus = \incarnation expected cycleId replayed frame ->
        commitWake incarnation expected cycleId replayed (Just frame),
      workingDegradeWake = degradeWake,
      workingReadCheckpoint = \identifier -> Map.lookup identifier . stateCheckpoints <$> readMVar lock,
      workingReadWakePacket = \identifier -> Map.lookup identifier . stateWakePackets <$> readMVar lock,
      workingReadSleepCycle = \identifier -> Map.lookup identifier . stateSleepCycles <$> readMVar lock,
      workingSleepCycles = \incarnation ->
        sortOn sleepCycleCreated
          . filter ((== incarnation) . sleepCycleIncarnationId)
          . Map.elems
          . stateSleepCycles
          <$> readMVar lock,
      workingRecover = recover,
      workingDelete = \incarnation ->
        () <$ modifyMVar lock (\state ->
              let changed =
                    state
                      { stateHeads = Map.delete incarnation (stateHeads state),
                        stateCheckpoints = Map.filter ((/= incarnation) . workingCheckpointIncarnationId) (stateCheckpoints state),
                        stateWakePackets = Map.filter ((/= incarnation) . wakePacketIncarnationId) (stateWakePackets state),
                        stateSleepCycles = Map.filter ((/= incarnation) . sleepCycleIncarnationId) (stateSleepCycles state)
                      }
               in persist changed *> pure (changed, ()))
    }
  where
    create incarnation cursor
      | Text.null (Text.strip incarnation) = pure (Left "incarnation id must not be empty")
      | cursorStreamId cursor /= experienceStream incarnation = pure (Left (cursorMismatch incarnation cursor))
      | cursorSeq cursor < 0 = pure (Left "experience cursor must not be negative")
      | otherwise =
          getPOSIXTime >>= \now ->
            modifyMVar lock $ \state ->
              case Map.lookup incarnation (stateHeads state) of
                Just _ -> pure (state, Left ("working memory already exists: " <> incarnation))
                Nothing ->
                  let stamp = round now
                      head' =
                        WorkingMemoryHead
                          ("working/" <> incarnation)
                          incarnation
                          1
                          WorkingAwake
                          cursor
                          Nothing
                          Nothing
                          Nothing
                          Map.empty
                          Nothing
                          stamp
                          stamp
                      changed = putHead head' state
                   in save persist changed head'
    appendCursor incarnation expected cursor =
      mutateHead persist lock incarnation expected $ \now state head' ->
        stateRequired WorkingAwake head'
          *> advance (workingMemoryCursor head') cursor
          <&> \advanced ->
            if advanced
              then
                let changedHead =
                      head'
                        { workingMemoryRevision = expected + 1,
                          workingMemoryCursor = cursor,
                          workingMemoryUpdated = now
                        }
                 in (putHead changedHead state, changedHead)
              else (state, head')
    putFocus incarnation expected frame =
      mutateHead persist lock incarnation expected $ \now state head' ->
        stateRequired WorkingAwake head'
          *> validateFrame head' frame
          *> validateFocusRevision (Map.lookup task (workingMemoryFocusFrames head')) frame
          $> changed now state head'
      where
        task = focusFrameTaskId frame
        changed now state head' =
          let active =
                case focusFrameStatus frame of
                  FocusActive -> Just task
                  _ | workingMemoryActiveTaskId head' == Just task -> Nothing
                  _ -> workingMemoryActiveTaskId head'
              changedHead =
                head'
                  { workingMemoryRevision = expected + 1,
                    workingMemoryActiveTaskId = active,
                    workingMemoryFocusFrames = Map.insert task frame (workingMemoryFocusFrames head'),
                    workingMemoryUpdated = now
                  }
           in (putHead changedHead state, changedHead)
    requestSleep incarnation expected cycleId task run baseEpoch trigger
      | any (Text.null . Text.strip) [cycleId, task, baseEpoch] =
          pure (Left "sleep cycle, task and base epoch ids must not be empty")
      | otherwise =
          getPOSIXTime >>= \now ->
            modifyMVar lock $ \state ->
              case (Map.lookup incarnation (stateHeads state), Map.lookup cycleId (stateSleepCycles state)) of
                (Nothing, _) -> pure (state, Left ("unknown working memory: " <> incarnation))
                (_, Just _) -> pure (state, Left ("sleep cycle already exists: " <> cycleId))
                (Just head', Nothing)
                  | workingMemoryRevision head' /= expected -> pure (state, Left (stale expected (workingMemoryRevision head')))
                  | workingMemoryStatus head' /= WorkingAwake -> pure (state, Left (wrongState WorkingAwake head'))
                  | Map.notMember task (workingMemoryFocusFrames head') -> pure (state, Left ("unknown focus task: " <> task))
                  | otherwise ->
                      let stamp = round now
                          changedHead =
                            head'
                              { workingMemoryRevision = expected + 1,
                                workingMemoryStatus = WorkingQuiescing,
                                workingMemoryUpdated = stamp
                              }
                          cycle' =
                            SleepCycle
                              cycleId
                              incarnation
                              task
                              run
                              baseEpoch
                              trigger
                              CycleQuiescing
                              (expected + 1)
                              (workingMemoryCursor head')
                              []
                              Nothing
                              Nothing
                              Nothing
                              Nothing
                              stamp
                              stamp
                          changed = putCycle cycle' (putHead changedHead state)
                       in save persist changed (changedHead, cycle')
    abortSleep incarnation expected cycleId reason
      | Text.null (Text.strip reason) = pure (Left "sleep abort reason must not be empty")
      | otherwise =
          getPOSIXTime >>= \now ->
            modifyMVar lock $ \state ->
              withHeadCycle state incarnation expected cycleId WorkingQuiescing CycleQuiescing $ \head' cycle' ->
                let stamp = round now
                    failure = Text.strip reason
                    changedHead =
                      head'
                        { workingMemoryRevision = expected + 1,
                          workingMemoryStatus = WorkingAwake,
                          workingMemoryDegradedReason = Just failure,
                          workingMemoryUpdated = stamp
                        }
                    changedCycle =
                      cycle'
                        { sleepCycleStatus = CycleDegraded,
                          sleepCycleFailure = Just failure,
                          sleepCycleUpdated = stamp
                        }
                    changed = putCycle changedCycle (putHead changedHead state)
                 in save persist changed (changedHead, changedCycle)
    prepareCheckpoint incarnation expected cycleId checkpoint packet =
      getPOSIXTime >>= \now ->
        modifyMVar lock $ \state ->
          case (Map.lookup incarnation (stateHeads state), Map.lookup cycleId (stateSleepCycles state)) of
            (Nothing, _) -> pure (state, Left ("unknown working memory: " <> incarnation))
            (_, Nothing) -> pure (state, Left ("unknown sleep cycle: " <> cycleId))
            (Just head', Just cycle')
              | workingMemoryRevision head' /= expected -> pure (state, Left (stale expected (workingMemoryRevision head')))
              | workingMemoryStatus head' /= WorkingQuiescing -> pure (state, Left (wrongState WorkingQuiescing head'))
              | sleepCycleIncarnationId cycle' /= incarnation -> pure (state, Left "sleep cycle incarnation mismatch")
              | sleepCycleStatus cycle' == CyclePrepared ->
                  case prepared state cycle' of
                    Just (storedCheckpoint, storedPacket)
                      | storedCheckpoint == checkpoint && storedPacket == packet -> pure (state, Right cycle')
                    _ -> pure (state, Left ("sleep cycle already prepared: " <> cycleId))
              | sleepCycleStatus cycle' /= CycleQuiescing -> pure (state, Left (wrongCycle CycleQuiescing cycle'))
              | otherwise ->
                  case validatePrepared expected head' cycle' checkpoint packet state of
                    Left failure -> pure (state, Left failure)
                    Right () ->
                      let stamp = round now
                          changedCycle =
                            cycle'
                              { sleepCycleStatus = CyclePrepared,
                                sleepCycleForgotten = wakePacketForgotten packet,
                                sleepCycleCheckpointId = Just (workingCheckpointId checkpoint),
                                sleepCycleWakePacketId = Just (wakePacketId packet),
                                sleepCycleUpdated = stamp
                              }
                          changed =
                            state
                              { stateCheckpoints =
                                  Map.insert (workingCheckpointId checkpoint) checkpoint (stateCheckpoints state),
                                stateWakePackets =
                                  Map.insert (wakePacketId packet) packet (stateWakePackets state),
                                stateSleepCycles =
                                  Map.insert cycleId changedCycle (stateSleepCycles state)
                              }
                       in save persist changed changedCycle
    commitSleep incarnation expected cycleId =
      getPOSIXTime >>= \now ->
        modifyMVar lock $ \state ->
          withHeadCycle state incarnation expected cycleId WorkingQuiescing CyclePrepared $ \head' cycle' ->
            case prepared state cycle' of
              Nothing -> pure (state, Left "prepared sleep objects are missing")
              Just (checkpoint, packet) ->
                let stamp = round now
                    changedHead =
                      head'
                        { workingMemoryRevision = expected + 1,
                          workingMemoryStatus = WorkingAsleep,
                          workingMemoryCursor = workingCheckpointCoveredThrough checkpoint,
                          workingMemoryCheckpointId = Just (workingCheckpointId checkpoint),
                          workingMemoryWakePacketId = Just (wakePacketId packet),
                          workingMemoryUpdated = stamp
                        }
                    changedCycle =
                      cycle'
                        { sleepCycleStatus = CycleAsleep,
                          sleepCycleUpdated = stamp
                        }
                    changed = putCycle changedCycle (putHead changedHead state)
                 in save persist changed (changedHead, changedCycle)
    beginWake incarnation expected cycleId =
      getPOSIXTime >>= \now ->
        modifyMVar lock $ \state ->
          withHeadCycle state incarnation expected cycleId WorkingAsleep CycleAsleep $ \head' cycle' ->
            let stamp = round now
                changedHead =
                  head'
                    { workingMemoryRevision = expected + 1,
                      workingMemoryStatus = WorkingWaking,
                      workingMemoryUpdated = stamp
                    }
                changedCycle =
                  cycle'
                    { sleepCycleStatus = CycleWaking,
                      sleepCycleExpectedRevision = expected + 1,
                      sleepCycleUpdated = stamp
                    }
                changed = putCycle changedCycle (putHead changedHead state)
             in save persist changed (changedHead, changedCycle)
    commitWake incarnation expected cycleId replayed frame =
      getPOSIXTime >>= \now ->
        modifyMVar lock $ \state ->
          withHeadCycle state incarnation expected cycleId WorkingWaking CycleWaking $ \head' cycle' ->
            case
                advance (workingMemoryCursor head') replayed
                  *> traverse_
                    ( \next ->
                        let replayedHead = head' {workingMemoryCursor = replayed}
                         in validateFrame replayedHead next
                              *> validateFocusRevision
                                (Map.lookup (focusFrameTaskId next) (workingMemoryFocusFrames head'))
                                next
                    )
                    frame
              of
              Left failure -> pure (state, Left failure)
              Right _ ->
                let stamp = round now
                    awake =
                      head'
                        { workingMemoryRevision = expected + 1,
                          workingMemoryStatus = WorkingAwake,
                          workingMemoryCursor = replayed,
                          workingMemoryDegradedReason = Nothing,
                          workingMemoryUpdated = stamp
                        }
                    changedHead =
                      maybe
                        awake
                        ( \next ->
                            awake
                              { workingMemoryActiveTaskId =
                                  bool (workingMemoryActiveTaskId awake) (Just (focusFrameTaskId next)) (focusFrameStatus next == FocusActive),
                                workingMemoryFocusFrames =
                                  Map.insert (focusFrameTaskId next) next (workingMemoryFocusFrames awake)
                              }
                        )
                        frame
                    changedCycle =
                      cycle'
                        { sleepCycleStatus = CycleAwake,
                          sleepCycleReplayCursor = Just replayed,
                          sleepCycleUpdated = stamp
                        }
                    changed = putCycle changedCycle (putHead changedHead state)
                 in save persist changed (changedHead, changedCycle)
    degradeWake incarnation expected cycleId reason
      | Text.null (Text.strip reason) = pure (Left "degraded wake reason must not be empty")
      | otherwise =
          getPOSIXTime >>= \now ->
            modifyMVar lock $ \state ->
              withHeadCycle state incarnation expected cycleId WorkingWaking CycleWaking $ \head' cycle' ->
                let stamp = round now
                    failure = Text.strip reason
                    changedHead =
                      head'
                        { workingMemoryRevision = expected + 1,
                          workingMemoryStatus = WorkingDegraded,
                          workingMemoryDegradedReason = Just failure,
                          workingMemoryUpdated = stamp
                        }
                    changedCycle =
                      cycle'
                        { sleepCycleStatus = CycleDegraded,
                          sleepCycleFailure = Just failure,
                          sleepCycleUpdated = stamp
                        }
                    changed = putCycle changedCycle (putHead changedHead state)
                 in save persist changed (changedHead, changedCycle)
    recover incarnation replayed =
      getPOSIXTime >>= \now ->
        modifyMVar lock $ \state ->
          case Map.lookup incarnation (stateHeads state) of
            Nothing -> pure (state, Left ("unknown working memory: " <> incarnation))
            Just head'
              | workingMemoryStatus head' == WorkingAwake -> pure (state, Right head')
              | otherwise ->
                  let stamp = round now
                      cycle' = recoveryCycle state head'
                      (cursor, cursorFailure) = recoveryCursor head' replayed
                      failure = recoveryFailure head' cycle' cursorFailure
                      checkpointId = preferCycle sleepCycleCheckpointId (workingMemoryCheckpointId head') cycle'
                      packetId = preferCycle sleepCycleWakePacketId (workingMemoryWakePacketId head') cycle'
                      changedHead =
                        head'
                          { workingMemoryRevision = workingMemoryRevision head' + 1,
                            workingMemoryStatus = WorkingAwake,
                            workingMemoryCursor = cursor,
                            workingMemoryCheckpointId = checkpointId,
                            workingMemoryWakePacketId = packetId,
                            workingMemoryDegradedReason = failure,
                            workingMemoryUpdated = stamp
                          }
                      changed =
                        maybe
                          (putHead changedHead state)
                          (\cycle -> putCycle (recoveredCycle stamp cursor failure changedHead cycle) (putHead changedHead state))
                          cycle'
                   in save persist changed changedHead

recoveryCycle :: WorkingState -> WorkingMemoryHead -> Maybe SleepCycle
recoveryCycle state head' =
  listToMaybe
    . reverse
    . sortOn sleepCycleUpdated
    . filter matching
    . Map.elems
    $ stateSleepCycles state
  where
    matching cycle =
      sleepCycleIncarnationId cycle == workingMemoryIncarnationId head'
        && case workingMemoryStatus head' of
          WorkingQuiescing -> sleepCycleStatus cycle `elem` [CycleQuiescing, CyclePrepared]
          WorkingAsleep -> sleepCycleStatus cycle == CycleAsleep
          WorkingWaking -> sleepCycleStatus cycle == CycleWaking
          WorkingDegraded -> sleepCycleStatus cycle == CycleDegraded
          WorkingAwake -> False

recoveryCursor :: WorkingMemoryHead -> ExperienceCursor -> (ExperienceCursor, Maybe Text)
recoveryCursor head' replayed
  | cursorStreamId replayed /= cursorStreamId current =
      (current, Just "experience stream mismatch during wake recovery")
  | cursorSeq replayed < cursorSeq current =
      (current, Just "experience stream lagged behind working memory during wake recovery")
  | otherwise = (replayed, Nothing)
  where
    current = workingMemoryCursor head'

recoveryFailure :: WorkingMemoryHead -> Maybe SleepCycle -> Maybe Text -> Maybe Text
recoveryFailure head' cycle' cursorFailure =
  combine transitionFailure cursorFailure
  where
    transitionFailure =
      case (workingMemoryStatus head', sleepCycleStatus <$> cycle') of
        (WorkingQuiescing, Just CycleQuiescing) ->
          Just "sleep was interrupted before checkpoint commit; no forgetting was applied"
        (WorkingQuiescing, Just CyclePrepared) ->
          Just "prepared sleep could not be resumed; continued from the durable pre-sleep context"
        (WorkingAsleep, Just CycleAsleep) ->
          Just "sleep could not complete wake recovery; continued from the durable context head"
        (WorkingWaking, Just CycleWaking) ->
          Just "wake could not complete recovery; continued from the durable context head"
        (WorkingDegraded, _) ->
          workingMemoryDegradedReason head' <> Just "working memory recovered from a degraded wake"
        (_, Nothing) -> Just "sleep transition metadata was missing; resumed from the durable working head"
        _ -> Just "sleep transition metadata was inconsistent; resumed from the durable working head"
    combine Nothing other = other
    combine other Nothing = other
    combine (Just left) (Just right) = Just (left <> "; " <> right)

preferCycle :: (SleepCycle -> Maybe value) -> Maybe value -> Maybe SleepCycle -> Maybe value
preferCycle field existing = maybe existing (\cycle -> maybe existing Just (field cycle))

recoveredCycle :: Integer -> ExperienceCursor -> Maybe Text -> WorkingMemoryHead -> SleepCycle -> SleepCycle
recoveredCycle stamp cursor failure head' cycle =
  cycle
    { sleepCycleStatus = status,
      sleepCycleExpectedRevision = workingMemoryRevision head',
      sleepCycleReplayCursor = replay,
      sleepCycleFailure = cycleFailure,
      sleepCycleUpdated = stamp
    }
  where
    aborted = maybe False (const True) failure
    status = bool CycleAwake CycleDegraded aborted
    replay = bool (Just cursor) (sleepCycleReplayCursor cycle) aborted
    cycleFailure = bool (sleepCycleFailure cycle) failure aborted

mutateHead ::
  (WorkingState -> IO ()) ->
  MVar WorkingState ->
  Text ->
  Int ->
  (Integer -> WorkingState -> WorkingMemoryHead -> Either Text (WorkingState, WorkingMemoryHead)) ->
  IO (Either Text WorkingMemoryHead)
mutateHead persist lock incarnation expected change =
  getPOSIXTime >>= \now ->
    modifyMVar lock $ \state ->
      case Map.lookup incarnation (stateHeads state) of
        Nothing -> pure (state, Left ("unknown working memory: " <> incarnation))
        Just head'
          | workingMemoryRevision head' /= expected -> pure (state, Left (stale expected (workingMemoryRevision head')))
          | otherwise ->
              case change (round now) state head' of
                Left failure -> pure (state, Left failure)
                Right (changed, value) -> save persist changed value

withHeadCycle ::
  WorkingState ->
  Text ->
  Int ->
  Text ->
  WorkingStatus ->
  SleepCycleStatus ->
  (WorkingMemoryHead -> SleepCycle -> IO (WorkingState, Either Text value)) ->
  IO (WorkingState, Either Text value)
withHeadCycle state incarnation expected cycleId headStatus cycleStatus use =
  case (Map.lookup incarnation (stateHeads state), Map.lookup cycleId (stateSleepCycles state)) of
    (Nothing, _) -> pure (state, Left ("unknown working memory: " <> incarnation))
    (_, Nothing) -> pure (state, Left ("unknown sleep cycle: " <> cycleId))
    (Just head', Just cycle')
      | workingMemoryRevision head' /= expected -> pure (state, Left (stale expected (workingMemoryRevision head')))
      | workingMemoryStatus head' /= headStatus -> pure (state, Left (wrongState headStatus head'))
      | sleepCycleIncarnationId cycle' /= incarnation -> pure (state, Left "sleep cycle incarnation mismatch")
      | sleepCycleStatus cycle' /= cycleStatus -> pure (state, Left (wrongCycle cycleStatus cycle'))
      | otherwise -> use head' cycle'

validatePrepared ::
  Int ->
  WorkingMemoryHead ->
  SleepCycle ->
  WorkingMemoryCheckpoint ->
  WakePacket ->
  WorkingState ->
  Either Text ()
validatePrepared expected head' cycle' checkpoint packet state =
  sequence_
    [ require (workingCheckpointIncarnationId checkpoint == workingMemoryIncarnationId head') "checkpoint incarnation mismatch",
      require (wakePacketIncarnationId packet == workingMemoryIncarnationId head') "wake packet incarnation mismatch",
      require (wakePacketTaskId packet == sleepCycleTaskId cycle') "wake packet task mismatch",
      require (wakePacketRunId packet == sleepCycleRunId cycle') "wake packet run mismatch",
      require (wakePacketBaseEpochId packet == sleepCycleBaseEpochId cycle') "wake packet base epoch mismatch",
      require (wakePacketTrigger packet == sleepCycleTrigger cycle') "wake packet trigger mismatch",
      require (workingCheckpointBaseRevision checkpoint == expected) "checkpoint base revision mismatch",
      require (workingCheckpointCoveredThrough checkpoint == sleepCycleFrozenCursor cycle') "checkpoint cursor mismatch",
      require (workingCheckpointCoveredThrough checkpoint == workingMemoryCursor head') "working cursor changed after quiescence",
      require (workingCheckpointWakePacketId checkpoint == wakePacketId packet) "checkpoint wake packet mismatch",
      require (workingCheckpointFocusFrames checkpoint == workingMemoryFocusFrames head') "checkpoint focus closure mismatch",
      require (workingCheckpointActiveTaskId checkpoint == workingMemoryActiveTaskId head') "checkpoint active task mismatch",
      require (Map.notMember (workingCheckpointId checkpoint) (stateCheckpoints state)) "checkpoint id already exists",
      require (Map.notMember (wakePacketId packet) (stateWakePackets state)) "wake packet id already exists",
      nonEmpty "checkpoint id" (workingCheckpointId checkpoint),
      nonEmpty "wake packet id" (wakePacketId packet),
      nonEmpty "checkpoint state ref" (workingCheckpointStateRef checkpoint),
      nonEmpty "checkpoint source closure hash" (workingCheckpointSourceClosureHash checkpoint),
      nonEmpty "wake packet payload ref" (wakePacketPayloadRef packet)
    ]

prepared :: WorkingState -> SleepCycle -> Maybe (WorkingMemoryCheckpoint, WakePacket)
prepared state cycle' =
  (,)
    <$> (sleepCycleCheckpointId cycle' >>= (`Map.lookup` stateCheckpoints state))
    <*> (sleepCycleWakePacketId cycle' >>= (`Map.lookup` stateWakePackets state))

validateFrame :: WorkingMemoryHead -> FocusFrame -> Either Text ()
validateFrame head' frame =
  sequence_
    [ nonEmpty "focus id" (focusFrameId frame),
      nonEmpty "focus task id" (focusFrameTaskId frame),
      require (focusFrameIncarnationId frame == workingMemoryIncarnationId head') "focus incarnation mismatch",
      require (cursorStreamId cursor == cursorStreamId headCursor) "focus cursor stream mismatch",
      require (cursorSeq cursor <= cursorSeq headCursor) "focus cursor exceeds working cursor",
      require (cursorSeq cursor >= 0) "focus cursor must not be negative",
      require (focusFrameRevision frame > 0) "focus revision must be positive"
    ]
  where
    cursor = focusFrameCursor frame
    headCursor = workingMemoryCursor head'

validateFocusRevision :: Maybe FocusFrame -> FocusFrame -> Either Text ()
validateFocusRevision Nothing frame =
  require (focusFrameRevision frame == 1) "new focus revision must be 1"
validateFocusRevision (Just current) frame =
  require
    (focusFrameRevision frame == focusFrameRevision current + 1)
    ( "stale focus revision: expected "
        <> shown (focusFrameRevision current + 1)
        <> ", got "
        <> shown (focusFrameRevision frame)
    )

advance :: ExperienceCursor -> ExperienceCursor -> Either Text Bool
advance current next
  | cursorStreamId current /= cursorStreamId next = Left "experience cursor stream mismatch"
  | cursorSeq next < cursorSeq current = Left "experience cursor cannot move backwards"
  | otherwise = Right (cursorSeq next > cursorSeq current)

stateRequired :: WorkingStatus -> WorkingMemoryHead -> Either Text ()
stateRequired expected head' = require (workingMemoryStatus head' == expected) (wrongState expected head')

putHead :: WorkingMemoryHead -> WorkingState -> WorkingState
putHead head' state =
  state {stateHeads = Map.insert (workingMemoryIncarnationId head') head' (stateHeads state)}

putCycle :: SleepCycle -> WorkingState -> WorkingState
putCycle cycle' state =
  state {stateSleepCycles = Map.insert (sleepCycleId cycle') cycle' (stateSleepCycles state)}

save :: (WorkingState -> IO ()) -> WorkingState -> value -> IO (WorkingState, Either Text value)
save persist changed value = persist changed $> (changed, Right value)

stale :: Int -> Int -> Text
stale expected actual =
  "stale working memory revision: expected " <> shown expected <> ", got " <> shown actual

wrongState :: WorkingStatus -> WorkingMemoryHead -> Text
wrongState expected head' =
  "invalid working memory transition: expected "
    <> statusName expected
    <> ", got "
    <> statusName (workingMemoryStatus head')

wrongCycle :: SleepCycleStatus -> SleepCycle -> Text
wrongCycle expected cycle' =
  "invalid sleep cycle transition: expected "
    <> cycleStatusName expected
    <> ", got "
    <> cycleStatusName (sleepCycleStatus cycle')

statusName :: WorkingStatus -> Text
statusName = \case
  WorkingAwake -> "awake"
  WorkingQuiescing -> "quiescing"
  WorkingAsleep -> "asleep"
  WorkingWaking -> "waking"
  WorkingDegraded -> "degraded"

cycleStatusName :: SleepCycleStatus -> Text
cycleStatusName = \case
  CycleQuiescing -> "quiescing"
  CyclePrepared -> "prepared"
  CycleAsleep -> "asleep"
  CycleWaking -> "waking"
  CycleAwake -> "awake"
  CycleDegraded -> "degraded"

cursorMismatch :: Text -> ExperienceCursor -> Text
cursorMismatch incarnation cursor =
  "experience stream mismatch: expected "
    <> experienceStream incarnation
    <> ", got "
    <> cursorStreamId cursor

experienceStream :: Text -> Text
experienceStream = ("experience/" <>)

nonEmpty :: Text -> Text -> Either Text ()
nonEmpty label value = require (not (Text.null (Text.strip value))) (label <> " must not be empty")

require :: Bool -> Text -> Either Text ()
require condition failure = bool (Left failure) (Right ()) condition

shown :: Show value => value -> Text
shown = Text.pack . show

loadState :: FilePath -> IO (Either Text WorkingState)
loadState path =
  (try (eitherDecodeFileStrict path) :: IO (Either IOException (Either String WorkingState)))
    <&> \case
      Left failure
        | isDoesNotExistError failure -> Right emptyState
        | otherwise -> Left ("cannot read working memory: " <> Text.pack (displayException failure))
      Right (Left failure) -> Left ("invalid working memory: " <> Text.pack failure)
      Right (Right state) -> state <$ validateState state

validateState :: WorkingState -> Either Text ()
validateState state =
  traverse_ (uncurry validateHead) (Map.toList (stateHeads state))
    *> traverse_ (uncurry validateCheckpoint) (Map.toList (stateCheckpoints state))
    *> traverse_ (uncurry validatePacket) (Map.toList (stateWakePackets state))
    *> traverse_ (uncurry validateCycle) (Map.toList (stateSleepCycles state))
  where
    validateHead key head' =
      sequence_
        [ require (key == workingMemoryIncarnationId head') ("working head key mismatch: " <> key),
          require (workingMemoryId head' == "working/" <> key) ("working head id mismatch: " <> key),
          require (workingMemoryRevision head' > 0) ("working head revision must be positive: " <> key),
          require (cursorStreamId (workingMemoryCursor head') == experienceStream key) ("working cursor stream mismatch: " <> key),
          require (cursorSeq (workingMemoryCursor head') >= 0) ("working cursor must not be negative: " <> key),
          traverse_ (uncurry (validateStoredFrame head')) (Map.toList (workingMemoryFocusFrames head')),
          maybe (Right ()) (\task -> require (Map.member task (workingMemoryFocusFrames head')) ("unknown active focus in " <> key)) (workingMemoryActiveTaskId head'),
          maybe (Right ()) (\identifier -> require (Map.member identifier (stateCheckpoints state)) ("unknown checkpoint in " <> key)) (workingMemoryCheckpointId head'),
          maybe (Right ()) (\identifier -> require (Map.member identifier (stateWakePackets state)) ("unknown wake packet in " <> key)) (workingMemoryWakePacketId head')
        ]
    validateStoredFrame head' key frame =
      require (key == focusFrameTaskId frame) ("focus key mismatch: " <> key) *> validateFrame head' frame
    validateCheckpoint key checkpoint =
      sequence_
        [ require (key == workingCheckpointId checkpoint) ("checkpoint key mismatch: " <> key),
          require (workingCheckpointBaseRevision checkpoint > 0) ("checkpoint revision must be positive: " <> key),
          require
            (cursorStreamId (workingCheckpointCoveredThrough checkpoint) == experienceStream (workingCheckpointIncarnationId checkpoint))
            ("checkpoint cursor stream mismatch: " <> key),
          require (Map.member (workingCheckpointWakePacketId checkpoint) (stateWakePackets state)) ("checkpoint wake packet missing: " <> key)
        ]
    validatePacket key packet =
      sequence_
        [ require (key == wakePacketId packet) ("wake packet key mismatch: " <> key),
          nonEmpty "wake packet incarnation id" (wakePacketIncarnationId packet),
          nonEmpty "wake packet task id" (wakePacketTaskId packet)
        ]
    validateCycle key cycle' =
      sequence_
        [ require (key == sleepCycleId cycle') ("sleep cycle key mismatch: " <> key),
          require (sleepCycleExpectedRevision cycle' > 0) ("sleep cycle revision must be positive: " <> key),
          require
            (cursorStreamId (sleepCycleFrozenCursor cycle') == experienceStream (sleepCycleIncarnationId cycle'))
            ("sleep cycle cursor stream mismatch: " <> key),
          maybe (Right ()) (\identifier -> require (Map.member identifier (stateCheckpoints state)) ("sleep checkpoint missing: " <> key)) (sleepCycleCheckpointId cycle'),
          maybe (Right ()) (\identifier -> require (Map.member identifier (stateWakePackets state)) ("sleep wake packet missing: " <> key)) (sleepCycleWakePacketId cycle')
        ]

workingPath :: FilePath -> FilePath
workingPath dir = dir </> "working"

statePath :: FilePath -> FilePath
statePath dir = workingPath dir </> "working.json"
