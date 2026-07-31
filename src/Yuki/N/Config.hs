module Yuki.N.Config
  ( Settings (..),
    loadSettings,
    resolveSettings,
  )
where

import Control.Applicative ((<|>))
import Control.Monad ((>=>))
import Data.Bool (bool)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Environment (getEnvironment)
import Text.Read (readMaybe)
import Yuki.N.Agent (ToolExecution (..))
import Yuki.N.Provider.OpenAI

data Settings = Settings
  { settingsHost :: String,
    settingsPort :: Int,
    settingsDataDir :: FilePath,
    settingsCorsOrigin :: Maybe Text,
    settingsMaxTurns :: Int,
    settingsToolExecution :: ToolExecution,
    settingsSystemPrompt :: Text,
    settingsJournalDir :: Maybe String,
    settingsArtifactDir :: Maybe String,
    settingsTranscriptDir :: Maybe String,
    settingsWorkDir :: Maybe String,
    settingsMemoryDir :: Maybe String,
    settingsMemoryModel :: Maybe Text,
    settingsSubAgentDepth :: Int,
    settingsProviderRetries :: Int,
    settingsSpliceChars :: Int,
    settingsSpliceKeep :: Int,
    settingsContextReserveTokens :: Int,
    settingsContextKeepUnits :: Int,
    settingsContextSummaryTokens :: Int,
    settingsProvider :: OpenAIConfig,
    settingsFallbackProviders :: [Text]
  }

loadSettings :: IO (Either Text Settings)
loadSettings = resolveSettings . Map.fromList <$> getEnvironment

resolveSettings :: Map String String -> Either Text Settings
resolveSettings environment =
  make
    <$> providerSettings environment
    <*> positiveBounded "YUKI_PORT" 65535 (value "YUKI_PORT" `orElse` "18080")
    <*> positive "YUKI_MAX_TURNS" (value "YUKI_MAX_TURNS" `orElse` "32")
    <*> parseExecution (value "YUKI_TOOL_EXECUTION" `orElse` "parallel")
    <*> nonNegative "YUKI_SUBAGENT_DEPTH" (value "YUKI_SUBAGENT_DEPTH" `orElse` "1")
    <*> nonNegative "YUKI_PROVIDER_RETRIES" (value "YUKI_PROVIDER_RETRIES" `orElse` "3")
    <*> positive "YUKI_SPLICE_CHARS" (value "YUKI_SPLICE_CHARS" `orElse` "200000")
    <*> nonNegative "YUKI_SPLICE_KEEP" (value "YUKI_SPLICE_KEEP" `orElse` "4")
    <*> positive "YUKI_CONTEXT_RESERVE_TOKENS" (value "YUKI_CONTEXT_RESERVE_TOKENS" `orElse` "16384")
    <*> positive "YUKI_CONTEXT_KEEP_UNITS" (value "YUKI_CONTEXT_KEEP_UNITS" `orElse` "12")
    <*> atLeast "YUKI_CONTEXT_SUMMARY_TOKENS" 96 (value "YUKI_CONTEXT_SUMMARY_TOKENS" `orElse` "2048")
    <*> parseFallbacks (Text.pack <$> Map.lookup "YUKI_FALLBACK_PROVIDERS" environment)
  where
    value key = Map.lookup key environment
    make provider port maxTurns execution subAgentDepth providerRetries spliceChars spliceKeep reserveTokens keepUnits summaryTokens fallbacks =
      Settings
        { settingsHost = value "YUKI_HOST" `orElse` "127.0.0.1",
          settingsPort = port,
          settingsDataDir = value "YUKI_DATA_DIR" `orElse` maybe ".yuki-n" (++ "/.yuki-n") (value "HOME"),
          settingsCorsOrigin = Text.pack <$> Map.lookup "YUKI_CORS_ORIGIN" environment,
          settingsMaxTurns = maxTurns,
          settingsToolExecution = execution,
          settingsSystemPrompt = Text.pack (value "YUKI_SYSTEM_PROMPT" `orElse` ""),
          settingsJournalDir = value "YUKI_JOURNAL_DIR",
          settingsArtifactDir = value "YUKI_ARTIFACT_DIR",
          settingsTranscriptDir = value "YUKI_TRANSCRIPT_DIR",
          settingsWorkDir = value "YUKI_WORK_DIR",
          settingsMemoryDir = value "YUKI_MEMORY_DIR",
          settingsMemoryModel = Text.pack <$> value "YUKI_MEMORY_MODEL",
          settingsSubAgentDepth = subAgentDepth,
          settingsProviderRetries = providerRetries,
          settingsSpliceChars = spliceChars,
          settingsSpliceKeep = spliceKeep,
          settingsContextReserveTokens = reserveTokens,
          settingsContextKeepUnits = keepUnits,
          settingsContextSummaryTokens = summaryTokens,
          settingsProvider = provider,
          settingsFallbackProviders = fallbacks
        }

