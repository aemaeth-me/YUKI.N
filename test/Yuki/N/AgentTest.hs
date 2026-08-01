-- | agent 运行时编排测试
--
-- 覆盖：事件流展开、并行/前端工具、回合上限、异常分类；provider 重试与 fallback 链；AgentHooks 组合；response machine 状态机。
-- 边界：不覆盖取消/steer（见 RunsTest）与真实 socket（见 E2E）。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.AgentTest
  ( agentTests,
    reasoningEvents,
    parallelTools,
    frontendTools,
    turnLimitError,
    unexpectedError,
    runError,
    retryTests,
    retryRecovers,
    retryExhausted,
    retryAfterDelta,
    retryReplay,
    fallbackTests,
    fallbackSucceeds,
    fallbackRetries,
    fallbackChainExhausted,
    fallbackEmptyChain,
    fallbackReplay,
    fallbackConfigParse,
    fallbackConfigRender,
    hooksTests,
    identity,
    ordering,
    denial,
    chaining,
    machineTests,
    textLifecycle,
    reasoningThenText,
    lateReasoning,
    toolLifecycle,
    incompleteTool,
    usageClose,
    noUsage,
  )
where

import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar
import Control.Exception (throwIO)
import Control.Monad ()
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (parseMaybe)
import Data.Bool (bool)
import Data.ByteString ()
import Data.Functor (($>))
import Data.IORef
import Data.List ()
import Data.Map.Strict qualified as Map
import Data.Maybe ()
import Data.Text (Text)
import Data.Text qualified as Text
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test ()
import System.Directory ()
import System.Exit ()
import System.FilePath ()
import System.Process ()
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types ()
import Yuki.N.Agent
import Yuki.N.Background ()
import Yuki.N.Config
import Yuki.N.Journal
import Yuki.N.Model
import Yuki.N.Provider.OpenAI ()
import Yuki.N.Replay
import Yuki.N.Runs ()
import Yuki.N.Server ()
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig

agentTests :: TestTree
agentTests =
  testGroup
    "agent"
    [ testCase "streams reasoning and text through normalized AG-UI events" reasoningEvents,
      testCase "executes backend tools concurrently and continues the model loop" parallelTools,
      testCase "hands client tools back without another model call" frontendTools,
      testCase "classifies the local model-turn guard distinctly" turnLimitError,
      testCase "surfaces an unexpected synchronous exception with its detail" unexpectedError,
      testCase "emits RUN_ERROR without a following RUN_FINISHED" runError
    ]

-- | 规格：agent 运行把推理增量与文本增量展开为归一化 AG-UI 生命周期事件序列。
-- 背景：前端按事件序列驱动推理/正文渲染；序列错乱（如 END 先于 START）会让 UI 卡在中间态。该用例失败代表核心事件管线违约。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
reasoningEvents :: Assertion
reasoningEvents =
  testRuntime model [] Parallel >>= collect >>= (@?= expected)
 where
  model =
    fakeModel $ \_ emit ->
      emit (ModelReasoningDelta "brief reasoning") *> emit (ModelTextDelta "hello") $> Stop
  collect runtime = eventType <$$> collectEvents runtime (sampleInput [])
  expected =
    [ "RUN_STARTED",
      "STEP_STARTED",
      "REASONING_START",
      "REASONING_MESSAGE_START",
      "REASONING_MESSAGE_CONTENT",
      "REASONING_MESSAGE_END",
      "REASONING_END",
      "TEXT_MESSAGE_START",
      "TEXT_MESSAGE_CONTENT",
      "TEXT_MESSAGE_END",
      "STEP_FINISHED",
      "RUN_FINISHED"
    ]

