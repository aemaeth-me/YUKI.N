-- | 线程配置与解析测试
--
-- 覆盖：字段合并、cwd 状态 JSON、思考档位、文件存储、工具集解析、提示/模型/上下文策略覆盖、钩子剥离与配置 HTTP 端点。
-- 边界：覆盖 Yuki.N.ThreadConfig；全局默认见 ConfigTest。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
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
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Exception ()
import Control.Monad ()
import Data.Aeson
import Data.Aeson.Types (parseEither, parseMaybe)
import Data.Bool ()
import Data.ByteString ()
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.IORef
import Data.List ()
import Data.Map.Strict qualified as Map
import Data.Maybe ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types
import Network.Wai (Application, pathInfo, queryString, requestMethod)
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit ()
import System.FilePath ()
import System.Process ()
import System.Timeout ()
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event ()
import Yuki.N.AGUI.Types ()
import Yuki.N.Agent
import Yuki.N.Artifact
import Yuki.N.Background ()
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

-- | 规格：resolveThreadConfig 按字段合并 session 覆盖 global。
-- 背景：字段级合并是线程配置的核心语义；覆盖方向错误会让配置生效反了。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
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

-- | 规格：Cwd 状态 JSON 兼容 inherit/none/path 与旧格式。
-- 背景：cwd 是工具沙箱的根；JSON 兼容错误会让既有客户端配置失效。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
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

-- | 规格：reasoningEffort 只接受受支持值，medium 等未知值被拒。
-- 背景：推理档位枚举是 provider 契约；错误接受会让请求被 provider 拒绝。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
reasoningEffortJson :: Assertion
reasoningEffortJson =
  sequence_
    [ eitherDecode "{\"reasoningEffort\":\"low\"}" @?= Right (emptyThreadConfig {configReasoningEffort = Just Low}),
      eitherDecode (encode (emptyThreadConfig {configReasoningEffort = Just Max})) @?= Right (emptyThreadConfig {configReasoningEffort = Just Max}),
      case eitherDecode "{\"reasoningEffort\":\"medium\"}" :: Either String ThreadConfig of
        Left _ -> pure ()
        Right _ -> assertFailure "medium should be rejected"
    ]

-- | 规格：session 可继承、清空或替换 global cwd，工具根随解析结果变化。
-- 背景：cwd 决定工具可见文件范围；解析错误会让工具读错目录。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cwdOverridesGlobal :: Assertion
cwdOverridesGlobal =
  withWorkDir $ \globalDir ->
    let localDir = globalDir ++ "/local"
        global = emptyThreadConfig {configCwd = CwdPath globalDir}
        effective session = resolveThreadConfig session global
     in createDirectoryIfMissing True localDir
          *> TextIO.writeFile (globalDir ++ "/global.txt") "global"
          *> TextIO.writeFile (localDir ++ "/local.txt") "local"
          *> newTlsManager
          >>= \manager ->
            testRuntime okModel [] Parallel >>= \base ->
              (,,)
                <$> resolveRuntime manager testProvider Nothing base (effective emptyThreadConfig) Map.empty Map.empty
                <*> resolveRuntime manager testProvider Nothing base (effective (emptyThreadConfig {configCwd = CwdNone})) Map.empty Map.empty
                <*> resolveRuntime manager testProvider Nothing base (effective (emptyThreadConfig {configCwd = CwdPath localDir})) Map.empty Map.empty
                >>= \(inherited, cleared, replaced) ->
                  callRuntimeList inherited >>= \globalList ->
                    callRuntimeList replaced >>= \localList ->
                      sequence_
                        [ configCwd (effective emptyThreadConfig) @?= CwdPath globalDir,
                          configCwd (effective (emptyThreadConfig {configCwd = CwdNone})) @?= CwdNone,
                          Map.member "fs_list" (runtimeTools inherited) @?= True,
                          Map.member "fs_list" (runtimeTools cleared) @?= False,
                          assertBool "inherited runtime is rooted globally" ("global.txt" `Text.isInfixOf` globalList),
                          assertBool "replacement runtime is rooted locally" ("local.txt" `Text.isInfixOf` localList && not ("global.txt" `Text.isInfixOf` localList))
                        ]
 where
  callRuntimeList runtime =
    maybe (assertFailure "missing fs_list") pure (Map.lookup "fs_list" (runtimeTools runtime))
      >>= \backend ->
        runBackendTool backend (ToolContext "run" "thread" "call" (const (pure ())) Nothing) (object [])
          <&> toolOutcomeContent