providerSettings :: Map String String -> Either Text OpenAIConfig
providerSettings environment =
  make
    <$> requiredText "YUKI_MODEL" (text "YUKI_MODEL" <|> presetModel preset)
    <*> requiredText "YUKI_BASE_URL" (text "YUKI_BASE_URL" <|> presetBaseUrl preset)
    <*> requiredText "YUKI_API_KEY" (text "YUKI_API_KEY" <|> (presetKeyVariable preset >>= text))
    <*> dialectSettings
    <*> traverse (positive "YUKI_MAX_TOKENS" . Text.unpack) (text "YUKI_MAX_TOKENS")
    <*> (Just <$> positive "YUKI_CONTEXT_TOKENS" (value "YUKI_CONTEXT_TOKENS" `orElse` "1000000"))
  where
    provider = text "YUKI_PROVIDER" `orElse` "deepseek"
    preset = providerPreset provider
    value key = Map.lookup key environment
    text key = Text.pack <$> Map.lookup key environment
    dialectSettings =
      maybe (Right (presetDialect preset)) parseDialect (text "YUKI_API_DIALECT")
        >>= \dialect ->
          (,) dialect <$> parseThinking dialect (text "YUKI_THINKING") (text "YUKI_REASONING_EFFORT") preset
    make model baseUrl apiKey (dialect, thinking) maxTokens contextTokens =
      OpenAIConfig
        { openAIProvider = provider,
          openAIModelName = model,
          openAIBaseUrl = baseUrl,
          openAIApiKey = apiKey,
          openAIDialect = dialect,
          openAIThinking = thinking,
          openAIMaxTokens = maxTokens,
          openAIContextTokens = contextTokens
        }

data ProviderPreset = ProviderPreset
  { presetModel :: Maybe Text,
    presetBaseUrl :: Maybe Text,
    presetKeyVariable :: Maybe String,
    presetDialect :: ApiDialect,
    presetThinking :: ThinkingMode
  }

providerPreset :: Text -> ProviderPreset
providerPreset = \case
  "deepseek" ->
    ProviderPreset
      { presetModel = Just "deepseek-v4-flash",
        presetBaseUrl = Just "https://api.deepseek.com",
        presetKeyVariable = Just "DEEPSEEK_API_KEY",
        presetDialect = DeepSeek,
        presetThinking = ThinkingEnabled High
      }
  "openai" ->
    ProviderPreset
      { presetModel = Nothing,
        presetBaseUrl = Just "https://api.openai.com/v1",
        presetKeyVariable = Just "OPENAI_API_KEY",
        presetDialect = OpenAICompatible,
        presetThinking = ThinkingDisabled
      }
  "openrouter" ->
    ProviderPreset
      { presetModel = Nothing,
        presetBaseUrl = Just "https://openrouter.ai/api/v1",
        presetKeyVariable = Just "OPENROUTER_API_KEY",
        presetDialect = OpenAICompatible,
        presetThinking = ThinkingDisabled
      }
  _ ->
    ProviderPreset
      { presetModel = Nothing,
        presetBaseUrl = Nothing,
        presetKeyVariable = Nothing,
        presetDialect = OpenAICompatible,
        presetThinking = ThinkingDisabled
      }

