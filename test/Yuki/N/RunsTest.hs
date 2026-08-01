-- | 运行注册表、取消与 steer 测试
--
-- 覆盖：run 终止记账、HTTP 取消、浏览器控制取消、steer/follow-up 注入与队列、取消与 steer 的 journal 重放。
-- 边界：覆盖 Yuki.N.Runs 相关契约；steer/follow-up 队列 HTTP 语义。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.RunsTest
  ( terminationTests,
    failureCheckpoint,
    disconnectAccounts,
    cancelOverHttp,
    browserControlE2E,
    oncePerTerminal,
    cancelReplay,
    steeringTests,
    steerMidRun,
    lateSteerContinues,
    followUpContinues,
    emptyDrainSilent,
    steerEndpoint,
    followUpEndpoint,
    steerReplay,
    queueEntryJson
  )
where
import Control.Concurrent (forkIO)
import Control.Exception (IOException, throwIO, try)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (isJust)
import Network.Wai (Application, pathInfo, requestHeaders, requestMethod)
import System.Process (readProcessWithExitCode)
import Data.Functor (($>))
import Control.Concurrent.MVar
import Data.Aeson
import Data.Bool (bool)
import Data.ByteString ()
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Foldable (traverse_)
import Data.IORef
import Data.List ()
import Data.Text (Text)
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS ()
import Network.HTTP.Types
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Internal ()
import Network.Wai.Test
import System.Directory ()
import System.Exit (ExitCode (..))
import System.FilePath ()
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Runs
import Yuki.N.Agent
import Yuki.N.Model
import Yuki.N.Journal
import Yuki.N.Replay
import Yuki.N.Provider.OpenAI ()
import Yuki.N.Server
import Yuki.N.AGUI.Types ()
import Yuki.N.AGUI.Event
import Yuki.N.Background ()
import Yuki.N.TestSupport


terminationTests :: TestTree
terminationTests =
  testGroup
    "run termination"
    [ testCase "failure runs afterRun once with the checkpoint history" failureCheckpoint,
      testCase "a thrown emit still accounts the run and rethrows" disconnectAccounts,
      testCase "cancel announces run.cancelled, finishes the stream and accounts" cancelOverHttp,
      testCase "browser control module cancels a real backend stream over loopback" browserControlE2E,
      testCase "afterRun runs exactly once on success, failure and cancel" oncePerTerminal,
      testCase "replays a cancelled journaled run without divergence" cancelReplay
    ]
failAfterTool :: IORef Int -> Model
failAfterTool turns =
  fakeModel $ \_ emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next)) >>= \case
      1 -> emit (ModelToolCallDelta 0 (Just "call-echo") (Just "echo") "{\"x\":1}") $> ToolUse
      _ -> throwIO (ProviderFailure "upstream down")
-- | 规格：失败运行的 afterRun 恰好执行一次，且拿到含工具结果的完整历史。
-- 背景：afterRun 是持久化钩子；重复执行会重复写入，漏执行会丢失失败现场。该用例同时验证失败历史包含工具结果。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
failureCheckpoint :: Assertion
failureCheckpoint =
  newIORef (0 :: Int) >>= \turns ->
    newIORef [] >>= \histories ->
      testRuntime (failAfterTool turns) [echoTool] Sequential >>= \base ->
        collectEvents base {runtimeHooks = afterSpy histories} (sampleInput []) >>= \events ->
          readIORef histories >>= \captured ->
            sequence_
              [ eventType (last events) @?= "RUN_ERROR",
                assertBool "no RUN_FINISHED on failure" (all ((/= "RUN_FINISHED") . eventType) events),
                case captured of
                  [history] -> [content | ChatToolResult _ content <- history] @?= ["{\"x\":1}"]
                  other -> assertFailure ("afterRun must run exactly once, got " <> show (length other))
              ]
