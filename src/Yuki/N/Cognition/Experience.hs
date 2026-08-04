module Yuki.N.Cognition.Experience
  ( appendRunEvents,
    archiveTaskRun,
    archiveTaskSnapshot,
    drainConsolidations,
    enqueueConsolidation,
    impressionModels,
    persistPayload,
    withIncarnationLock,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Monad (void)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Bool (bool)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor ((<&>))
import Data.List (find, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent
import Yuki.N.Blob
import Yuki.N.Cognition.Tools
import Yuki.N.Cognition.Types
import Yuki.N.Experience
import Yuki.N.Incarnation
import Yuki.N.Memory.Archive
import Yuki.N.Memory.Impression
import Yuki.N.Memory.Working
import Yuki.N.Model

impressionModels :: Cognition -> Incarnation -> [Model]
impressionModels cognition incarnation =
  maybe available selected (nonEmpty =<< incarnationImpressionModel incarnation)
 where
  available = cognitionModels cognition
  selected requested =
    filter
      ( \model ->
          modelName model == requested
            || modelProvider model <> "/" <> modelName model == requested
      )
      available

persistPayload :: Cognition -> Text -> Text -> Text -> Value -> IO Text
persistPayload cognition identity purpose source value =
  blobPut
    (cognitionBlobs cognition)
    "application/json"
    (encode value)
    >>= attach
 where
  attach meta =
    blobAttach
      (cognitionBlobs cognition)
      (refOf meta)
      (blobId meta)
      identity
      purpose
      source
      >>= either (ioError . userError . Text.unpack) (const (pure (blobId meta)))
  refOf meta =
    "ref-" <> Text.take 32 (sha256 (TextEncoding.encodeUtf8 (Text.intercalate "\NUL" [identity, purpose, source, blobId meta])))

archiveTaskRun ::
  Cognition ->
  Incarnation ->
  AGUI.RunAgentInput ->
  RunOutcome ->
  [ChatMessage] ->
  IO (Either Text ArchiveRun)
archiveTaskRun cognition incarnation input outcome =
  archiveTaskSnapshot cognition incarnation input (outcomeStatus outcome) (outcomeMessage outcome)

archiveTaskSnapshot ::
  Cognition ->
  Incarnation ->
  AGUI.RunAgentInput ->
  Text ->
  Maybe Text ->
  [ChatMessage] ->
  IO (Either Text ArchiveRun)
archiveTaskSnapshot cognition incarnation input status failure messages =
  taskArchiveAppend
    (cognitionArchive cognition)
    ( ArchiveRunDraft
        (incarnationId incarnation)
        (AGUI.runThreadId input)
        (AGUI.runId input)
        latestIntent
        status
        failure
        (archiveEntries (AGUI.runId input) (currentRunMessages messages))
    )
 where
  latestIntent =
    listToMaybe
      ( reverse
          [ AGUI.userId user
          | AGUI.User user <- AGUI.runMessages input
          ]
      )

experienceDraft ::
  Text ->
  Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Text ->
  Text ->
  ExperienceDraft
experienceDraft identity operation intent task run delegation causation kind payload =
  ExperienceDraft
    identity
    operation
    identity
    intent
    task
    run
    delegation
    causation
    kind
    payload
    payload

appendRunEvents :: Cognition -> Incarnation -> AGUI.RunAgentInput -> RunOutcome -> [ChatMessage] -> IO [ExperienceEvent]
appendRunEvents cognition incarnation input outcome messages =
  appendMaybe "UserInputAccepted" (String <$> latestUser)
    >>= runAssistant
 where
  identity = incarnationId incarnation
  run = AGUI.runId input
  task = AGUI.runThreadId input
  latestUser =
    listToMaybe
      ( reverse
          [ text
          | AGUI.User user <- AGUI.runMessages input,
            Right text <- [AGUI.userText (AGUI.userContent user)]
          ]
      )
  latestAssistant =
    listToMaybe
      ( reverse
          [ turn
          | ChatAssistant turn <- suffixAfterLastUser messages,
            maybe False (not . Text.null . Text.strip) (turnText turn)
          ]
      )
  appendMaybe _ Nothing = pure Nothing
  appendMaybe kind (Just value) = Just <$> appendValue kind value
  appendValue kind value =
    appendExperienceIdempotent
      cognition
      identity
      run
      kind
      "experience"
      (run <> "/" <> kind)
      value
      (draft kind)
  runAssistant userEvent =
    appendMaybe "AssistantOutcomeRecorded" (toJSON <$> latestAssistant)
      >>= terminate userEvent
  terminate userEvent assistantEvent =
    appendValue
      "RunTerminated"
      ( object
          [ "status" .= outcomeStatus outcome,
            "code" .= outcomeCode outcome,
            "message" .= outcomeMessage outcome,
            "messageCount" .= length messages,
            "assistantOutcomeRef" .= (experienceEventId <$> assistantEvent)
          ]
      )
      <&> collect userEvent assistantEvent
  collect userEvent assistantEvent terminal =
    catMaybes [userEvent, assistantEvent, Just terminal]
  draft =
    experienceDraft
      identity
      run
      (Just run)
      (Just task)
      (Just run)
      (delegationIdOf input)
      Nothing

delegationIdOf :: AGUI.RunAgentInput -> Maybe Text
delegationIdOf input =
  parseMaybe (withObject "forwardedProps" (.: "delegationId")) (AGUI.runForwardedProps input)

enqueueConsolidation :: Cognition -> Incarnation -> [ExperienceEvent] -> IO ExperienceEvent
enqueueConsolidation cognition incarnation events =
  appendExperienceIdempotent
    cognition
    identity
    operation
    "ImpressionConsolidationRequested"
    "impression-consolidation"
    operation
    (toJSON request)
    draft
    >>= spawn
 where
  identity = incarnationId incarnation
  reference = maybe ("empty/" <> identity) experienceEventId (listToMaybe (reverse events))
  operation = "impression/consolidate/" <> reference
  request = ConsolidationRequest reference (fmap experienceEventId events)
  terminal = listToMaybe (reverse events)
  draft =
    experienceDraft
      identity
      operation
      (experienceIntentId =<< terminal)
      (experienceTaskId =<< terminal)
      (experienceRunId =<< terminal)
      (experienceDelegationId =<< terminal)
      (experienceEventId <$> terminal)
      "ImpressionConsolidationRequested"
  spawn event =
    event
      <$ void
        ( forkIO
            (withIncarnationLock cognition identity (drainConsolidations cognition incarnation))
        )

drainConsolidations :: Cognition -> Incarnation -> IO ()
drainConsolidations cognition incarnation =
  nextPending >>= traverse_ (\request -> process request *> drainConsolidations cognition incarnation)
 where
  identity = incarnationId incarnation
  experiences = cognitionExperiences cognition
  nextPending =
    experienceEvents experiences identity <&> nextPendingEvent
  nextPendingEvent events =
    let completed =
          Set.fromList
            [ experienceOperationId event
            | event <- events,
              experienceKind event `elem` ["ImpressionConsolidationSucceeded", "ImpressionConsolidationFailed"]
            ]
     in listToMaybe
          [ event
          | event <- sortOn experienceSeq events,
            experienceKind event == "ImpressionConsolidationRequested",
            experienceOperationId event `Set.notMember` completed
          ]
  process requested =
    loadConsolidationRequest cognition requested
      >>= either
        (failWith requested)
        (consolidateRequest requested)
  consolidateRequest requested request =
    experienceClosure cognition identity (consolidationEventIds request)
      >>= either
        (failWith requested)
        (consolidateCatalog requested request)
  consolidateCatalog requested request closure =
    taskArchiveTasks (cognitionArchive cognition) identity 64
      >>= consolidate requested request closure
  consolidate requested request closure catalog =
    consolidateImpression
      (impressionModels cognition incarnation)
      (cognitionJournal cognition)
      (cognitionImpressions cognition)
      identity
      (consolidationExperienceRef request)
      (fmap archiveTaskId catalog)
      (consolidationExperienceRef request : consolidationEventIds request)
      closure
      >>= either
        (failWith requested)
        (succeedWith requested)
  failWith requested failure =
    finish requested "ImpressionConsolidationFailed" (object ["error" .= failure])
  succeedWith requested revision =
    finish requested "ImpressionConsolidationSucceeded" (object ["revision" .= revision])
  finish requested kind payload =
    void
      ( appendExperienceIdempotent
          cognition
          identity
          (experienceOperationId requested)
          kind
          "impression-consolidation"
          (experienceOperationId requested <> "/" <> kind)
          payload
          ( \payloadRef ->
              experienceDraft
                identity
                (experienceOperationId requested)
                (experienceIntentId requested)
                (experienceTaskId requested)
                (experienceRunId requested)
                (experienceDelegationId requested)
                (Just (experienceEventId requested))
                kind
                payloadRef
          )
      )

loadConsolidationRequest :: Cognition -> ExperienceEvent -> IO (Either Text ConsolidationRequest)
loadConsolidationRequest cognition event =
  blobFetch (cognitionBlobs cognition) (experiencePayloadRef event)
    <&> either Left (either (Left . Text.pack) Right . eitherDecode)

experienceClosure :: Cognition -> Text -> [Text] -> IO (Either Text Text)
experienceClosure cognition identity identifiers =
  experienceEvents (cognitionExperiences cognition) identity >>= closureEvents
 where
  closureEvents events =
    let index = Map.fromList [(experienceEventId event, event) | event <- events]
     in case traverse (`Map.lookup` index) identifiers of
          Nothing -> pure (Left "impression consolidation references a missing experience event")
          Just selected ->
            traverse render selected
              <&> fmap encodeEvents . sequence
  encodeEvents items =
    Text.take 50000 (encodeText (object ["events" .= items]))
  render event =
    blobFetch (cognitionBlobs cognition) (experiencePayloadRef event)
      <&> fmap (payloadView event)
  payloadView event payload =
    object
      [ "eventId" .= experienceEventId event,
        "kind" .= experienceKind event,
        "taskId" .= experienceTaskId event,
        "runId" .= experienceRunId event,
        "authority" .= experienceActorId event,
        "sourceRef" .= experiencePayloadRef event,
        "payload" .= Text.take 14000 (TextEncoding.decodeUtf8 (LazyByteString.toStrict payload))
      ]

appendExperienceIdempotent ::
  Cognition ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Value ->
  (Text -> ExperienceDraft) ->
  IO ExperienceEvent
appendExperienceIdempotent cognition identity operation kind purpose source payload draft =
  existing >>= maybe prepare pure
 where
  experiences = cognitionExperiences cognition
  existing =
    find
      ( (&&)
          <$> ((== operation) . experienceOperationId)
          <*> ((== kind) . experienceKind)
      )
      <$> experienceEvents experiences identity
  prepare =
    persistPayload cognition identity purpose source payload >>= retry 16
  retry :: Int -> Text -> IO ExperienceEvent
  retry remaining payloadRef =
    experienceHead experiences identity >>= appendAt
   where
    appendAt cursor =
      experienceAppend experiences (Just cursor) (draft payloadRef)
        >>= either (retryOrFail remaining payloadRef) pure
    retryOrFail remaining' payloadRef' failure
      | remaining' <= 0 = ioError (userError (Text.unpack failure))
      | otherwise = existing >>= maybe (retry (remaining' - 1) payloadRef') pure

withIncarnationLock :: Cognition -> Text -> IO value -> IO value
withIncarnationLock cognition identity action =
  modifyMVar (cognitionRunLocks cognition) acquire
    >>= flip withMVar (const action)
 where
  acquire locks =
    case Map.lookup identity locks of
      Just lock -> pure (locks, lock)
      Nothing -> newMVar () >>= insertLock locks
  insertLock locks lock =
    pure (Map.insert identity lock locks, lock)

suffixAfterLastUser :: [ChatMessage] -> [ChatMessage]
suffixAfterLastUser = reverse . takeWhile notUser . reverse
 where
  notUser ChatUser {} = False
  notUser _ = True

outcomeStatus :: RunOutcome -> Text
outcomeStatus = \case
  RunSucceeded -> "completed"
  RunFailed {} -> "failed"
  RunWasCancelled -> "cancelled"

outcomeCode :: RunOutcome -> Maybe Text
outcomeCode = \case
  RunFailed code _ -> Just code
  _ -> Nothing

outcomeMessage :: RunOutcome -> Maybe Text
outcomeMessage = \case
  RunFailed _ message -> Just message
  _ -> Nothing

currentRunMessages :: [ChatMessage] -> [ChatMessage]
currentRunMessages messages =
  maybe messages (`drop` messages) latestUserIndex
 where
  latestUserIndex =
    foldl
      (\found (index, message) -> bool found (Just index) (isUser message))
      Nothing
      (zip [0 ..] messages)
  isUser ChatUser {} = True
  isUser _ = False

archiveEntries :: Text -> [ChatMessage] -> [ArchiveEntryDraft]
archiveEntries run =
  concatMap (filter (not . Text.null . Text.strip . archiveEntryDraftContent) . one)
    . zip [1 :: Int ..]
 where
  source index suffix =
    "task/"
      <> run
      <> "/"
      <> shown index
      <> "/"
      <> suffix
  one (index, ChatSystem content)
    | wakePacketMarker `Text.isPrefixOf` content =
        [draft (source index "wake") ArchiveWakePacket content Nothing Nothing Nothing]
    | otherwise =
        [draft (source index "instruction") ArchiveInstruction content Nothing Nothing Nothing]
  one (index, ChatUser content) =
    [draft (source index "user") ArchiveUser content Nothing Nothing Nothing]
  one (_, ChatToolResult call content) =
    [draft (call <> "/result") ArchiveToolResult content (Just call) (Just call) Nothing]
  one (index, ChatAssistant turn) =
    [ draft (turnGroup <> "/reasoning") ArchiveReasoning content (Just turnGroup) Nothing Nothing
    | content <- maybe [] pure (turnReasoning turn)
    ]
      <> [ draft (turnGroup <> "/assistant") ArchiveAssistant content (Just turnGroup) Nothing Nothing
         | content <- maybe [] pure (turnText turn)
         ]
      <> [ draft
             (modelToolCallId call <> "/call")
             ArchiveToolCall
             (encodeText call)
             (Just turnGroup)
             (Just (modelToolCallId call))
             (Just (modelToolName call))
         | call <- turnToolCalls turn
         ]
   where
    turnGroup = fromMaybe (source index "assistant") (nonEmpty (turnMessageId turn))
  draft = ArchiveEntryDraft
