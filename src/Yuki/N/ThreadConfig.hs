module Yuki.N.ThreadConfig
  ( CwdSetting (..),
    ThreadConfig (..),
    ThreadConfigStore (..),
    cwdPath,
    emptyThreadConfig,
    fsInterceptor,
    globalThreadConfig,
    newMemoryThreadConfigStore,
    newThreadConfigStore,
    renderGlobalConfig,
    resolveRuntime,
    resolveThreadConfig,
  )
where

import Control.Applicative (liftA3, (<|>))
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (IOException, evaluate, try)
import Control.Monad (when)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseMaybe)
import Data.Bool (bool)
import Data.Functor (($>), (<&>))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Lazy qualified as LazyText
import Data.Text.Lazy.IO qualified as LazyTextIO
import Network.HTTP.Client (Manager)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Text.Read (readMaybe)
import Yuki.N.AGUI.Types (toolName)
import Yuki.N.Agent
import Yuki.N.Artifact (ArtifactStore, artifactReadToolName)
import Yuki.N.AtomicFile (atomicEncodeFile)
import Yuki.N.Config (Settings (..))
import Yuki.N.Context (ContextConfig (..))
import Yuki.N.Domain.Diff (unified)
import Yuki.N.Memory (sanitizeThreadId)
import Yuki.N.Provider.OpenAI
import Yuki.N.Providers (ProviderEntry (..), ProviderRegistry, providerConfig, providerDefaultModel)
import Yuki.N.Runs (RunKind (..))
import Yuki.N.SubAgent (registerSubAgent)
import Yuki.N.Telemetry
  ( DeliveryKind (DeliveryFileWrite),
    DeliveryRecord (..),
    FsChangeOp (..),
    FsChangeOrigin (OriginTool),
    FsChangeRecord (..),
    Ledger,
    Telemetry,
    telemetryLedger,
  )
import Yuki.N.Telemetry.Ledger (quietly, recordDelivery, recordFsChange)
import Yuki.N.Tools (backgroundTools, workTools)

data CwdSetting
  = CwdInherit
  | CwdNone
  | CwdPath FilePath
  deriving stock (Eq, Show)

cwdPath :: CwdSetting -> Maybe FilePath
cwdPath CwdInherit = Nothing
cwdPath CwdNone = Nothing
cwdPath (CwdPath path) = Just path

data ThreadConfig = ThreadConfig
  { configCwd :: CwdSetting,
    configIncarnationId :: Maybe Text,
    configSystemPrompt :: Maybe Text,
    configProvider :: Maybe Text,
    configModel :: Maybe Text,
    configReasoningEffort :: Maybe ReasoningEffort,
    configFs :: Maybe Bool,
    configShell :: Maybe Bool,
    configMemory :: Maybe Bool,
    configContextReserveTokens :: Maybe Int,
    configContextKeepUnits :: Maybe Int,
    configContextSummaryTokens :: Maybe Int
  }
  deriving stock (Eq, Show)

emptyThreadConfig :: ThreadConfig
emptyThreadConfig = ThreadConfig CwdInherit Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

instance Semigroup ThreadConfig where
  session <> fallback =
    ThreadConfig
      cwd
      (pick configIncarnationId)
      (pick configSystemPrompt)
      (pick configProvider)
      (pick configModel)
      (pick configReasoningEffort)
      (pick configFs)
      (pick configShell)
      (pick configMemory)
      (pick configContextReserveTokens)
      (pick configContextKeepUnits)
      (pick configContextSummaryTokens)
   where
    cwd = case configCwd session of
      CwdInherit -> configCwd fallback
      explicit -> explicit
    pick :: (ThreadConfig -> Maybe field) -> Maybe field
    pick field = field session <|> field fallback

instance Monoid ThreadConfig where
  mempty = emptyThreadConfig

resolveThreadConfig :: ThreadConfig -> ThreadConfig -> ThreadConfig
resolveThreadConfig = (<>)

instance ToJSON ThreadConfig where
  toJSON config =
    object
      ( cwdPairs (configCwd config)
          <> [ "cwdMode" .= cwdMode cwd,
               "incarnationId" .= configIncarnationId config,
               "systemPrompt" .= configSystemPrompt config,
               "provider" .= configProvider config,
               "model" .= configModel config,
               "reasoningEffort" .= configReasoningEffort config,
               "fs" .= configFs config,
               "shell" .= configShell config,
               "memory" .= configMemory config,
               "contextReserveTokens" .= configContextReserveTokens config,
               "contextKeepUnits" .= configContextKeepUnits config,
               "contextSummaryTokens" .= configContextSummaryTokens config
             ]
      )
   where
    cwd = configCwd config
    cwdPairs CwdInherit = []
    cwdPairs CwdNone = ["cwd" .= Null]
    cwdPairs (CwdPath path) = ["cwd" .= path]
    cwdMode CwdInherit = "inherit" :: Text
    cwdMode CwdNone = "none"
    cwdMode CwdPath {} = "path"

