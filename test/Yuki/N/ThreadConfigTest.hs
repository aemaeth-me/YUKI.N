module Yuki.N.ThreadConfigTest
  ( threadConfigTests,
    resolveFields,
    cwdStateJson,
    reasoningEffortJson,
    cwdOverridesGlobal,
    fileStoreRoundTrip,
    toolResolution,
    promptAndModel,
    reasoningEffortResolution,
    contextPolicyResolution,
    memoryStripped,
    configEndpoints,
    configCapabilities,
    configContextPolicy,
    configRejectsBadCwd,
    configRejectsBadContext,
    configRejectsBadEffort,
    configTreeSymlinks,
    configPathCompletion,
    configMasksKey,
    perThreadPrompts,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson
import Data.Aeson.Types (parseEither, parseMaybe)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types
import Network.Wai (Application, pathInfo, queryString, requestMethod)
import Network.Wai.Test
import System.Directory (createDirectoryIfMissing, doesFileExist)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Agent
import Yuki.N.Artifact
import Yuki.N.Config
import Yuki.N.Context
import Yuki.N.Model
import Yuki.N.Provider.OpenAI
import Yuki.N.Providers
import Yuki.N.Server
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig

threadConfigTests :: TestTree
threadConfigTests =
  testGroup
    "thread config"
    [ testCase "resolve merges session over global per field" resolveFields,
      testCase "cwd JSON distinguishes inherit, none and a concrete path" cwdStateJson,
      testCase "reasoning effort JSON accepts only supported values" reasoningEffortJson,
      testCase "a session can inherit, clear or replace a global cwd" cwdOverridesGlobal,
      testCase "file store round-trips under a sanitized name and reloads" fileStoreRoundTrip,
      testCase "resolveRuntime roots tools at the configured cwd and gates fs and shell" toolResolution,
      testCase "resolveRuntime overrides the prompt and rebuilds the model by name" promptAndModel,
      testCase "resolveRuntime applies per-thread reasoning effort" reasoningEffortResolution,
      testCase "resolveRuntime applies per-thread context policy" contextPolicyResolution,
      testCase "resolveRuntime strips the hooks when memory is off" memoryStripped,
      testCase "PUT then GET returns the saved config, unknown threads are all null" configEndpoints,
      testCase "capabilities endpoint reports the resolved backend tools" configCapabilities,
      testCase "context endpoint explains the exact compaction threshold" configContextPolicy,
      testCase "PUT rejects a missing cwd without saving" configRejectsBadCwd,
      testCase "PUT rejects invalid context policy values" configRejectsBadContext,
      testCase "PUT rejects an unknown reasoning effort" configRejectsBadEffort,
      testCase "config tree endpoint never descends through symlinks" configTreeSymlinks,
      testCase "path completion endpoint uses the resolved session cwd" configPathCompletion,
      testCase "GET /config masks the API key" configMasksKey,
      testCase "handleAgent resolves the system prompt per thread" perThreadPrompts
    ]

resolveFields :: Assertion
resolveFields =
  sequence_
    [ resolveThreadConfig emptyThreadConfig global @?= global,
      resolveThreadConfig session emptyThreadConfig @?= session,
      resolveThreadConfig session global
        @?= emptyThreadConfig
          { configCwd = CwdPath "/global",
            configSystemPrompt = Just "session",
            configModel = Just "global-model",
            configReasoningEffort = Just Max,
            configFs = Just False,
            configMemory = Just True
          }
    ]
 where
  session = emptyThreadConfig {configSystemPrompt = Just "session", configFs = Just False}
  global =
    emptyThreadConfig
      { configCwd = CwdPath "/global",
        configSystemPrompt = Just "global",
        configModel = Just "global-model",
        configReasoningEffort = Just Max,
        configMemory = Just True
      }

cwdStateJson :: Assertion
cwdStateJson =
  sequence_
    [ decodeConfig "{}" @?= Right CwdInherit,
      decodeConfig "{\"cwd\":null}" @?= Right CwdNone,
      decodeConfig "{\"cwd\":\"/work\"}" @?= Right (CwdPath "/work"),
      decodeConfig "{\"cwdMode\":\"inherit\",\"cwd\":null}" @?= Right CwdInherit,
      decodeConfig "{\"cwdMode\":\"none\",\"cwd\":\"/ignored\"}" @?= Right CwdNone,
      decodeConfig "{\"cwdMode\":\"path\",\"cwd\":\"/chosen\"}" @?= Right (CwdPath "/chosen"),
      eitherDecode (encode (emptyThreadConfig {configCwd = CwdNone})) @?= Right (emptyThreadConfig {configCwd = CwdNone}),
      eitherDecode (encode (emptyThreadConfig {configCwd = CwdPath "/chosen"})) @?= Right (emptyThreadConfig {configCwd = CwdPath "/chosen"})
    ]
 where
  decodeConfig bytes = configCwd <$> (eitherDecode bytes :: Either String ThreadConfig)

reasoningEffortJson :: Assertion
reasoningEffortJson =
  sequence_
    [ eitherDecode "{\"reasoningEffort\":\"low\"}" @?= Right (emptyThreadConfig {configReasoningEffort = Just Low}),
      eitherDecode (encode (emptyThreadConfig {configReasoningEffort = Just Max})) @?= Right (emptyThreadConfig {configReasoningEffort = Just Max}),
      case eitherDecode "{\"reasoningEffort\":\"medium\"}" :: Either String ThreadConfig of
        Left _ -> pure ()
        Right _ -> assertFailure "medium should be rejected"
    ]

cwdOverridesGlobal :: Assertion
cwdOverridesGlobal = withWorkDir $ \globalDir -> do
  let localDir = globalDir ++ "/local"
      global = emptyThreadConfig {configCwd = CwdPath globalDir}
      effective session = resolveThreadConfig session global
  createDirectoryIfMissing True localDir
  TextIO.writeFile (globalDir ++ "/global.txt") "global"
  TextIO.writeFile (localDir ++ "/local.txt") "local"
  manager <- newTlsManager
  base <- testRuntime okModel [] Parallel
  inherited <- resolveRuntime manager testProvider Nothing base (effective emptyThreadConfig) Map.empty Map.empty
  cleared <- resolveRuntime manager testProvider Nothing base (effective (emptyThreadConfig {configCwd = CwdNone})) Map.empty Map.empty
  replaced <- resolveRuntime manager testProvider Nothing base (effective (emptyThreadConfig {configCwd = CwdPath localDir})) Map.empty Map.empty
  globalList <- callRuntimeList inherited
  localList <- callRuntimeList replaced
  configCwd (effective emptyThreadConfig) @?= CwdPath globalDir
  configCwd (effective (emptyThreadConfig {configCwd = CwdNone})) @?= CwdNone
  Map.member "fs_list" (runtimeTools inherited) @?= True
  Map.member "fs_list" (runtimeTools cleared) @?= False
  assertBool "inherited runtime is rooted globally" ("global.txt" `Text.isInfixOf` globalList)
  assertBool "replacement runtime is rooted locally" ("local.txt" `Text.isInfixOf` localList && not ("global.txt" `Text.isInfixOf` localList))
 where
  callRuntimeList runtime =
    maybe (assertFailure "missing fs_list") pure (Map.lookup "fs_list" (runtimeTools runtime))
      >>= \backend ->
        runBackendTool backend (ToolContext "run" "thread" "call" (const (pure ())) Nothing "") (object [])
          <&> toolOutcomeContent

fileStoreRoundTrip :: Assertion
fileStoreRoundTrip = withWorkDir $ \dir -> do
  store <- newThreadConfigStore dir
  threadConfigWrite store "th/read:me" saved
  threadConfigRead store "th/read:me" >>= (@?= saved)
  doesFileExist (dir ++ "/threads-config/th-read-me.json") >>= assertBool "config file uses the sanitized name"
  reopened <- newThreadConfigStore dir
  threadConfigRead reopened "th/read:me" >>= (@?= saved)
  threadConfigRead store "absent" >>= (@?= emptyThreadConfig)
 where
  saved =
    emptyThreadConfig
      { configCwd = CwdPath "/work",
        configSystemPrompt = Just "prompt",
        configModel = Just "model-x",
        configReasoningEffort = Just Low,
        configFs = Just False,
        configShell = Just True,
        configMemory = Just False,
        configContextReserveTokens = Just 4096,
        configContextKeepUnits = Just 8,
        configContextSummaryTokens = Just 1024
      }

toolResolution :: Assertion
toolResolution = withWorkDir $ \dir -> do
  manager <- newTlsManager
  artifacts <- newMemoryArtifactStore
  base <- testRuntime okModel [] Parallel
  let resolved config = Map.keys . runtimeTools <$> resolveRuntime manager testProvider (Just artifacts) base config Map.empty Map.empty
  resolvedRuntimes <- traverse resolved (configs dir)
  resolvedRuntimes @?= expected
 where
  configs dir =
    [ emptyThreadConfig {configCwd = CwdPath dir},
      emptyThreadConfig,
      emptyThreadConfig {configCwd = CwdPath dir, configFs = Just False},
      emptyThreadConfig {configCwd = CwdPath dir, configShell = Just False}
    ]
  expected =
    [ [artifactReadToolName, "fs_edit", "fs_glob", "fs_grep", "fs_list", "fs_read", "fs_write", "plan", "shell", "shell_bg", "shell_kill", "shell_output", "shell_stdin", "sub_agent", "sub_agent_cancel", "sub_agent_list", "sub_agent_send", "sub_agent_spawn", "sub_agent_status", "sub_agent_wait"],
      [artifactReadToolName, "sub_agent", "sub_agent_cancel", "sub_agent_list", "sub_agent_send", "sub_agent_spawn", "sub_agent_status", "sub_agent_wait"],
      [artifactReadToolName, "plan", "shell", "shell_bg", "shell_kill", "shell_output", "shell_stdin", "sub_agent", "sub_agent_cancel", "sub_agent_list", "sub_agent_send", "sub_agent_spawn", "sub_agent_status", "sub_agent_wait"],
      [artifactReadToolName, "fs_edit", "fs_glob", "fs_grep", "fs_list", "fs_read", "fs_write", "plan", "sub_agent", "sub_agent_cancel", "sub_agent_list", "sub_agent_send", "sub_agent_spawn", "sub_agent_status", "sub_agent_wait"]
    ]

promptAndModel :: Assertion
promptAndModel = do
  manager <- newTlsManager
  base <- testRuntime okModel [] Parallel
  let resolved config = resolveRuntime manager testProvider Nothing base {runtimeSystemPrompt = "global prompt"} config Map.empty Map.empty
  global <- resolved emptyThreadConfig
  local <- resolved emptyThreadConfig {configSystemPrompt = Just "local"}
  override <- resolved emptyThreadConfig {configModel = Just "deepseek-v4-pro"}
  runtimeSystemPrompt global @?= "global prompt"
  runtimeSystemPrompt local @?= "local"
  modelName (runtimeModel global) @?= "fake"
  modelName (runtimeModel override) @?= "deepseek-v4-pro"

reasoningEffortResolution :: Assertion
reasoningEffortResolution = do
  manager <- newTlsManager
  base <- testRuntime okModel [] Parallel
  let selected =
        emptyThreadConfig
          { configProvider = Just "kimi-coding",
            configReasoningEffort = Just Low
          }
      inherited = emptyThreadConfig {configReasoningEffort = Just Max}
      keys = Map.singleton "kimi-coding" "key"
      effort runtime =
        parseMaybe
          ( withObject "request" $ \req ->
              (req .: "reasoning_effort")
                <|> (req .: "reasoning" >>= \reasoning -> reasoning .: "effort")
          )
          (modelRender (runtimeModel runtime) (ModelRequest [] []))
  kimi <- resolveRuntime manager testProvider Nothing base selected defaultProviders keys
  deepseek <- resolveRuntime manager (settingsProvider testSettings) Nothing base inherited Map.empty Map.empty
  modelProvider (runtimeModel kimi) @?= "kimi-coding"
  effort kimi @?= Just ("low" :: Text)
  effort deepseek @?= Just ("max" :: Text)

contextPolicyResolution :: Assertion
contextPolicyResolution = do
  manager <- newTlsManager
  base <- testRuntime okModel [] Parallel
  let initial = ContextConfig 8192 12 2048 200000
      config =
        emptyThreadConfig
          { configContextReserveTokens = Just 4096,
            configContextKeepUnits = Just 6,
            configContextSummaryTokens = Just 768
          }
  resolved <- resolveRuntime manager testProvider Nothing base {runtimeContext = Just initial} config Map.empty Map.empty
  case runtimeContext resolved of
    Nothing -> assertFailure "context policy disappeared"
    Just policy -> do
      contextReserveTokens policy @?= 4096
      contextKeepUnits policy @?= 6
      contextSummaryTokens policy @?= 768
      contextFallbackChars policy @?= 200000

memoryStripped :: Assertion
memoryStripped = do
  called <- newIORef False
  manager <- newTlsManager
  base <- testRuntime okModel [] Parallel
  let hooks config = runtimeHooks <$> resolveRuntime manager testProvider Nothing base {runtimeHooks = business} config Map.empty Map.empty
      business =
        defaultHooks
          { afterRun = \_ _ -> writeIORef called True,
            getSteeringMessages = const (pure [ChatSystem "steer"])
          }
  stripped <- hooks emptyThreadConfig {configMemory = Just False}
  kept <- hooks emptyThreadConfig
  afterRun stripped (sampleInput []) []
  stripCalled <- readIORef called
  stripCalled @?= False
  steering <- getSteeringMessages stripped (sampleInput [])
  steering @?= []
  afterRun kept (sampleInput []) []
  keptCalled <- readIORef called
  keptCalled @?= True

configApp :: IO (Application, ThreadConfigStore)
configApp = do
  store <- newMemoryThreadConfigStore
  manager <- newTlsManager
  base <- testRuntime okModel [] Parallel
  let context =
        ContextConfig
          (settingsContextReserveTokens testSettings)
          (settingsContextKeepUnits testSettings)
          (settingsContextSummaryTokens testSettings)
          (settingsSpliceChars testSettings)
  pure
    ( application Nothing Nothing (Just (testView store)) Nothing Nothing Nothing (configResolver store manager base {runtimeContext = Just context}),
      store
    )
configResolver :: ThreadConfigStore -> Manager -> Runtime -> Text -> IO Runtime
configResolver store manager base threadId =
  threadConfigRead store threadId
    >>= \session ->
      resolveRuntime manager (settingsProvider testSettings) Nothing base (resolveThreadConfig session (globalThreadConfig testSettings)) Map.empty Map.empty

configEndpoints :: Assertion
configEndpoints = do
  (app, _) <- configApp
  saved <- runSession (srequest (putConfig "t-a" (encode (emptyThreadConfig {configSystemPrompt = Just "prompt-a"})))) app
  fetched <- runSession (request (httpGet ["config", "threads", "t-a"])) app
  unknown <- runSession (request (httpGet ["config", "threads", "t-unknown"])) app
  simpleStatus saved @?= status204
  either assertFailure (@?= emptyThreadConfig {configSystemPrompt = Just "prompt-a"}) (eitherDecode (simpleBody fetched))
  either assertFailure (@?= emptyThreadConfig) (eitherDecode (simpleBody unknown))

configCapabilities :: Assertion
configCapabilities = withWorkDir $ \dir -> do
  (app, store) <- configApp
  threadConfigWrite store "capable" (emptyThreadConfig {configCwd = CwdPath dir, configShell = Just False})
  response <- runSession (request (httpGet ["config", "threads", "capable", "capabilities"])) app
  simpleStatus response @?= status200
  either
    assertFailure
    ( @?=
        [ "fs_edit",
          "fs_glob",
          "fs_grep",
          "fs_list",
          "fs_read",
          "fs_write",
          "plan",
          "sub_agent",
          "sub_agent_cancel",
          "sub_agent_list",
          "sub_agent_send",
          "sub_agent_spawn",
          "sub_agent_status",
          "sub_agent_wait"
        ]
    )
    (eitherDecode (simpleBody response) :: Either String [Text])

configContextPolicy :: Assertion
configContextPolicy = do
  (app, store) <- configApp
  threadConfigWrite
    store
    "contextual"
    ( emptyThreadConfig
        { configContextReserveTokens = Just 4096,
          configContextKeepUnits = Just 6,
          configContextSummaryTokens = Just 768
        }
    )
  response <- runSession (request (httpGet ["config", "threads", "contextual", "context"])) app
  case eitherDecode (simpleBody response) of
    Left failure -> assertFailure failure
    Right value -> verify response value
 where
  verify response value = do
    simpleStatus response @?= status200
    parseMaybe (withObject "policy" (.: "enabled")) value @?= Just True
    parseMaybe (withObject "policy" (.: "reserveTokens")) value @?= Just (4096 :: Int)
    parseMaybe (withObject "policy" (.: "keepUnits")) value @?= Just (6 :: Int)
    parseMaybe (withObject "policy" (.: "summaryTokens")) value @?= Just (768 :: Int)
    let budgetMatches =
          (\window reserve tools budget -> budget == max 256 (window - reserve - tools))
            <$> (parseMaybe (withObject "policy" (.: "windowTokens")) value :: Maybe Int)
            <*> (parseMaybe (withObject "policy" (.: "reserveTokens")) value :: Maybe Int)
            <*> (parseMaybe (withObject "policy" (.: "toolTokens")) value :: Maybe Int)
            <*> (parseMaybe (withObject "policy" (.: "budgetTokens")) value :: Maybe Int)
    budgetMatches @?= Just True

configRejectsBadCwd :: Assertion
configRejectsBadCwd = do
  (app, store) <- configApp
  rejected <- runSession (srequest (putConfig "t-b" (encode (emptyThreadConfig {configCwd = CwdPath "/no/such/yuki-dir"})))) app
  stored <- threadConfigRead store "t-b"
  simpleStatus rejected @?= status400
  stored @?= emptyThreadConfig

configRejectsBadContext :: Assertion
configRejectsBadContext = do
  (app, store) <- configApp
  traverse_
    (reject app store)
    [ ("bad-reserve", emptyThreadConfig {configContextReserveTokens = Just 0}),
      ("bad-keep", emptyThreadConfig {configContextKeepUnits = Just 0}),
      ("bad-summary", emptyThreadConfig {configContextSummaryTokens = Just 95})
    ]
 where
  reject app store (threadId, config) = do
    rejected <- runSession (srequest (putConfig threadId (encode config))) app
    stored <- threadConfigRead store threadId
    simpleStatus rejected @?= status400
    stored @?= emptyThreadConfig

configRejectsBadEffort :: Assertion
configRejectsBadEffort = do
  (app, store) <- configApp
  rejected <- runSession (srequest (putConfig "bad-effort" "{\"reasoningEffort\":\"medium\"}")) app
  stored <- threadConfigRead store "bad-effort"
  simpleStatus rejected @?= status400
  stored @?= emptyThreadConfig

configTreeSymlinks :: Assertion
configTreeSymlinks = withSandbox $ \root -> do
  (app, store) <- configApp
  threadConfigWrite store "tree-thread" (emptyThreadConfig {configCwd = CwdPath root})
  response <- runSession (request treeRequest) app
  case eitherDecode (simpleBody response) of
    Left failure -> assertFailure failure
    Right entries -> do
      let rendered = Text.intercalate "\n" (entries :: [Text])
      simpleStatus response @?= status200
      assertBool "external symlink remains a leaf" ("linkdir@" `Text.isInfixOf` rendered)
      assertBool "internal symlink remains a leaf" ("inner@" `Text.isInfixOf` rendered)
      assertBool "cycle remains a leaf" ("up@" `Text.isInfixOf` rendered)
      assertBool "outside content is absent" (not ("secret.txt" `Text.isInfixOf` rendered))
 where
  treeRequest =
    defaultRequest
      { requestMethod = methodGet,
        pathInfo = ["config", "threads", "tree-thread", "tree"],
        queryString = [("depth", Just "8")]
      }

configPathCompletion :: Assertion
configPathCompletion = withWorkDir $ \root -> do
  createDirectoryIfMissing True (root ++ "/src")
  TextIO.writeFile (root ++ "/src/Main.hs") "main = pure ()"
  (app, store) <- configApp
  threadConfigWrite store "paths-thread" (emptyThreadConfig {configCwd = CwdPath root})
  response <-
    runSession
      (srequest (jsonRequest methodPost ["config", "threads", "paths-thread", "paths"] (object ["prefix" .= ("src/M" :: Text)])))
      app
  simpleStatus response @?= status200
  either
    assertFailure
    (\paths -> paths @?= ["src/Main.hs"])
    ( ( eitherDecode (simpleBody response)
          >>= parseEither (withObject "paths" (.: "paths"))
      ) ::
        Either String [Text]
    )

configMasksKey :: Assertion
configMasksKey = do
  (app, _) <- configApp
  response <- runSession (request (httpGet ["config"])) app
  let body = TextEncoding.decodeUtf8 (LazyByteString.toStrict (simpleBody response))
  simpleStatus response @?= status200
  assertBool "masks the API key" (Text.isInfixOf "＊＊＊" body)
  assertBool "never leaks the API key" (not (Text.isInfixOf "super-secret-key-123" body))
  assertBool "summarizes the provider" (Text.isInfixOf "deepseek-v4-flash" body)

perThreadPrompts :: Assertion
perThreadPrompts = do
  store <- newMemoryThreadConfigStore
  captured <- newIORef []
  manager <- newTlsManager
  base <- testRuntime (capturePrompts captured) [] Parallel
  let app = application Nothing Nothing (Just (testView store)) Nothing Nothing Nothing (configResolver store manager base)
  _ <- runSession (srequest (putConfig "thread-a" (encode (emptyThreadConfig {configSystemPrompt = Just "prompt-a"})))) app
  _ <- runSession (srequest (putConfig "thread-b" (encode (emptyThreadConfig {configSystemPrompt = Just "prompt-b"})))) app
  _ <- runSession (srequest (agentPost "thread-a")) app
  _ <- runSession (srequest (agentPost "thread-b")) app
  requests <- readIORef captured
  verify requests
 where
  verify [forB, forA] =
    sequence_ [systemHead forA @?= Just "prompt-a", systemHead forB @?= Just "prompt-b"]
  verify other = assertFailure ("unexpected request count: " <> show (length other))
  systemHead messages = case messages of
    (ChatSystem text : _) -> Just text
    _ -> Nothing

capturePrompts :: IORef [[ChatMessage]] -> Model
capturePrompts captured =
  fakeModel $ \req emit ->
    modifyIORef' captured (requestMessages req :) *> emit (ModelTextDelta "ok") $> Stop