-- | 规格：并行工具回合中两个后端工具同时执行，结果均进入下一轮模型请求，回合不互锁。
-- 背景：工具并行是吞吐核心；若其中一个被阻塞则整个运行死锁。该用例以 5 秒超时验证无死锁。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
parallelTools :: Assertion
parallelTools =
  fixture >>= exercise
 where
  fixture =
    (,,,)
      <$> newIORef (0 :: Int)
      <*> newIORef []
      <*> newEmptyMVar
      <*> newEmptyMVar
  exercise (turns, secondRequest, leftStarted, rightStarted) =
    testRuntime
      (parallelModel turns secondRequest)
      [ barrier "left" leftStarted rightStarted "left-result",
        barrier "right" rightStarted leftStarted "right-result"
      ]
      Parallel
      >>= run secondRequest
  run secondRequest runtime =
    timeout 5000000 (collectEvents runtime (sampleInput []))
      >>= maybe
        (assertFailure "parallel tool execution deadlocked")
        (verifyParallel secondRequest)

parallelModel :: IORef Int -> IORef [ChatMessage] -> Model
parallelModel turns secondRequest =
  fakeModel $ \modelRequest emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next))
      >>= turn modelRequest emit
 where
  turn _ emit 1 =
    emit (ModelToolCallDelta 0 (Just "call-a") (Just "left") "{}")
      *> emit (ModelToolCallDelta 1 (Just "call-b") (Just "right") "{}")
      $> ToolUse
  turn modelRequest emit 2 =
    writeIORef secondRequest (requestMessages modelRequest) *> emit (ModelTextDelta "done") $> Stop
  turn _ _ _ = throwIO (ProviderFailure "unexpected model turn")
barrier :: Text -> MVar () -> MVar () -> Text -> BackendTool
barrier name own other content =
  BackendTool
    (tool name)
    (\_ _ -> (putMVar own () *> readMVar other) $> ToolOutcome content False False)
verifyParallel :: IORef [ChatMessage] -> [Event] -> Assertion
verifyParallel secondRequest events =
  sequence_
    [ length (filter ((== "TOOL_CALL_RESULT") . eventType) events) @?= 2,
      eventType <$> takeEnd 2 events @?= ["STEP_FINISHED", "RUN_FINISHED"]
    ]
    *> (readIORef secondRequest >>= verifyMessages)
 where
  verifyMessages messages =
    [call | ChatToolResult call _ <- messages] @?= ["call-a", "call-b"]

-- | 规格：前端工具调用不触发后端执行，也不产生 TOOL_CALL_RESULT，直接继续模型循环。
-- 背景：前端工具（如 confirm）由客户端处理；后端若误执行会产生副作用或重复执行。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
frontendTools :: Assertion
frontendTools = newIORef (0 :: Int) >>= prepare
 where
  prepare calls = testRuntime (frontendModel calls) [] Parallel >>= run calls
  run calls runtime =
    collectEvents runtime (sampleInput [tool "confirm"]) >>= verifyFrontend calls

frontendModel :: IORef Int -> Model
frontendModel calls =
  fakeModel $ \_ emit ->
    modifyIORef' calls (+ 1)
      *> emit (ModelToolCallDelta 0 (Just "frontend-call") (Just "confirm") "{\"ok\":true}")
      $> ToolUse
verifyFrontend :: IORef Int -> [Event] -> Assertion
verifyFrontend calls events =
  readIORef calls
    >>= \count ->
      sequence_
        [ count @?= 1,
          assertBool
            "frontend call must not produce a backend result"
            (all ((/= "TOOL_CALL_RESULT") . eventType) events),
          eventType (last events) @?= "RUN_FINISHED"
        ]