parseThinking ::
  ApiDialect ->
  Maybe Text ->
  Maybe Text ->
  ProviderPreset ->
  Either Text ThinkingMode
parseThinking dialect enabled effort preset =
  thinkingMode enabled effort (presetThinking preset) >>= compatible dialect

thinkingMode :: Maybe Text -> Maybe Text -> ThinkingMode -> Either Text ThinkingMode
thinkingMode Nothing _ ThinkingDisabled = Right ThinkingDisabled
thinkingMode Nothing effort (ThinkingEnabled fallback) =
  ThinkingEnabled <$> maybe (Right fallback) parseEffort effort
thinkingMode (Just "enabled") effort _ = ThinkingEnabled <$> maybe (Right High) parseEffort effort
thinkingMode (Just "disabled") _ _ = Right ThinkingDisabled
thinkingMode (Just other) _ _ = Left ("YUKI_THINKING must be enabled or disabled, got " <> other)

compatible :: ApiDialect -> ThinkingMode -> Either Text ThinkingMode
compatible OpenAICompatible (ThinkingEnabled _) =
  Left "YUKI_THINKING=enabled requires YUKI_API_DIALECT=deepseek"
compatible _ mode = Right mode

parseEffort :: Text -> Either Text ReasoningEffort
parseEffort = \case
  "high" -> Right High
  "max" -> Right Max
  other -> Left ("YUKI_REASONING_EFFORT must be high or max, got " <> other)

parseDialect :: Text -> Either Text ApiDialect
parseDialect = \case
  "deepseek" -> Right DeepSeek
  "openai-compatible" -> Right OpenAICompatible
  other -> Left ("YUKI_API_DIALECT must be deepseek or openai-compatible, got " <> other)

parseFallbacks :: Maybe Text -> Either Text [Text]
parseFallbacks = maybe (Right []) names
  where
    names raw
      | Text.null (Text.strip raw) = Right []
      | otherwise = traverse nonEmpty (Text.splitOn "," raw)
    nonEmpty name
      | Text.null stripped = Left "YUKI_FALLBACK_PROVIDERS entries must be non-empty provider names"
      | otherwise = Right stripped
      where
        stripped = Text.strip name

parseExecution :: String -> Either Text ToolExecution
parseExecution = \case
  "parallel" -> Right Parallel
  "sequential" -> Right Sequential
  other -> Left ("YUKI_TOOL_EXECUTION must be parallel or sequential, got " <> Text.pack other)

required :: Text -> Maybe value -> Either Text value
required name = maybe (Left ("missing " <> name)) Right

requiredText :: Text -> Maybe Text -> Either Text Text
requiredText name =
  required name >=> \value ->
    bool (Right value) (Left (name <> " must not be empty")) (Text.null value)

nonNegative :: Text -> String -> Either Text Int
nonNegative name raw =
  maybe (Left ("invalid " <> name <> ": " <> Text.pack raw)) Right (readMaybe raw)
    >>= nonNegativeValue name

nonNegativeValue :: Text -> Int -> Either Text Int
nonNegativeValue name number
  | number >= 0 = Right number
  | otherwise = Left (name <> " must be non-negative")

positive :: Text -> String -> Either Text Int
positive name raw =
  maybe (Left ("invalid " <> name <> ": " <> Text.pack raw)) Right (readMaybe raw)
    >>= positiveValue name

positiveValue :: Text -> Int -> Either Text Int
positiveValue name number
  | number > 0 = Right number
  | otherwise = Left (name <> " must be positive")

positiveBounded :: Text -> Int -> String -> Either Text Int
positiveBounded name upper = positive name >=> bounded name upper

atLeast :: Text -> Int -> String -> Either Text Int
atLeast name lower =
  positive name >=> \number ->
    bool
      (Left (name <> " must be at least " <> Text.pack (show lower)))
      (Right number)
      (number >= lower)

bounded :: Text -> Int -> Int -> Either Text Int
bounded name upper number
  | number <= upper = Right number
  | otherwise = Left (name <> " must be at most " <> Text.pack (show upper))

orElse :: Maybe value -> value -> value
orElse = flip fromMaybe
