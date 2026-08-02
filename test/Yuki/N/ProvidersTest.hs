{-# LANGUAGE ScopedTypeVariables #-}

module Yuki.N.ProvidersTest
  ( providersTests,
    providerFileTests,
    defaultsExist,
    keyResolution,
    dialectThinking,
    providerOverride,
    listEntryShape,
    listingDoesNotProbe,
    missingKeyFallback,
    providersEndpoint,
    providersFileOverrides,
    providersFileInvalidFallsBack,
    providersFileMissingFallsBack,
    homeProvidersFileLoaded,
    authJsonReadsHome,
    authJsonMissingFallsBack,
    authJsonCorruptFallsBack,
  )
where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (finally)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types
import Network.Wai (Application, responseLBS)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.IO.Unsafe (unsafePerformIO)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Agent
import Yuki.N.Model
import Yuki.N.Provider.OpenAI
import Yuki.N.Providers
import Yuki.N.Server
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig

providersTests :: TestTree
providersTests =
  testGroup
    "providers"
    [ testCase "loadProviders returns built-in defaults when no file" defaultsExist,
      testCase "resolveApiKey prefers env over piAuth" keyResolution,
      testCase "providerConfig applies local provider thinking defaults" dialectThinking,
      testCase "resolveRuntime uses provider entry when configProvider matches" providerOverride,
      testCase "resolveRuntime falls back when provider key is missing" missingKeyFallback,
      testCase "listEntry output shape with keyReady" listEntryShape,
      testCase "provider listing never probes the external model endpoint" listingDoesNotProbe,
      testCase "/providers endpoint returns 200 with static listing" providersEndpoint
    ]

defaultsExist :: Assertion
defaultsExist =
  let loaded = defaultProviders
   in sequence_
        [ (providerName <$> Map.lookup "deepseek" loaded) @?= Just "deepseek",
          (providerDefaultModel <$> Map.lookup "deepseek" loaded) @?= Just "deepseek-v4-flash",
          (providerDialect <$> Map.lookup "deepseek" loaded) @?= Just DeepSeek,
          (providerContextTokens <$> Map.lookup "deepseek" loaded) @?= Just 1000000,
          (providerBaseUrl <$> Map.lookup "zai" loaded) @?= Just "https://open.bigmodel.cn/api/paas/v4",
          (providerContextTokens <$> Map.lookup "zai" loaded) @?= Just 1000000,
          (providerPiAuth <$> Map.lookup "zai" loaded) @?= Just (Just "zai"),
          (providerApiKeyEnv <$> Map.lookup "kimi-coding" loaded) @?= Just (Just "KIMI_API_KEY"),
          (providerContextTokens <$> Map.lookup "kimi-coding" loaded) @?= Just 1048576,
          Map.size loaded @?= 3
        ]

keyResolution :: Assertion
keyResolution =
  let entry = ProviderEntry "test" "https://x" OpenAICompatible "m" (Just "TEST_KEY") (Just "pi-name") 65536
      envKey = Map.singleton "TEST_KEY" "env-secret"
      authValue = object ["pi-name" .= object ["key" .= ("pi-secret" :: Text)]]
   in sequence_
        [ resolveApiKey envKey Nothing entry @?= Just "env-secret",
          resolveApiKey Map.empty (Just authValue) entry @?= Just "pi-secret",
          resolveApiKey envKey (Just authValue) entry @?= Just "env-secret",
          resolveApiKey Map.empty Nothing entry @?= Nothing
        ]

dialectThinking :: Assertion
dialectThinking =
  let ds = providerConfig entry "key" (Just "m1")
      compat = providerConfig entry {providerDialect = OpenAICompatible} "key" (Just "m2")
      fallback = providerConfig entry "key" Nothing
      zai = providerConfig (fromMaybe entry (Map.lookup "zai" defaultProviders)) "key" Nothing
      kimi = providerConfig (fromMaybe entry (Map.lookup "kimi-coding" defaultProviders)) "key" Nothing
      entry = ProviderEntry "ds" "https://x" DeepSeek "m0" Nothing Nothing 65536
   in sequence_
        [ openAIThinking ds @?= ThinkingEnabled High,
          openAIDialect ds @?= DeepSeek,
          openAIModelName ds @?= "m1",
          openAIThinking compat @?= ThinkingDisabled,
          openAIDialect compat @?= OpenAICompatible,
          openAIThinking zai @?= ThinkingEnabled High,
          openAIThinking kimi @?= ThinkingEnabled Max,
          openAIModelName fallback @?= "m0"
        ]

providerOverride :: Assertion
providerOverride = do
  manager <- newTlsManager
  base <- testRuntime okModel [] Parallel
  let registry = defaultProviders
      keyMap = Map.singleton "zai" "test-key-zai"
      session = emptyThreadConfig {configProvider = Just "zai"}
      resolved = resolveRuntime manager testProvider Nothing base session registry keyMap
      override = resolveRuntime manager testProvider Nothing base emptyThreadConfig {configModel = Just "override"} registry keyMap
  resolvedRuntime <- resolved
  overrideRuntime <- override
  modelProvider (runtimeModel resolvedRuntime) @?= "zai"
  modelName (runtimeModel resolvedRuntime) @?= "glm-5.2"
  modelName (runtimeModel overrideRuntime) @?= "override"

listEntryShape :: Assertion
listEntryShape = do
  manager <- newTlsManager
  let entry = fromMaybe (error "missing") (Map.lookup "deepseek" defaultProviders)
      keyMap = Map.empty
  value <- listEntry manager keyMap ("deepseek", entry)
  parseMaybe (withObject "provider" (.: "name")) value @?= Just ("deepseek" :: Text)
  parseMaybe (withObject "provider" (.: "baseUrl")) value @?= Just ("https://api.deepseek.com" :: Text)
  parseMaybe (withObject "provider" (.: "dialect")) value @?= Just ("deepseek" :: Text)
  parseMaybe (withObject "provider" (.: "defaultModel")) value @?= Just ("deepseek-v4-flash" :: Text)
  parseMaybe (withObject "provider" (.: "keyReady")) value @?= Just False
  parseMaybe (withObject "provider" (.: "models")) value @?= Just (["deepseek-v4-flash"] :: [Text])

listingDoesNotProbe :: Assertion
listingDoesNotProbe = do
  requests <- newIORef (0 :: Int)
  testWithApplication (pure (modelEndpoint requests)) $ \port -> do
    manager <- newTlsManager
    let baseUrl = "http://127.0.0.1:" <> Text.pack (show port)
        entry = ProviderEntry "local" baseUrl OpenAICompatible "configured-model" Nothing Nothing 4096
    _ <- listEntry manager (Map.singleton "local" "key") ("local", entry)
    readIORef requests >>= (@?= 0)

modelEndpoint :: IORef Int -> Application
modelEndpoint requests _ respond =
  modifyIORef' requests (+ 1)
    *> respond
      (responseLBS status200 [(hContentType, "application/json")] "{\"data\":[{\"id\":\"remote-model\"}]}")

missingKeyFallback :: Assertion
missingKeyFallback = do
  manager <- newTlsManager
  base <- testRuntime okModel [] Parallel
  let registry = defaultProviders
      session = emptyThreadConfig {configProvider = Just "deepseek"}
  resolved <- resolveRuntime manager testProvider Nothing base session registry Map.empty
  modelProvider (runtimeModel resolved) @?= "fake"

providersEndpoint :: Assertion
providersEndpoint = do
  store <- newMemoryThreadConfigStore
  base <- testRuntime okModel [] Parallel
  let staticListing =
        pure
          [ object
              [ "name" .= ("deepseek" :: Text),
                "baseUrl" .= ("https://api.deepseek.com" :: Text),
                "dialect" .= ("deepseek" :: Text),
                "defaultModel" .= ("deepseek-v4-flash" :: Text),
                "keyReady" .= True,
                "models" .= (["deepseek-v4-flash", "deepseek-v4-pro"] :: [Text])
              ]
          ]
      view = ConfigView (renderGlobalConfig testSettings (globalThreadConfig testSettings)) store (globalThreadConfig testSettings) (pure (Right [])) staticListing
      app = application Nothing Nothing (Just view) Nothing Nothing (const (pure base))
  response <- runSession (request (httpGet ["providers"])) app
  let decoded = eitherDecode (simpleBody response) :: Either String [Value]
  case decoded of
    Left err -> assertFailure ("providers decode: " <> err)
    Right providers -> do
      let names = mapMaybe (parseMaybe (withObject "provider" (.: "name"))) providers
          first = listToMaybe providers
      simpleStatus response @?= status200
      length providers @?= 1
      names @?= ["deepseek" :: Text]
      (first >>= parseMaybe (withObject "provider" (.: "keyReady"))) @?= Just True

providerFileTests :: TestTree
providerFileTests =
  testGroup
    "provider file loading"
    [ testCase "YUKI_PROVIDERS_FILE overrides the built-in registry" providersFileOverrides,
      testCase "an invalid providers file falls back to built-ins" providersFileInvalidFallsBack,
      testCase "a missing providers file falls back to built-ins" providersFileMissingFallsBack,
      testCase "the home providers file is picked up without an env override" homeProvidersFileLoaded,
      testCase "loadAuthJson reads $HOME/.pi/agent/auth.json" authJsonReadsHome,
      testCase "loadAuthJson returns Nothing without an auth file" authJsonMissingFallsBack,
      testCase "loadAuthJson returns Nothing for a corrupt auth file" authJsonCorruptFallsBack
    ]

providersFileOverrides :: Assertion
providersFileOverrides =
  withWorkDir $ \dir -> do
    LazyByteString.writeFile (dir ++ "/providers.json") (encode (Map.singleton ("custom" :: Text) customEntry))
    loaded <- loadProviders (Map.singleton "YUKI_PROVIDERS_FILE" (dir ++ "/providers.json"))
    sequence_
      [ Map.size loaded @?= 1,
        (providerName <$> Map.lookup "custom" loaded) @?= Just "custom",
        (providerBaseUrl <$> Map.lookup "custom" loaded) @?= Just "https://custom.example",
        (providerDialect <$> Map.lookup "custom" loaded) @?= Just DeepSeek,
        (providerContextTokens <$> Map.lookup "custom" loaded) @?= Just 4096,
        Map.lookup "deepseek" loaded @?= Nothing
      ]
 where
  customEntry =
    object
      [ "name" .= ("custom" :: Text),
        "baseUrl" .= ("https://custom.example" :: Text),
        "dialect" .= ("deepseek" :: Text),
        "defaultModel" .= ("custom-model" :: Text),
        "apiKeyEnv" .= ("CUSTOM_API_KEY" :: Text),
        "contextTokens" .= (4096 :: Int)
      ]

providersFileInvalidFallsBack :: Assertion
providersFileInvalidFallsBack =
  withWorkDir $ \dir -> do
    LazyByteString.writeFile (dir ++ "/providers.json") "{not-json"
    loaded <- loadProviders (Map.singleton "YUKI_PROVIDERS_FILE" (dir ++ "/providers.json"))
    Map.size loaded @?= 3

providersFileMissingFallsBack :: Assertion
providersFileMissingFallsBack =
  withWorkDir $ \dir -> do
    loaded <- loadProviders (Map.singleton "YUKI_PROVIDERS_FILE" (dir ++ "/nonexistent.json"))
    Map.size loaded @?= 3

homeProvidersFileLoaded :: Assertion
homeProvidersFileLoaded =
  withWorkDir $ \dir -> do
    createDirectoryIfMissing True (dir ++ "/.yuki-n")
    LazyByteString.writeFile (dir ++ "/.yuki-n/providers.json") (encode (Map.singleton ("custom" :: Text) customEntry))
    withHome dir (loadProviders Map.empty) >>= \loaded ->
      sequence_
        [ Map.size loaded @?= 1,
          (providerName <$> Map.lookup "custom" loaded) @?= Just "custom"
        ]
 where
  customEntry =
    object
      [ "name" .= ("custom" :: Text),
        "baseUrl" .= ("https://custom.example" :: Text),
        "dialect" .= ("openai-compatible" :: Text),
        "defaultModel" .= ("custom-model" :: Text)
      ]

authJsonReadsHome :: Assertion
authJsonReadsHome =
  withWorkDir $ \dir -> do
    createDirectoryIfMissing True (dir ++ "/.pi/agent")
    LazyByteString.writeFile (dir ++ "/.pi/agent/auth.json") "{\"zai\":{\"key\":\"pi-secret\"}}"
    withHome dir loadAuthJson >>= \auth ->
      auth @?= Just (object ["zai" .= object ["key" .= ("pi-secret" :: Text)]])

authJsonMissingFallsBack :: Assertion
authJsonMissingFallsBack =
  withWorkDir $ \dir -> do
    withHome dir loadAuthJson >>= (@?= Nothing)

authJsonCorruptFallsBack :: Assertion
authJsonCorruptFallsBack =
  withWorkDir $ \dir -> do
    createDirectoryIfMissing True (dir ++ "/.pi/agent")
    LazyByteString.writeFile (dir ++ "/.pi/agent/auth.json") "{broken"
    withHome dir loadAuthJson >>= (@?= Nothing)

-- | 在受控 HOME 下执行动作，结束后恢复原值（含未设置的情况）。
-- HOME 是进程级全局量：tasty 默认并行跑测试，故用锁串行化所有 HOME 改写。
withHome :: FilePath -> IO value -> IO value
withHome dir action =
  withMVar homeLock $ \_ -> do
    saved <- lookupEnv "HOME"
    setEnv "HOME" dir
    action `finally` restore saved
 where
  restore Nothing = unsetEnv "HOME"
  restore (Just original) = setEnv "HOME" original

{-# NOINLINE homeLock #-}
homeLock :: MVar ()
homeLock = unsafePerformIO (newMVar ())