-- | 规格：本地模型回合上限被分类为 MAX_TURNS_EXCEEDED，消息提及限制数值与 YUKI_MAX_TURNS 键。
-- 背景：无限循环的模型会耗尽配额；明确的本地限制错误让用户知道是配置而非 provider 故障。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
turnLimitError :: Assertion
turnLimitError =
  testRuntime looping [echoTool] Sequential >>= \base ->
    collectEvents base {runtimeMaxTurns = 1} (sampleInput []) >>= \events ->
      case [(message, code) | RunError message code <- events] of
        [(message, code)] ->
          sequence_
            [ code @?= Just "MAX_TURNS_EXCEEDED",
              assertBool "error identifies the configured local limit" ("1 model turns" `Text.isInfixOf` message),
              assertBool "error identifies the configuration key" ("YUKI_MAX_TURNS" `Text.isInfixOf` message)
            ]
        failures -> assertFailure ("expected one turn-limit error, got " <> show failures)
 where
  looping =
    fakeModel $ \_ emit ->
      emit (ModelToolCallDelta 0 (Just "call-echo") (Just "echo") "{}") $> ToolUse

-- | 规格：hook 抛出的同步异常被捕获为 UNHANDLED_ERROR，且保留原始异常细节。
-- 背景：第三方 hook 抛错不应击穿整个服务；保留细节对排障必不可少。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
unexpectedError :: Assertion
unexpectedError =
  testRuntime okModel [] Parallel >>= \base ->
    let hooks = defaultHooks {transformContext = \_ _ -> ioError (userError "context transformer exploded")}
     in collectEvents base {runtimeHooks = hooks} (sampleInput []) >>= \events ->
          case [(message, code) | RunError message code <- events] of
            [(message, code)] ->
              sequence_
                [ code @?= Just "UNHANDLED_ERROR",
                  assertBool "error retains the original exception detail" ("context transformer exploded" `Text.isInfixOf` message)
                ]
            failures -> assertFailure ("expected one unhandled error, got " <> show failures)

-- | 规格：provider 启动即失败时事件流以 RUN_ERROR 收尾，不再发出 RUN_FINISHED。
-- 背景：错误与正常完成必须可区分；若同时发出 FINISHED 会让前端与重放逻辑误判为成功。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
runError :: Assertion
runError =
  testRuntime
    (fakeModel (\_ _ -> throwIO (ProviderFailure "unavailable")))
    []
    Parallel
    >>= \runtime ->
      eventType <$$> collectEvents runtime (sampleInput [])
        >>= (@?= ["RUN_STARTED", "STEP_STARTED", "RUN_ERROR"])

retryTests :: TestTree
retryTests =
  testGroup
    "provider retry"
    [ testCase "retries before the first delta and announces the attempt" retryRecovers,
      testCase "gives up at the attempt cap" retryExhausted,
      testCase "never retries after a delta was consumed" retryAfterDelta,
      testCase "replays a journaled run with provider.retry events without divergence" retryReplay
    ]
flakyModel :: Int -> IORef Int -> Model
flakyModel failures calls =
  fakeModel $ \_ emit ->
    atomicModifyIORef' calls (\count -> (count + 1, count + 1))
      >>= \call ->
        bool
          (emit (ModelTextDelta "recovered") $> Stop)
          (throwIO (ProviderFailure "upstream 429"))
          (call <= failures)
retryEvents :: [Event] -> [Value]
retryEvents events = [value | Custom "provider.retry" value <- events]

-- | 规格：重试在首个 delta 前发生并宣告尝试。
-- 背景：重试是应对上游限流的基础；事件缺失会让运维无法观测重试。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
retryRecovers :: Assertion
retryRecovers =
  newIORef (0 :: Int) >>= \calls ->
    testRuntime (flakyModel 1 calls) [] Parallel >>= \base ->
      collectEvents base {runtimeProviderRetries = 3} (sampleInput []) >>= \events ->
        readIORef calls >>= \attempts ->
          sequence_
            [ attempts @?= 2,
              [delta | TextMessageContent _ delta <- events] @?= ["recovered"],
              eventType (last events) @?= "RUN_FINISHED",
              case retryEvents events of
                [value] ->
                  sequence_
                    [ parseMaybe (withObject "retry" (.: "attempt")) value @?= Just (1 :: Int),
                      parseMaybe (withObject "retry" (.: "maxAttempts")) value @?= Just (3 :: Int),
                      parseMaybe (withObject "retry" (.: "delayMs")) value @?= Just (1000 :: Int),
                      parseMaybe (withObject "retry" (.: "reason")) value @?= Just ("upstream 429" :: Text)
                    ]
                other -> assertFailure ("expected one provider.retry, got " <> show (length other))
            ]