instance FromJSON ThreadConfig where
  parseJSON = withObject "ThreadConfig" $ \fields ->
    ThreadConfig
      <$> parseCwd fields
      <*> fields .:? "incarnationId"
      <*> fields .:? "systemPrompt"
      <*> fields .:? "provider"
      <*> fields .:? "model"
      <*> fields .:? "reasoningEffort"
      <*> fields .:? "fs"
      <*> fields .:? "shell"
      <*> fields .:? "memory"
      <*> fields .:? "contextReserveTokens"
      <*> fields .:? "contextKeepUnits"
      <*> fields .:? "contextSummaryTokens"
   where
    parseCwd fields =
      fields .:? "cwdMode" >>= maybe (legacy fields) (explicit fields)
    legacy fields =
      case KeyMap.lookup "cwd" fields of
        Nothing -> pure CwdInherit
        Just Null -> pure CwdNone
        Just value -> CwdPath <$> parseJSON value
    explicit _ "inherit" = pure CwdInherit
    explicit _ "none" = pure CwdNone
    explicit fields "path" = CwdPath <$> fields .: "cwd"
    explicit _ mode = fail ("unknown cwdMode: " <> Text.unpack mode)

data ThreadConfigStore = ThreadConfigStore
  { threadConfigRead :: Text -> IO ThreadConfig,
    threadConfigWrite :: Text -> ThreadConfig -> IO (),
    threadConfigDelete :: Text -> IO ()
  }