-- | 规格：线程配置落盘使用净化文件名并在重启后读回。
-- 背景：线程名含分隔符时必须净化；净化冲突会让不同线程互相覆盖。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
fileStoreRoundTrip :: Assertion
fileStoreRoundTrip =
  withWorkDir $ \dir ->
    newThreadConfigStore dir >>= \store ->
      threadConfigWrite store "th/read:me" saved
        *> (threadConfigRead store "th/read:me" >>= (@?= saved))
        *> (doesFileExist (dir ++ "/threads-config/th-read-me.json") >>= assertBool "config file uses the sanitized name")
        *> (newThreadConfigStore dir >>= \reopened -> threadConfigRead reopened "th/read:me" >>= (@?= saved))
        *> (threadConfigRead store "absent" >>= (@?= emptyThreadConfig))
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

-- | 规格：resolveRuntime 按 cwd/fs/shell 配置组装确切工具集。
-- 背景：工具集是能力的声明；多配或少配都会让模型使用不可用工具。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
toolResolution :: Assertion
toolResolution =
  withWorkDir $ \dir ->
    newTlsManager >>= \manager ->
      newMemoryArtifactStore >>= \artifacts ->
        testRuntime okModel [] Parallel >>= \base ->
          let resolved config = Map.keys . runtimeTools <$> resolveRuntime manager testProvider (Just artifacts) base config Map.empty Map.empty
           in traverse resolved (configs dir) >>= (@?= expected)
 where
  configs dir =
    [ emptyThreadConfig {configCwd = CwdPath dir},
      emptyThreadConfig,
      emptyThreadConfig {configCwd = CwdPath dir, configFs = Just False},
      emptyThreadConfig {configCwd = CwdPath dir, configShell = Just False}
    ]
  expected =
    [ [artifactReadToolName, "fs_edit", "fs_glob", "fs_grep", "fs_list", "fs_read", "fs_write", "plan", "shell", "shell_bg", "shell_kill", "shell_output", "shell_stdin", "sub_agent"],
      [artifactReadToolName, "sub_agent"],
      [artifactReadToolName, "plan", "shell", "shell_bg", "shell_kill", "shell_output", "shell_stdin", "sub_agent"],
      [artifactReadToolName, "fs_edit", "fs_glob", "fs_grep", "fs_list", "fs_read", "fs_write", "plan", "sub_agent"]
    ]

-- | 规格：resolveRuntime 按线程覆盖 system prompt 并按名重建模型。
-- 背景：每线程提示与模型是会话定制的基础；不生效会让定制形同虚设。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
promptAndModel :: Assertion
promptAndModel =
  newTlsManager >>= \manager ->
    testRuntime okModel [] Parallel >>= \base ->
      let resolved config = resolveRuntime manager testProvider Nothing base {runtimeSystemPrompt = "global prompt"} config Map.empty Map.empty
       in (,,)
            <$> resolved emptyThreadConfig
            <*> resolved emptyThreadConfig {configSystemPrompt = Just "local"}
            <*> resolved emptyThreadConfig {configModel = Just "deepseek-v4-pro"}
            >>= \(global, local, override) ->
              sequence_
                [ runtimeSystemPrompt global @?= "global prompt",
                  runtimeSystemPrompt local @?= "local",
                  modelName (runtimeModel global) @?= "fake",
                  modelName (runtimeModel override) @?= "deepseek-v4-pro"
                ]

-- | 规格：每线程思考档位生效于 wire 请求（reasoning_effort 或 reasoning.effort）。
-- 背景：思考档位是成本与质量权衡的旋钮；不生效会让配置静默失效。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
reasoningEffortResolution :: Assertion
reasoningEffortResolution =
  newTlsManager >>= \manager ->
    testRuntime okModel [] Parallel >>= \base ->
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
       in (,)
            <$> resolveRuntime manager testProvider Nothing base selected defaultProviders keys
            <*> resolveRuntime manager (settingsProvider testSettings) Nothing base inherited Map.empty Map.empty
            >>= \(kimi, deepseek) ->
              sequence_
                [ modelProvider (runtimeModel kimi) @?= "kimi-coding",
                  effort kimi @?= Just ("low" :: Text),
                  effort deepseek @?= Just ("max" :: Text)
                ]

