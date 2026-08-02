module Yuki.N (runFromEnvironment) where

import Control.Applicative (liftA3, (<|>))
import Control.Exception (SomeException, bracket, displayException, try)
import Control.Monad (join, when)
import Data.Aeson (toJSON)
import Data.Bool (bool)
import Data.Foldable (traverse_)
import Data.Functor ((<&>))
import Data.IORef (writeIORef)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isNothing, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import System.Environment (getEnvironment)
import System.Exit (die)
import System.FilePath ((</>))
import System.IO (stderr)
import Yuki.N.AGUI.Types (toolName)
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent
import Yuki.N.AgentsMd (agentsMdSection, appendAgentsMd)
import Yuki.N.Artifact (ArtifactStore, SpliceConfig (..), artifactReadToolName, newArtifactStore)
import Yuki.N.Background (BackgroundRegistry, newBackgroundRegistry, shutdownBackground, shutdownBackgroundThread)
import Yuki.N.Cognition
import Yuki.N.Config
import Yuki.N.Context (ContextConfig (..))
import Yuki.N.Dispatch
import Yuki.N.Facts (Fact (..), FactStore (..), factKindName, newFactStore)
import Yuki.N.Incarnation (IncarnationStore (..))
import Yuki.N.Inspect
import Yuki.N.Invocation (invokeModel)
import Yuki.N.Journal
import Yuki.N.Memory (ThreadStore (..), newThreadStore)
import Yuki.N.Model (AssistantTurn (..), ChatMessage (..), Model)
import Yuki.N.Provider.OpenAI
import Yuki.N.Providers (ProviderRegistry, loadAuthJson, loadProviders, providerConfig, providerKeyMap, providerListing)
import Yuki.N.Runs (RunKind (..), RunRegistry, newRunRegistry)
import Yuki.N.Server
import Yuki.N.Sessions (SessionMeta (..), SessionService (..), SessionStore (..), migrateSessionOwners, newSessionStore, sessionIsHome)
import Yuki.N.SubAgent (registerSubAgent)
import Yuki.N.Telemetry (DeliveryKind (DeliveryAnswer), DeliveryRecord (..), newTelemetry, noteEvent, telemetryLedger)
import Yuki.N.Telemetry.Ledger (enrichFromGit, newLedger, recordDelivery)
import Yuki.N.ThreadConfig
import Yuki.N.Tools (backgroundTools, workTools)
import Yuki.N.Transcript (TranscriptStore (..), newTranscriptStore, transcriptHooks)

runFromEnvironment :: IO ()
runFromEnvironment =
  getEnvironment
    >>= (\env -> either (die . Text.unpack) (boot env) (resolveSettings env))
      . Map.fromList

boot :: Map.Map String String -> Settings -> IO ()
boot env settings =
  bracket newBackgroundRegistry shutdownBackground $ \background ->
    newTlsManager >>= \manager ->
      traverse newFileJournal (settingsJournalDir settings)
        >>= \journal ->
          traverse newArtifactStore (settingsArtifactDir settings)
            >>= \artifacts ->
              newRunRegistry >>= \runs ->
                serve env manager journal artifacts settings runs background

