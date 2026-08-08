module Yuki.N.ThreadConfig
  ( CwdSetting (..),
    ThreadConfig (..),
    cwdPath,
    loadThreadConfig,
    resolveRuntime,
  )
where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Data.Aeson (FromJSON (..), decodeFileStrict, withObject, (.:), (.:?))
import Data.Bool (bool)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client (Manager)
import Yuki.N.AGUI.Types (toolName)
import Yuki.N.Agent
import Yuki.N.Artifact (ArtifactStore, artifactReadToolName)
import Yuki.N.Context (ContextConfig (..))
import Yuki.N.Domain.Thread (sanitizeThreadId)
import Yuki.N.Provider.OpenAI
import Yuki.N.Providers (ProviderRegistry, providerConfig)
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
    configSystemPrompt :: Maybe Text,
    configProvider :: Maybe Text,
    configModel :: Maybe Text,
    configReasoningEffort :: Maybe ReasoningEffort,
    configFs :: Maybe Bool,
    configShell :: Maybe Bool,
    configContextReserveTokens :: Maybe Int,
    configContextKeepUnits :: Maybe Int,
    configContextSummaryTokens :: Maybe Int
  }
  deriving stock (Eq, Show)

instance Semigroup ThreadConfig where
  session <> fallback =
    ThreadConfig
      cwd
      (pick configSystemPrompt)
      (pick configProvider)
      (pick configModel)
      (pick configReasoningEffort)
      (pick configFs)
      (pick configShell)
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
  mempty = ThreadConfig CwdInherit Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

instance FromJSON ThreadConfig where
  parseJSON = withObject "ThreadConfig" $ \fields ->
    ThreadConfig
      <$> parseCwd fields
      <*> fields .:? "systemPrompt"
      <*> fields .:? "provider"
      <*> fields .:? "model"
      <*> fields .:? "reasoningEffort"
      <*> fields .:? "fs"
      <*> fields .:? "shell"
      <*> fields .:? "contextReserveTokens"
      <*> fields .:? "contextKeepUnits"
      <*> fields .:? "contextSummaryTokens"
   where
    parseCwd fields = fields .:? "cwdMode" >>= maybe (pure CwdInherit) (explicit fields)
    explicit _ "inherit" = pure CwdInherit
    explicit _ "none" = pure CwdNone
    explicit fields "path" = CwdPath <$> fields .: "cwd"
    explicit _ mode = fail ("unknown cwdMode: " <> Text.unpack mode)

loadThreadConfig :: FilePath -> Text -> IO ThreadConfig
loadThreadConfig dir threadId =
  either (const mempty) (fromMaybe mempty)
    <$> (try (decodeFileStrict (configPath dir threadId)) :: IO (Either IOException (Maybe ThreadConfig)))

configPath :: FilePath -> Text -> FilePath
configPath dir threadId = dir ++ "/threads-config/" ++ Text.unpack (sanitizeThreadId threadId) ++ ".json"

resolveRuntime :: Manager -> OpenAIConfig -> Maybe ArtifactStore -> Runtime -> ThreadConfig -> ProviderRegistry -> Map.Map String Text -> IO Runtime
resolveRuntime manager provider artifacts base config registry keyMap =
  fmap build workToolSet
 where
  build tools =
    base
      { runtimeModel = maybe (fallbackModel base) (openAIModel manager) chosenConfig,
        runtimeTools = artifactTools <> gated tools,
        runtimeSystemPrompt = fromMaybe (runtimeSystemPrompt base) (configSystemPrompt config),
        runtimeContext = applyContext (runtimeContext base)
      }
  chosenConfig = configProvider config >>= pick
  pick name =
    liftA2 resolve (Map.lookup name registry) (Map.lookup (Text.unpack name) keyMap)
  resolve entry key =
    applyEffort (providerConfig entry key (configModel config))
  fallbackModel source
    | isJust (configProvider config) = runtimeModel source
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