-- | 规格：每线程上下文策略（reserve/keep/summary）覆盖运行时上下文配置。
-- 背景：上下文策略影响压缩行为；解析错误会让预算计算失真。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
contextPolicyResolution :: Assertion
contextPolicyResolution =
  newTlsManager >>= \manager ->
    testRuntime okModel [] Parallel >>= \base ->
      let initial = ContextConfig 8192 12 2048 200000
          config =
            emptyThreadConfig
              { configContextReserveTokens = Just 4096,
                configContextKeepUnits = Just 6,
                configContextSummaryTokens = Just 768
              }
       in resolveRuntime manager testProvider Nothing base {runtimeContext = Just initial} config Map.empty Map.empty
            >>= maybe
              (assertFailure "context policy disappeared")
              ( \resolved ->
                  sequence_
                    [ contextReserveTokens resolved @?= 4096,
                      contextKeepUnits resolved @?= 6,
                      contextSummaryTokens resolved @?= 768,
                      contextFallbackChars resolved @?= 200000
                    ]
              )
              . runtimeContext

-- | 规格：configMemory=False 时运行时钩子被剥离，业务钩子不执行。
-- 背景：关闭记忆必须彻底；残留钩子会继续读写记忆存储。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
memoryStripped :: Assertion
memoryStripped =
  newIORef False >>= \called ->
    newTlsManager >>= \manager ->
      testRuntime okModel [] Parallel >>= \base ->
        let hooks config = runtimeHooks <$> resolveRuntime manager testProvider Nothing base {runtimeHooks = business} config Map.empty Map.empty
            business =
              defaultHooks
                { afterRun = \_ _ -> writeIORef called True,
                  getSteeringMessages = const (pure [ChatSystem "steer"])
                }
         in (,) <$> hooks emptyThreadConfig {configMemory = Just False} <*> hooks emptyThreadConfig >>= \(stripped, kept) ->
              afterRun stripped (sampleInput []) []
                *> (readIORef called >>= (@?= False))
                *> (getSteeringMessages stripped (sampleInput []) >>= (@?= []))
                *> afterRun kept (sampleInput []) []
                *> (readIORef called >>= (@?= True))

configApp :: IO (Application, ThreadConfigStore)
configApp =
  newMemoryThreadConfigStore >>= \store ->
    newTlsManager >>= \manager ->
      testRuntime okModel [] Parallel >>= \base ->
        let context =
              ContextConfig
                (settingsContextReserveTokens testSettings)
                (settingsContextKeepUnits testSettings)
                (settingsContextSummaryTokens testSettings)
                (settingsSpliceChars testSettings)
         in pure
              ( application Nothing Nothing (Just (testView store)) Nothing (configResolver store manager base {runtimeContext = Just context}),
                store
              )
configResolver :: ThreadConfigStore -> Manager -> Runtime -> Text -> IO Runtime
configResolver store manager base threadId =
  threadConfigRead store threadId
    >>= \session ->
      resolveRuntime manager (settingsProvider testSettings) Nothing base (resolveThreadConfig session (globalThreadConfig testSettings)) Map.empty Map.empty

-- | 规格：PUT/GET /config/threads/:id 往返一致，未知线程返回默认配置。
-- 背景：配置端点是线程定制的通道；往返不一致会让保存静默丢失。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
configEndpoints :: Assertion
configEndpoints =
  configApp >>= \(app, _) ->
    runSession (srequest (putConfig "t-a" (encode (emptyThreadConfig {configSystemPrompt = Just "prompt-a"})))) app >>= \saved ->
      runSession (request (httpGet ["config", "threads", "t-a"])) app >>= \fetched ->
        runSession (request (httpGet ["config", "threads", "t-unknown"])) app >>= \unknown ->
          sequence_
            [ simpleStatus saved @?= status204,
              either assertFailure (@?= emptyThreadConfig {configSystemPrompt = Just "prompt-a"}) (eitherDecode (simpleBody fetched)),
              either assertFailure (@?= emptyThreadConfig) (eitherDecode (simpleBody unknown))
            ]