newThreadConfigStore :: FilePath -> IO ThreadConfigStore
newThreadConfigStore dir =
  createDirectoryIfMissing True (configsPath dir)
    *> newMVar ()
    <&> \lock -> ThreadConfigStore (load dir) (save lock) (delete lock)
 where
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
    <&> \configs ->
      ThreadConfigStore
        (\threadId -> Map.findWithDefault emptyThreadConfig threadId <$> readIORef configs)
        (\threadId config -> modifyIORef' configs (Map.insert threadId config))
        (\threadId -> modifyIORef' configs (Map.delete threadId))

resolveRuntime :: Manager -> OpenAIConfig -> Maybe ArtifactStore -> Runtime -> ThreadConfig -> ProviderRegistry -> Map.Map String Text -> IO Runtime
resolveRuntime manager provider artifacts base config registry keyMap =
  liftA3 (,,) workToolSet ledgerPair envDiffBytes <&> \(tools, pair, diffBytes) ->
    registerSubAgent
      base
        { runtimeModel = maybe (fallbackModel base) (openAIModel manager) chosenConfig,
          runtimeTools = artifactTools <> gated (maybe tools (wrapFs diffBytes tools) pair),
          runtimeSystemPrompt = fromMaybe (runtimeSystemPrompt base) (configSystemPrompt config),
          runtimeHooks = bool defaultHooks (runtimeHooks base) (configMemory config /= Just False),
          runtimeContext = applyContext <$> runtimeContext base
        }
 where
  chosenConfig =
    configProvider config >>= \name ->
      Map.lookup name registry >>= \entry ->
        Map.lookup (Text.unpack name) keyMap <&> \key ->
          applyEffort (providerConfig entry key (configModel config <|> Just (providerDefaultModel entry)))
  fallbackModel source
    | isNothing (configModel config) && isNothing (configReasoningEffort config) = runtimeModel source
    | otherwise = openAIModel manager (applyEffort provider) {openAIModelName = fromMaybe (openAIModelName provider) (configModel config)}
  applyEffort cfg = maybe cfg (\effort -> cfg {openAIThinking = ThinkingEnabled effort}) (configReasoningEffort config)
  artifactTools = maybe Map.empty (Map.singleton artifactReadToolName . artifactReadTool) artifacts
  workToolSet = maybe (pure Map.empty) (fmap byName . withBackground) (cwdPath (configCwd config))
  withBackground cwd = (<> backgroundTools (runtimeBackground base) cwd) <$> workTools artifacts cwd
  byName = Map.fromList . fmap (\tool -> (toolName (backendToolSpec tool), tool))
  gated = fsGate . shellGate
  fsGate = bool (Map.filterWithKey (\name _ -> not ("fs_" `Text.isPrefixOf` name))) id (configFs config /= Just False)
  shellGate = bool (Map.filterWithKey (\name _ -> not ("shell" `Text.isPrefixOf` name))) id (configShell config /= Just False)
  applyContext context =
    context
      { contextReserveTokens = fromMaybe (contextReserveTokens context) (configContextReserveTokens config),
        contextKeepUnits = fromMaybe (contextKeepUnits context) (configContextKeepUnits config),
        contextSummaryTokens = fromMaybe (contextSummaryTokens context) (configContextSummaryTokens config)
      }
  ledgerPair =
    maybe
      (pure Nothing)
      (\telemetry -> readIORef (telemetryLedger telemetry) <&> fmap ((,) telemetry))
      (runtimeTelemetry base)
  wrapFs diffBytes tools (telemetry, ledger) =
    Map.adjust (fsInterceptor telemetry ledger diffBytes rootDir runKind) "fs_write"
      . Map.adjust (fsInterceptor telemetry ledger diffBytes rootDir runKind) "fs_edit"
      $ tools
  rootDir = fromMaybe "" (cwdPath (configCwd config))
  runKind = identityKind (runtimeIdentity base)
  envDiffBytes = fromMaybe 8192 . (>>= readMaybe) <$> lookupEnv "YUKI_TELEMETRY_DIFF_BYTES"

fsInterceptor :: Telemetry -> Ledger -> Int -> FilePath -> RunKind -> BackendTool -> BackendTool
fsInterceptor telemetry ledger diffBytes root kind tool =
  tool {runBackendTool = \context arguments -> intercept tool context arguments}
 where
  intercept original context arguments =
    case parseMaybe (withObject "fs-write" (.: "path")) arguments of
      Nothing -> runBackendTool original context arguments
      Just path ->
        let target = root </> path
         in boundedRead target >>= \old ->
              runBackendTool original context arguments >>= \outcome ->
                bool (record original context target path old $> outcome) (pure outcome) (toolOutcomeError outcome)
  record original context target path old =
    boundedRead target >>= \new ->
      quietly
        ( recordFsChange ledger telemetry (change original context path old new)
            *> recordDelivery ledger telemetry (delivery context path new)
        )
  change original context path old new =
    FsChangeRecord
      { fsChangeId = "",
        fsChangeRunId = toolContextRunId context,
        fsChangeThreadId = toolContextThreadId context,
        fsChangeIncarnation = toolContextIncarnation context,
        fsChangePath = Text.pack path,
        fsChangeOp = opOf old new,
        fsChangeOrigin = OriginTool (toolName (backendToolSpec original)) (toolContextCallId context),
        fsChangeDiff = diffOf path old new,
        fsChangeStat = Nothing,
        fsChangeAt = 0
      }
  delivery context path new =
    DeliveryRecord
      { deliveryId = "",
        deliveryRunId = toolContextRunId context,
        deliveryThreadId = toolContextThreadId context,
        deliveryIncarnation = toolContextIncarnation context,
        deliveryRunKind = kind,
        deliveryKind = DeliveryFileWrite,
        deliveryTitle = Text.pack path,
        deliveryRef = Text.pack path,
        deliveryBytes = fmap Text.length new,
        deliveryAt = 0
      }
  opOf old new = case (old, new) of
    (Nothing, Just _) -> FsCreated
    (Just _, Nothing) -> FsDeleted
    _ -> FsModified
  diffOf path old new
    | Text.null diff = Nothing
    | otherwise = Just (Text.take diffBytes diff)
   where
    diff = unified path (fromMaybe "" old) (fromMaybe "" new)
  boundedRead path =
    try @IOException (LazyTextIO.readFile path >>= evaluate . LazyText.toStrict . LazyText.take 200000) >>= \case
      Left _ -> pure Nothing
      Right content -> pure (Just content)

globalThreadConfig :: Settings -> ThreadConfig
globalThreadConfig settings =
  ThreadConfig
    { configCwd = maybe CwdNone CwdPath (settingsWorkDir settings),
      configIncarnationId = Just "yuki",
      configSystemPrompt = bool (Just prompt) Nothing (Text.null prompt),
      configProvider = Nothing,
      configModel = Nothing,
      configReasoningEffort = Nothing,
      configFs = Nothing,
      configShell = Nothing,
      configMemory = Just True,
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
            "journalDir" .= settingsJournalDir settings,
            "artifactDir" .= settingsArtifactDir settings,
            "transcriptDir" .= settingsTranscriptDir settings,
            "memoryDir" .= settingsMemoryDir settings,
            "memoryModel" .= settingsMemoryModel settings,
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