serve :: Map.Map String String -> Manager -> Maybe Journal -> Maybe ArtifactStore -> Settings -> RunRegistry -> BackgroundRegistry -> IO ()
serve env manager journal artifacts settings runs background =
  liftA2 (,) newTelemetry (newLedger (settingsDataDir settings)) >>= \(telemetry, ledger) ->
    writeIORef (telemetryLedger telemetry) (Just ledger)
      >> loadAuthJson
      >>= \auth ->
        loadProviders env >>= \registry ->
          let keyMap = providerKeyMap env auth registry
           in fallbackModels manager settings registry keyMap
                >>= \fallbacks ->
                  newCognition
                    (cognitionDir settings)
                    (cognitionModelsOf manager settings <> fallbacks)
                    journal
                    >>= either
                      (die . Text.unpack)
                      ( \cognition ->
                          legacyMemoryOf settings
                            >>= \memory ->
                              transcriptOf settings
                                >>= \(transcriptHooks', transcripts) ->
                                  configStore
                                    >>= \store ->
                                      newSessionStore (settingsDataDir settings)
                                        >>= \sessions ->
                                          newDispatchStore (settingsDataDir settings)
                                            >>= \dispatches ->
                                              let service = SessionService sessions transcripts store (shutdownBackgroundThread background)
                                                  dispatchService =
                                                    newDispatchService
                                                      dispatches
                                                      service
                                                      (cognitionIncarnations cognition)
                                                      newId
                                                      ( generateDraft
                                                          invokeModel
                                                          (cognitionModelsOf manager settings <> fallbacks)
                                                          (settingsDispatchGenerateTimeout settings)
                                                          journal
                                                      )
                                               in migrateSessionOwners sessions store
                                                    >>= either
                                                      (die . Text.unpack)
                                                      ( \() ->
                                                          migrateLegacy cognition memory transcripts service defaults
                                                            *> putStrLn (banner settings)
                                                            *> runServer settings (inspection cognition memory transcripts service) (Just (view store registry keyMap)) (Just runs) (Just dispatchService) (resolve telemetry ledger cognition sessions store registry keyMap transcriptHooks' fallbacks)
                                                      )
                      )
 where
  inspection cognition memory transcripts sessions =
    Just
      ( withCognition
          cognition
          ( withSessionService
              sessions
              ( maybe
                  id
                  withLiveJournal
                  journal
                  (newInspection memory artifacts (journalFilePath <$> settingsJournalDir settings) (Just transcripts))
              )
          )
      )
  defaults = globalThreadConfig settings
  configStore = newThreadConfigStore (fromMaybe (settingsDataDir settings) (settingsMemoryDir settings))
  view store registry keyMap =
    ConfigView
      (renderGlobalConfig settings defaults)
      store
      defaults
      (pure (Right [openAIModelName (settingsProvider settings)]))
      (providerListing manager registry keyMap)
  base telemetry fallbacks = runtime background defaultHooks manager journal artifacts settings fallbacks <&> \foundation -> foundation {runtimeRuns = Just runs, runtimeTelemetry = Just telemetry}
  resolve telemetry ledger cognition sessions store registry keyMap transcriptHooks' fallbacks threadId =
    liftA3 (,,) (base telemetry fallbacks) (threadConfigRead store threadId) (findSession sessions threadId)
      >>= \(foundation, session, meta) ->
        let config = resolveThreadConfig session defaults
            identity = fromMaybe "yuki" ((nonBlank . sessionIncarnationId =<< meta) <|> (nonBlank =<< configIncarnationId config))
            resolvedConfig = config {configIncarnationId = Just identity}
            runIdentity = RunIdentity (maybe RunTask (bool RunTask RunHome . sessionIsHome) meta) identity
         in resolveRuntime manager (settingsProvider settings) artifacts foundation {runtimeIdentity = runIdentity} resolvedConfig registry keyMap
              >>= cognitivize resolvedConfig runIdentity
   where
    cognitivize config runIdentity resolved =
      liftA2 (,) (ensureIncarnation cognition (fromMaybe "yuki" (configIncarnationId config))) (agentsMdSection (cwdPath (configCwd config)))
        >>= uncurry (assemble config runIdentity resolved)
    assemble config runIdentity resolved incarnation section =
      attachCognition cognition incarnation resolved <&> \cognitive ->
        registerSubAgent
          cognitive
            { runtimeSystemPrompt = appendAgentsMd section (runtimeSystemPrompt cognitive),
              runtimeHooks = runtimeHooks cognitive <> transcriptHooks' <> telemetryObserver telemetry <> ledgerObserver config runIdentity
            }
    telemetryObserver hub =
      defaultHooks {observeEvent = \input event -> noteEvent hub (AGUI.runId input) event}
    ledgerObserver config runIdentity =
      defaultHooks
        { afterRunOutcome = \input outcome messages ->
            try @SomeException (ledgerOutcome config runIdentity input outcome messages) >>= either (logErr "ledger") (const (pure ()))
        }
    ledgerOutcome config runIdentity input outcome messages =
      when (isRootRun && outcome == RunSucceeded) (answerDelivery *> gitEnrichment)
     where
      isRootRun = isNothing (AGUI.runParentId input) && identityKind runIdentity /= RunWorker
      answerDelivery =
        recordDelivery
          ledger
          telemetry
          DeliveryRecord
            { deliveryId = "",
              deliveryRunId = AGUI.runId input,
              deliveryThreadId = AGUI.runThreadId input,
              deliveryIncarnation = identityIncarnation runIdentity,
              deliveryRunKind = identityKind runIdentity,
              deliveryKind = DeliveryAnswer,
              deliveryTitle = Text.take 200 (answerSummary finalText),
              deliveryRef = fromMaybe (AGUI.runId input) (finalMessageId messages),
              deliveryBytes = Nothing,
              deliveryAt = 0
            }
       where
        finalText = Text.take 4000 (fromMaybe "" (finalAssistantText messages))
      gitEnrichment =
        enrichFromGit ledger telemetry (settingsTelemetryGitTimeout settings) (identityIncarnation runIdentity) (AGUI.runId input) (AGUI.runThreadId input) (cwdPath (configCwd config))
      finalAssistantText msgs =
        listToMaybe (reverse [text | ChatAssistant turn <- msgs, Just text <- [turnText turn], not (Text.null text)])
      finalMessageId msgs =
        listToMaybe (reverse [turnMessageId turn | ChatAssistant turn <- msgs])
      answerSummary text =
        fromMaybe "" (find (not . Text.null) (Text.lines text))
    logErr tag =
      TextIO.hPutStrLn stderr . (("yuki.telemetry: " <> tag <> ": ") <>) . Text.pack . displayException
    nonBlank value
      | Text.null clean = Nothing
      | otherwise = Just clean
     where
      clean = Text.strip value

transcriptOf :: Settings -> IO (AgentHooks, TranscriptStore)
transcriptOf settings =
  build (fromMaybe (settingsDataDir settings) (settingsTranscriptDir settings))
 where
  build dir = newTranscriptStore dir <&> \store -> (transcriptHooks store, store)

legacyMemoryOf :: Settings -> IO (Maybe (ThreadStore, FactStore))
legacyMemoryOf settings =
  traverse
    (\dir -> liftA2 (,) (newThreadStore dir) (newFactStore dir))
    (settingsMemoryDir settings)

cognitionDir :: Settings -> FilePath
cognitionDir settings =
  fromMaybe (settingsDataDir settings) (settingsMemoryDir settings) </> "cognition-v2"

cognitionModelsOf :: Manager -> Settings -> [Model]
cognitionModelsOf manager settings =
  [ openAIModel
      manager
      (settingsProvider settings)
        { openAIModelName =
            fromMaybe
              (openAIModelName (settingsProvider settings))
              (settingsMemoryModel settings)
        }
  ]

migrateLegacy ::
  Cognition ->
  Maybe (ThreadStore, FactStore) ->
  TranscriptStore ->
  SessionService ->
  ThreadConfig ->
  IO ()
migrateLegacy cognition legacy transcripts sessions defaults =
  listSessions (serviceSessions sessions) True >>= \allSessions ->
    let collisions =
          Set.fromList
            ( concat
                [ identifiers
                | identifiers <- Map.elems (Map.fromListWith (<>) [(legacyTaskId (sessionId session), [sessionId session]) | session <- allSessions]),
                  length identifiers > 1
                ]
            )
     in traverse_ (migrateTask collisions) allSessions *> traverse_ migrateFacts legacy
 where
  migrateTask collisions session
    | sessionId session `Set.member` collisions =
        putStrLn
          ( "YUKI.N cognition migration: skipped ambiguous legacy task path "
              <> Text.unpack (sessionId session)
              <> " (dot/dash collision)"
          )
    | otherwise =
        loadConfig (sessionId session) >>= \local ->
          migrationIncarnation
            (fromMaybe "yuki" (configIncarnationId (resolveThreadConfig local defaults)))
            >>= \incarnation ->
              loadTranscript (sessionId session) >>= \transcript ->
                loadBrief (sessionId session) >>= \brief ->
                  case (transcript, brief) of
                    (Nothing, Nothing) -> pure ()
                    _ ->
                      cognitionMigrateLegacyTask
                        cognition
                        incarnation
                        (sessionId session)
                        (fromMaybe [] transcript)
                        (toJSON <$> brief)
                        >>= report ("task " <> sessionId session)
  loadConfig task =
    threadConfigRead (serviceConfigs sessions) task >>= \current ->
      if current /= emptyThreadConfig || legacyTaskId task == task
        then pure current
        else
          threadConfigRead (serviceConfigs sessions) (legacyTaskId task) >>= \fallback ->
            if fallback == emptyThreadConfig
              then pure fallback
              else fallback <$ threadConfigWrite (serviceConfigs sessions) task fallback
  loadTranscript task =
    transcriptLoad transcripts task >>= \case
      Just messages -> pure (Just messages)
      Nothing
        | legacyTaskId task == task -> pure Nothing
        | otherwise ->
            transcriptLoad transcripts (legacyTaskId task) >>= \fallback ->
              fallback <$ traverse_ (transcriptSave transcripts task) fallback
  loadBrief task =
    traverse (flip threadBrief task . fst) legacy >>= \current ->
      case join current of
        Just brief -> pure (Just brief)
        Nothing
          | legacyTaskId task == task -> pure Nothing
          | otherwise ->
              traverse (flip threadBrief (legacyTaskId task) . fst) legacy <&> (>>= id)
  migrationIncarnation identifier =
    incarnationRead (cognitionIncarnations cognition) identifier >>= \case
      Nothing -> ioError (userError ("unknown incarnation: " <> Text.unpack identifier))
      Just incarnation -> pure incarnation
  migrateFacts (_, facts) =
    ensureIncarnation cognition "yuki" >>= \incarnation ->
      factList facts
        >>= traverse_
          ( \fact ->
              cognitionMigrateLegacyMemory
                cognition
                incarnation
                (factKindName (factKind fact))
                (factContent fact)
                (take 16 (Text.words (Text.toLower (factContent fact))))
                ["legacy-fact/" <> factId fact, factSource fact]
                >>= report ("fact " <> factId fact)
          )
          . filter ((&&) <$> (not . factArchived) <*> (not . factVoid))
  report label =
    either
      (putStrLn . Text.unpack . \failure -> "YUKI.N cognition migration (" <> label <> "): " <> failure)
      (const (pure ()))
  legacyTaskId = Text.map (\character -> if character == '.' then '-' else character)

fallbackModels :: Manager -> Settings -> ProviderRegistry -> Map.Map String Text -> IO [Model]
fallbackModels manager settings registry keyMap =
  catMaybes <$> traverse resolve (settingsFallbackProviders settings)
 where
  resolve name =
    maybe (warn name "not in provider registry") (withKey name) (Map.lookup name registry)
  withKey name entry =
    maybe
      (warn name "has no API key")
      (\key -> pure (Just (openAIModel manager (providerConfig entry key Nothing))))
      (Map.lookup (Text.unpack name) keyMap)
  warn name reason =
    Nothing
      <$ putStrLn ("YUKI_FALLBACK_PROVIDERS: skipping " <> Text.unpack name <> " (" <> reason <> ")")

runtime :: BackgroundRegistry -> AgentHooks -> Manager -> Maybe Journal -> Maybe ArtifactStore -> Settings -> [Model] -> IO Runtime
runtime background hooks manager journal artifacts settings fallbacks =
  workToolSet background <&> \tools ->
    Runtime
      { runtimeModel = openAIModel manager (settingsProvider settings),
        runtimeTools = artifactTools <> tools,
        runtimeToolExecution = settingsToolExecution settings,
        runtimeMaxTurns = settingsMaxTurns settings,
        runtimeSystemPrompt = settingsSystemPrompt settings,
        runtimeHooks = hooks,
        runtimeNewId = newId,
        runtimeJournal = journal,
        runtimeArtifactStore = artifacts,
        runtimeBackground = background,
        runtimeDepth = settingsSubAgentDepth settings,
        runtimeProviderRetries = settingsProviderRetries settings,
        runtimeFallbacks = fallbacks,
        runtimeSplice = Just (SpliceConfig (settingsSpliceChars settings) (settingsSpliceKeep settings)),
        runtimeContext =
          Just
            ( ContextConfig
                (settingsContextReserveTokens settings)
                (settingsContextKeepUnits settings)
                (settingsContextSummaryTokens settings)
                (settingsSpliceChars settings)
            ),
        runtimeRuns = Nothing,
        runtimeTelemetry = Nothing,
        runtimeIdentity = defaultIdentity,
        runtimeSteer = const (pure []),
        runtimeFollowUp = const (pure [])
      }
 where
  artifactTools = maybe Map.empty (Map.singleton artifactReadToolName . artifactReadTool) artifacts
  workToolSet registry = maybe (pure Map.empty) (fmap fromTools . withBackground registry) (settingsWorkDir settings)
  withBackground registry cwd = (<> backgroundTools registry cwd) <$> workTools artifacts cwd
  fromTools = Map.fromList . fmap (\tool -> (toolName (backendToolSpec tool), tool))

banner :: Settings -> String
banner settings =
  "YUKI.N listening on http://"
    <> settingsHost settings
    <> ":"
    <> show (settingsPort settings)
    <> "/agent ("
    <> Text.unpack (openAIProvider provider)
    <> "/"
    <> Text.unpack (openAIModelName provider)
    <> ")"
 where
  provider = settingsProvider settings