-- | 规格：capabilities 端点按解析后的工具集报告能力。
-- 背景：能力报告是前端开关的依据；错误报告会误导界面。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
configCapabilities :: Assertion
configCapabilities =
  withWorkDir $ \dir ->
    configApp >>= \(app, store) ->
      threadConfigWrite store "capable" (emptyThreadConfig {configCwd = CwdPath dir, configShell = Just False})
        *> runSession (request (httpGet ["config", "threads", "capable", "capabilities"])) app
        >>= \response ->
          sequence_
            [ simpleStatus response @?= status200,
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
                      "sub_agent"
                    ]
                )
                (eitherDecode (simpleBody response) :: Either String [Text])
            ]

-- | 规格：context 端点解释精确压缩阈值公式（budget = max 256 (window − reserve − tools)）。
-- 背景：阈值公式是用户可见的契约；公式漂移会让界面解释与实现不一致。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
configContextPolicy :: Assertion
configContextPolicy =
  configApp >>= \(app, store) ->
    threadConfigWrite
      store
      "contextual"
      ( emptyThreadConfig
          { configContextReserveTokens = Just 4096,
            configContextKeepUnits = Just 6,
            configContextSummaryTokens = Just 768
          }
      )
      *> runSession (request (httpGet ["config", "threads", "contextual", "context"])) app
      >>= \response ->
        case eitherDecode (simpleBody response) of
          Left failure -> assertFailure failure
          Right value ->
            sequence_
              [ simpleStatus response @?= status200,
                parseMaybe (withObject "policy" (.: "enabled")) value @?= Just True,
                parseMaybe (withObject "policy" (.: "reserveTokens")) value @?= Just (4096 :: Int),
                parseMaybe (withObject "policy" (.: "keepUnits")) value @?= Just (6 :: Int),
                parseMaybe (withObject "policy" (.: "summaryTokens")) value @?= Just (768 :: Int),
                ( (\window reserve tools budget -> budget == max 256 (window - reserve - tools))
                    <$> (parseMaybe (withObject "policy" (.: "windowTokens")) value :: Maybe Int)
                    <*> (parseMaybe (withObject "policy" (.: "reserveTokens")) value :: Maybe Int)
                    <*> (parseMaybe (withObject "policy" (.: "toolTokens")) value :: Maybe Int)
                    <*> (parseMaybe (withObject "policy" (.: "budgetTokens")) value :: Maybe Int)
                )
                  @?= Just True
              ]

-- | 规格：PUT 拒绝不存在的 cwd 且不落盘。
-- 背景：坏 cwd 会让工具沙箱指向空目录；拒绝必须发生在保存前。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
configRejectsBadCwd :: Assertion
configRejectsBadCwd =
  configApp >>= \(app, store) ->
    runSession (srequest (putConfig "t-b" (encode (emptyThreadConfig {configCwd = CwdPath "/no/such/yuki-dir"})))) app >>= \rejected ->
      threadConfigRead store "t-b" >>= \stored ->
        sequence_ [simpleStatus rejected @?= status400, stored @?= emptyThreadConfig]

-- | 规格：PUT 拒绝非法上下文策略值且不落盘。
-- 背景：非法策略会破坏压缩预算；静默接受会让运行时带着坏配置运行。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
configRejectsBadContext :: Assertion
configRejectsBadContext =
  configApp >>= \(app, store) ->
    traverse_
      (reject app store)
      [ ("bad-reserve", emptyThreadConfig {configContextReserveTokens = Just 0}),
        ("bad-keep", emptyThreadConfig {configContextKeepUnits = Just 0}),
        ("bad-summary", emptyThreadConfig {configContextSummaryTokens = Just 95})
      ]
 where
  reject app store (threadId, config) =
    runSession (srequest (putConfig threadId (encode config))) app >>= \rejected ->
      threadConfigRead store threadId >>= \stored ->
        sequence_ [simpleStatus rejected @?= status400, stored @?= emptyThreadConfig]

-- | 规格：PUT 拒绝未知 reasoning effort。
-- 背景：非法档位会在请求时被 provider 拒绝；提前拒绝更友好。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
configRejectsBadEffort :: Assertion
configRejectsBadEffort =
  configApp >>= \(app, store) ->
    runSession (srequest (putConfig "bad-effort" "{\"reasoningEffort\":\"medium\"}")) app >>= \rejected ->
      threadConfigRead store "bad-effort" >>= \stored ->
        sequence_ [simpleStatus rejected @?= status400, stored @?= emptyThreadConfig]

