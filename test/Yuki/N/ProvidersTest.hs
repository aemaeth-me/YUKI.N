-- | provider 注册表与解析测试
--
-- 覆盖：内置默认 provider、密钥解析、dialect 思考默认、resolveRuntime 覆盖、列表形状与 /providers 端点。
-- 边界：列表形状断言不发起外部网络请求（有专门用例锁定）。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
--   - 2026-08-01: 补充 provider 文件加载（loadProviders/loadAuthJson）的回归覆盖。
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
    authJsonCorruptFallsBack
  )
where
import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Monad ()
import Data.Aeson
import Data.Bool ()
import Data.ByteString ()
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Foldable ()
import Data.Functor ()
import Data.IORef
import Data.List ()
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Internal ()
import Network.Wai.Test
import System.Exit ()
import System.FilePath ()
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.IO.Unsafe (unsafePerformIO)
import System.Process ()
import System.Timeout ()
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Providers
import Yuki.N.Provider.OpenAI
import Yuki.N.ThreadConfig
import Yuki.N.Server
import Yuki.N.AGUI.Types ()
import Yuki.N.Agent
import Yuki.N.Model
import Yuki.N.TestSupport
import System.Directory (createDirectoryIfMissing)
import Network.Wai (Application, responseLBS)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Aeson.Types (parseMaybe)
import Control.Exception (finally)


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
-- | 规格：无配置文件时 loadProviders 返回内置 deepseek/zai/kimi-coding 默认项及其元数据。
-- 背景：首次启动的用户依赖内置 provider 即可运行；默认项缺失会让零配置体验失效。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
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
-- | 规格：resolveApiKey 优先环境变量、其次 piAuth 映射，缺省为 Nothing。
-- 背景：密钥解析顺序决定凭据优先级；顺序颠倒会错误地泄露或覆盖密钥。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
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
-- | 规格：providerConfig 按 dialect 应用默认思考策略（DeepSeek High、kimi Max 等）。
-- 背景：方言默认思考策略是出厂契约；丢失会让同一配置在不同 provider 上行为漂移。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
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
-- | 规格：resolveRuntime 在 configProvider 匹配时切换到 provider 条目，并让 configModel 覆盖模型名。
-- 背景：按线程选择 provider 是会话路由的核心；切换失败会把请求发往错误供应商。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
providerOverride :: Assertion
providerOverride =
  newTlsManager >>= \manager ->
    testRuntime okModel [] Parallel >>= \base ->
      let registry = defaultProviders
          keyMap = Map.singleton "zai" "test-key-zai"
          session = emptyThreadConfig {configProvider = Just "zai"}
          resolved = resolveRuntime manager testProvider Nothing base session registry keyMap
          override = resolveRuntime manager testProvider Nothing base emptyThreadConfig {configModel = Just "override"} registry keyMap
       in (,) <$> resolved <*> override >>= \cfgAndOverride ->
            let cfg = runtimeModel (fst cfgAndOverride)
             in sequence_
                  [ modelProvider cfg @?= "zai",
                    modelName cfg @?= "glm-5.2",
                    modelName (runtimeModel (snd cfgAndOverride)) @?= "override"
                  ]
-- | 规格：listEntry 输出静态 provider 条目形状（名称、baseUrl、dialect、默认模型、keyReady、模型列表）。
-- 背景：前端 provider 页依赖该 JSON 契约；形状变化会造成前端解析失败。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
listEntryShape :: Assertion
listEntryShape =
  newTlsManager >>= \manager ->
    let entry = fromMaybe (error "missing") (Map.lookup "deepseek" defaultProviders)
        keyMap = Map.empty
     in listEntry manager keyMap ("deepseek", entry) >>= \value ->
          sequence_
            [ parseMaybe (withObject "provider" (.: "name")) value @?= Just ("deepseek" :: Text),
              parseMaybe (withObject "provider" (.: "baseUrl")) value @?= Just ("https://api.deepseek.com" :: Text),
              parseMaybe (withObject "provider" (.: "dialect")) value @?= Just ("deepseek" :: Text),
              parseMaybe (withObject "provider" (.: "defaultModel")) value @?= Just ("deepseek-v4-flash" :: Text),
              parseMaybe (withObject "provider" (.: "keyReady")) value @?= Just False,
              parseMaybe (withObject "provider" (.: "models")) value @?= Just (["deepseek-v4-flash"] :: [Text])
            ]
-- | 规格：列出 provider 时绝不请求外部模型端点。
-- 背景：列表页会在用户未配置密钥时渲染；若列表触发网络探测，未配置的供应商会造成卡顿与隐私泄露。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
listingDoesNotProbe :: Assertion
listingDoesNotProbe =
  newIORef (0 :: Int) >>= \requests ->
    testWithApplication (pure (modelEndpoint requests)) $ \port ->
      newTlsManager >>= \manager ->
        let baseUrl = "http://127.0.0.1:" <> Text.pack (show port)
            entry = ProviderEntry "local" baseUrl OpenAICompatible "configured-model" Nothing Nothing 4096
         in listEntry manager (Map.singleton "local" "key") ("local", entry)
              *> readIORef requests
              >>= (@?= 0)
modelEndpoint :: IORef Int -> Application
modelEndpoint requests _ respond =
  modifyIORef' requests (+ 1)
    *> respond
      (responseLBS status200 [(hContentType, "application/json")] "{\"data\":[{\"id\":\"remote-model\"}]}")
