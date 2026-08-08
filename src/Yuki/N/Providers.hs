module Yuki.N.Providers
  ( ProviderEntry (..),
    ProviderRegistry,
    loadAuthJson,
    loadProviders,
    providerConfig,
    providerKeyMap,
  )
where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Control.Monad ((>=>))
import Data.Aeson (FromJSON (..), Value, eitherDecode, withObject, (.!=), (.:), (.:?))
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Bool (bool)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (fromRight)
import Data.Functor ((<&>))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory (doesFileExist, getHomeDirectory)
import System.FilePath ((</>))
import Yuki.N.Provider.OpenAI
  ( ApiDialect (..),
    OpenAIConfig (..),
    ReasoningEffort (..),
    ThinkingMode (..),
    parseDialectText,
  )

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

instance FromJSON ProviderEntry where
  parseJSON = withObject "ProviderEntry" $ \fields ->
    ProviderEntry
      <$> fields .: "name"
      <*> fields .: "baseUrl"
      <*> (fields .: "dialect" >>= either (fail . Text.unpack) pure . parseDialectText)
      <*> fields .: "defaultModel"
      <*> fields .:? "apiKeyEnv"
      <*> fields .:? "piAuth"
      <*> fields .:? "contextTokens" .!= 1000000

defaultProviders :: ProviderRegistry
defaultProviders =
  Map.fromList
    [ ("deepseek", ProviderEntry "deepseek" "https://api.deepseek.com" DeepSeek "deepseek-v4-flash" (Just "DEEPSEEK_API_KEY") Nothing 1000000),
      ("zai", ProviderEntry "zai" "https://open.bigmodel.cn/api/paas/v4" OpenAICompatible "glm-5.2" (Just "ZAI_API_KEY") (Just "zai") 1000000),
      ("kimi-coding", ProviderEntry "kimi-coding" "https://api.kimi.com/coding/v1" OpenAICompatible "k3" (Just "KIMI_API_KEY") (Just "kimi-coding") 1048576)
    ]

loadProviders :: Map String String -> IO ProviderRegistry
loadProviders env =
  resolvePath >>= maybe (pure defaultProviders) loadFile
 where
  resolvePath =
    maybe homeFile (pure . Just) (Map.lookup "YUKI_PROVIDERS_FILE" env)
  homeFile =
    getHomeDirectory
      >>= existingProvidersFile . (</> ".yuki-n" </> "providers.json")
   where
    existingProvidersFile path = bool Nothing (Just path) <$> doesFileExist path
  loadFile path =
    try (LazyByteString.readFile path) >>= loadResult
   where
    loadResult (Left (_ :: IOException)) = pure defaultProviders
    loadResult (Right bytes) = pure (fromRight defaultProviders (eitherDecode bytes))

loadAuthJson :: IO (Maybe Value)
loadAuthJson = authPath >>= readIfExists
 where
  authPath = (</> ".pi/agent/auth.json") <$> getHomeDirectory
  readIfExists path = doesFileExist path >>= bool (pure Nothing) (readAuth path)
  readAuth path =
    try (LazyByteString.readFile path) >>= readResult
   where
    readResult (Left (_ :: IOException)) = pure Nothing
    readResult (Right bytes) = pure (either (const Nothing) Just (eitherDecode bytes))

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
      openAIContextTokens = providerContextTokens entry
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
  keep (name, entry) = resolveApiKey env auth entry <&> (Text.unpack name,)
