module Yuki.N.Server
  ( ConfigView (..),
    application,
    runServer,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO, killThread, readChan, threadDelay, writeChan)
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
import Yuki.N.Agent (BackendTool (..), Runtime (..), defaultHooks, newId, runAgent, runtimeContextWindow, toChatMessages)
import Yuki.N.Artifact (ArtifactStore (..))
import Yuki.N.Cognition
import Yuki.N.Cognition qualified as Cognition
import Yuki.N.Config (Settings (..))
import Yuki.N.Context
  ( Compaction (..),
    ContextConfig (..),
    contextBudget,
    contextWindow,
    estimateToolsTokens,
  )
import Yuki.N.ContextEpoch
  ( ContextEpoch (..),
    ContextEpochStore (..),
    projectedAguiMessages,
  )
import Yuki.N.Dispatch
import Yuki.N.Experience (ExperienceStore (..))
import Yuki.N.Incarnation
import Yuki.N.Inspect (Inspection (..), forRun, runIds, runSummary, runTrace)
import Yuki.N.Journal (journalSnapshot)
import Yuki.N.Memory.Archive
import Yuki.N.Memory.Impression (ImpressionStore (..))
import Yuki.N.Memory.LongTerm
import Yuki.N.Memory.Working
import Yuki.N.Model (ChatMessage (ChatUser))
import Yuki.N.Replay (readJournal, replayEntries)
import Yuki.N.Runs (RunKind (..), RunRegistry, activeThreads, cancelRun, followUpRun, steerRun)
import Yuki.N.Sessions
import Yuki.N.Telemetry (ActivityFrame (..), DeliveryRecord (..), Ledger, LiveStatus (..), Telemetry, liveRuns, noteCancelling, subscribe, telemetryLedger)
import Yuki.N.Telemetry qualified as Telemetry
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
      <$> fields .:? "id" .!= ""
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
  route "POST" ["replay"] = withJournal replayReport
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
    skeleton = fleetObject ([] :: [Value]) <$> liveRuns hub
    present cognition =
      incarnationList (cognitionIncarnations cognition) >>= fleetEntries
    fleetEntries incarnations =
      liveRuns hub >>= fleetEntriesWith incarnations
    fleetEntriesWith incarnations running =
      flip fleetObject running <$> traverse (fleetEntry hub running) incarnations
    fleetObject incarnations running =
      object ["incarnations" .= incarnations, "runs" .= running]
  fleetEntry hub running incarnation =
    fleetRow
      <$> draftCountOf identifier
      <*> lastDeliveryOf hub identifier
   where
    identifier = incarnationId incarnation
    fleetRow draftCount lastDelivery =
      object
        [ "id" .= identifier,
          "name" .= incarnationName incarnation,
          "state" .= stateOf (activeOf running identifier) draftCount,
          "activeRuns" .= activeOf running identifier,
          "waitingDrafts" .= draftCount,
          "lastDeliveryAt" .= lastDelivery
        ]
  activeOf running identifier =
    length (filter ((== identifier) . liveIncarnation) running)
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
    liveRuns hub >>= activityRespond identifier hub
   where
    activityRespond identifier' hub' running =
      liftA2 (,) (draftsOf identifier') (recentDeliveriesOf hub' identifier')
        >>= respond . ok . uncurry (activityJson identifier' running)
  recentDeliveriesOf hub identifier =
    readIORef (telemetryLedger hub) >>= maybe (pure []) recent
   where
    recent ledger = deliveriesFor ledger identifier Nothing 20 Nothing
  activityJson identifier running drafts recent =
    object
      [ "incarnationId" .= identifier,
        "home" .= object ["threadId" .= homeThreadId identifier, "activeRunId" .= homeRun],
        "runs" .= own,
        "waitingDrafts" .= drafts,
        "recentDeliveries" .= recent
      ]
   where
    own = filter ((== identifier) . liveIncarnation) running
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
      query ledger >>= respond . ok . items
    items found =
      object ["items" .= take pageLimit found, "hasMore" .= (length found > pageLimit)]
  pageLimit = min 200 (fromMaybe 50 (queryInt "limit" request))
  pageBefore = toInteger <$> queryInt "before" request
  queryText name = Text.decodeUtf8 <$> join (lookup name (queryString request))
  activityStreamHandler hub =
    respond (responseStream status200 (corsHeaders cors <> streamHeaders) (streamActivity hub))
  streamActivity hub write flush =
    subscribe hub >>= withChannel
   where
    withChannel chan =
      bracket (forkIO (heartbeat chan)) killThread (const (preamble *> cycleFrames chan))
    heartbeat chan = forever (threadDelay 15000000 *> writeChan chan FramePing)
    preamble =
      (fleetValue hub >>= write . sseFrame "snapshot") *> flush
    cycleFrames chan =
      (readChan chan >>= write . encodeFrame) *> flush *> cycleFrames chan
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
    dispatchServiceConfirm service identifier >>= outcome
   where
    outcome ConfirmMissing = respond (missing "dispatch not found")
    outcome (ConfirmConflict failure) = respond (conflict failure)
    outcome (ConfirmError failure) = respond (failed failure)
    outcome (ConfirmOk threadId) =
      broadcast (FrameDraftResolved identifier "dispatched" (Just threadId))
        *> respond (jsonResponse cors status201 [] (object ["threadId" .= threadId]))
  cancelDispatchRoute identifier service =
    markDispatchCancelled (dispatchServiceStore service) identifier
      >>= either (respond . dispatchFailure) (\draft -> broadcast (FrameDraftResolved identifier "cancelled" Nothing) *> respond (ok draft))
  broadcast frame =
    traverse_ (\hub -> Telemetry.publish hub frame) telemetry
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
              >>= active
                . fromMaybe "yuki"
                . configIncarnationId
                . flip resolveThreadConfig (configViewDefaults view)
        )
        configs
    active identifier =
      incarnationRead (cognitionIncarnations cognition) identifier <&> incarnationGate identifier
    incarnationGate identifier = \case
      Nothing -> Left ("unknown incarnation: " <> identifier)
      Just incarnation
        | incarnationStatus incarnation == IncarnationArchived ->
            Left ("incarnation is archived: " <> identifier)
        | otherwise -> Right incarnation
  threadTranscript threadId =
    case inspectionSessions =<< inspection of
      Just service ->
        findSession (serviceSessions service) threadId >>= transcriptSession service threadId
      Nothing -> withTranscripts (transcript threadId)
   where
    transcriptSession service threadId' = \case
      Nothing -> transcriptLoad (serviceTranscripts service) threadId' >>= transcriptMissing service threadId'
      Just _ -> transcriptLoad (serviceTranscripts service) threadId' >>= respond . ok . renderTranscript threadId' . fromMaybe []
    transcriptMissing service threadId' = \case
      Nothing -> respond (missing "thread not found")
      Just messages ->
        (taskOwnerFor service threadId' >>= ensureSession (serviceSessions service) threadId' Nothing)
          *> respond (ok (renderTranscript threadId' messages))
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
      resolveIncarnationId (cognitionIncarnations cognition) identifier name
        >>= createNew cognition name direction model
   where
    createNew cognition' name direction model finalId =
      incarnationCreate (cognitionIncarnations cognition') finalId name direction model
        >>= either (respond . cognitionError) (bootstrap cognition')
    resolveIncarnationId store identifier name
      | TextValue.null (TextValue.strip identifier) = freshIncarnationId store name
      | otherwise = pure (TextValue.strip identifier)
    bootstrap cognition' created =
      cognitionBootstrapIncarnation cognition' created
        >>= either (respond . cognitionError) (generateInitial cognition')
    generateInitial cognition' bootstrapped =
      cognitionGeneratePrompt cognition' bootstrapped "initial charter generated from the new incarnation direction"
        >>= either
          (generationFailure bootstrapped)
          (activateGeneration cognition' bootstrapped)
    generationFailure bootstrapped failure =
      respond (ok (object ["incarnation" .= bootstrapped, "prompt" .= Null, "promptError" .= failure]))
    activateGeneration cognition' bootstrapped prompt =
      promptActivate
        (cognitionIncarnations cognition')
        (incarnationId bootstrapped)
        (incarnationRevision bootstrapped)
        (promptRevisionId prompt)
        >>= respond . either cognitionError (generationActivated prompt)
    generationActivated prompt activated =
      ok (object ["incarnation" .= activated, "prompt" .= prompt])
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
        >>= respond . ok . revisionOutcome changed
    revisionOutcome changed generated =
      object
        [ "incarnation" .= changed,
          "prompt" .= either (const Nothing) Just generated,
          "promptError" .= either Just (const Nothing) generated
        ]
  archiveIncarnation identifier cognition =
    withBody "invalid incarnation archive request: " $ \(ActivatePromptRequest expected) ->
      archivePreflight cognition identifier expected
        >>= either
          (respond . cognitionError)
          (const (archiveWithSessions identifier cognition expected))
   where
    archiveWithSessions identifier' cognition' expected =
      maybe
        (finishArchive cognition' identifier' expected Nothing [])
        (archiveTasks identifier' cognition' expected)
        (inspectionSessions =<< inspection)
    archiveTasks identifier' cognition' expected service =
      tasksForIncarnation identifier' service True
        >>= archiveUnlessRunning identifier' cognition' expected service
    archiveUnlessRunning identifier' cognition' expected service owned =
      activeTaskRuns owned >>= runningGate identifier' cognition' expected service owned
    runningGate _ _ _ _ _ running@(_ : _) =
      respond (conflict (activeRunMessage running))
    runningGate identifier' cognition' expected service owned [] =
      archiveOwnedTasks service active
        >>= either (respond . sessionError) (archiveRecheck identifier' cognition' expected service owned)
     where
      active = filter (not . sessionArchived) . filter (not . sessionIsHome) $ owned
    archiveRecheck identifier' cognition' expected service owned archived =
      activeTaskRuns owned >>= recheckGate identifier' cognition' expected service archived
    recheckGate _ _ _ service archived running@(_ : _) =
      rollbackTasks service archived
        *> respond (conflict (activeRunMessage running))
    recheckGate identifier' cognition' expected service archived [] =
      finishArchive cognition' identifier' expected (Just service) archived
  restoreIncarnation identifier cognition =
    withBody "invalid incarnation restore request: " $ \(ActivatePromptRequest expected) ->
      incarnationRestore (cognitionIncarnations cognition) identifier expected
        >>= respond . either cognitionError ok
  deleteIncarnationRoute identifier cognition =
    withBody "invalid incarnation delete request: " $ \(ActivatePromptRequest expected) ->
      Cognition.deleteIncarnation cognition identifier expected
        >>= either (respond . cognitionError) (const (deleteSessions identifier))
   where
    deleteSessions identifier' =
      maybe
        (respond (ok (object ["deleted" .= identifier'])))
        ( \service ->
            deleteIncarnationSessions service identifier'
              *> respond (ok (object ["deleted" .= identifier']))
        )
        (inspectionSessions =<< inspection)
  archivePreflight cognition identifier expected =
    incarnationRead (cognitionIncarnations cognition) identifier <&> archiveGate identifier expected
   where
    archiveGate identifier' expected' = \case
      Nothing -> Left ("unknown incarnation: " <> identifier')
      Just incarnation
        | identifier' == "yuki" -> Left "default incarnation yuki cannot be archived"
        | incarnationRevision incarnation /= expected' ->
            Left
              ( "stale incarnation revision: expected "
                  <> TextValue.pack (show expected')
                  <> ", actual "
                  <> TextValue.pack (show (incarnationRevision incarnation))
              )
        | incarnationStatus incarnation == IncarnationArchived ->
            Left ("incarnation is already archived: " <> identifier')
        | otherwise -> Right incarnation
  activeTaskRuns owned =
    maybe
      (pure [])
      (\registry -> filter (`elem` fmap sessionId owned) <$> activeThreads registry)
      runs
  activeRunMessage running =
    "incarnation has active task runs: " <> TextValue.intercalate ", " running
  archiveOwnedTasks service = go []
   where
    go archived [] = pure (Right (reverse archived))
    go archived (task : rest) =
      archiveSession service (sessionId task) >>= archiveStep archived rest
    archiveStep archived rest = \case
      Left failure -> rollbackTasks service archived $> Left failure
      Right changed -> go (changed : archived) rest
  rollbackTasks service =
    mapM_ (restoreSession service . sessionId)
  finishArchive cognition identifier expected service archived =
    incarnationArchive (cognitionIncarnations cognition) identifier expected
      >>= either (archiveFailure service archived) (respond . ok)
   where
    archiveFailure service' archived' failure =
      maybe (pure ()) (`rollbackTasks` archived') service'
        *> respond (cognitionError failure)
  rootPrompts cognition =
    promptList (cognitionIncarnations cognition) Nothing >>= respond . ok
  editRootPrompt cognition =
    withBody "invalid root prompt revision: " $ \(EditPromptRequest source content parent) ->
      either
        (respond . bad)
        (appendRootPrompt cognition parent)
        (validatePromptDraft source content)
   where
    appendRootPrompt cognition' parent (cleanSource, cleanContent) =
      promptList store Nothing >>= appendRootAfterList store parent cleanSource cleanContent
     where
      store = cognitionIncarnations cognition'
    appendRootAfterList store parent cleanSource cleanContent existing =
      validatePromptParent
        store
        Nothing
        RootConstitution
        (parent <|> (promptRevisionId <$> listToMaybe (reverse (sortOn promptOrdinal existing))))
        >>= either (respond . cognitionError) (appendRoot store cleanSource cleanContent)
    appendRoot store cleanSource cleanContent lineage =
      promptAppend store Nothing RootConstitution cleanSource cleanContent "manual-root-audit-edit/v1" Nothing lineage PromptDraft
        >>= respond . ok
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
        (editPromptWith identifier cognition parent)
        (validatePromptDraft source content)
   where
    editPromptWith identifier' cognition' parent (cleanSource, cleanContent) =
      activeIncarnation cognition' identifier'
        >>= either (respond . cognitionError) (editPromptCurrent identifier' cognition' parent cleanSource cleanContent)
    editPromptCurrent identifier' cognition' parent cleanSource cleanContent current =
      validatePromptParent
        store
        (Just identifier')
        IncarnationCharter
        (parent <|> incarnationPromptRevision current)
        >>= either (respond . cognitionError) (appendIncarnationPrompt store identifier' cleanSource cleanContent)
     where
      store = cognitionIncarnations cognition'
    appendIncarnationPrompt store identifier' cleanSource cleanContent lineage =
      promptAppend store (Just identifier') IncarnationCharter cleanSource cleanContent "manual-audit-edit/v1" Nothing lineage PromptDraft
        >>= respond . ok
  generatePrompt identifier cognition =
    withBody "invalid prompt generation request: " $ \(GeneratePromptRequest source activate) ->
      activeIncarnation cognition identifier
        >>= either (respond . cognitionError) (generateFor cognition source activate)
   where
    generateFor cognition' source activate current =
      cognitionGeneratePrompt cognition' current source
        >>= either (respond . failed) (finish current cognition' activate)
    finish current _ False prompt = respond (ok (object ["incarnation" .= current, "prompt" .= prompt]))
    finish current cognition' True prompt =
      promptActivate
        (cognitionIncarnations cognition')
        (incarnationId current)
        (incarnationRevision current)
        (promptRevisionId prompt)
        >>= respond . either cognitionError (generationResult prompt)
    generationResult prompt activated =
      ok (object ["incarnation" .= activated, "prompt" .= prompt])
  activatePrompt identifier promptId cognition =
    withBody "invalid prompt activation request: " $ \(ActivatePromptRequest expected) ->
      promptActivate (cognitionIncarnations cognition) identifier expected promptId
        >>= respond . either cognitionError ok
  activeIncarnation cognition identifier =
    incarnationRead (cognitionIncarnations cognition) identifier <&> activeGate identifier
   where
    activeGate identifier' = \case
      Nothing -> Left ("unknown incarnation: " <> identifier')
      Just incarnation
        | incarnationStatus incarnation == IncarnationArchived ->
            Left ("incarnation is archived: " <> identifier')
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
    maybe notFound (\service -> taskOwnerFor service task >>= listFor) (inspectionSessions =<< inspection)
   where
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
      validateTaskOwner requestedOwner
        >>= either
          (respond . cognitionError)
          (const (createSessionFor service threadId title requestedOwner))
   where
    createSessionFor service' threadId title requestedOwner =
      let owner = fromMaybe "yuki" (nonBlankText =<< requestedOwner)
       in createSession (serviceSessions service') threadId title owner Nothing Nothing
            >>= either (respond . sessionError) (createdSession service' threadId owner)
    createdSession service' threadId owner created =
      bindTaskOwner service' threadId owner *> respond (ok created)
  validateTaskOwner Nothing = pure (Right ())
  validateTaskOwner (Just identifier) =
    maybe
      (pure (Left "incarnation service is unavailable"))
      (\cognition -> incarnationRead (cognitionIncarnations cognition) identifier <&> taskOwnerGate identifier)
      (inspectionCognition =<< inspection)
   where
    taskOwnerGate identifier' = \case
      Nothing -> Left ("unknown incarnation: " <> identifier')
      Just incarnation
        | incarnationStatus incarnation == IncarnationArchived ->
            Left ("incarnation is archived: " <> identifier')
        | otherwise -> Right ()
  bindTaskOwner service threadId identifier =
    threadConfigRead (serviceConfigs service) threadId
      >>= writeOwner (serviceConfigs service) threadId identifier
   where
    writeOwner store threadId' identifier' current =
      threadConfigWrite store threadId' current {configIncarnationId = Just identifier'}
  renameThread threadId service =
    withBody "invalid rename request: " $ \(RenameSessionRequest title) ->
      renameSession (serviceSessions service) threadId title >>= sessionResult
  homeGuard service threadId continue =
    findSession (serviceSessions service) threadId >>= homeGate continue
   where
    homeGate _ (Just meta)
      | sessionIsHome meta =
          respond (jsonResponse cors status400 [] (message "home_session_immutable"))
    homeGate continue' _ = continue'
  archiveThread threadId service = homeGuard service threadId (archiveSession service threadId >>= sessionResult)
  restoreThread threadId service =
    homeGuard service threadId $
      maybe
        (restoreSession service threadId >>= sessionResult)
        (restoreWithCognition threadId service)
        (inspectionCognition =<< inspection)
   where
    restoreWithCognition threadId' service' cognition =
      incarnationForThread cognition threadId'
        >>= either (respond . cognitionError) (const (restoreSession service' threadId' >>= sessionResult))
  forkThread source service =
    homeGuard service source $
      refreshTaskProjection source service
        >>= either (respond . cognitionError) (forkWithBody source service)
   where
    forkWithBody source' service' () =
      withBody "invalid fork request: " $ \(ForkSessionRequest target title node) ->
        forkSession service' source' target node title >>= sessionResult
  sleepThread threadId service =
    case inspectionCognition =<< inspection of
      Nothing -> respond (missing "sleep requires the cognition service")
      Just cognition ->
        readSleepRequest
          >>= const (incarnationForThread cognition threadId)
          >>= either (respond . cognitionError) (sleepWithIncarnation threadId service cognition)
   where
    sleepWithIncarnation threadId' service' cognition incarnation =
      authoritativeMessages cognition service' (incarnationId incarnation) threadId'
        >>= either (respond . cognitionError) (sleepWithMessages threadId' service' cognition incarnation)
    sleepWithMessages threadId' service' cognition incarnation messages =
      runtimeFor threadId' >>= sleepWithRuntime threadId' service' cognition incarnation messages
    sleepWithRuntime threadId' service' cognition incarnation messages runtime =
      newId >>= sleepWithRunId threadId' service' cognition incarnation messages runtime
    sleepWithRunId threadId' service' cognition incarnation messages runtime sleepRunId =
      cognitionSleepMessages cognition incarnation threadId' (Just sleepRunId) SleepManual runtime messages
        >>= either (respond . cognitionError) (sleepCompleted threadId' service')
    sleepCompleted threadId' service' result =
      transcriptSave (serviceTranscripts service') threadId' (compactionMessages (sleepResultCompaction result))
        *> (taskOwnerFor service' threadId' >>= ensureSession (serviceSessions service') threadId' Nothing)
        *> respond (ok result)
    readSleepRequest =
      strictRequestBody request >>= sleepRequestFromBody
    sleepRequestFromBody body
      | LazyByteString.null body = pure (SleepThreadRequest Nothing)
      | otherwise = either (const (pure (SleepThreadRequest Nothing))) pure (eitherDecode body)
  refreshTaskProjection threadId service =
    case inspectionCognition =<< inspection of
      Nothing -> pure (Right ())
      Just cognition ->
        incarnationForThread cognition threadId
          >>= either (pure . Left) (projectWithIncarnation threadId service cognition)
   where
    projectWithIncarnation threadId' service' cognition incarnation =
      authoritativeMessages cognition service' (incarnationId incarnation) threadId'
        >>= either (pure . Left) (projectWithMessages threadId' service')
    projectWithMessages threadId' service' messages =
      Right () <$ transcriptSave (serviceTranscripts service') threadId' messages
  exportThread threadId service =
    refreshTaskProjection threadId service
      >>= either (respond . cognitionError) (exportAfterProjection threadId service)
   where
    exportAfterProjection threadId' service' () =
      exportSession service' threadId' >>= respond . maybe (missing "thread not found") ok
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
        findSession (serviceSessions service) threadId >>= lockedSession config
      lockedSession config' = \case
        Nothing -> unlocked
        Just meta ->
          let owner = sessionOwnerId meta
           in case nonBlankText =<< configIncarnationId config' of
                Just requested
                  | requested /= owner ->
                      respond (conflict ("thread incarnation is immutable: " <> owner))
                _ -> validateActive owner config' {configIncarnationId = Just owner}
    validateActive identifier config =
      maybe
        (persist config)
        (\cognition -> incarnationRead (cognitionIncarnations cognition) identifier >>= validateActiveIncarnation config identifier)
        (inspectionCognition =<< inspection)
    validateActiveIncarnation config identifier = \case
      Nothing -> respond (missing ("unknown incarnation: " <> identifier))
      Just incarnation
        | incarnationStatus incarnation == IncarnationArchived ->
            respond (conflict ("incarnation is archived: " <> identifier))
        | otherwise -> persist config
    persist config =
      threadConfigWrite (configViewStore view) threadId config
        *> respond (responseLBS status204 (corsHeaders cors) "")
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
          (completeFor prefix)
          . cwdPath
          . configCwd
          . flip resolveThreadConfig (configViewDefaults view)
   where
    completeFor prefix dir =
      completePaths dir prefix >>= respond . ok . completed prefix
    completed prefix matches =
      object ["prefix" .= prefix, "paths" .= matches]
  artifact identifier store = maybe (missing "artifact not found") plain <$> artifactFetch store identifier
  journalRuns = respond . ok . runIds
  summaryFor runId = respond . maybe (missing "run not found") ok . runSummary runId
  traceFor runId = respond . maybe (missing "run not found") ok . runTrace runId
  journalEntries = respond . ok . forRun runParam
  replayReport entries =
    strictRequestBody request
      >>= either (respond . bad) result . replayWanted
   where
    result wanted = replayEntries defaultHooks wanted entries >>= respond . either bad ok
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
        cancelRun registry runId >>= cancelOutcome runId
      cancelOutcome runId cancelled =
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
      taskOwnerFor service (AGUI.runThreadId input)
        >>= ensureSession (serviceSessions service) (AGUI.runThreadId input) (latestUserTitle input)
        >>= bool
          (validateIncarnation service)
          (respond (conflict "thread is archived"))
          . sessionArchived
    validateIncarnation service =
      maybe
        (accept service)
        (validateIncarnationWith service)
        (inspectionCognition =<< inspection)
    validateIncarnationWith service cognition =
      incarnationForThread cognition (AGUI.runThreadId input)
        >>= either (respond . cognitionError) (const (accept service))
    accept service =
      authoritativeInput (inspectionCognition =<< inspection) configs service input
        >>= either (respond . failed) streamRun
    streamRun accepted =
      runtimeFor (AGUI.runThreadId accepted)
        >>= respond
          . responseStream status200 (corsHeaders cors <> streamHeaders)
          . streamFor accepted
     where
      streamFor accepted' runtime write flush =
        runAgent runtime accepted' (\event -> write (encodeEvent event) *> flush)
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
  promptRead store identifier <&> parentGate owner layer identifier
 where
  parentGate owner' layer' identifier' = \case
    Nothing -> Left ("unknown parent prompt revision: " <> identifier')
    Just parent
      | promptIncarnationId parent /= owner' ->
          Left "parent prompt revision belongs to another owner"
      | promptLayer parent /= layer' ->
          Left "parent prompt revision belongs to another layer"
      | otherwise -> Right (Just identifier')

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
  maybe
    (threadConfigRead (serviceConfigs service) threadId <&> fromMaybe "yuki" . (nonBlankText =<<) . configIncarnationId)
    (pure . sessionOwnerId)
    =<< findSession (serviceSessions service) threadId

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
  taskOwnerFor service task
    >>= flip (contextEpochHead (cognitionContexts cognition)) task
    >>= epochInput service input
 where
  task = AGUI.runThreadId input
  epochInput service' input' = \case
    Nothing -> Right <$> transcriptInput service' input'
    Just epoch ->
      contextEpochProject (cognitionContexts cognition) (contextEpochId epoch)
        <&> (>>= projectInput)
  projectInput projected =
    projectedAguiMessages projected <&> projectMessages input
  projectMessages input'' messages =
    input''
      { AGUI.runMessages =
          appendLatestUser messages (latestUserMessage input'')
      }

transcriptInput :: SessionService -> AGUI.RunAgentInput -> IO AGUI.RunAgentInput
transcriptInput service input =
  transcriptLoad (serviceTranscripts service) (AGUI.runThreadId input) <&> transcriptInputFromHistory input
 where
  transcriptInputFromHistory input' = \case
    Nothing -> input'
    Just [] -> input'
    Just history ->
      input'
        { AGUI.runMessages =
            appendLatestUser (toAguiMessages history) (latestUserMessage input')
        }

authoritativeMessages :: Cognition -> SessionService -> Text -> Text -> IO (Either Text [ChatMessage])
authoritativeMessages cognition service identity task =
  contextEpochHead (cognitionContexts cognition) identity task >>= epochMessages cognition service task
 where
  epochMessages cognition' service' task' = \case
    Just epoch ->
      contextEpochProject (cognitionContexts cognition') (contextEpochId epoch)
        <&> (>>= projectedAguiMessages >=> toChatMessages)
    Nothing ->
      transcriptLoad (serviceTranscripts service') task'
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
  FrameDraft draft -> sseFrame "draft" (toJSON draft)
  FrameDraftResolved identifier status threadId -> sseFrame "draft.resolved" (object ["dispatchId" .= identifier, "status" .= status, "threadId" .= threadId])

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