-- | 规格：达到尝试上限后放弃并以 PROVIDER_ERROR 收尾。
-- 背景：重试必须有界；无界重试会拖死运行。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
retryExhausted :: Assertion
retryExhausted =
  newIORef (0 :: Int) >>= \calls ->
    testRuntime (flakyModel 9 calls) [] Parallel >>= \base ->
      collectEvents base {runtimeProviderRetries = 2} (sampleInput []) >>= \events ->
        readIORef calls >>= \attempts ->
          sequence_
            [ attempts @?= 2,
              length (retryEvents events) @?= 1,
              eventType (last events) @?= "RUN_ERROR",
              [code | RunError _ (Just code) <- events] @?= ["PROVIDER_ERROR"]
            ]

-- | 规格：消费过 delta 后绝不再重试。
-- 背景：已产生输出后再重试会重复输出；禁止重试是流式语义的底线。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
retryAfterDelta :: Assertion
retryAfterDelta =
  testRuntime midStreamFailure [] Parallel >>= \base ->
    collectEvents base {runtimeProviderRetries = 3} (sampleInput []) >>= \events ->
      sequence_
        [ [delta | TextMessageContent _ delta <- events] @?= ["partial"],
          retryEvents events @?= [],
          eventType (last events) @?= "RUN_ERROR"
        ]
 where
  midStreamFailure =
    fakeModel $ \_ emit ->
      emit (ModelTextDelta "partial") *> throwIO (ProviderFailure "connection reset")

-- | 规格：带 provider.retry 事件的 journaled 运行可无分歧重放。
-- 背景：重放必须复现重试事件；否则重放轨迹与真实执行不一致。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
retryReplay :: Assertion
retryReplay =
  newMemoryJournal >>= \(journal, readEntries) ->
    newIORef (0 :: Int) >>= \calls ->
      testRuntime (flakyModel 1 calls) [] Parallel >>= \base ->
        collectEvents base {runtimeJournal = Just journal, runtimeProviderRetries = 3} (sampleInput [])
          >>= \events ->
            readEntries >>= \recorded ->
              replayEntries defaultHooks Nothing recorded >>= \report ->
                sequence_
                  [ assertBool "journal records provider.retry" (any journaled recorded),
                    fmap reportDivergence report @?= Right Nothing,
                    fmap reportEvents report @?= Right (length (filter (not . isRetry) events))
                  ]
 where
  journaled (Entry _ _ _ (AgentEventEntry (Custom "provider.retry" _))) = True
  journaled _ = False
  isRetry (Custom "provider.retry" _) = True
  isRetry _ = False

fallbackTests :: TestTree
fallbackTests =
  testGroup
    "provider fallback"
    [ testCase "falls back after the primary exhausts its retries" fallbackSucceeds,
      testCase "gives each fallback its own retry budget" fallbackRetries,
      testCase "walks the chain and rethrows the last failure" fallbackChainExhausted,
      testCase "an empty chain keeps the single-provider behavior" fallbackEmptyChain,
      testCase "replays a journaled fallback run without divergence" fallbackReplay,
      testCase "fallback env var defaults, parses a list and rejects empty names" fallbackConfigParse,
      testCase "global config exposes the fallback roster" fallbackConfigRender
    ]
