module Yuki.N (runFromEnvironment) where

import Control.Applicative (liftA3, (<|>))
import Control.Exception (SomeException, bracket, displayException, try)
import Control.Monad (when)
import Data.Bool (bool)
import Data.Functor ((<&>))
import Data.IORef (writeIORef)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isNothing, listToMaybe)
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
import Yuki.N.Inspect
import Yuki.N.Invocation (invokeModel)
import Yuki.N.Journal
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
    >>= (either (die . Text.unpack) . boot <*> resolveSettings) . Map.fromList

boot :: Map.Map String String -> Settings -> IO ()
boot env settings =
  bracket newBackgroundRegistry shutdownBackground $ \background ->
    (,,,) <$> newTlsManager <*> traverse newFileJournal (settingsJournalDir settings) <*> traverse newArtifactStore (settingsArtifactDir settings) <*> newRunRegistry
      >>= serveWith background
 where
  serveWith background (manager, journal, artifacts, runs) =
    serve env manager journal artifacts settings runs background

serve :: Map.Map String String -> Manager -> Maybe Journal -> Maybe ArtifactStore -> Settings -> RunRegistry -> BackgroundRegistry -> IO ()
serve env manager journal artifacts settings runs background =
  liftA2 (,) (newTelemetry (settingsTelemetryDiffBytes settings)) (newLedger (settingsDataDir settings))
    >>= uncurry serveTelemetry
 where
  serveTelemetry telemetry ledger =
    writeIORef (telemetryLedger telemetry) (Just ledger)
      *> liftA2 (,) loadAuthJson (loadProviders env)
      >>= uncurry (serveRegistry telemetry ledger)
  serveRegistry telemetry ledger auth registry =
    let keyMap = providerKeyMap env auth registry
     in fallbackModels manager settings registry keyMap
          >>= serveFallbacks telemetry ledger registry keyMap
  serveFallbacks telemetry ledger registry keyMap fallbacks =
    newCognition
      (cognitionDir settings)
      (cognitionModelsOf manager settings <> fallbacks)
      journal
      >>= either (die . Text.unpack) (serveCognition telemetry ledger registry keyMap fallbacks)
  serveCognition telemetry ledger registry keyMap fallbacks cognition =
    (,,,) <$> transcriptOf settings <*> configStore <*> newSessionStore (settingsDataDir settings) <*> newDispatchStore (settingsDataDir settings)
      >>= serveStores telemetry ledger registry keyMap fallbacks cognition
  serveStores telemetry ledger registry keyMap fallbacks cognition (transcripts, store, sessions, dispatches) =
    migrateSessionOwners sessions store
      >>= either (die . Text.unpack) (serveReady telemetry ledger registry keyMap fallbacks cognition transcripts store sessions dispatches)
  serveReady telemetry ledger registry keyMap fallbacks cognition (transcriptHooks', transcripts) store sessions dispatches () =
    putStrLn (banner settings)
      *> runServer settings (inspection cognition transcripts service) (Just (view store registry keyMap)) (Just runs) (Just dispatchService) (Just telemetry) (resolve telemetry ledger cognition sessions store registry keyMap transcriptHooks' fallbacks dispatches)
   where
    service = SessionService sessions transcripts store (shutdownBackgroundThread background)
    dispatchService =
      newDispatchService
        dispatches
        service
        (cognitionIncarnations cognition)
        newId
        (generateDraft invokeModel (cognitionModelsOf manager settings <> fallbacks) (settingsDispatchGenerateTimeout settings) journal)
  inspection cognition transcripts sessions =
    Just
      ( withCognition
          cognition
          ( withSessionService
              sessions
              ( maybe
                  id
                  withLiveJournal
                  journal
                  (newInspection artifacts (journalFilePath <$> settingsJournalDir settings) (Just transcripts))
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
  base dispatches telemetry fallbacks =
    runtime background defaultHooks manager journal artifacts settings fallbacks <&> withRuntime dispatches telemetry
  withRuntime dispatches telemetry foundation =
    foundation {runtimeRuns = Just runs, runtimeTelemetry = Just telemetry, runtimeDispatchStore = Just dispatches, runtimeDispatchConfirmTimeout = settingsDispatchConfirmTimeout settings}
  resolve telemetry ledger cognition sessions store registry keyMap transcriptHooks' fallbacks dispatches threadId =
    liftA3 (,,) (base dispatches telemetry fallbacks) (threadConfigRead store threadId) (findSession sessions threadId)
      >>= resolveSession
   where
    resolveSession (foundation, session, meta) =
      let config = resolveThreadConfig session defaults
          identity = fromMaybe "yuki" ((nonBlank . sessionIncarnationId =<< meta) <|> (nonBlank =<< configIncarnationId config))
          resolvedConfig = config {configIncarnationId = Just identity}
          runIdentity = RunIdentity (maybe RunTask (bool RunTask RunHome . sessionIsHome) meta) identity
       in resolveRuntime manager (settingsProvider settings) artifacts foundation {runtimeIdentity = runIdentity} resolvedConfig registry keyMap
            >>= cognitivize resolvedConfig runIdentity
    cognitivize config runIdentity resolved =
      liftA2 (,) (ensureIncarnation cognition (fromMaybe "yuki" (configIncarnationId config))) (agentsMdSection (cwdPath (configCwd config)))
        >>= uncurry (assemble config runIdentity resolved)
    assemble config runIdentity resolved incarnation section =
      attachCognition cognition incarnation resolved <&> registerAgent config runIdentity section
    registerAgent config runIdentity section cognitive =
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
      when isRootRun (when (outcome == RunSucceeded) answerDelivery *> gitEnrichment)
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
  build dir = newTranscriptStore dir <&> withHooks
  withHooks store = (transcriptHooks store, store)

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
  buildRuntime <$> workToolSet background
 where
  buildRuntime tools =
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
        runtimeSubAgentMaxParallel = settingsSubAgentMaxParallel settings,
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
        runtimeDispatchStore = Nothing,
        runtimeDispatchConfirmTimeout = 600,
        runtimeIdentity = defaultIdentity,
        runtimeSteer = const (pure []),
        runtimeFollowUp = const (pure [])
      }
  artifactTools = maybe Map.empty (Map.singleton artifactReadToolName . artifactReadTool) artifacts
  workToolSet registry = maybe (pure Map.empty) (fmap fromTools . withBackground registry) (settingsWorkDir settings)
  withBackground registry cwd = (<> backgroundTools registry cwd) <$> workTools artifacts cwd
  fromTools = Map.fromList . fmap toolEntry
  toolEntry tool = (toolName (backendToolSpec tool), tool)

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