-- | 规格：流写回调抛错时异常逃逸出 runAgent，但运行仍被记账（afterRun 执行一次）。
-- 背景：客户端断连不应吞掉运行计数；否则泄漏的运行永远不落账。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
disconnectAccounts :: Assertion
disconnectAccounts =
  newIORef [] >>= \histories ->
    testRuntime okModel [] Parallel >>= \base ->
      (try (runAgent base {runtimeHooks = afterSpy histories} (sampleInput []) throwing) :: IO (Either IOException ()))
        >>= \outcome ->
          readIORef histories >>= \captured ->
            sequence_
              [ assertBool "the failure escapes runAgent" (either (const True) (const False) outcome),
                captured @?= [[ChatUser "hello"]]
              ]
  where
    throwing (TextMessageContent {}) = throwIO (userError "client disconnected")
    throwing _ = pure ()
-- | 规格：POST /agent/cancel 对幽灵 runId 返回 404、对活动 run 返回 202 并结束流，事件含 run.cancelled。
-- 背景：取消是长任务运维的关键路径；404/202 语义错误会让取消工具失效。该用例同时验证取消后不再出现 RUN_ERROR。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cancelOverHttp :: Assertion
cancelOverHttp =
  newEmptyMVar >>= \gate ->
    newRunRegistry >>= \runs ->
      newIORef [] >>= \chunks ->
        newIORef [] >>= \histories ->
          newEmptyMVar >>= \streamed ->
            testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel >>= \base ->
              let runtime = base {runtimeRuns = Just runs, runtimeHooks = afterSpy histories}
                  app = application Nothing Nothing Nothing (Just runs) (const (pure runtime))
               in forkIO (streamAgent app chunks streamed)
                    *> (waitUntil (started chunks) >>= bool (assertFailure "run never started") (pure ()))
                    *> runSession (srequest (cancelRequest "ghost")) app
                    >>= \ghost ->
                      runSession (srequest (cancelRequest "run")) app >>= \accepted ->
                        timeout 5000000 (takeMVar streamed) >>= \finished ->
                          runSession (srequest (cancelRequest "run")) app >>= \gone ->
                            decodeChunks chunks >>= \events ->
                              readIORef histories >>= \captured ->
                                sequence_
                                  [ simpleStatus ghost @?= status404,
                                    simpleStatus accepted @?= status202,
                                    simpleStatus gone @?= status404,
                                    assertBool "the stream ends after cancel" (isJust finished),
                                    length [() | Custom "run.cancelled" _ <- events] @?= 1,
                                    eventType (last events) @?= "RUN_FINISHED",
                                    assertBool "no RUN_ERROR on cancel" (all ((/= "RUN_ERROR") . eventType) events),
                                    captured @?= [[ChatUser "hello"]]
                                  ]
  where
    started ref =
      any (ByteString.isInfixOf "RUN_STARTED" . LazyByteString.toStrict . Builder.toLazyByteString) <$> readIORef ref
-- | 规格：前端浏览器控制模块（node 脚本）能通过回环 HTTP 取消真实后端流。
-- 背景：这是浏览器控件与后端取消协议的全链路验证；失败代表协议或服务端路由失配。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
browserControlE2E :: Assertion
browserControlE2E =
  newEmptyMVar >>= \gate ->
    newRunRegistry >>= \runs ->
      testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel >>= \base ->
        let runId = "browser-control-e2e"
            runtime = base {runtimeRuns = Just runs}
            app = application Nothing Nothing Nothing (Just runs) (const (pure runtime))
         in testWithApplication (pure app) $ \port ->
              timeout
                60000000
                ( readProcessWithExitCode
                    "node"
                    ["frontend/test/backend-control-e2e.mjs", "http://127.0.0.1:" <> show port <> "/"]
                    ""
                )
                >>= \result ->
                  cancelRun runs runId
                    *> maybe
                      (assertFailure "browser control test timed out")
                      verify
                      result
  where
    verify (ExitSuccess, _, _) = pure ()
    verify (code, stdout, stderr) =
      assertFailure
        ( "browser control test failed with "
            <> show code
            <> "\nstdout:\n"
            <> stdout
            <> "\nstderr:\n"
            <> stderr
        )