-- | 规格：config 树端点不穿透符号链接。
-- 背景：树视图穿透链接会泄漏外部结构或陷入环。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
configTreeSymlinks :: Assertion
configTreeSymlinks =
  withSandbox $ \root ->
    configApp >>= \(app, store) ->
      threadConfigWrite store "tree-thread" (emptyThreadConfig {configCwd = CwdPath root})
        *> runSession (request treeRequest) app
        >>= \response ->
          case eitherDecode (simpleBody response) of
            Left failure -> assertFailure failure
            Right entries ->
              let rendered = Text.intercalate "\n" (entries :: [Text])
               in sequence_
                    [ simpleStatus response @?= status200,
                      assertBool "external symlink remains a leaf" ("linkdir@" `Text.isInfixOf` rendered),
                      assertBool "internal symlink remains a leaf" ("inner@" `Text.isInfixOf` rendered),
                      assertBool "cycle remains a leaf" ("up@" `Text.isInfixOf` rendered),
                      assertBool "outside content is absent" (not ("secret.txt" `Text.isInfixOf` rendered))
                    ]
 where
  treeRequest =
    defaultRequest
      { requestMethod = methodGet,
        pathInfo = ["config", "threads", "tree-thread", "tree"],
        queryString = [("depth", Just "8")]
      }

-- | 规格：路径补全端点使用解析后的 session cwd。
-- 背景：补全根错误会让前端补全出错误路径。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
configPathCompletion :: Assertion
configPathCompletion =
  withWorkDir $ \root ->
    createDirectoryIfMissing True (root ++ "/src")
      *> TextIO.writeFile (root ++ "/src/Main.hs") "main = pure ()"
      *> configApp
      >>= \(app, store) ->
        threadConfigWrite store "paths-thread" (emptyThreadConfig {configCwd = CwdPath root})
          *> runSession
            (srequest (jsonRequest methodPost ["config", "threads", "paths-thread", "paths"] (object ["prefix" .= ("src/M" :: Text)])))
            app
          >>= \response ->
            sequence_
              [ simpleStatus response @?= status200,
                either
                  assertFailure
                  (\paths -> paths @?= ["src/Main.hs"])
                  ( ( eitherDecode (simpleBody response)
                        >>= parseEither (withObject "paths" (.: "paths"))
                    ) ::
                      Either String [Text]
                  )
              ]

-- | 规格：GET /config 掩码 API 密钥。
-- 背景：配置回读是调试入口；泄漏密钥会造成凭据暴露。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
configMasksKey :: Assertion
configMasksKey =
  configApp >>= \(app, _) ->
    runSession (request (httpGet ["config"])) app >>= \response ->
      let body = TextEncoding.decodeUtf8 (LazyByteString.toStrict (simpleBody response))
       in sequence_
            [ simpleStatus response @?= status200,
              assertBool "masks the API key" (Text.isInfixOf "＊＊＊" body),
              assertBool "never leaks the API key" (not (Text.isInfixOf "super-secret-key-123" body)),
              assertBool "summarizes the provider" (Text.isInfixOf "deepseek-v4-flash" body)
            ]

-- | 规格：agent 请求按线程解析系统提示。
-- 背景：每线程提示是会话人格的载体；解析错误会让所有线程共享同一提示。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
perThreadPrompts :: Assertion
perThreadPrompts =
  newMemoryThreadConfigStore >>= \store ->
    newIORef [] >>= \captured ->
      newTlsManager >>= \manager ->
        testRuntime (capturePrompts captured) [] Parallel >>= \base ->
          let app = application Nothing Nothing (Just (testView store)) Nothing (configResolver store manager base)
           in runSession (srequest (putConfig "thread-a" (encode (emptyThreadConfig {configSystemPrompt = Just "prompt-a"})))) app
                *> runSession (srequest (putConfig "thread-b" (encode (emptyThreadConfig {configSystemPrompt = Just "prompt-b"})))) app
                *> runSession (srequest (agentPost "thread-a")) app
                *> runSession (srequest (agentPost "thread-b")) app
                *> (readIORef captured >>= verify)
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