-- | 规格：provider 密钥缺失时 resolveRuntime 回退到测试/默认 provider 而非崩溃。
-- 背景：用户可能只配置了部分密钥；缺失项必须可降级，否则整个运行时无法启动。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
missingKeyFallback :: Assertion
missingKeyFallback =
  newTlsManager >>= \manager ->
    testRuntime okModel [] Parallel >>= \base ->
      let registry = defaultProviders
          session = emptyThreadConfig {configProvider = Just "deepseek"}
       in resolveRuntime manager testProvider Nothing base session registry Map.empty >>= \resolved ->
            modelProvider (runtimeModel resolved) @?= "fake"
-- | 规格：GET /providers 返回静态 provider 列表，含 keyReady 与模型名。
-- 背景：该端点是前端 provider 管理界面的数据源；返回错误会让界面空白或误导。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
providersEndpoint :: Assertion
providersEndpoint =
  newMemoryThreadConfigStore >>= \store ->
    testRuntime okModel [] Parallel >>= \base ->
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
          app = application Nothing Nothing (Just view) Nothing (const (pure base))
       in runSession (request (httpGet ["providers"])) app >>= \response ->
            let decoded = eitherDecode (simpleBody response) :: Either String [Value]
             in case decoded of
                  Left err -> assertFailure ("providers decode: " <> err)
                  Right providers ->
                    let names = mapMaybe (parseMaybe (withObject "provider" (.: "name"))) providers
                        first = listToMaybe providers
                     in sequence_
                          [ simpleStatus response @?= status200,
                            length providers @?= 1,
                            names @?= ["deepseek" :: Text],
                            (first >>= parseMaybe (withObject "provider" (.: "keyReady"))) @?= Just True
                          ]

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
-- | 规格：YUKI_PROVIDERS_FILE 指向的有效 JSON 完全取代内置注册表。
-- 背景：自托管用户用该文件定制供应商；解析路径错误会让自定义配置静默失效。
-- 变更记录：- 2026-08-01: 补充 loadProviders 文件覆盖路径的回归覆盖。
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
-- | 规格：YUKI_PROVIDERS_FILE 内容非法时回退内置注册表而非崩溃。
-- 背景：配置文件被截断/手改坏时启动不能失败；静默回退是降级契约。
-- 变更记录：- 2026-08-01: 补充 loadProviders 非法文件回退的回归覆盖。
providersFileInvalidFallsBack :: Assertion
providersFileInvalidFallsBack =
  withWorkDir $ \dir -> do
    LazyByteString.writeFile (dir ++ "/providers.json") "{not-json"
    loaded <- loadProviders (Map.singleton "YUKI_PROVIDERS_FILE" (dir ++ "/providers.json"))
    Map.size loaded @?= 3
-- | 规格：YUKI_PROVIDERS_FILE 指向不存在的路径时回退内置注册表。
-- 背景：环境变量残留/拼写错误不应让启动失败；降级必须可预期。
-- 变更记录：- 2026-08-01: 补充 loadProviders 缺失文件回退的回归覆盖。
providersFileMissingFallsBack :: Assertion
providersFileMissingFallsBack =
  withWorkDir $ \dir -> do
    loaded <- loadProviders (Map.singleton "YUKI_PROVIDERS_FILE" (dir ++ "/nonexistent.json"))
    Map.size loaded @?= 3
-- | 规格：未设置 YUKI_PROVIDERS_FILE 时读取 $HOME/.yuki-n/providers.json。
-- 背景：home 默认路径是零配置部署的载体；读取失败会让自定义供应商丢失。
-- 变更记录：- 2026-08-01: 补充 loadProviders home 路径的回归覆盖。
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
-- | 规格：loadAuthJson 读取 $HOME/.pi/agent/auth.json 并返回其 JSON 值。
-- 背景：piAuth 是密钥回退源；路径或解析错误会让回退密钥整体失效。
-- 变更记录：- 2026-08-01: 补充 loadAuthJson 文件读取的回归覆盖。
authJsonReadsHome :: Assertion
authJsonReadsHome =
  withWorkDir $ \dir -> do
    createDirectoryIfMissing True (dir ++ "/.pi/agent")
    LazyByteString.writeFile (dir ++ "/.pi/agent/auth.json") "{\"zai\":{\"key\":\"pi-secret\"}}"
    withHome dir loadAuthJson >>= \auth ->
      auth @?= Just (object ["zai" .= object ["key" .= ("pi-secret" :: Text)]])
-- | 规格：$HOME/.pi/agent/auth.json 不存在时 loadAuthJson 返回 Nothing。
-- 背景：未配置 pi 的用户必须走环境变量路径；误报存在会掩盖密钥缺失。
-- 变更记录：- 2026-08-01: 补充 loadAuthJson 缺失回退的回归覆盖。
authJsonMissingFallsBack :: Assertion
authJsonMissingFallsBack =
  withWorkDir $ \dir -> do
    withHome dir loadAuthJson >>= (@?= Nothing)
-- | 规格：auth.json 内容非法时 loadAuthJson 返回 Nothing 而非抛出。
-- 背景：损坏的凭据文件不能击穿启动流程；必须可降级到其他密钥源。
-- 变更记录：- 2026-08-01: 补充 loadAuthJson 损坏回退的回归覆盖。
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

homeLock :: MVar ()
homeLock = unsafePerformIO (newMVar ())
