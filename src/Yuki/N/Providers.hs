module Yuki.N.Providers
  ( ProviderEntry (..),
    ProviderRegistry,
    defaultProviders,
    listEntry,
    loadProviders,
    loadAuthJson,
    resolveApiKey,
    providerConfig,
    providerKeyMap,
    providerListing,
  )
where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Control.Monad ((>=>))
import Data.Aeson
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Bool (bool)
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Functor ((<&>))
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Network.HTTP.Client (Manager)
import System.Directory (doesFileExist, getHomeDirectory)
import System.FilePath ((</>))
import Yuki.N.Provider.OpenAI

data ProviderEntry = ProviderEntry
  { providerName :: Text,
    providerBaseUrl :: Text,
    providerDialect :: ApiDialect,
    providerDefaultModel :: Text,
    providerApiKeyEnv :: Maybe String,
    providerPiAuth :: Maybe Text,
    providerContextTokens :: Int
  }
  deriving stock (Eq, Show)

type ProviderRegistry = Map Text ProviderEntry

instance ToJSON ProviderEntry where
  toJSON entry =
    object
      [ "name" .= providerName entry,
        "baseUrl" .= providerBaseUrl entry,
        "dialect" .= dialectToText (providerDialect entry),
        "defaultModel" .= providerDefaultModel entry,
        "apiKeyEnv" .= providerApiKeyEnv entry,
        "piAuth" .= providerPiAuth entry,
        "contextTokens" .= providerContextTokens entry
      ]

instance FromJSON ProviderEntry where
  parseJSON = withObject "ProviderEntry" $ \fields ->
    ProviderEntry
      <$> fields .: "name"
      <*> fields .: "baseUrl"
      <*> (fields .: "dialect" >>= either (fail . Text.unpack) pure . dialectFromText)
      <*> fields .: "defaultModel"
      <*> fields .:? "apiKeyEnv"
      <*> fields .:? "piAuth"
      <*> fields .:? "contextTokens" .!= 1000000

dialectToText :: ApiDialect -> Text
dialectToText DeepSeek = "deepseek"
dialectToText OpenAICompatible = "openai-compatible"

dialectFromText :: Text -> Either Text ApiDialect
dialectFromText "deepseek" = Right DeepSeek
dialectFromText "openai-compatible" = Right OpenAICompatible
dialectFromText other = Left ("unknown dialect: " <> other)

defaultProviders :: ProviderRegistry
defaultProviders =
  Map.fromList
    [ ("deepseek", ProviderEntry "deepseek" "https://api.deepseek.com" DeepSeek "deepseek-v4-pro" (Just "DEEPSEEK_API_KEY") Nothing 1000000),
      ("zai", ProviderEntry "zai" "https://open.bigmodel.cn/api/paas/v4" OpenAICompatible "glm-5.2" (Just "ZAI_API_KEY") (Just "zai") 1000000),
      ("kimi-coding", ProviderEntry "kimi-coding" "https://api.kimi.com/coding/v1" OpenAICompatible "k3" (Just "KIMI_API_KEY") (Just "kimi-coding") 1048576)
    ]

loadProviders :: Map String String -> IO ProviderRegistry
loadProviders env =
  resolvePath >>= maybe (pure defaultProviders) loadFile
  where
    resolvePath =
      maybe homeFile (pure . Just) (Map.lookup "YUKI_PROVIDERS_FILE" env)
    homeFile = do
      home <- getHomeDirectory
      let path = home </> ".yuki-n" </> "providers.json"
      bool Nothing (Just path) <$> doesFileExist path
    loadFile path =
      try (LazyByteString.readFile path) >>= \case
        Left (_ :: IOException) -> pure defaultProviders
        Right bytes -> pure (either (const defaultProviders) id (eitherDecode bytes))

loadAuthJson :: IO (Maybe Value)
loadAuthJson =
  authPath >>= \path -> doesFileExist path >>= bool (pure Nothing) (readAuth path)
  where
    authPath = (</> ".pi/agent/auth.json") <$> getHomeDirectory
    readAuth path =
      try (LazyByteString.readFile path) >>= \case
        Left (_ :: IOException) -> pure Nothing
        Right bytes -> pure (either (const Nothing) Just (eitherDecode bytes))

resolveApiKey :: Map String String -> Maybe Value -> ProviderEntry -> Maybe Text
resolveApiKey env auth entry =
  (Text.pack <$> (providerApiKeyEnv entry >>= flip Map.lookup env))
    <|> (providerPiAuth entry >>= authKey)
  where
    authKey name = auth >>= parseMaybe (withObject "auth.json" (.: fromText name) >=> withObject "auth entry" (.: "key"))

providerConfig :: ProviderEntry -> Text -> Maybe Text -> OpenAIConfig
providerConfig entry apiKey model =
  OpenAIConfig
    { openAIProvider = providerName entry,
      openAIModelName = fromMaybe (providerDefaultModel entry) model,
      openAIBaseUrl = providerBaseUrl entry,
      openAIApiKey = apiKey,
      openAIDialect = dialect,
      openAIThinking = providerThinking entry,
      openAIMaxTokens = Nothing,
      openAIContextTokens = Just (providerContextTokens entry)
    }
  where
    dialect = providerDialect entry

providerThinking :: ProviderEntry -> ThinkingMode
providerThinking entry
  | providerName entry == "kimi-coding" = ThinkingEnabled Max
  | providerName entry == "zai" = ThinkingEnabled High
  | providerDialect entry == DeepSeek = ThinkingEnabled High
  | otherwise = ThinkingDisabled

providerKeyMap :: Map String String -> Maybe Value -> ProviderRegistry -> Map String Text
providerKeyMap env auth =
  Map.fromList . mapMaybe keep . Map.toList
  where
    keep (name, entry) = resolveApiKey env auth entry <&> \key -> (Text.unpack name, key)

providerListing :: Manager -> ProviderRegistry -> Map String Text -> IO [Value]
providerListing manager registry keyMap =
  traverse (listEntry manager keyMap) (Map.toList registry)

listEntry :: Manager -> Map String Text -> (Text, ProviderEntry) -> IO Value
listEntry _ keyMap (name, entry) =
  pure
    ( object
        [ "name" .= name,
          "baseUrl" .= providerBaseUrl entry,
          "dialect" .= dialectToText (providerDialect entry),
          "defaultModel" .= providerDefaultModel entry,
          "contextTokens" .= providerContextTokens entry,
          "keyReady" .= isJust key,
          "models" .= ([providerDefaultModel entry] :: [Text])
        ]
    )
  where
    key = Map.lookup (Text.unpack name) keyMap
