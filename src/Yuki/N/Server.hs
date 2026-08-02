module Yuki.N.Server
  ( ConfigView (..),
    application,
    runServer,
  )
where

import Control.Applicative (liftA2, (<|>))
import Control.Concurrent (Chan, forkIO, killThread, readChan, threadDelay, writeChan)
import Control.Exception (bracket)
import Control.Monad (forever, join, when, (>=>))
import Data.Aeson (FromJSON (..), ToJSON, Value (..), eitherDecode, encode, object, toJSON, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (parseEither)
import Data.Bool (bool)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.IORef (readIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.String (fromString)
import Data.Text (Text, unpack)
import Data.Text qualified as TextValue
import Data.Text.Encoding qualified as Text
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import System.Directory (doesDirectoryExist)
import Text.Read (readMaybe)
import Yuki.N.AGUI.Event (Event)
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent (BackendTool (..), Runtime (..), compactHistory, defaultHooks, newId, runAgent, runtimeContextWindow, toChatMessages)
import Yuki.N.Artifact (ArtifactStore (..))
import Yuki.N.Cognition
import Yuki.N.Cognition qualified as Cognition
import Yuki.N.Config (Settings (..))
import Yuki.N.Context
  ( Compaction (..),
    ContextConfig (..),
    contextBudget,
    contextWindow,
    estimateMessagesTokens,
    estimateToolsTokens,
  )
import Yuki.N.ContextEpoch
  ( ContextEpoch (..),
    ContextEpochStore (..),
    projectedAguiMessages,
  )
import Yuki.N.Dispatch
import Yuki.N.Experience (ExperienceStore (..))
import Yuki.N.Facts (FactStore (..))
import Yuki.N.Incarnation
import Yuki.N.Inspect (Inspection (..), forRun, runIds, runSummary, runTrace)
import Yuki.N.Journal (journalSnapshot)
import Yuki.N.Memory (ThreadStore (..))
import Yuki.N.Memory.Archive
import Yuki.N.Memory.Impression (ImpressionStore (..))
import Yuki.N.Memory.LongTerm
import Yuki.N.Memory.Working
import Yuki.N.Model (ChatMessage (ChatUser))
import Yuki.N.Replay (memoryInjected, readJournal, replayEntries, replayWithStores)
import Yuki.N.Runs (RunKind (..), RunRegistry, activeThreads, cancelRun, followUpRun, steerRun)
import Yuki.N.Sessions
import Yuki.N.Telemetry (ActivityFrame (..), DeliveryRecord (..), Ledger, LiveStatus (..), Telemetry, liveRuns, noteCancelling, subscribe, telemetryLedger)
import Yuki.N.Telemetry.Ledger (deliveriesFor, fsChangesFor)
import Yuki.N.ThreadConfig (ThreadConfig (..), ThreadConfigStore (..), cwdPath, resolveThreadConfig)
import Yuki.N.Tools (completePaths, listTree)
import Yuki.N.Transcript (TranscriptStore (..), renderTranscript, toAguiMessages)

data ConfigView = ConfigView
  { configViewGlobal :: Value,
    configViewStore :: ThreadConfigStore,
    configViewDefaults :: ThreadConfig,
    configViewModels :: IO (Either Text [Text]),
    configViewProviders :: IO [Value]
  }

data CreateSessionRequest = CreateSessionRequest Text (Maybe Text) (Maybe Text)

instance FromJSON CreateSessionRequest where
  parseJSON = withObject "CreateSessionRequest" $ \fields ->
    CreateSessionRequest
      <$> fields .: "threadId"
      <*> fields .:? "title"
      <*> fields .:? "incarnationId"

newtype RenameSessionRequest = RenameSessionRequest Text

instance FromJSON RenameSessionRequest where
  parseJSON = withObject "RenameSessionRequest" $ \fields -> RenameSessionRequest <$> fields .: "title"

data ForkSessionRequest = ForkSessionRequest Text (Maybe Text) (Maybe Text)

instance FromJSON ForkSessionRequest where
  parseJSON = withObject "ForkSessionRequest" $ \fields ->
    ForkSessionRequest
      <$> fields .: "threadId"
      <*> fields .:? "title"
      <*> fields .:? "messageId"

newtype PathRequest = PathRequest Text

instance FromJSON PathRequest where
  parseJSON = withObject "PathRequest" $ \fields -> PathRequest <$> fields .: "prefix"

data CreateIncarnationRequest = CreateIncarnationRequest Text Text Text (Maybe Text)

instance FromJSON CreateIncarnationRequest where
  parseJSON = withObject "CreateIncarnationRequest" $ \fields ->
    CreateIncarnationRequest
      <$> fields .: "id"
      <*> fields .: "name"
      <*> fields .: "direction"
      <*> fields .:? "impressionModel"

data UpdateIncarnationRequest = UpdateIncarnationRequest Int Text Text (Maybe Text)

instance FromJSON UpdateIncarnationRequest where
  parseJSON = withObject "UpdateIncarnationRequest" $ \fields ->
    UpdateIncarnationRequest
      <$> fields .: "expectedRevision"
      <*> fields .: "name"
      <*> fields .: "direction"
      <*> fields .:? "impressionModel"

data GeneratePromptRequest = GeneratePromptRequest Text Bool

instance FromJSON GeneratePromptRequest where
  parseJSON = withObject "GeneratePromptRequest" $ \fields ->
    GeneratePromptRequest
      <$> fields .: "sourceIntent"
      <*> fields .:? "activate" .!= False

newtype CreateDispatchRequest = CreateDispatchRequest Text

instance FromJSON CreateDispatchRequest where
  parseJSON = withObject "CreateDispatchRequest" $ \fields -> CreateDispatchRequest <$> fields .: "input"

data PatchDispatchRequest = PatchDispatchRequest (Maybe Text) (Maybe Text) (Maybe ThreadConfig)

instance FromJSON PatchDispatchRequest where
  parseJSON = withObject "PatchDispatchRequest" $ \fields ->
    PatchDispatchRequest
      <$> fields .:? "title"
      <*> fields .:? "prompt"
      <*> fields .:? "config"

data EditPromptRequest = EditPromptRequest Text Text (Maybe Text)

instance FromJSON EditPromptRequest where
  parseJSON = withObject "EditPromptRequest" $ \fields ->
    EditPromptRequest
      <$> fields .: "sourceIntent"
      <*> fields .: "content"
      <*> fields .:? "parentRevision"

newtype ActivatePromptRequest = ActivatePromptRequest Int

instance FromJSON ActivatePromptRequest where
  parseJSON = withObject "ActivatePromptRequest" $ \fields ->
    ActivatePromptRequest <$> fields .: "expectedRevision"

data MemorySearchRequest = MemorySearchRequest Text (Maybe MemoryVisibility) Int

instance FromJSON MemorySearchRequest where
  parseJSON = withObject "MemorySearchRequest" $ \fields ->
    MemorySearchRequest
      <$> fields .: "query"
      <*> fields .:? "visibility"
      <*> fields .:? "limit" .!= 8

data TaskRecordSearchRequest = TaskRecordSearchRequest Text (Maybe Text) [ArchiveKind] Bool Int Int Bool

instance FromJSON TaskRecordSearchRequest where
  parseJSON = withObject "TaskRecordSearchRequest" $ \fields ->
    TaskRecordSearchRequest
      <$> fields .: "query"
      <*> fields .:? "taskId"
      <*> fields .:? "kinds" .!= []
      <*> fields .:? "caseSensitive" .!= False
      <*> fields .:? "limit" .!= 20
      <*> fields .:? "offset" .!= 0
      <*> fields .:? "includeProcess" .!= False

data RememberMemoryRequest = RememberMemoryRequest MemoryVisibility Text Text [Text] [Text]

instance FromJSON RememberMemoryRequest where
  parseJSON = withObject "RememberMemoryRequest" $ \fields ->
    RememberMemoryRequest
      <$> fields .:? "visibility" .!= MemoryPrivate
      <*> fields .: "kind"
      <*> fields .: "content"
      <*> fields .:? "keywords" .!= []
      <*> fields .:? "sourceRefs" .!= []

newtype SleepThreadRequest = SleepThreadRequest (Maybe Text)

instance FromJSON SleepThreadRequest where
  parseJSON = withObject "SleepThreadRequest" $ \fields -> SleepThreadRequest <$> fields .:? "reason"

application :: Maybe Text -> Maybe Inspection -> Maybe ConfigView -> Maybe RunRegistry -> Maybe DispatchService -> Maybe Telemetry -> (Text -> IO Runtime) -> Application
application cors inspection configs runs dispatches telemetry runtimeFor request respond =
  route (requestMethod request) (pathInfo request)
 where
  route "POST" ["agent"] = handleAgent
  route "POST" ["agent", "cancel"] = handleCancel
  route "POST" ["agent", "steer"] = handleSteer
  route "POST" ["agent", "follow-up"] = handleFollowUp
  route "POST" ["replay"] = withJournal (replayReport (inspectionMemory =<< inspection))
  route "OPTIONS" _ =
    respond (responseLBS status204 (corsHeaders cors <> preflightHeaders) "")
  route "GET" ["config"] = withConfig (respond . ok . configViewGlobal)
  route "GET" ["providers"] = withConfig (\view -> configViewProviders view >>= respond . ok)
  route "GET" ["models"] = withConfig (\view -> configViewModels view >>= respond . either failed ok)
  route "GET" ["config", "threads", threadId] =
    withConfig (\view -> threadConfigRead (configViewStore view) threadId >>= respond . ok)
  route "GET" ["config", "threads", threadId, "capabilities"] =
    runtimeFor threadId >>= respond . ok . Map.keys . runtimeTools
  route "GET" ["config", "threads", threadId, "context"] =
    runtimeFor threadId >>= respond . ok . renderContextPolicy
  route "PUT" ["config", "threads", threadId] = withConfig (saveConfig threadId)
  route "GET" ["config", "threads", threadId, "tree"] = withConfig (tree threadId)
  route "POST" ["config", "threads", threadId, "paths"] = withConfig (paths threadId)
  route "GET" ["incarnations"] = withCognition listIncarnations
  route "POST" ["incarnations"] = withCognition createIncarnation
  route "GET" ["incarnations", incarnationId] = withCognition (readIncarnation incarnationId)
  route "GET" ["incarnations", incarnationId, "tasks"] = withSessions (incarnationTasks incarnationId)
  route "GET" ["incarnations", incarnationId, "home"] = withSessions (homeThread incarnationId)
  route "GET" ["fleet"] = withTelemetry fleetHandler
  route "GET" ["activity", "stream"] = withTelemetry activityStreamHandler
  route "GET" ["incarnations", incarnationId, "activity"] = withTelemetry (activityHandler incarnationId)
  route "GET" ["incarnations", incarnationId, "deliveries"] = withTelemetry (deliveriesHandler incarnationId)
  route "GET" ["incarnations", incarnationId, "fs-changes"] = withTelemetry (fsChangesHandler incarnationId)
  route "POST" ["incarnations", incarnationId, "dispatches"] = withCognition (createDispatchRoute incarnationId)
  route "GET" ["incarnations", incarnationId, "dispatches"] = withDispatch (listDispatchesFor incarnationId)
  route "GET" ["dispatches", dispatchId] = withDispatch (readDispatch dispatchId)
  route "PATCH" ["dispatches", dispatchId] = withDispatch (patchDispatchRoute dispatchId)
  route "POST" ["dispatches", dispatchId, "confirm"] = withDispatch (confirmDispatchRoute dispatchId)
  route "POST" ["dispatches", dispatchId, "cancel"] = withDispatch (cancelDispatchRoute dispatchId)
  route "PATCH" ["incarnations", incarnationId] = withCognition (updateIncarnation incarnationId)
  route "POST" ["incarnations", incarnationId, "archive"] = withCognition (archiveIncarnation incarnationId)
  route "POST" ["incarnations", incarnationId, "restore"] = withCognition (restoreIncarnation incarnationId)
  route "POST" ["incarnations", incarnationId, "delete"] = withCognition (deleteIncarnationRoute incarnationId)
  route "GET" ["prompts", "root"] = withCognition rootPrompts
  route "POST" ["prompts", "root"] = withCognition editRootPrompt
  route "POST" ["prompts", "root", promptId, "activate"] =
    withCognition (activateRootPrompt promptId)
  route "GET" ["incarnations", incarnationId, "prompts"] = withCognition (listPrompts incarnationId)
  route "POST" ["incarnations", incarnationId, "prompts"] = withCognition (editPrompt incarnationId)
  route "POST" ["incarnations", incarnationId, "prompts", "generate"] = withCognition (generatePrompt incarnationId)
  route "POST" ["incarnations", incarnationId, "prompts", promptId, "activate"] =
    withCognition (activatePrompt incarnationId promptId)
  route "GET" ["incarnations", incarnationId, "impression"] = withCognition (readImpression incarnationId)
  route "GET" ["incarnations", incarnationId, "impression", "activations"] =
    withCognition (listActivations incarnationId)
  route "GET" ["incarnations", incarnationId, "impression", "revisions"] =
    withCognition (listImpressionRevisions incarnationId)
  route "GET" ["incarnations", incarnationId, "working-memory"] = withCognition (readWorking incarnationId)
  route "GET" ["incarnations", incarnationId, "sleep-cycles"] = withCognition (listSleeps incarnationId)
  route "GET" ["incarnations", incarnationId, "experiences"] = withCognition (listExperiences incarnationId)
  route "GET" ["incarnations", incarnationId, "task-records"] = withCognition (taskRecords incarnationId)
  route "POST" ["incarnations", incarnationId, "task-records", "search"] =
    withCognition (searchTaskRecords incarnationId)
  route "GET" ["incarnations", incarnationId, "task-records", entryId] =
    withCognition (readTaskRecord incarnationId entryId)
  route "GET" ["incarnations", incarnationId, "memories"] = withCognition (memoryCatalog incarnationId)
  route "POST" ["incarnations", incarnationId, "memories", "search"] =
    withCognition (searchMemories incarnationId)
  route "POST" ["incarnations", incarnationId, "memories"] = withCognition (rememberMemory incarnationId)
  route "GET" ["incarnations", incarnationId, "memories", memoryId] =
    withCognition (readMemory incarnationId memoryId)
  route "POST" ["incarnations", incarnationId, "memories", memoryId, "void"] =
    withCognition (voidMemory incarnationId memoryId)
  route "GET" ["incarnations", incarnationId, "memory-receipts"] =
    withCognition (memoryReceipts incarnationId)
  route "GET" ["threads", threadId, "context-epochs"] = withCognition (contextEpochs threadId)
  route "GET" ["memory", "threads", threadId] = withMemory (brief threadId)
  route "GET" ["memory", "facts"] = withMemory facts
  route "GET" ["threads"] = withSessions sessionList
  route "POST" ["threads"] = withSessions createThread
  route "POST" ["threads", "import"] = withSessions importThread
  route "PATCH" ["threads", threadId] = withSessions (renameThread threadId)
  route "POST" ["threads", threadId, "archive"] = withSessions (archiveThread threadId)
  route "POST" ["threads", threadId, "restore"] = withSessions (restoreThread threadId)
  route "POST" ["threads", threadId, "fork"] = withSessions (forkThread threadId)
  route "POST" ["threads", threadId, "compact"] = withSessions (sleepThread threadId)
  route "POST" ["threads", threadId, "sleep"] = withSessions (sleepThread threadId)
  route "GET" ["threads", threadId, "export"] = withSessions (exportThread threadId)
  route "GET" ["threads", threadId, "transcript"] = threadTranscript threadId
  route "GET" ["artifacts"] = withStore (fmap ok . artifactList)
  route "GET" ["artifacts", identifier] = withStore (artifact identifier)
  route "GET" ["journal", "runs"] = withJournal journalRuns
  route "GET" ["journal", "runs", runId, "summary"] = withJournal (summaryFor runId)
  route "GET" ["journal", "runs", runId, "trace"] = withJournal (traceFor runId)
  route "GET" ["journal"] = withJournal journalEntries
  route _ ["agent"] =
    respond (jsonResponse cors status405 [("Allow", "POST, OPTIONS")] (message "method not allowed"))
  route _ _ = notFound
  notFound = respond (jsonResponse cors status404 [] (message "not found"))
  withMemory use = maybe notFound (use >=> respond) (inspectionMemory =<< inspection)
  withStore use = maybe notFound (use >=> respond) (inspectionArtifacts =<< inspection)
  withJournal use =
    maybe
      notFound
      (\load -> load >>= either (respond . failed) use)
      (journalSource =<< inspection)
  journalSource insp =
    case inspectionLiveJournal insp of
      Just journal -> Just (Right <$> journalSnapshot journal)
      Nothing -> readJournal <$> inspectionJournal insp
  withTranscripts use = maybe notFound (use >=> respond) (inspectionTranscripts =<< inspection)
  withSessions use = maybe notFound use (inspectionSessions =<< inspection)
  withTelemetry use = maybe notFound use telemetry
  fleetHandler hub =
    fleetValue hub >>= respond . ok
  fleetValue hub =
    maybe skeleton present (inspectionCognition =<< inspection)
   where
    skeleton = (\runs -> object ["incarnations" .= ([] :: [Value]), "runs" .= runs]) <$> liveRuns hub
    present cognition =
      incarnationList (cognitionIncarnations cognition) >>= fleetEntries
    fleetEntries incarnations =
      liveRuns hub >>= \runs ->
        (\entries -> object ["incarnations" .= entries, "runs" .= runs]) <$> traverse (fleetEntry hub runs) incarnations
  fleetEntry hub runs incarnation =
    liftA2 (,) (draftCountOf identifier) (lastDeliveryOf hub identifier) >>= \(draftCount, lastDelivery) ->
      pure
        ( object
            [ "id" .= identifier,
              "name" .= incarnationName incarnation,
              "state" .= stateOf (activeOf runs identifier) draftCount,
              "activeRuns" .= activeOf runs identifier,
              "waitingDrafts" .= draftCount,
              "lastDeliveryAt" .= lastDelivery
            ]
        )
   where
    identifier = incarnationId incarnation
  activeOf runs identifier =
    length (filter ((== identifier) . liveIncarnation) runs)
  stateOf :: Int -> Int -> Text
  stateOf active drafts
    | active > 0 = "active"
    | drafts > 0 = "waiting"
    | otherwise = "idle"
  draftCountOf identifier =
    maybe (pure 0) count dispatches
   where
    count service = length <$> listDispatches (dispatchServiceStore service) identifier (Just Draft)
  draftsOf identifier =
    maybe (pure []) list dispatches
   where
    list service = listDispatches (dispatchServiceStore service) identifier (Just Draft)
  lastDeliveryOf hub identifier =
    readIORef (telemetryLedger hub) >>= maybe (pure Nothing) latest
   where
    latest ledger = fmap deliveryAt . listToMaybe <$> deliveriesFor ledger identifier Nothing 1 Nothing
  activityHandler identifier hub =
    liveRuns hub >>= \runs ->
      liftA2 (,) (draftsOf identifier) (recentDeliveriesOf hub identifier) >>= \(drafts, recent) ->
        respond (ok (activityJson identifier runs drafts recent))
  recentDeliveriesOf hub identifier =
    readIORef (telemetryLedger hub) >>= maybe (pure []) recent
   where
    recent ledger = deliveriesFor ledger identifier Nothing 20 Nothing
  activityJson identifier runs drafts recent =
    object
      [ "incarnationId" .= identifier,
        "home" .= object ["threadId" .= homeThreadId identifier, "activeRunId" .= homeRun],
        "runs" .= own,
        "waitingDrafts" .= drafts,
        "recentDeliveries" .= recent
      ]
   where
    own = filter ((== identifier) . liveIncarnation) runs
    homeRun = listToMaybe [liveRunId run | run <- own, liveKind run == RunHome]
  deliveriesHandler identifier hub =
    ledgerEndpoint hub (\ledger -> deliveriesFor ledger identifier (queryText "threadId") (pageLimit + 1) pageBefore)
  fsChangesHandler identifier hub =
    ledgerEndpoint hub (\ledger -> fsChangesFor ledger identifier (queryText "threadId") (queryText "runId") (pageLimit + 1) pageBefore)
  ledgerEndpoint :: (ToJSON a) => Telemetry -> (Ledger -> IO [a]) -> IO ResponseReceived
  ledgerEndpoint hub query =
    readIORef (telemetryLedger hub) >>= maybe (respond (missing "ledger unavailable")) page
   where
    page ledger =
      query ledger >>= \found ->
        respond (ok (object ["items" .= take pageLimit found, "hasMore" .= (length found > pageLimit)]))
  pageLimit = min 200 (fromMaybe 50 (queryInt "limit" request))
  pageBefore = toInteger <$> queryInt "before" request
  queryText name = Text.decodeUtf8 <$> join (lookup name (queryString request))
  activityStreamHandler hub =
    respond (responseStream status200 (corsHeaders cors <> streamHeaders) (streamActivity hub))
  streamActivity hub write flush =
    subscribe hub >>= \chan ->
      bracket (forkIO (heartbeat chan)) killThread (const (preamble *> cycleFrames chan))
   where
    heartbeat chan = forever (threadDelay 15000000 *> writeChan chan FramePing)
    preamble = fleetValue hub >>= \snapshot -> write (sseFrame "snapshot" snapshot) *> flush
    cycleFrames chan =
      readChan chan >>= \frame -> write (encodeFrame frame) *> flush *> cycleFrames chan
  withConfig use = maybe notFound use configs
  withCognition use = maybe notFound use (inspectionCognition =<< inspection)
  withDispatch use = maybe notFound use dispatches
  createDispatchRoute identifier cognition =
    maybe notFound go dispatches
   where
    go service =
      withBody "invalid dispatch request: " $ \(CreateDispatchRequest input) ->
        bool (publish service input) (respond (bad "dispatch input must not be empty")) (TextValue.null (TextValue.strip input))
    publish service input =
      activeIncarnation cognition identifier
        >>= either (respond . cognitionError) (announce service input)
    announce service input incarnation =
      dispatchServiceGenerate service incarnation input
        >>= respond . jsonResponse cors status202 [] . toJSON
  readDispatch identifier service =
    getDispatch (dispatchServiceStore service) identifier
      >>= respond . maybe (missing "dispatch not found") ok
  listDispatchesFor identifier service =
    either (respond . bad) list (dispatchStatusQuery (queryString request))
   where
    list status =
      listDispatches (dispatchServiceStore service) identifier status >>= respond . ok
  patchDispatchRoute identifier service =
    withBody "invalid dispatch patch: " $ \(PatchDispatchRequest title prompt config) ->
      patchDispatch (dispatchServiceStore service) identifier (DispatchPatch title prompt config)
        >>= respond . either dispatchFailure ok
  confirmDispatchRoute identifier service =
    dispatchServiceConfirm service identifier >>= respond . outcome
   where
    outcome ConfirmMissing = missing "dispatch not found"
    outcome (ConfirmConflict failure) = conflict failure
    outcome (ConfirmError failure) = failed failure
    outcome (ConfirmOk threadId) = jsonResponse cors status201 [] (object ["threadId" .= threadId])
  cancelDispatchRoute identifier service =
    markDispatchCancelled (dispatchServiceStore service) identifier
      >>= respond . either dispatchFailure ok
  dispatchFailure errorText
    | "unknown dispatch:" `TextValue.isPrefixOf` errorText = missing errorText
    | "is not draft" `TextValue.isInfixOf` errorText = conflict errorText
    | otherwise = bad errorText
  incarnationForThread cognition threadId =
    maybe configured (\service -> taskOwnerFor service threadId >>= active) (inspectionSessions =<< inspection)
   where
    configured =
      maybe
        (active "yuki")
        ( \view ->
            threadConfigRead (configViewStore view) threadId
              >>= \local ->
                active
                  ( fromMaybe
                      "yuki"
                      (configIncarnationId (resolveThreadConfig local (configViewDefaults view)))
                  )
        )
        configs
    active identifier =
      incarnationRead (cognitionIncarnations cognition) identifier <&> \case
        Nothing -> Left ("unknown incarnation: " <> identifier)
        Just incarnation
          | incarnationStatus incarnation == IncarnationArchived ->
              Left ("incarnation is archived: " <> identifier)
          | otherwise -> Right incarnation
  threadTranscript threadId =
    case inspectionSessions =<< inspection of
      Just service ->
        findSession (serviceSessions service) threadId >>= \case
          Nothing ->
            transcriptLoad (serviceTranscripts service) threadId >>= \case
              Nothing -> respond (missing "thread not found")
              Just messages ->
                taskOwnerFor service threadId >>= \owner ->
                  ensureSession (serviceSessions service) threadId Nothing owner
                    *> respond (ok (renderTranscript threadId messages))
          Just _ ->
            transcriptLoad (serviceTranscripts service) threadId
              >>= respond . ok . renderTranscript threadId . fromMaybe []
      Nothing -> withTranscripts (transcript threadId)
  withBody :: (FromJSON body) => Text -> (body -> IO ResponseReceived) -> IO ResponseReceived
  withBody label use =
    strictRequestBody request
      >>= either (respond . bad . (label <>) . fromString) use . eitherDecode
  listIncarnations cognition =
    incarnationList (cognitionIncarnations cognition)
      >>= respond
        . ok
        . filter
          ( \incarnation ->
              includeArchived || incarnationStatus incarnation == IncarnationActive
          )
  createIncarnation cognition =
    withBody "invalid incarnation request: " $ \(CreateIncarnationRequest identifier name direction model) ->
      incarnationCreate (cognitionIncarnations cognition) identifier name direction model
        >>= either (respond . cognitionError) (bootstrap cognition)
   where
    bootstrap cognition' created =
      cognitionBootstrapIncarnation cognition' created
        >>= either (respond . cognitionError) (generateInitial cognition')
    generateInitial cognition' bootstrapped =
      cognitionGeneratePrompt cognition' bootstrapped "initial charter generated from the new incarnation direction"
        >>= \case
          Left failure ->
            respond (ok (object ["incarnation" .= bootstrapped, "prompt" .= Null, "promptError" .= failure]))
          Right prompt ->
            promptActivate
              (cognitionIncarnations cognition')
              (incarnationId bootstrapped)
              (incarnationRevision bootstrapped)
              (promptRevisionId prompt)
              >>= respond . either cognitionError (\activated -> ok (object ["incarnation" .= activated, "prompt" .= prompt]))
  readIncarnation identifier cognition =
    incarnationRead (cognitionIncarnations cognition) identifier
      >>= respond
        . maybe
          (missing "incarnation not found")
          ( \incarnation ->
              if includeArchived || incarnationStatus incarnation == IncarnationActive
                then ok incarnation
                else missing "incarnation not found"
          )
  updateIncarnation identifier cognition =
    withBody "invalid incarnation update: " $ \(UpdateIncarnationRequest expected name direction model) ->
      incarnationUpdate (cognitionIncarnations cognition) identifier expected name direction model
        >>= either (respond . cognitionError) (generateRevision cognition)
   where
    generateRevision cognition' changed =
      cognitionGeneratePrompt cognition' changed "identity metadata changed; regenerate the incarnation charter for audit"
        >>= \generated ->
          respond
            ( ok
                ( object
                    [ "incarnation" .= changed,
                      "prompt" .= either (const Nothing) Just generated,
                      "promptError" .= either Just (const Nothing) generated
                    ]
                )
            )
  archiveIncarnation identifier cognition =
    withBody "invalid incarnation archive request: " $ \(ActivatePromptRequest expected) ->
      archivePreflight cognition identifier expected >>= \case
        Left failure -> respond (cognitionError failure)
        Right _ ->
          maybe
            (finishArchive cognition identifier expected Nothing [])
            ( \service ->
                tasksForIncarnation identifier service True >>= \owned ->
                  activeTaskRuns owned >>= \case
                    running@(_ : _) -> respond (conflict (activeRunMessage running))
                    [] ->
                      let active = filter (not . sessionArchived) . filter (not . sessionIsHome) $ owned
                       in archiveOwnedTasks service active >>= \case
                            Left failure -> respond (sessionError failure)
                            Right archived ->
                              activeTaskRuns owned >>= \case
                                running@(_ : _) ->
                                  rollbackTasks service archived
                                    *> respond (conflict (activeRunMessage running))
                                [] ->
                                  finishArchive cognition identifier expected (Just service) archived
            )
            (inspectionSessions =<< inspection)
  restoreIncarnation identifier cognition =
    withBody "invalid incarnation restore request: " $ \(ActivatePromptRequest expected) ->
      incarnationRestore (cognitionIncarnations cognition) identifier expected
        >>= respond . either cognitionError ok
  deleteIncarnationRoute identifier cognition =
    withBody "invalid incarnation delete request: " $ \(ActivatePromptRequest expected) ->
      Cognition.deleteIncarnation cognition identifier expected >>= \case
        Left failure -> respond (cognitionError failure)
        Right _ ->
          maybe
            (respond (ok (object ["deleted" .= identifier])))
            ( \service ->
                deleteIncarnationSessions service identifier
                  *> respond (ok (object ["deleted" .= identifier]))
            )
            (inspectionSessions =<< inspection)
  archivePreflight cognition identifier expected =
    incarnationRead (cognitionIncarnations cognition) identifier <&> \case
      Nothing -> Left ("unknown incarnation: " <> identifier)
      Just incarnation
        | identifier == "yuki" -> Left "default incarnation yuki cannot be archived"
        | incarnationRevision incarnation /= expected ->
            Left
              ( "stale incarnation revision: expected "
                  <> TextValue.pack (show expected)
                  <> ", actual "
                  <> TextValue.pack (show (incarnationRevision incarnation))
              )
        | incarnationStatus incarnation == IncarnationArchived ->
            Left ("incarnation is already archived: " <> identifier)
        | otherwise -> Right incarnation
  activeTaskRuns owned =
    maybe
      (pure [])
      ( \registry ->
          activeThreads registry <&> \running ->
            filter (`elem` fmap sessionId owned) running
      )
      runs
  activeRunMessage running =
    "incarnation has active task runs: " <> TextValue.intercalate ", " running
  archiveOwnedTasks service = go []
   where
    go archived [] = pure (Right (reverse archived))
    go archived (task : rest) =
      archiveSession service (sessionId task) >>= \case
        Left failure -> rollbackTasks service archived $> Left failure
        Right changed -> go (changed : archived) rest
  rollbackTasks service =
    mapM_ (restoreSession service . sessionId)
  finishArchive cognition identifier expected service archived =
    incarnationArchive (cognitionIncarnations cognition) identifier expected >>= \case
      Left failure ->
        maybe (pure ()) (`rollbackTasks` archived) service
          *> respond (cognitionError failure)
      Right incarnation -> respond (ok incarnation)
  rootPrompts cognition =
    promptList (cognitionIncarnations cognition) Nothing >>= respond . ok
  editRootPrompt cognition =
    withBody "invalid root prompt revision: " $ \(EditPromptRequest source content parent) ->
      either
        (respond . bad)
        ( \(cleanSource, cleanContent) ->
            let store = cognitionIncarnations cognition
             in promptList store Nothing >>= \existing ->
                  validatePromptParent
                    store
                    Nothing
                    RootConstitution
                    (parent <|> (promptRevisionId <$> listToMaybe (reverse (sortOn promptOrdinal existing))))
                    >>= either
                      (respond . cognitionError)
                      ( \lineage ->
                          promptAppend
                            store
                            Nothing
                            RootConstitution
                            cleanSource
                            cleanContent
                            "manual-root-audit-edit/v1"
                            Nothing
                            lineage
                            PromptDraft
                            >>= respond . ok
                      )
        )
        (validatePromptDraft source content)
  activateRootPrompt promptId cognition =
    withBody "invalid Root prompt activation request: " $ \(ActivatePromptRequest expected) ->
      promptActivateRoot (cognitionIncarnations cognition) expected promptId
        >>= respond . either cognitionError ok
  listPrompts identifier cognition =
    promptList (cognitionIncarnations cognition) (Just identifier) >>= respond . ok
  editPrompt identifier cognition =
    withBody "invalid prompt revision: " $ \(EditPromptRequest source content parent) ->
      either
        (respond . bad)
        ( \(cleanSource, cleanContent) ->
            let store = cognitionIncarnations cognition
             in activeIncarnation cognition identifier
                  >>= either
                    (respond . cognitionError)
                    ( \current ->
                        validatePromptParent
                          store
                          (Just identifier)
                          IncarnationCharter
                          (parent <|> incarnationPromptRevision current)
                          >>= either
                            (respond . cognitionError)
                            ( \lineage ->
                                promptAppend
                                  store
                                  (Just identifier)
                                  IncarnationCharter
                                  cleanSource
                                  cleanContent
                                  "manual-audit-edit/v1"
                                  Nothing
                                  lineage
                                  PromptDraft
                                  >>= respond . ok
                            )
                    )
        )
        (validatePromptDraft source content)
  generatePrompt identifier cognition =
    withBody "invalid prompt generation request: " $ \(GeneratePromptRequest source activate) ->
      activeIncarnation cognition identifier
        >>= either
          (respond . cognitionError)
          ( \current ->
              cognitionGeneratePrompt cognition current source
                >>= either (respond . failed) (finish current cognition activate)
          )
   where
    finish current _ False prompt = respond (ok (object ["incarnation" .= current, "prompt" .= prompt]))
    finish current cognition' True prompt =
      promptActivate
        (cognitionIncarnations cognition')
        (incarnationId current)
        (incarnationRevision current)
        (promptRevisionId prompt)
        >>= respond . either cognitionError (\activated -> ok (object ["incarnation" .= activated, "prompt" .= prompt]))
  activatePrompt identifier promptId cognition =
    withBody "invalid prompt activation request: " $ \(ActivatePromptRequest expected) ->
      promptActivate (cognitionIncarnations cognition) identifier expected promptId
        >>= respond . either cognitionError ok
  activeIncarnation cognition identifier =
    incarnationRead (cognitionIncarnations cognition) identifier <&> \case
      Nothing -> Left ("unknown incarnation: " <> identifier)
      Just incarnation
        | incarnationStatus incarnation == IncarnationArchived ->
            Left ("incarnation is archived: " <> identifier)
        | otherwise -> Right incarnation
  readImpression identifier cognition =
    impressionRead (cognitionImpressions cognition) identifier >>= respond . ok
  listActivations identifier cognition =
    impressionActivations (cognitionImpressions cognition) identifier >>= respond . ok
  listImpressionRevisions identifier cognition =
    impressionRevisions (cognitionImpressions cognition) identifier >>= respond . ok
  readWorking identifier cognition =
    workingRead (cognitionWorking cognition) identifier
      >>= respond . maybe (missing "working memory not found") ok
  listSleeps identifier cognition =
    workingSleepCycles (cognitionWorking cognition) identifier >>= respond . ok
  listExperiences identifier cognition =
    experienceEvents (cognitionExperiences cognition) identifier >>= respond . ok
  taskRecords identifier cognition =
    taskArchiveTasks (cognitionArchive cognition) identifier (queryLimit 1000 request) >>= respond . ok
  searchTaskRecords identifier cognition =
    withBody "invalid task record search: " $ \(TaskRecordSearchRequest query task kinds sensitive limit offset includeProcess) ->
      taskArchiveGrep
        (cognitionArchive cognition)
        (ArchiveGrepRequest identifier query task kinds sensitive limit offset includeProcess Nothing)
        >>= respond . either cognitionError ok
  readTaskRecord identifier entryId cognition =
    taskArchiveRead
      (cognitionArchive cognition)
      ( ArchiveReadRequest
          identifier
          entryId
          (queryBounded "before" 2 20 request)
          (queryBounded "after" 2 20 request)
          (queryBounded "offset" 0 maxBound request)
          (queryBounded "chars" 6000 20000 request)
      )
      >>= respond . either cognitionError ok
  memoryCatalog identifier cognition =
    longTermCatalog (cognitionLongTerm cognition) identifier (queryLimit 100 request) >>= respond . ok
  searchMemories identifier cognition =
    withBody "invalid memory search: " $ \(MemorySearchRequest query visibility limit) ->
      longTermGrep (cognitionLongTerm cognition) (GrepRequest identifier query visibility limit)
        >>= respond . either cognitionError ok
  rememberMemory identifier cognition =
    withBody "invalid memory: " $ \(RememberMemoryRequest visibility kind content keywords sources) ->
      longTermRemember
        (cognitionLongTerm cognition)
        (RememberRequest identifier visibility kind content keywords sources)
        >>= respond . either cognitionError ok
  readMemory identifier memoryId cognition =
    longTermRead
      (cognitionLongTerm cognition)
      (ReadRequest identifier memoryId (queryRevision request))
      >>= respond . either cognitionError ok
  voidMemory identifier memoryId cognition =
    withBody "invalid memory void request: " $ \(ActivatePromptRequest expected) ->
      longTermVoid
        (cognitionLongTerm cognition)
        (VoidRequest identifier memoryId expected)
        >>= respond . either cognitionError ok
  memoryReceipts identifier cognition =
    longTermReceipts (cognitionLongTerm cognition) identifier >>= respond . ok
  contextEpochs task cognition =
    maybe legacy (\service -> taskOwnerFor service task >>= listFor) (inspectionSessions =<< inspection)
   where
    legacy =
      maybe
        (listFor "yuki")
        ( \view ->
            threadConfigRead (configViewStore view) task
              >>= listFor
                . fromMaybe "yuki"
                . configIncarnationId
                . flip resolveThreadConfig (configViewDefaults view)
        )
        configs
    listFor identity =
      contextEpochList (cognitionContexts cognition) identity task >>= respond . ok
  sessionList service =
    listSessions (serviceSessions service) includeArchived
      >>= respond . ok . filter (matches (kindQuery request))
   where
    matches (Just "home") = sessionIsHome
    matches (Just "task") = not . sessionIsHome
    matches _ = const True
    kindQuery = fmap Text.decodeUtf8 . join . lookup "kind" . queryString
  incarnationTasks identifier service =
    tasksForIncarnation identifier service includeArchived >>= respond . ok
  homeThread identifier service =
    maybe (respond (missing "incarnation not found")) present (inspectionCognition =<< inspection)
   where
    present cognition =
      incarnationRead (cognitionIncarnations cognition) identifier
        >>= maybe (respond (missing "incarnation not found")) loadHome
    loadHome incarnation
      | incarnationStatus incarnation == IncarnationArchived = respond (missing "incarnation not found")
      | otherwise =
          liftA2 (homeView identifier) (ensureHomeSession (serviceSessions service) identifier (Just (incarnationName incarnation))) (threadConfigRead (serviceConfigs service) (homeThreadId identifier))
            >>= respond . ok
    homeView identity meta config =
      object
        [ "threadId" .= homeThreadId identity,
          "meta" .= meta,
          "config" .= config
        ]
  tasksForIncarnation identifier service archived =
    filter ((== identifier) . sessionOwnerId) <$> listSessions (serviceSessions service) archived
  createThread service =
    withBody "invalid create request: " $ \(CreateSessionRequest threadId title requestedOwner) ->
      validateTaskOwner requestedOwner >>= \case
        Left failure -> respond (cognitionError failure)
        Right () ->
          let owner = fromMaybe "yuki" (nonBlankText =<< requestedOwner)
           in createSession (serviceSessions service) threadId title owner Nothing Nothing >>= \case
                Left failure -> respond (sessionError failure)
                Right created ->
                  bindTaskOwner service threadId owner *> respond (ok created)
  validateTaskOwner Nothing = pure (Right ())
  validateTaskOwner (Just identifier) =
    maybe
      (pure (Left "incarnation service is unavailable"))
      ( \cognition ->
          incarnationRead (cognitionIncarnations cognition) identifier <&> \case
            Nothing -> Left ("unknown incarnation: " <> identifier)
            Just incarnation
              | incarnationStatus incarnation == IncarnationArchived ->
                  Left ("incarnation is archived: " <> identifier)
              | otherwise -> Right ()
      )
      (inspectionCognition =<< inspection)
  bindTaskOwner service threadId identifier =
    threadConfigRead (serviceConfigs service) threadId
      >>= \current ->
        threadConfigWrite
          (serviceConfigs service)
          threadId
          current {configIncarnationId = Just identifier}
  renameThread threadId service =
    withBody "invalid rename request: " $ \(RenameSessionRequest title) ->
      renameSession (serviceSessions service) threadId title >>= sessionResult
  homeGuard service threadId continue =
    findSession (serviceSessions service) threadId >>= \case
      Just meta | sessionIsHome meta -> respond (jsonResponse cors status400 [] (message "home_session_immutable"))
      _ -> continue
  archiveThread threadId service = homeGuard service threadId (archiveSession service threadId >>= sessionResult)
  restoreThread threadId service =
    homeGuard service threadId $
      maybe
        (restoreSession service threadId >>= sessionResult)
        ( \cognition ->
            incarnationForThread cognition threadId >>= \case
              Left failure -> respond (cognitionError failure)
              Right _ -> restoreSession service threadId >>= sessionResult
        )
        (inspectionCognition =<< inspection)
  forkThread source service =
    homeGuard service source $
      refreshTaskProjection source service >>= \case
        Left failure -> respond (cognitionError failure)
        Right () ->
          withBody "invalid fork request: " $ \(ForkSessionRequest target title node) ->
            forkSession service source target node title >>= sessionResult
  sleepThread threadId service =
    case inspectionCognition =<< inspection of
      Nothing ->
        transcriptLoad (serviceTranscripts service) threadId
          >>= maybe (respond (missing "thread not found")) legacyCompact
      Just cognition ->
        readSleepRequest >>= \_reason ->
          incarnationForThread cognition threadId >>= \case
            Left failure -> respond (cognitionError failure)
            Right incarnation ->
              authoritativeMessages cognition service (incarnationId incarnation) threadId >>= \case
                Left failure -> respond (cognitionError failure)
                Right messages ->
                  runtimeFor threadId >>= \runtime ->
                    newId >>= \sleepRunId ->
                      cognitionSleepMessages
                        cognition
                        incarnation
                        threadId
                        (Just sleepRunId)
                        SleepManual
                        runtime
                        messages
                        >>= either
                          (respond . cognitionError)
                          ( \result ->
                              transcriptSave
                                (serviceTranscripts service)
                                threadId
                                (compactionMessages (sleepResultCompaction result))
                                *> ( taskOwnerFor service threadId
                                       >>= ensureSession (serviceSessions service) threadId Nothing
                                   )
                                *> respond (ok result)
                          )
   where
    legacyCompact messages =
      runtimeFor threadId >>= \runtime ->
        compactHistory runtime True messages >>= \case
          Nothing ->
            respond
              ( ok
                  ( object
                      [ "changed" .= False,
                        "beforeTokens" .= estimateMessagesTokens messages,
                        "message" .= ("当前上下文尚未达到手动压缩阈值。" :: Text)
                      ]
                  )
              )
          Just compaction ->
            transcriptSave (serviceTranscripts service) threadId (compactionMessages compaction)
              *> ( taskOwnerFor service threadId
                     >>= ensureSession (serviceSessions service) threadId Nothing
                 )
              *> respond
                ( ok
                    ( object
                        [ "changed" .= True,
                          "beforeTokens" .= compactionBeforeTokens compaction,
                          "afterTokens" .= compactionAfterTokens compaction,
                          "budgetTokens" .= compactionBudgetTokens compaction,
                          "droppedMessages" .= length (compactionDropped compaction),
                          "summary" .= compactionSummary compaction
                        ]
                    )
                )
    readSleepRequest =
      strictRequestBody request >>= \body ->
        if LazyByteString.null body
          then pure (SleepThreadRequest Nothing)
          else
            either
              (const (pure (SleepThreadRequest Nothing)))
              pure
              (eitherDecode body)
  refreshTaskProjection threadId service =
    case inspectionCognition =<< inspection of
      Nothing -> pure (Right ())
      Just cognition ->
        incarnationForThread cognition threadId >>= \case
          Left failure -> pure (Left failure)
          Right incarnation ->
            authoritativeMessages cognition service (incarnationId incarnation) threadId >>= \case
              Left failure -> pure (Left failure)
              Right messages ->
                Right () <$ transcriptSave (serviceTranscripts service) threadId messages
  exportThread threadId service =
    refreshTaskProjection threadId service >>= \case
      Left failure -> respond (cognitionError failure)
      Right () -> exportSession service threadId >>= respond . maybe (missing "thread not found") ok
  importThread service =
    withBody "invalid import request: " $ \incoming ->
      homeGuard service (importTarget incoming) (importSession service incoming >>= sessionResult)
   where
    importTarget incoming = fromMaybe (sessionId (bundleMeta (importBundle incoming))) (importTargetId incoming)
  sessionResult = either (respond . sessionError) (respond . ok)
  sessionError errorText
    | "unknown thread:" `TextValue.isPrefixOf` errorText = missing errorText
    | "not found:" `TextValue.isInfixOf` errorText = missing errorText
    | "already exists:" `TextValue.isInfixOf` errorText =
        jsonResponse cors status409 [] (message errorText)
    | otherwise = bad errorText
  cognitionError errorText
    | any
        (`TextValue.isInfixOf` normalized)
        ["stale", "already exists", "already active", "already archived", "is archived", "active task runs"] =
        jsonResponse cors status409 [] (message errorText)
    | any (`TextValue.isInfixOf` normalized) ["unknown", "not found"] = missing errorText
    | otherwise = bad errorText
   where
    normalized = TextValue.toLower errorText
  saveConfig threadId view =
    strictRequestBody request
      >>= either (respond . bad . ("invalid ThreadConfig: " <>) . fromString) check . eitherDecode
   where
    check config =
      validateConfig config >>= either (respond . bad) (const (validateOwner config))
    validateOwner config =
      maybe unlocked locked (inspectionSessions =<< inspection)
     where
      unlocked = maybe (persist config) (`validateActive` config) (configIncarnationId config)
      locked service =
        findSession (serviceSessions service) threadId >>= \case
          Nothing -> unlocked
          Just meta ->
            let owner = sessionOwnerId meta
             in case nonBlankText =<< configIncarnationId config of
                  Just requested
                    | requested /= owner ->
                        respond (conflict ("thread incarnation is immutable: " <> owner))
                  _ -> validateActive owner config {configIncarnationId = Just owner}
    validateActive identifier config =
      maybe
        (persist config)
        ( \cognition ->
            incarnationRead (cognitionIncarnations cognition) identifier >>= \case
              Nothing -> respond (missing ("unknown incarnation: " <> identifier))
              Just incarnation
                | incarnationStatus incarnation == IncarnationArchived ->
                    respond (conflict ("incarnation is archived: " <> identifier))
                | otherwise -> persist config
        )
        (inspectionCognition =<< inspection)
    persist config =
      threadConfigWrite (configViewStore view) threadId config
        *> respond (responseLBS status204 (corsHeaders cors) "")
  brief threadId (threads, _) = maybe (missing "thread not found") ok <$> threadBrief threads threadId
  transcript threadId store =
    maybe (missing "transcript not found") (ok . renderTranscript threadId) <$> transcriptLoad store threadId
  tree threadId view =
    threadConfigRead (configViewStore view) threadId
      >>= maybe notFound listing . cwdPath . configCwd . flip resolveThreadConfig (configViewDefaults view)
   where
    listing dir = listTree dir (treeDepth (queryString request)) >>= respond . ok
  paths threadId view =
    withBody "invalid path completion request: " $ \(PathRequest prefix) ->
      threadConfigRead (configViewStore view) threadId
        >>= maybe
          (respond (ok (object ["prefix" .= prefix, "paths" .= ([] :: [Text])])))
          (\dir -> completePaths dir prefix >>= \matches -> respond (ok (object ["prefix" .= prefix, "paths" .= matches])))
          . cwdPath
          . configCwd
          . flip resolveThreadConfig (configViewDefaults view)
  facts (_, factStore) = ok <$> factList factStore
  artifact identifier store = maybe (missing "artifact not found") plain <$> artifactFetch store identifier
  journalRuns = respond . ok . runIds
  summaryFor runId = respond . maybe (missing "run not found") ok . runSummary runId
  traceFor runId = respond . maybe (missing "run not found") ok . runTrace runId
  journalEntries = respond . ok . forRun runParam
  replayReport memory entries =
    strictRequestBody request
      >>= either (respond . bad) result . replayWanted
   where
    result wanted =
      ( case memory of
          Just (threads, storeFacts)
            | memoryInjected entries ->
                replayWithStores threads storeFacts wanted entries
          _ -> replayEntries defaultHooks wanted entries
      )
        >>= respond . either bad ok
  ok :: (ToJSON a) => a -> Response
  ok = jsonResponse cors status200 [] . toJSON
  missing text = jsonResponse cors status404 [] (message text)
  bad text = jsonResponse cors status400 [] (message text)
  failed text = jsonResponse cors status500 [] (message text)
  plain content =
    responseLBS
      status200
      (corsHeaders cors <> plainHeaders)
      (LazyByteString.fromStrict (Text.encodeUtf8 content))
  runParam = Text.decodeUtf8 <$> join (lookup "run" (queryString request))
  handleAgent = strictRequestBody request >>= either invalid stream . eitherDecode
  invalid parseError =
    respond (jsonResponse cors status400 [] (object ["error" .= ("invalid RunAgentInput: " <> parseError)]))
  handleCancel = maybe notFound cancel runs
   where
    cancel registry =
      strictRequestBody request
        >>= either (respond . bad . ("invalid cancel request: " <>) . fromString) decide . cancelWanted
     where
      decide runId =
        cancelRun registry runId >>= \cancelled ->
          when cancelled (traverse_ (\hub -> noteCancelling hub runId) telemetry)
            *> bool
              (respond (missing "run not found"))
              (respond (responseLBS status202 (corsHeaders cors) ""))
              cancelled
  handleSteer = maybe notFound steer runs
   where
    steer registry =
      strictRequestBody request
        >>= either (respond . bad . ("invalid steer request: " <>) . fromString) decide . steerWanted
     where
      decide (runId, text) =
        steerRun registry runId (ChatUser text)
          >>= bool
            (respond (missing "run not found"))
            (respond (responseLBS status202 (corsHeaders cors) ""))
  handleFollowUp = maybe notFound followUp runs
   where
    followUp registry =
      strictRequestBody request
        >>= either (respond . bad . ("invalid follow-up request: " <>) . fromString) decide . steerWanted
     where
      decide (runId, text) =
        followUpRun registry runId (ChatUser text)
          >>= bool
            (respond (missing "run not found"))
            (respond (responseLBS status202 (corsHeaders cors) ""))
  stream input
    | not (validThreadId (AGUI.runThreadId input)) = respond (bad "invalid thread id")
    | otherwise =
        maybe (streamRun input) prepare (inspectionSessions =<< inspection)
   where
    prepare service =
      taskOwnerFor service (AGUI.runThreadId input) >>= \owner ->
        ensureSession (serviceSessions service) (AGUI.runThreadId input) (latestUserTitle input) owner
          >>= \meta ->
            bool
              (validateIncarnation service)
              (respond (conflict "thread is archived"))
              (sessionArchived meta)
    validateIncarnation service =
      maybe
        (accept service)
        ( \cognition ->
            incarnationForThread cognition (AGUI.runThreadId input) >>= \case
              Left failure -> respond (cognitionError failure)
              Right _ -> accept service
        )
        (inspectionCognition =<< inspection)
    accept service =
      authoritativeInput (inspectionCognition =<< inspection) configs service input >>= \case
        Left failure -> respond (failed failure)
        Right accepted -> streamRun accepted
    streamRun accepted =
      runtimeFor (AGUI.runThreadId accepted) >>= \runtime ->
        respond
          ( responseStream status200 (corsHeaders cors <> streamHeaders) $ \write flush ->
              runAgent runtime accepted (\event -> write (encodeEvent event) *> flush)
          )
  conflict text = jsonResponse cors status409 [] (message text)
  includeArchived = join (lookup "archived" (queryString request)) == Just "true"

validatePromptDraft :: Text -> Text -> Either Text (Text, Text)
validatePromptDraft source content
  | TextValue.null cleanSource = Left "prompt revision source intent must not be empty"
  | TextValue.null cleanContent = Left "prompt revision content must not be empty"
  | TextValue.length cleanContent > 120000 = Left "prompt revision content exceeds 120000 characters"
  | otherwise = Right (TextValue.take 1000 cleanSource, cleanContent)
 where
  cleanSource = TextValue.strip source
  cleanContent = TextValue.strip content

validatePromptParent ::
  IncarnationStore ->
  Maybe Text ->
  PromptLayer ->
  Maybe Text ->
  IO (Either Text (Maybe Text))
validatePromptParent _ _ _ Nothing = pure (Right Nothing)
validatePromptParent store owner layer (Just identifier) =
  promptRead store identifier <&> \case
    Nothing -> Left ("unknown parent prompt revision: " <> identifier)
    Just parent
      | promptIncarnationId parent /= owner ->
          Left "parent prompt revision belongs to another owner"
      | promptLayer parent /= layer ->
          Left "parent prompt revision belongs to another layer"
      | otherwise -> Right (Just identifier)

latestUserTitle :: AGUI.RunAgentInput -> Maybe Text
latestUserTitle input =
  listToMaybe
    ( reverse
        [ TextValue.take 80 title
        | AGUI.User userMessage <- AGUI.runMessages input,
          Right raw <- [AGUI.userText (AGUI.userContent userMessage)],
          let title = TextValue.unwords (TextValue.words raw),
          not (TextValue.null title)
        ]
    )

taskOwnerFor :: SessionService -> Text -> IO Text
taskOwnerFor service threadId =
  findSession (serviceSessions service) threadId >>= \case
    Just meta -> pure (sessionOwnerId meta)
    Nothing ->
      threadConfigRead (serviceConfigs service) threadId
        <&> fromMaybe "yuki" . (nonBlankText =<<) . configIncarnationId

sessionOwnerId :: SessionMeta -> Text
sessionOwnerId = fromMaybe "yuki" . nonBlankText . sessionIncarnationId

nonBlankText :: Text -> Maybe Text
nonBlankText value
  | TextValue.null clean = Nothing
  | otherwise = Just clean
 where
  clean = TextValue.strip value

authoritativeInput :: Maybe Cognition -> Maybe ConfigView -> SessionService -> AGUI.RunAgentInput -> IO (Either Text AGUI.RunAgentInput)
authoritativeInput Nothing _ service input = Right <$> transcriptInput service input
authoritativeInput (Just cognition) _ service input =
  taskOwnerFor service task >>= \identity ->
    contextEpochHead (cognitionContexts cognition) identity task >>= \case
      Nothing -> Right <$> transcriptInput service input
      Just epoch ->
        contextEpochProject (cognitionContexts cognition) (contextEpochId epoch)
          <&> (>>= projectInput)
 where
  task = AGUI.runThreadId input
  projectInput projected =
    projectedAguiMessages projected <&> \messages ->
      input
        { AGUI.runMessages =
            appendLatestUser messages (latestUserMessage input)
        }

transcriptInput :: SessionService -> AGUI.RunAgentInput -> IO AGUI.RunAgentInput
transcriptInput service input =
  transcriptLoad (serviceTranscripts service) (AGUI.runThreadId input) <&> \case
    Nothing -> input
    Just [] -> input
    Just history ->
      input
        { AGUI.runMessages =
            appendLatestUser (toAguiMessages history) (latestUserMessage input)
        }

authoritativeMessages :: Cognition -> SessionService -> Text -> Text -> IO (Either Text [ChatMessage])
authoritativeMessages cognition service identity task =
  contextEpochHead (cognitionContexts cognition) identity task >>= \case
    Just epoch ->
      contextEpochProject (cognitionContexts cognition) (contextEpochId epoch)
        <&> (>>= projectedAguiMessages >=> toChatMessages)
    Nothing ->
      transcriptLoad (serviceTranscripts service) task
        <&> maybe (Left "thread not found") Right

appendLatestUser :: [AGUI.Message] -> Maybe AGUI.Message -> [AGUI.Message]
appendLatestUser history Nothing = history
appendLatestUser history (Just nextMessage)
  | sameUser (listToMaybe (reverse history)) nextMessage = history
  | otherwise = history <> [nextMessage]
 where
  sameUser (Just (AGUI.User left)) (AGUI.User right) =
    AGUI.userId left == AGUI.userId right
      || AGUI.userContent left == AGUI.userContent right
  sameUser _ _ = False

latestUserMessage :: AGUI.RunAgentInput -> Maybe AGUI.Message
latestUserMessage =
  listToMaybe
    . reverse
    . filter user
    . AGUI.runMessages
 where
  user AGUI.User {} = True
  user _ = False

treeDepth :: Query -> Int
treeDepth = clamp . fromMaybe 2 . parse
 where
  parse = (readMaybe . unpack . Text.decodeUtf8 =<<) . join . lookup "depth"
  clamp = max 1 . min 8

queryLimit :: Int -> Request -> Int
queryLimit upper =
  max 1 . min upper . fromMaybe upper . queryInt "limit"

queryRevision :: Request -> Maybe Int
queryRevision = queryInt "revision"

queryBounded :: ByteString.ByteString -> Int -> Int -> Request -> Int
queryBounded name fallback upper =
  max 0 . min upper . fromMaybe fallback . queryInt name

queryInt :: ByteString.ByteString -> Request -> Maybe Int
queryInt name =
  (readMaybe . unpack . Text.decodeUtf8 =<<)
    . join
    . lookup name
    . queryString

dispatchStatusQuery :: Query -> Either Text (Maybe DispatchStatus)
dispatchStatusQuery query =
  case join (lookup "status" query) of
    Nothing -> Right Nothing
    Just "draft" -> Right (Just Draft)
    Just "dispatched" -> Right (Just Dispatched)
    Just "cancelled" -> Right (Just Cancelled)
    Just other -> Left ("unknown dispatch status: " <> Text.decodeUtf8 other)

validateCwd :: ThreadConfig -> IO (Either Text ())
validateCwd = maybe (pure (Right ())) check . cwdPath . configCwd
 where
  check dir = bool (Left ("not a directory: " <> fromString dir)) (Right ()) <$> doesDirectoryExist dir

validateConfig :: ThreadConfig -> IO (Either Text ())
validateConfig config = validateCwd config <&> (>> validateContextConfig config)

validateContextConfig :: ThreadConfig -> Either Text ()
validateContextConfig config =
  sequence_
    [ optional "contextReserveTokens" (> 0) (configContextReserveTokens config),
      optional "contextKeepUnits" (> 0) (configContextKeepUnits config),
      optional "contextSummaryTokens" (>= 96) (configContextSummaryTokens config)
    ]
 where
  optional name valid =
    maybe
      (Right ())
      (\value -> bool (Left (name <> " 超出允许范围")) (Right ()) (valid value))

renderContextPolicy :: Runtime -> Value
renderContextPolicy runtime =
  maybe
    (object ["enabled" .= False])
    configured
    (runtimeContext runtime)
 where
  tools = backendToolSpec <$> Map.elems (runtimeTools runtime)
  configured config =
    object
      [ "enabled" .= True,
        "windowTokens" .= contextWindow config (runtimeContextWindow runtime),
        "reserveTokens" .= contextReserveTokens config,
        "toolTokens" .= estimateToolsTokens tools,
        "budgetTokens" .= contextBudget config (runtimeContextWindow runtime) tools,
        "keepUnits" .= contextKeepUnits config,
        "summaryTokens" .= contextSummaryTokens config
      ]

runServer :: Settings -> Maybe Inspection -> Maybe ConfigView -> Maybe RunRegistry -> Maybe DispatchService -> Maybe Telemetry -> (Text -> IO Runtime) -> IO ()
runServer settings inspection configs runs dispatches telemetry runtimeFor =
  runSettings
    ( setPort (settingsPort settings)
        . setHost (fromString (settingsHost settings))
        $ defaultSettings
    )
    (application (settingsCorsOrigin settings) inspection configs runs dispatches telemetry runtimeFor)

replayWanted :: LazyByteString.ByteString -> Either Text (Maybe Text)
replayWanted body
  | LazyByteString.null body = Right Nothing
  | otherwise =
      either
        (Left . fromString)
        Right
        (eitherDecode body >>= parseEither (withObject "replay" (.:? "runId")))

cancelWanted :: LazyByteString.ByteString -> Either String Text
cancelWanted body = eitherDecode body >>= parseEither (withObject "cancel" (.: "runId"))

steerWanted :: LazyByteString.ByteString -> Either String (Text, Text)
steerWanted body =
  eitherDecode body >>= parseEither (withObject "steer" (\fields -> (,) <$> fields .: "runId" <*> fields .: "text"))

encodeEvent :: Event -> Builder.Builder
encodeEvent event =
  Builder.byteString "data: "
    <> Builder.lazyByteString (encode event)
    <> Builder.byteString "\n\n"

sseFrame :: Text -> Value -> Builder.Builder
sseFrame name value =
  Builder.byteString "event: "
    <> Builder.byteString (Text.encodeUtf8 name)
    <> Builder.byteString "\ndata: "
    <> Builder.lazyByteString (encode value)
    <> Builder.byteString "\n\n"

encodeFrame :: ActivityFrame -> Builder.Builder
encodeFrame = \case
  FramePing -> Builder.byteString ": ping\n\n"
  FrameStatus status -> sseFrame "status" (toJSON status)
  FrameRunEnd runId outcome -> sseFrame "run.end" (object ["runId" .= runId, "outcome" .= outcome])
  FrameDelivery record -> sseFrame "delivery" (toJSON record)
  FrameFsChange record -> sseFrame "fschange" (toJSON record)

jsonResponse :: Maybe Text -> Status -> ResponseHeaders -> Value -> Response
jsonResponse cors status headers value =
  responseLBS
    status
    (corsHeaders cors <> [(hContentType, "application/json; charset=utf-8")] <> headers)
    (encode value)

message :: Text -> Value
message text = object ["error" .= text]

streamHeaders :: ResponseHeaders
streamHeaders =
  [ (hContentType, "text/event-stream; charset=utf-8"),
    (hCacheControl, "no-cache"),
    ("X-Accel-Buffering", "no")
  ]

plainHeaders :: ResponseHeaders
plainHeaders = [(hContentType, "text/plain; charset=utf-8")]

preflightHeaders :: ResponseHeaders
preflightHeaders =
  [ ("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, OPTIONS"),
    ("Access-Control-Allow-Headers", "Content-Type, Authorization"),
    ("Access-Control-Max-Age", "86400")
  ]

corsHeaders :: Maybe Text -> ResponseHeaders
corsHeaders = \case
  Nothing -> []
  Just origin ->
    [ ("Access-Control-Allow-Origin", Text.encodeUtf8 origin),
      (hVary, "Origin")
    ]