-- | 规格：afterRun 在成功、失败、取消三种终局下都恰好执行一次。
-- 背景：记账钩子必须三态一致；任一态多算或少算都会破坏运营数据。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
oncePerTerminal :: Assertion
oncePerTerminal =
  newIORef (0 :: Int) >>= \count ->
    let hooks = defaultHooks {afterRun = \_ _ -> modifyIORef' count (+ 1)}
     in succeed hooks *> failed hooks *> cancelled hooks *> (readIORef count >>= (@?= 3))
  where
    succeed hooks =
      testRuntime okModel [] Parallel
        >>= \base -> collectEvents base {runtimeHooks = hooks} (sampleInput [])
    failed hooks =
      testRuntime (fakeModel (\_ _ -> throwIO (ProviderFailure "down"))) [] Parallel
        >>= \base -> collectEvents base {runtimeHooks = hooks} (sampleInput [])
    cancelled hooks =
      newEmptyMVar >>= \gate ->
        newRunRegistry >>= \runs ->
          newIORef [] >>= \events ->
            newEmptyMVar >>= \done ->
              testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel >>= \base ->
                forkIO
                  ( runAgent base {runtimeRuns = Just runs, runtimeHooks = hooks} (sampleInput [])
                      (\event -> modifyIORef' events (event :))
                      *> putMVar done ()
                  )
                  *> (waitUntil (runStarted <$> readIORef events) >>= bool (assertFailure "run never started") (pure ()))
                  *> cancelRun runs "run"
                  *> (timeout 5000000 (takeMVar done) >>= maybe (assertFailure "cancel did not finish the run") pure)
-- | 规格：被取消的 journaled 运行可无分歧重放，journal 记录 run.cancelled。
-- 背景：重放是审计与排障的基础；取消场景若不可重放，故障排查会丢失重要分支。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cancelReplay :: Assertion
cancelReplay =
  newEmptyMVar >>= \gate ->
    newMemoryJournal >>= \(journal, readEntries) ->
      newRunRegistry >>= \runs ->
        newIORef [] >>= \events ->
          newEmptyMVar >>= \done ->
            testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel >>= \base ->
              forkIO
                ( runAgent
                    base {runtimeRuns = Just runs, runtimeJournal = Just journal}
                    (sampleInput [])
                    (\event -> modifyIORef' events (event :))
                    *> putMVar done ()
                )
                *> (waitUntil (runStarted <$> readIORef events) >>= bool (assertFailure "run never started") (pure ()))
                *> cancelRun runs "run"
                *> (timeout 5000000 (takeMVar done) >>= maybe (assertFailure "cancel did not finish the run") pure)
                *> readEntries
                >>= \recorded ->
                  replayEntries defaultHooks Nothing recorded >>= \report ->
                    sequence_
                      [ assertBool "journal records run.cancelled" (any journaled recorded),
                        fmap reportDivergence report @?= Right Nothing,
                        fmap reportEvents report @?= Right 4
                      ]
  where
    journaled (Entry _ _ _ (AgentEventEntry (Custom "run.cancelled" _))) = True
    journaled _ = False
runStarted :: [Event] -> Bool
runStarted = any (\case RunStarted {} -> True; _ -> False)
streamAgent :: Application -> IORef [Builder.Builder] -> MVar () -> IO ()
streamAgent app = streamInput app (sampleInput [])
steeringTests :: TestTree
steeringTests =
  testGroup
    "steering"
    [ testCase "a mid-run steer lands in the next model request and announces the injection" steerMidRun,
      testCase "a steer arriving during the final answer continues the run" lateSteerContinues,
      testCase "a follow-up arriving during the final answer starts the next turn" followUpContinues,
      testCase "an empty queue leaves history and events untouched" emptyDrainSilent,
      testCase "POST /agent/steer answers 202, 404 and 400" steerEndpoint,
      testCase "POST /agent/follow-up queues separately" followUpEndpoint,
      testCase "replays a journaled run with steering without divergence" steerReplay,
      testCase "steering and follow-up entries JSON round-trip" queueEntryJson
    ]
steerModel :: IORef Int -> IORef [ChatMessage] -> Model
steerModel turns captured =
  fakeModel $ \req emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next)) >>= \case
      1 -> emit (ModelToolCallDelta 0 (Just "call-gate") (Just "gate") "{}") $> ToolUse
      _ -> writeIORef captured (requestMessages req) *> emit (ModelTextDelta "done") $> Stop
gateTool :: MVar () -> BackendTool
gateTool gate =
  BackendTool (tool "gate") (\_ _ -> takeMVar gate $> ToolOutcome "tool done" False False)
steerPost :: Text -> Text -> SRequest
steerPost run text =
  SRequest
    { simpleRequest =
        defaultRequest
          { requestMethod = methodPost,
            pathInfo = ["agent", "steer"],
            requestHeaders = [(hContentType, "application/json")]
          },
      simpleRequestBody = encode (object ["runId" .= run, "text" .= text])
    }
followUpPost :: Text -> Text -> SRequest
followUpPost run text = (steerPost run text) {simpleRequest = waiRequest}
  where
    waiRequest = (simpleRequest (steerPost run text)) {pathInfo = ["agent", "follow-up"]}
-- | 规格：运行中注入的 steer 出现在下一轮请求末尾并发布 steering.inject 事件（step/count）。
-- 背景：方向修正必须落在模型下一轮可见的位置；注入丢失会让用户指令石沉大海。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
steerMidRun :: Assertion
steerMidRun =
  newEmptyMVar >>= \gate ->
    newRunRegistry >>= \runs ->
      newIORef (0 :: Int) >>= \turns ->
        newIORef [] >>= \captured ->
          newIORef [] >>= \chunks ->
            newEmptyMVar >>= \streamed ->
              testRuntime (steerModel turns captured) [gateTool gate] Sequential >>= \base ->
                let runtime = base {runtimeRuns = Just runs}
                    app = application Nothing Nothing Nothing (Just runs) (const (pure runtime))
                 in forkIO (streamAgent app chunks streamed)
                      *> (waitUntil (started chunks) >>= bool (assertFailure "run never started") (pure ()))
                      *> runSession (srequest (steerPost "ghost" "late")) app
                      >>= \ghost ->
                        runSession (srequest (steerPost "run" "hold on")) app
                          >>= \accepted ->
                            putMVar gate ()
                              *> (timeout 5000000 (takeMVar streamed) >>= maybe (assertFailure "steered run did not finish") pure)
                              *> decodeChunks chunks
                              >>= \events ->
                                readIORef captured >>= \messages ->
                                  sequence_
                                    [ simpleStatus ghost @?= status404,
                                      simpleStatus accepted @?= status202,
                                      takeEnd 1 messages @?= [ChatUser "hold on"],
                                      [content | ChatToolResult _ content <- messages] @?= ["tool done"],
                                      eventType (last events) @?= "RUN_FINISHED",
                                      injectValues events
                                    ]
  where
    started ref =
      any (ByteString.isInfixOf "RUN_STARTED" . LazyByteString.toStrict . Builder.toLazyByteString) <$> readIORef ref
    injectValues events =
      case [value | Custom "steering.inject" value <- events] of
        [value] ->
          sequence_
            [ parseMaybe (withObject "steer" (.: "step")) value @?= Just (2 :: Int),
              parseMaybe (withObject "steer" (.: "count")) value @?= Just (1 :: Int)
            ]
        other -> assertFailure ("expected one steering.inject, got " <> show (length other))
-- | 规格：最终回答阶段的 steer 让运行继续一轮并发布 steering.inject。
-- 背景：回答阶段是竞态高发窗口；steer 若被丢弃，用户以为已生效实为未生效。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
lateSteerContinues :: Assertion
lateSteerContinues = queuedAfterAnswer steerPost "steering.inject"
-- | 规格：最终回答阶段的 follow-up 排队进入下一轮并发布 followup.inject。
-- 背景：follow-up 与 steer 共用竞态窗口；排队语义错误会导致追问丢失或错序。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
followUpContinues :: Assertion
followUpContinues = queuedAfterAnswer followUpPost "followup.inject"
queuedAfterAnswer :: (Text -> Text -> SRequest) -> Text -> Assertion
queuedAfterAnswer post kind =
  newEmptyMVar >>= \entered ->
    newEmptyMVar >>= \release ->
      newRunRegistry >>= \runs ->
        newIORef (0 :: Int) >>= \turns ->
          newIORef [] >>= \captured ->
            newIORef [] >>= \chunks ->
              newEmptyMVar >>= \streamed ->
                testRuntime (answerGateModel entered release turns captured) [] Sequential >>= \base ->
                  let app = application Nothing Nothing Nothing (Just runs) (const (pure base {runtimeRuns = Just runs}))
                   in forkIO (streamAgent app chunks streamed)
                        *> (timeout 5000000 (takeMVar entered) >>= maybe (assertFailure "model answer never opened") pure)
                        *> runSession (srequest (post "run" "one more thing")) app
                        >>= \accepted ->
                          putMVar release ()
                            *> (timeout 5000000 (takeMVar streamed) >>= maybe (assertFailure "queued run did not finish") pure)
                            *> decodeChunks chunks
                            >>= \events ->
                              readIORef captured >>= \messages ->
                                sequence_
                                  [ simpleStatus accepted @?= status202,
                                    takeEnd 1 messages @?= [ChatUser "one more thing"],
                                    length [() | Custom name _ <- events, name == kind] @?= 1,
                                    eventType (last events) @?= "RUN_FINISHED"
                                  ]
answerGateModel :: MVar () -> MVar () -> IORef Int -> IORef [ChatMessage] -> Model
answerGateModel entered release turns captured =
  fakeModel $ \req emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next)) >>= \case
      1 -> emit (ModelTextDelta "first") *> putMVar entered () *> takeMVar release $> Stop
      _ -> writeIORef captured (requestMessages req) *> emit (ModelTextDelta "second") $> Stop
