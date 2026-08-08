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
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent
import Yuki.N.AgentsMd (agentsMdSection, appendAgentsMd)
import Yuki.N.Artifact (ArtifactStore, SpliceConfig (..), newArtifactStore)
import Yuki.N.Background (BackgroundRegistry, newBackgroundRegistry, shutdownBackground)
import Yuki.N.Config
import Yuki.N.Context (ContextConfig (..))
import Yuki.N.Model (ChatMessage, Model)
import Yuki.N.Provider.OpenAI
import Yuki.N.Providers (ProviderRegistry, loadAuthJson, loadProviders, providerConfig, providerKeyMap)
import Yuki.N.Runs (RunRegistry, newRunRegistry)
import Yuki.N.Server
import Yuki.N.Sessions (newSessionStore)
import Yuki.N.SubAgent (registerSubAgent)
import Yuki.N.ThreadConfig
import Yuki.N.Transcript (newTranscriptStore, transcriptHook)

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
    (,) <$> newTranscriptStore transcriptDir <*> newSessionStore (settingsDataDir settings)
      >>= serveStores registry keyMap fallbacks
  serveStores registry keyMap fallbacks (transcripts, sessions) =
    putStrLn (banner settings)
      *> runServer
        settings
        sessions
        transcripts
        (resolve registry keyMap (transcriptHook transcripts) fallbacks)
  transcriptDir = fromMaybe (settingsDataDir settings) (settingsTranscriptDir settings)
  defaults = mempty {configCwd = maybe CwdNone CwdPath (settingsWorkDir settings)}
  resolve registry keyMap afterRun fallbacks threadId =
    loadThreadConfig (settingsDataDir settings) threadId >>= resolveSession
   where
    resolveSession session =
      let config = session <> defaults
       in resolveRuntime manager (settingsProvider settings) artifacts (runtime background afterRun manager artifacts settings runs fallbacks) config registry keyMap
            >>= assemble config
    assemble config resolved =
      agentsMdSection (cwdPath (configCwd config))
        <&> registerAgent resolved
    registerAgent resolved section =
      registerSubAgent
        resolved
          { runtimeSystemPrompt = appendAgentsMd section (runtimeSystemPrompt resolved)
          }

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

runtime :: BackgroundRegistry -> (AGUI.RunAgentInput -> [ChatMessage] -> IO ()) -> Manager -> Maybe ArtifactStore -> Settings -> RunRegistry -> [Model] -> Runtime
runtime background afterRun manager artifacts settings runs fallbacks =
  Runtime
    { runtimeModel = openAIModel manager (settingsProvider settings),
      runtimeTools = Map.empty,
      runtimeToolExecution = settingsToolExecution settings,
      runtimeMaxTurns = settingsMaxTurns settings,
      runtimeSystemPrompt = settingsSystemPrompt settings,
      runtimeAfterRun = afterRun,
      runtimeNewId = newId,
      runtimeArtifactStore = artifacts,
      runtimeBackground = background,
      runtimeSubAgentMaxParallel = settingsSubAgentMaxParallel settings,
      runtimeProviderRetries = settingsProviderRetries settings,
      runtimeFallbacks = fallbacks,
      runtimeSplice = SpliceConfig (settingsSpliceChars settings) (settingsSpliceKeep settings),
      runtimeContext =
        ContextConfig
          (settingsContextReserveTokens settings)
          (settingsContextKeepUnits settings)
          (settingsContextSummaryTokens settings),
      runtimeRuns = runs
    }

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
