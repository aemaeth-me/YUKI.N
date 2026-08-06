module Yuki.N (runFromEnvironment) where

import Control.Exception (bracket)
import Data.Functor ((<&>))
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import System.Environment (getEnvironment)
import System.Exit (die)
import Yuki.N.AGUI.Types (toolName)
import Yuki.N.Agent
import Yuki.N.AgentsMd (agentsMdSection, appendAgentsMd)
import Yuki.N.Artifact (ArtifactStore, SpliceConfig (..), artifactReadToolName, newArtifactStore)
import Yuki.N.Background (BackgroundRegistry, newBackgroundRegistry, shutdownBackground, shutdownBackgroundThread)
import Yuki.N.Config
import Yuki.N.Context (ContextConfig (..))
import Yuki.N.Model (Model)
import Yuki.N.Provider.OpenAI
import Yuki.N.Providers (ProviderRegistry, loadAuthJson, loadProviders, providerConfig, providerKeyMap, providerListing)
import Yuki.N.Runs (RunRegistry, newRunRegistry)
import Yuki.N.Server
import Yuki.N.Sessions (SessionService (..), migrateSessionOwners, newSessionStore)
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
    (,,) <$> newTlsManager <*> traverse newArtifactStore (settingsArtifactDir settings) <*> newRunRegistry
      >>= serveWith background
 where
  serveWith background (manager, artifacts, runs) =
    serve env manager artifacts settings runs background

serve :: Map.Map String String -> Manager -> Maybe ArtifactStore -> Settings -> RunRegistry -> BackgroundRegistry -> IO ()
serve env manager artifacts settings runs background =
  liftA2 (,) loadAuthJson (loadProviders env)
    >>= uncurry serveRegistry
 where
  serveRegistry auth registry =
    let keyMap = providerKeyMap env auth registry
     in fallbackModels manager settings registry keyMap
          >>= serveFallbacks registry keyMap
  serveFallbacks registry keyMap fallbacks =
    (,,) <$> transcriptOf settings <*> configStore <*> newSessionStore (settingsDataDir settings)
      >>= serveStores registry keyMap fallbacks
  serveStores registry keyMap fallbacks (transcripts, store, sessions) =
    migrateSessionOwners sessions store
      >>= either (die . Text.unpack) (serveReady registry keyMap fallbacks transcripts store sessions)
  serveReady registry keyMap fallbacks (transcriptHooks', transcripts) store sessions () =
    putStrLn (banner settings)
      *> runServer
        settings
        (Just service)
        (Just (view store registry keyMap))
        artifacts
        (resolve store registry keyMap transcriptHooks' fallbacks)
   where
    service = SessionService sessions transcripts store (shutdownBackgroundThread background)
  defaults = globalThreadConfig settings
  configStore = newThreadConfigStore (settingsDataDir settings)
  view store registry keyMap =
    ConfigView
      (renderGlobalConfig settings defaults)
      store
      defaults
      (pure (Right [openAIModelName (settingsProvider settings)]))
      (providerListing manager registry keyMap)
  base fallbacks =
    runtime background defaultHooks manager artifacts settings fallbacks <&> withRuntime
  withRuntime foundation = foundation {runtimeRuns = Just runs}
  resolve store registry keyMap transcriptHooks' fallbacks threadId =
    threadConfigRead store threadId >>= resolveSession
   where
    resolveSession session =
      let config = resolveThreadConfig session defaults
       in base fallbacks
            >>= \foundation ->
              resolveRuntime manager (settingsProvider settings) artifacts foundation config registry keyMap
                >>= assemble config
    assemble config resolved =
      agentsMdSection (cwdPath (configCwd config))
        <&> registerAgent resolved
    registerAgent resolved section =
      resolved
        { runtimeSystemPrompt = appendAgentsMd section (runtimeSystemPrompt resolved),
          runtimeHooks = runtimeHooks resolved <> transcriptHooks'
        }

transcriptOf :: Settings -> IO (AgentHooks, TranscriptStore)
transcriptOf settings =
  build (fromMaybe (settingsDataDir settings) (settingsTranscriptDir settings))
 where
  build dir = newTranscriptStore dir <&> withHooks
  withHooks store = (transcriptHooks store, store)

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

runtime :: BackgroundRegistry -> AgentHooks -> Manager -> Maybe ArtifactStore -> Settings -> [Model] -> IO Runtime
runtime background hooks manager artifacts settings fallbacks =
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