-- | 规格：空队列抽取不改变历史与事件流（无 steering.inject）。
-- 背景：空队列必须无副作用；否则每轮都会注入假事件污染重放。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
emptyDrainSilent :: Assertion
emptyDrainSilent =
  newRunRegistry >>= \runs ->
    newIORef (0 :: Int) >>= \turns ->
      newIORef [] >>= \captured ->
        testRuntime (steerModel turns captured) [staticTool "gate" "tool done"] Sequential >>= \base ->
          collectEvents base {runtimeRuns = Just runs} (sampleInput []) >>= \events ->
            readIORef captured >>= \messages ->
              sequence_
                [ assertBool "no steering.inject without a steer" (null [() | Custom "steering.inject" _ <- events]),
                  messages
                    @?= [ ChatUser "hello",
                          ChatAssistant (AssistantTurn "id-1" Nothing Nothing [ModelToolCall "call-gate" "gate" "{}"]),
                          ChatToolResult "call-gate" "tool done"
                        ]
                ]
-- | 规格：POST /agent/steer 对活动 run 202、未知 run 404、坏请求 400，并正确入队。
-- 背景：HTTP 状态码是调用方分支依据；状态码漂移会让前端取消/注入逻辑失灵。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
steerEndpoint :: Assertion
steerEndpoint =
  newRunRegistry >>= \runs ->
    testRuntime okModel [] Parallel >>= \base ->
      let app = application Nothing Nothing Nothing (Just runs) (const (pure base))
       in withRunRegistration runs "run" $
            runSession (srequest (steerPost "run" "hold on")) app >>= \accepted ->
              runSession (srequest (steerPost "ghost" "late")) app >>= \ghost ->
                runSession (srequest badSteer) app >>= \invalid ->
                  drainSteering runs "run" >>= \queued ->
                    sequence_
                      [ simpleStatus accepted @?= status202,
                        simpleStatus ghost @?= status404,
                        simpleStatus invalid @?= status400,
                        queued @?= [ChatUser "hold on"]
                      ]
  where
    badSteer =
      SRequest
        { simpleRequest =
            defaultRequest
              { requestMethod = methodPost,
                pathInfo = ["agent", "steer"],
                requestHeaders = [(hContentType, "application/json")]
              },
          simpleRequestBody = "{\"runId\":1}"
        }