downModel :: IORef Int -> Text -> Text -> Text -> Model
downModel calls provider name reason =
  Model provider name Nothing (\_ _ -> modifyIORef' calls (+ 1) *> throwIO (ProviderFailure reason)) (const (object []))
answeringModel :: IORef Int -> Text -> Text -> Text -> Model
answeringModel calls provider name answer =
  Model provider name Nothing (\_ emit -> modifyIORef' calls (+ 1) *> emit (ModelTextDelta answer) $> Stop) (const (object []))
fallbackField :: Value -> Text -> Maybe Text
fallbackField value key = parseMaybe (withObject "fallback" (.: Key.fromText key)) value

-- | 规格：主 provider 重试耗尽后回退到备用 provider 并宣告 fallback。
-- 背景：回退是可用性保障；事件字段（from/to/reason）是审计依据。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
fallbackSucceeds :: Assertion
fallbackSucceeds =
  newIORef (0 :: Int) >>= \primaryCalls ->
    newIORef (0 :: Int) >>= \backupCalls ->
      testRuntime (downModel primaryCalls "alpha" "a1" "alpha down") [] Parallel >>= \base ->
        collectEvents
          base
            { runtimeProviderRetries = 3,
              runtimeFallbacks = [answeringModel backupCalls "beta" "b1" "second wind"]
            }
          (sampleInput [])
          >>= \events ->
            (,) <$> readIORef primaryCalls <*> readIORef backupCalls >>= \calls ->
              sequence_
                [ calls @?= (3, 1),
                  [name | Custom name _ <- events] @?= ["provider.retry", "provider.retry", "provider.fallback"],
                  case [value | Custom "provider.fallback" value <- events] of
                    [value] ->
                      sequence_
                        [ fallbackField value "from" @?= Just "alpha/a1",
                          fallbackField value "to" @?= Just "beta/b1",
                          fallbackField value "reason" @?= Just "alpha down"
                        ]
                    other -> assertFailure ("expected one provider.fallback, got " <> show (length other)),
                  [delta | TextMessageContent _ delta <- events] @?= ["second wind"],
                  eventType (last events) @?= "RUN_FINISHED"
                ]

-- | 规格：每个 fallback 拥有独立重试预算。
-- 背景：共享预算会让链上单个成员耗尽全部机会。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
fallbackRetries :: Assertion
fallbackRetries =
  newIORef (0 :: Int) >>= \primaryCalls ->
    newIORef (0 :: Int) >>= \backupCalls ->
      testRuntime (downModel primaryCalls "alpha" "a1" "alpha down") [] Parallel >>= \base ->
        collectEvents
          base
            { runtimeProviderRetries = 2,
              runtimeFallbacks = [(flakyModel 1 backupCalls) {modelProvider = "beta", modelName = "b1"}]
            }
          (sampleInput [])
          >>= \events ->
            (,) <$> readIORef primaryCalls <*> readIORef backupCalls >>= \calls ->
              sequence_
                [ calls @?= (2, 2),
                  [name | Custom name _ <- events] @?= ["provider.retry", "provider.fallback", "provider.retry"],
                  [delta | TextMessageContent _ delta <- events] @?= ["recovered"],
                  eventType (last events) @?= "RUN_FINISHED"
                ]

-- | 规格：整条链耗尽后重抛最后一个失败。
-- 背景：链尾错误必须保留，用户需要知道最终失败原因。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
fallbackChainExhausted :: Assertion
fallbackChainExhausted =
  newIORef (0 :: Int) >>= \callsA ->
    newIORef (0 :: Int) >>= \callsB ->
      newIORef (0 :: Int) >>= \callsC ->
        testRuntime (downModel callsA "alpha" "a1" "alpha down") [] Parallel >>= \base ->
          collectEvents
            base
              { runtimeProviderRetries = 1,
                runtimeFallbacks =
                  [ downModel callsB "beta" "b1" "beta down",
                    downModel callsC "gamma" "g1" "gamma down"
                  ]
              }
            (sampleInput [])
            >>= \events ->
              (,,) <$> readIORef callsA <*> readIORef callsB <*> readIORef callsC >>= \calls ->
                sequence_
                  [ calls @?= (1, 1, 1),
                    [name | Custom name _ <- events] @?= ["provider.fallback", "provider.fallback"],
                    [to | Custom "provider.fallback" value <- events, Just to <- [fallbackField value "to"]]
                      @?= ["beta/b1", "gamma/g1"],
                    [message | RunError message _ <- events] @?= ["gamma down"],
                    [code | RunError _ (Just code) <- events] @?= ["PROVIDER_ERROR"]
                  ]

-- | 规格：空链保持单 provider 行为。
-- 背景：空链是默认配置；行为变化会让未配置用户受惊。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
fallbackEmptyChain :: Assertion
fallbackEmptyChain =
  newIORef (0 :: Int) >>= \calls ->
    testRuntime (downModel calls "alpha" "a1" "alpha down") [] Parallel >>= \base ->
      collectEvents base {runtimeProviderRetries = 2} (sampleInput []) >>= \events ->
        readIORef calls >>= \attempts ->
          sequence_
            [ attempts @?= 2,
              [() | Custom "provider.fallback" _ <- events] @?= [],
              eventType (last events) @?= "RUN_ERROR",
              [code | RunError _ (Just code) <- events] @?= ["PROVIDER_ERROR"]
            ]

-- | 规格：带 provider.fallback 的 journaled 运行可无分歧重放。
-- 背景：回退轨迹必须可重放；否则审计与排障失真。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
fallbackReplay :: Assertion
fallbackReplay =
  newMemoryJournal >>= \(journal, readEntries) ->
    newIORef (0 :: Int) >>= \calls ->
      testRuntime (downModel calls "alpha" "a1" "alpha down") [] Parallel >>= \base ->
        collectEvents
          base
            { runtimeJournal = Just journal,
              runtimeProviderRetries = 2,
              runtimeFallbacks = [answeringModel calls "beta" "b1" "second wind"]
            }
          (sampleInput [])
          >>= \events ->
            readEntries >>= \recorded ->
              replayEntries defaultHooks Nothing recorded >>= \report ->
                sequence_
                  [ assertBool "journal records provider.fallback" (any journaled recorded),
                    fmap reportDivergence report @?= Right Nothing,
                    fmap reportEvents report @?= Right (length (filter (not . transient) events))
                  ]
 where
  journaled (Entry _ _ _ (AgentEventEntry (Custom "provider.fallback" _))) = True
  journaled _ = False
  transient (Custom "provider.retry" _) = True
  transient (Custom "provider.fallback" _) = True
  transient _ = False

-- | 规格：fallback 环境变量默认空列表、解析逗号列表并拒绝空名。
-- 背景：配置解析是环境输入的守门员；空名会制造不可用 provider。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
fallbackConfigParse :: Assertion
fallbackConfigParse =
  sequence_
    [ fallbacksOf [] >>= (@?= []),
      fallbacksOf [("YUKI_FALLBACK_PROVIDERS", "zai,kimi-coding")] >>= (@?= ["zai", "kimi-coding"]),
      fallbacksOf [("YUKI_FALLBACK_PROVIDERS", " zai , kimi-coding ")] >>= (@?= ["zai", "kimi-coding"]),
      fallbacksOf [("YUKI_FALLBACK_PROVIDERS", "")] >>= (@?= []),
      rejected "zai,,kimi-coding",
      rejected ",",
      rejected "zai,"
    ]
 where
  fallbacksOf extra =
    either (assertFailure . Text.unpack) (pure . settingsFallbackProviders) (resolveSettings (env extra))
  env extra = Map.fromList (("DEEPSEEK_API_KEY", "secret") : extra)
  rejected value =
    either
      (const (pure ()))
      (const (assertFailure ("YUKI_FALLBACK_PROVIDERS=" <> value <> " should be rejected")))
      (resolveSettings (env [("YUKI_FALLBACK_PROVIDERS", value)]))

-- | 规格：全局配置渲染 fallback 名册。
-- 背景：名册是界面与文档的数据源；渲染错误会误导配置。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
fallbackConfigRender :: Assertion
fallbackConfigRender =
  either (assertFailure . Text.unpack) pure (resolveSettings env) >>= \settings ->
    parseMaybe names (renderGlobalConfig settings (globalThreadConfig settings))
      @?= Just (["zai", "kimi-coding"] :: [Text])
 where
  env = Map.fromList [("DEEPSEEK_API_KEY", "secret"), ("YUKI_FALLBACK_PROVIDERS", "zai,kimi-coding")]
  names = withObject "config" $ \fields ->
    fields .: "settings" >>= withObject "settings" (.: "fallbackProviders")

hooksTests :: TestTree
hooksTests =
  testGroup
    "agent hooks"
    [ testCase "mempty is neutral" identity,
      testCase "steering appends in order" ordering,
      testCase "beforeToolCall stops at the first denial" denial,
      testCase "afterToolCall chains" chaining
    ]

-- | 规格：
-- 背景：
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
identity :: Assertion
identity =
  (getSteeringMessages (mempty <> steering "x") (sampleInput []) >>= (@?= [ChatSystem "x"]))
    *> (getSteeringMessages (steering "x" <> mempty) (sampleInput []) >>= (@?= [ChatSystem "x"]))

-- | 规格：steering 注入按合并顺序追加。
-- 背景：顺序是用户指令次序的保证；颠倒会让指令错序。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
ordering :: Assertion
ordering =
  getSteeringMessages (steering "a" <> steering "b") (sampleInput [])
    >>= (@?= [ChatSystem "a", ChatSystem "b"])

-- | 规格：beforeToolCall 在首个拒绝处短路。
-- 背景：拒绝短路防止后续钩子执行危险工具。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
denial :: Assertion
denial =
  newIORef False >>= \called ->
    beforeToolCall (deny <> spy called) someCall
      >>= \result ->
        readIORef called >>= \wasCalled ->
          sequence_ [result @?= Left "no", wasCalled @?= False]

-- | 规格：afterToolCall 按序链式改写结果。
-- 背景：链式改写的顺序即结果叠加顺序；顺序错误会污染结果。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
chaining :: Assertion
chaining =
  afterToolCall (mark "a" <> mark "b") someCall (ToolOutcome "x" False False)
    >>= (@?= ToolOutcome "xab" False False)

steering :: Text -> AgentHooks
steering text = defaultHooks {getSteeringMessages = const (pure [ChatSystem text])}
deny :: AgentHooks
deny = defaultHooks {beforeToolCall = const (pure (Left "no"))}
spy :: IORef Bool -> AgentHooks
spy ref = defaultHooks {beforeToolCall = const (writeIORef ref True *> pure (Right ()))}
mark :: Text -> AgentHooks
mark suffix =
  defaultHooks
    { afterToolCall = \_ outcome ->
        pure outcome {toolOutcomeContent = toolOutcomeContent outcome <> suffix}
    }
someCall :: ModelToolCall
someCall = ModelToolCall "call" "echo" "{}"
machineTests :: TestTree
machineTests =
  testGroup
    "response machine"
    [ testCase "emits text lifecycle in order" textLifecycle,
      testCase "closes reasoning before text" reasoningThenText,
      testCase "rejects reasoning after final content" lateReasoning,
      testCase "announces a tool call once and completes it at close" toolLifecycle,
      testCase "rejects an incomplete tool call at close" incompleteTool,
      testCase "emits collected usage at close" usageClose,
      testCase "omits the usage event without usage" noUsage
    ]

-- | 规格：文本增量按 START/CONTENT/END 生命周期展开并在关闭时生成 AssistantTurn。
-- 背景：生命周期顺序是前端渲染的契约；错序会让 UI 卡在中间态。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
textLifecycle :: Assertion
textLifecycle =
  ( steps [ModelTextDelta "hello"] >>= \(state, events) ->
      closeModelTurn "m" "r" state >>= \closed ->
        Right (events, closed)
  )
    @?= Right
      ( [TextMessageStarted "m", TextMessageContent "m" "hello"],
        ([TextMessageEnded "m"], AssistantTurn "m" (Just "hello") Nothing [])
      )

-- | 规格：推理段先于文本段关闭。
-- 背景：关闭顺序错误会让模型回合结构错乱。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
reasoningThenText :: Assertion
reasoningThenText =
  fmap snd (steps [ModelReasoningDelta "r1", ModelTextDelta "t"])
    @?= Right
      [ ReasoningStarted "r",
        ReasoningMessageStarted "r",
        ReasoningMessageContent "r" "r1",
        ReasoningMessageEnded "r",
        ReasoningEnded "r",
        TextMessageStarted "m",
        TextMessageContent "m" "t"
      ]

-- | 规格：最终内容之后出现推理增量被拒绝。
-- 背景：推理必须在文本前；违序接收会破坏回合结构。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
lateReasoning :: Assertion
lateReasoning =
  assertLeft (steps [ModelTextDelta "t", ModelReasoningDelta "x"])

-- | 规格：工具调用宣告一次并在关闭时完成参数拼接。
-- 背景：工具生命周期事件驱动前端渲染；重复宣告会重复渲染。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
toolLifecycle :: Assertion
toolLifecycle =
  ( steps
      [ ModelToolCallDelta 0 (Just "c") (Just "f") "{\"a\":",
        ModelToolCallDelta 0 Nothing Nothing "1}"
      ]
      >>= \(state, events) ->
        closeModelTurn "m" "r" state >>= \closed ->
          Right (events, closed)
  )
    @?= Right
      ( [ ToolCallStarted "c" "f" (Just "m"),
          ToolCallArguments "c" "{\"a\":",
          ToolCallArguments "c" "1}"
        ],
        ([ToolCallEnded "c"], AssistantTurn "m" Nothing Nothing [ModelToolCall "c" "f" "{\"a\":1}"])
      )

-- | 规格：关闭时未完成的工具调用被拒绝。
-- 背景：残缺调用进入工具执行会以坏参数运行；拒绝优于猜测。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
incompleteTool :: Assertion
incompleteTool =
  assertLeft (fmap fst (steps [ModelToolCallDelta 0 (Just "c") Nothing "{}"]) >>= closeModelTurn "m" "r")

-- | 规格：关闭时聚合 usage 事件。
-- 背景：用量事件是计费闭环；缺失会让成本核算缺失。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
usageClose :: Assertion
usageClose =
  ( steps [ModelTextDelta "hi", ModelUsage (Usage (Just 10) (Just 5) (Just 3) (Just 7))]
      >>= \(state, events) ->
        closeModelTurn "m" "r" state >>= \closed ->
          Right (events, closed)
  )
    @?= Right
      ( [TextMessageStarted "m", TextMessageContent "m" "hi"],
        ( [ TextMessageEnded "m",
            Custom
              "usage"
              ( object
                  [ "promptTokens" .= (10 :: Int),
                    "completionTokens" .= (5 :: Int),
                    "cacheHitTokens" .= (3 :: Int),
                    "cacheMissTokens" .= (7 :: Int)
                  ]
              )
          ],
          AssistantTurn "m" (Just "hi") Nothing []
        )
      )

-- | 规格：无用量时关闭不产生 usage 事件。
-- 背景：空事件噪声会污染前端与重放。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
noUsage :: Assertion
noUsage =
  (steps [ModelTextDelta "hi"] >>= \(state, _) -> fst <$> closeModelTurn "m" "r" state)
    @?= Right [TextMessageEnded "m"]

steps :: [ModelEvent] -> Either ProviderFailure (ResponseState, [Event])
steps = foldl apply (Right (emptyResponse, []))
 where
  apply acc event =
    acc >>= \(state, events) ->
      (\(state', new) -> (state', events <> new)) <$> stepModelEvent "m" "r" state event
infixl 4 <$$>

(<$$>) :: (Functor outer, Functor inner) => (a -> b) -> outer (inner a) -> outer (inner b)
(<$$>) = fmap . fmap
