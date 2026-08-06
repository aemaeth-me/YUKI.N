module Yuki.N.ThreadConfig
  ( module Yuki.N.ThreadConfig.Types,
    globalThreadConfig,
    newMemoryThreadConfigStore,
    newThreadConfigStore,
    renderGlobalConfig,
    resolveRuntime,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.Aeson
import Data.Bool (bool)
import Data.Functor ((<&>))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client (Manager)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import Yuki.N.AGUI.Types (toolName)
import Yuki.N.Agent
import Yuki.N.Artifact (ArtifactStore, artifactReadToolName)
import Yuki.N.AtomicFile (atomicEncodeFile)
import Yuki.N.Config (Settings (..))
import Yuki.N.Context (ContextConfig (..))
import Yuki.N.Domain.Thread (sanitizeThreadId)
import Yuki.N.Provider.OpenAI
import Yuki.N.Providers (ProviderEntry (..), ProviderRegistry, providerConfig, providerDefaultModel)
import Yuki.N.SubAgent (registerSubAgent)
import Yuki.N.ThreadConfig.Types
import Yuki.N.Tools (backgroundTools, workTools)

newThreadConfigStore :: FilePath -> IO ThreadConfigStore
newThreadConfigStore dir =
  createDirectoryIfMissing True (configsPath dir)
    *> newMVar ()
    <&> mkStore
 where
  mkStore lock = ThreadConfigStore (load dir) (save lock) (delete lock)
  save lock threadId config =
    withMVar lock (const (atomicEncodeFile (configPath dir threadId) config))
  delete lock threadId =
    withMVar lock $ \_ ->
      doesFileExist target >>= flip when (removeFile target)
   where
    target = configPath dir threadId

load :: FilePath -> Text -> IO ThreadConfig
load dir threadId =
  either (const emptyThreadConfig) (fromMaybe emptyThreadConfig)
    <$> (try (decodeFileStrict (configPath dir threadId)) :: IO (Either IOException (Maybe ThreadConfig)))

configsPath :: FilePath -> FilePath
configsPath dir = dir ++ "/threads-config"

configPath :: FilePath -> Text -> FilePath
configPath dir threadId = configsPath dir ++ "/" ++ Text.unpack (sanitizeThreadId threadId) ++ ".json"

newMemoryThreadConfigStore :: IO ThreadConfigStore
newMemoryThreadConfigStore =
  newIORef Map.empty
    <&> mkStore
 where
  mkStore configs =
    ThreadConfigStore
      ((<$> readIORef configs) . Map.findWithDefault emptyThreadConfig)
      ((modifyIORef' configs .) . Map.insert)
      (modifyIORef' configs . Map.delete)

resolveRuntime :: Manager -> OpenAIConfig -> Maybe ArtifactStore -> Runtime -> ThreadConfig -> ProviderRegistry -> Map.Map String Text -> IO Runtime
resolveRuntime manager provider artifacts base config registry keyMap =
  fmap build workToolSet
 where
  build tools =
    registerSubAgent
      base
        { runtimeModel = maybe (fallbackModel base) (openAIModel manager) chosenConfig,
          runtimeTools = artifactTools <> gated tools,
          runtimeSystemPrompt = fromMaybe (runtimeSystemPrompt base) (configSystemPrompt config),
          runtimeContext = applyContext <$> runtimeContext base
        }
  chosenConfig = configProvider config >>= pick
  pick name =
    liftA2 resolve (Map.lookup name registry) (Map.lookup (Text.unpack name) keyMap)
  resolve entry key =
    applyEffort (providerConfig entry key (configModel config <|> Just (providerDefaultModel entry)))
  fallbackModel source
    | isNothing (configModel config) && isNothing (configReasoningEffort config) = runtimeModel source
    | otherwise = openAIModel manager (applyEffort provider) {openAIModelName = fromMaybe (openAIModelName provider) (configModel config)}
  applyEffort cfg = maybe cfg (\effort -> cfg {openAIThinking = ThinkingEnabled effort}) (configReasoningEffort config)
  artifactTools = maybe Map.empty (Map.singleton artifactReadToolName . artifactReadTool) artifacts
  workToolSet = maybe (pure Map.empty) (fmap byName . withBackground) (cwdPath (configCwd config))
  withBackground cwd = (<> backgroundTools (runtimeBackground base) cwd) <$> workTools artifacts cwd
  byName = Map.fromList . fmap ((,) <$> (toolName . backendToolSpec) <*> id)
  gated = fsGate . shellGate
  fsGate = bool (Map.filterWithKey (\name _ -> not ("fs_" `Text.isPrefixOf` name))) id (configFs config /= Just False)
  shellGate = bool (Map.filterWithKey (\name _ -> not ("shell" `Text.isPrefixOf` name))) id (configShell config /= Just False)
  applyContext context =
    context
      { contextReserveTokens = fromMaybe (contextReserveTokens context) (configContextReserveTokens config),
        contextKeepUnits = fromMaybe (contextKeepUnits context) (configContextKeepUnits config),
        contextSummaryTokens = fromMaybe (contextSummaryTokens context) (configContextSummaryTokens config)
      }

globalThreadConfig :: Settings -> ThreadConfig
globalThreadConfig settings =
  ThreadConfig
    { configCwd = maybe CwdNone CwdPath (settingsWorkDir settings),
      configSystemPrompt = bool (Just prompt) Nothing (Text.null prompt),
      configProvider = Nothing,
      configModel = Nothing,
      configReasoningEffort = Nothing,
      configFs = Nothing,
      configShell = Nothing,
      configContextReserveTokens = Just (settingsContextReserveTokens settings),
      configContextKeepUnits = Just (settingsContextKeepUnits settings),
      configContextSummaryTokens = Just (settingsContextSummaryTokens settings)
    }
 where
  prompt = settingsSystemPrompt settings

renderGlobalConfig :: Settings -> ThreadConfig -> Value
renderGlobalConfig settings defaults =
  object
    [ "provider"
        .= object
          [ "name" .= openAIProvider provider,
            "model" .= openAIModelName provider,
            "baseUrl" .= openAIBaseUrl provider,
            "apiKey" .= ("＊＊＊" :: Text),
            "dialect" .= dialectName (openAIDialect provider),
            "thinking" .= thinkingName (openAIThinking provider),
            "maxTokens" .= openAIMaxTokens provider,
            "contextTokens" .= openAIContextTokens provider
          ],
      "settings"
        .= object
          [ "host" .= settingsHost settings,
            "port" .= settingsPort settings,
            "corsOrigin" .= settingsCorsOrigin settings,
            "maxTurns" .= settingsMaxTurns settings,
            "providerRetries" .= settingsProviderRetries settings,
            "fallbackProviders" .= settingsFallbackProviders settings,
            "toolExecution" .= executionName (settingsToolExecution settings),
            "systemPrompt" .= settingsSystemPrompt settings,
            "workDir" .= settingsWorkDir settings,
            "artifactDir" .= settingsArtifactDir settings,
            "transcriptDir" .= settingsTranscriptDir settings,
            "spliceChars" .= settingsSpliceChars settings,
            "spliceKeep" .= settingsSpliceKeep settings,
            "contextReserveTokens" .= settingsContextReserveTokens settings,
            "contextKeepUnits" .= settingsContextKeepUnits settings,
            "contextSummaryTokens" .= settingsContextSummaryTokens settings
          ],
      "defaults" .= defaults
    ]
 where
  provider = settingsProvider settings

dialectName :: ApiDialect -> Text
dialectName DeepSeek = "deepseek"
dialectName OpenAICompatible = "openai-compatible"

thinkingName :: ThinkingMode -> Text
thinkingName ThinkingDisabled = "disabled"
thinkingName (ThinkingEnabled Low) = "low"
thinkingName (ThinkingEnabled High) = "high"
thinkingName (ThinkingEnabled Max) = "max"

executionName :: ToolExecution -> Text
executionName Parallel = "parallel"
executionName Sequential = "sequential"