-- | 规格：POST /agent/follow-up 与 steer 分队列存储，互不串扰。
-- 背景：两队列混用会导致 follow-up 被当作 steer 注入同一位置，语义错乱。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
followUpEndpoint :: Assertion
followUpEndpoint =
  newRunRegistry >>= \runs ->
    testRuntime okModel [] Parallel >>= \base ->
      let app = application Nothing Nothing Nothing (Just runs) (const (pure base))
       in withRunRegistration runs "run" $
            runSession (srequest (followUpPost "run" "later")) app >>= \accepted ->
              runSession (srequest (followUpPost "ghost" "late")) app >>= \ghost ->
                drainSteering runs "run" >>= \steering ->
                  drainFollowUps runs "run" >>= \followUps ->
                    sequence_
                      [ simpleStatus accepted @?= status202,
                        simpleStatus ghost @?= status404,
                        steering @?= [],
                        followUps @?= [ChatUser "later"]
                      ]
-- | 规格：带 steer 的 journaled 运行可无分歧重放，journal 记录 SteeringEntry 与注入事件。
-- 背景：重放必须复现用户注入；否则审计轨迹与真实执行不一致。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
steerReplay :: Assertion
steerReplay =
  newEmptyMVar >>= \started ->
    newEmptyMVar >>= \gate ->
      newRunRegistry >>= \runs ->
        newMemoryJournal >>= \(journal, readEntries) ->
          newIORef (0 :: Int) >>= \turns ->
            newIORef [] >>= \captured ->
              newIORef [] >>= \events ->
                newEmptyMVar >>= \done ->
                  testRuntime (steerModel turns captured) [blockingTool started gate] Sequential >>= \base ->
                    forkIO
                      ( runAgent base {runtimeRuns = Just runs, runtimeJournal = Just journal} (sampleInput [])
                          (\event -> modifyIORef' events (event :))
                          *> putMVar done ()
                      )
                      *> (timeout 5000000 (takeMVar started) >>= maybe (assertFailure "tool never ran") pure)
                      *> (steerRun runs "run" (ChatUser "hold on") >>= (@?= True))
                      *> putMVar gate ()
                      *> (timeout 5000000 (takeMVar done) >>= maybe (assertFailure "steered run did not finish") pure)
                      *> readEntries
                      >>= \recorded ->
                        reverse <$> readIORef events >>= \live ->
                          replayEntries defaultHooks Nothing recorded >>= \report ->
                            sequence_
                              [ assertBool "journal records the steering entry" (any journaled recorded),
                                assertBool "journal records the injection event" (any announced recorded),
                                fmap reportDivergence report @?= Right Nothing,
                                fmap reportEvents report @?= Right (length live)
                              ]
  where
    blockingTool started gate =
      BackendTool (tool "gate") (\_ _ -> (putMVar started () *> takeMVar gate) $> ToolOutcome "tool done" False False)
    journaled (Entry _ _ _ (SteeringEntry 2 [ChatUser "hold on"])) = True
    journaled _ = False
    announced (Entry _ _ _ (AgentEventEntry (Custom "steering.inject" _))) = True
    announced _ = False
-- | 规格：SteeringEntry 与 FollowUpEntry 的 JSON round-trip 稳定。
-- 背景：队列条目跨进程持久化（文件 journal）依赖稳定的 JSON 形状；漂移会让旧 journal 无法读取。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
queueEntryJson :: Assertion
queueEntryJson =
  traverse_ (\entry -> eitherDecode (encode entry) @?= Right entry) entries
  where
    entries =
      [ Entry 11 ["run"] (Just 1700000000) (SteeringEntry 2 [ChatUser "hold on"]),
        Entry 12 ["run"] (Just 1700000001) (FollowUpEntry 3 [ChatUser "later"])
      ]
