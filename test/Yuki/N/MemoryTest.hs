-- | 记忆（briefing/watcher/thread）测试
--
-- 覆盖：增量观察、episode 落盘、故障隔离、钩子组合、briefing 结构/幂等/上限/跨运行、注入事件与各种重放形态。
-- 边界：覆盖 Yuki.N.Memory 记忆钩子；事实库见 FactsTest。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.MemoryTest
  ( memoryTests,
    injectionEvents,
    briefingIdempotent,
    briefingStructure,
    briefingCap,
    briefingAcrossRuns,
    briefingReplay,
    briefingReplayWithStores,
    multiRunMemoryReplay,
    storesUnchangedAfterReplay,
    replayFileGateForMemory,
    increments,
    episodeOnDisk,
    failureIsolation,
    composition
  )
where
import Control.Exception (throwIO)
import Data.Aeson.Types (parseMaybe)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import Data.Functor (($>))
import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Monad ()
import Data.Aeson
import Data.Bool ()
import Data.ByteString ()
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Foldable ()
import Data.IORef
import Data.List ()
import Data.Maybe ()
import Data.Text ()
import qualified Data.Text as Text
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS ()
import Network.HTTP.Types ()
import Network.Wai ()
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test ()
import System.Exit ()
import System.FilePath ()
import System.Process ()
import System.Timeout ()
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Memory
import Yuki.N.Facts
import Yuki.N.Agent
import Yuki.N.Model
import Yuki.N.Journal
import Yuki.N.Replay
import Yuki.N.Transcript
import Yuki.N.ThreadConfig ()
import Yuki.N.AGUI.Types
import Yuki.N.AGUI.Event
import Yuki.N.Background ()
import Yuki.N.Provider.OpenAI ()
import Yuki.N.TestSupport


memoryTests :: TestTree
memoryTests =
  testGroup
    "memory"
    [ testCase "watches only the increment of a thread" increments,
      testCase "persists an episode when the run finishes" episodeOnDisk,
      testCase "watcher failure never breaks the run" failureIsolation,
      testCase "composes with business afterRun hooks" composition,
      testCase "injects the brief once when transformed twice" briefingIdempotent,
      testCase "renders the briefing at the head with marker, summary, episodes and as-of time" briefingStructure,
      testCase "caps the rolling summary at 2000 characters" briefingCap,
      testCase "carries the brief into the next run exactly once" briefingAcrossRuns,
      testCase "announces context injections as custom events" injectionEvents,
      testCase "replays a journaled run with briefing without divergence" briefingReplay,
      testCase "replays a memory-enabled journal via replayWithStores without divergence" briefingReplayWithStores,
      testCase "multi-run memory replay resumes after the prior run boundary" multiRunMemoryReplay,
      testCase "replayWithStores leaves the live ThreadStore unchanged" storesUnchangedAfterReplay,
      testCase "replayFile gates journals with memory-injected requests" replayFileGateForMemory
    ]
-- | 规格：记忆注入以 context.inject 自定义事件宣告并携带 brief 内容。
-- 背景：前端与重放依赖注入事件对齐；缺失会让前端展示与真实上下文不一致。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
injectionEvents :: Assertion
injectionEvents =
  newMemoryThreadStore >>= \store ->
    newMemoryFactStore >>= \facts ->
      newMemoryState >>= \state ->
        testRuntime (fakeModel (\_ emit -> emit (ModelTextDelta "ok") $> Stop)) [] Sequential >>= \base ->
          threadSaveEpisode store "thread" (Episode "run-0" "did things" 1700000000)
            *> collectEvents base {runtimeHooks = memoryHooks rollingWatcher store facts Nothing state} (sampleInput [])
            >>= \events ->
              case [text | Custom "context.inject" value <- events, Just text <- [injectedText value]] of
                [text] -> assertBool "injection carries the brief" (Text.isInfixOf "did things" text)
                other -> assertFailure ("expected one context.inject, got " <> show (length other))
  where
    injectedText = parseMaybe (withObject "inject" (.: "content"))
rollingWatcher :: Model
rollingWatcher = fakeModel (\_ emit -> emit (ModelTextDelta "rolling memo") $> Stop)
markedMessage :: ChatMessage -> Bool
markedMessage (ChatSystem text) = briefingMarker `Text.isInfixOf` text
markedMessage _ = False
briefingCount :: [ChatMessage] -> Int
briefingCount = length . filter markedMessage
-- | 规格：同一线程连续两次 transformContext 只注入一次 briefing。
-- 背景：幂等性防止每轮重复注入；重复 briefing 会污染模型输入与重放。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
briefingIdempotent :: Assertion
briefingIdempotent =
  newMemoryThreadStore >>= \store ->
    threadSaveEpisode store "thread" (Episode "run-0" "did things" 1700000000)
      *> newMemoryFactStore
      >>= \facts -> newMemoryState >>= exercise store facts
  where
    exercise store facts state =
      transformContext hooks input [ChatUser "hi"]
        >>= \once ->
          transformContext hooks input once >>= \twice ->
            sequence_ [briefingCount twice @?= 1, twice @?= once]
      where
        hooks = memoryHooks rollingWatcher store facts Nothing state
        input = sampleInput []
-- | 规格：briefing 位于头部，按 marker/摘要/episodes/as-of 时间戳的顺序组织。
-- 背景：briefing 是模型看到的历史索引；结构错乱会误导模型对时间的理解。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
briefingStructure :: Assertion
briefingStructure =
  newMemoryThreadStore >>= \store ->
    threadSaveEpisode store "thread" (Episode "run-0" "did things" 1700000000)
      *> threadSaveEpisode store "thread" (Episode "run-1" "shipped" 1700000100)
      *> newMemoryFactStore
      >>= \facts ->
        newMemoryState
        >>= \state ->
          ( transformContext (memoryHooks rollingWatcher store facts Nothing state) (sampleInput []) [ChatUser "hi"]
              >>= verify
          )
            *> (newMemoryThreadStore >>= empty facts)
  where
    verify (ChatSystem text : rest) =
      sequence_
        [ rest @?= [ChatUser "hi"],
          init (Text.lines text)
            @?= [ briefingMarker,
                  "summary: shipped",
                  "episode 2023-11-14T22:13:20Z: did things",
                  "episode 2023-11-14T22:15:00Z: shipped"
                ],
          assertBool "an as-of line closes the briefing" ("as of 2023-11-14T22:15:00Z" == last (Text.lines text))
        ]
    verify other = assertFailure ("briefing missing at head: " <> show (length other) <> " messages")
    empty facts store =
      newMemoryState >>= \state ->
        transformContext (memoryHooks rollingWatcher store facts Nothing state) (sampleInput []) [ChatUser "hi"]
          >>= (@?= [ChatUser "hi"])
-- | 规格：滚动摘要被裁剪到 2000 字符上限。
-- 背景：超长摘要会挤占上下文预算；裁剪必须发生在注入前。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
briefingCap :: Assertion
briefingCap =
  newMemoryThreadStore >>= \store ->
    threadSaveEpisode store "thread" (Episode "run-0" (Text.replicate 3000 "x") 1700000000)
      *> newMemoryFactStore
      >>= \facts ->
        newMemoryState
        >>= \state ->
          transformContext (memoryHooks rollingWatcher store facts Nothing state) (sampleInput []) [ChatUser "hi"]
          >>= \case
            (ChatSystem text : _) -> Text.lines text !! 1 @?= "summary: " <> Text.replicate 2000 "x"
            _ -> assertFailure "briefing missing at head"
-- | 规格：briefing 只带进下一轮运行一次，跨运行可见摘要与 episode。
-- 背景：跨运行记忆是核心价值；多算或少算一次都会造成记忆重复或遗漏。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
briefingAcrossRuns :: Assertion
briefingAcrossRuns =
  newMemoryThreadStore >>= \store ->
    newMemoryFactStore >>= \facts ->
      newMemoryState >>= \state ->
        newIORef [] >>= \captured ->
          testRuntime (captureModel captured) [echoTool] Sequential >>= \base ->
            collectEvents base {runtimeHooks = hooks state store facts} (input "run-1")
              *> collectEvents base {runtimeHooks = hooks state store facts} (input "run-2")
              *> (reverse <$> readIORef captured)
              >>= verify
  where
    hooks state store facts = memoryHooks rollingWatcher store facts Nothing state
    input runId = (sampleInput [tool "echo"]) {runId = runId}
    verify [first, second, third, fourth] =
      sequence_
        [ briefingCount first @?= 0,
          briefingCount second @?= 0,
          briefingCount third @?= 1,
          briefingCount fourth @?= 1,
          case third of
            (ChatSystem text : _) ->
              assertBool "briefing carries the rolling summary" (Text.isInfixOf "rolling memo" text)
            _ -> assertFailure "briefing is not at the head"
        ]
    verify other = assertFailure ("unexpected request count: " <> show (length other))
captureModel :: IORef [[ChatMessage]] -> Model
captureModel captured =
  fakeModel $ \request emit ->
    modifyIORef' captured (requestMessages request :)
      *> case lastMessage request of
        Just (ChatToolResult {}) -> emit (ModelTextDelta "done") $> Stop
        _ -> emit (ModelToolCallDelta 0 (Just "call-echo") (Just "echo") "{\"x\":1}") $> ToolUse
-- | 规格：带 briefing 的 journaled 运行可无分歧重放，请求中携带 briefing。
-- 背景：重放必须复现同样的记忆注入；否则重放与真实执行分歧。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
briefingReplay :: Assertion
briefingReplay =
  newMemoryThreadStore >>= \store ->
    threadSaveEpisode store "thread" (Episode "run-0" "earlier" 1700000000)
      *> newMemoryFactStore
      >>= \facts ->
        newMemoryJournal
        >>= \(journal, readEntries) ->
          newMemoryState >>= \state ->
            testRuntime mainModel [] Parallel >>= \base ->
              collectEvents base {runtimeHooks = hooks state store facts, runtimeJournal = Just journal} (sampleInput [])
                >>= \events ->
                  readEntries >>= \recorded ->
                    newMemoryThreadStore >>= \replayStore ->
                      threadSaveEpisode replayStore "thread" (Episode "run-0" "earlier" 1700000000)
                        *> newMemoryState
                        >>= \replayState ->
                          replayEntries (hooks replayState replayStore facts) Nothing recorded >>= \report ->
                            sequence_
                              [ fmap reportDivergence report @?= Right Nothing,
                                fmap reportEvents report @?= Right (length events),
                                assertBool "journaled request carries the briefing" (any briefed recorded)
                              ]
  where
    hooks state store facts = memoryHooks rollingWatcher store facts Nothing state
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)
    briefed (Entry _ _ _ (ModelRequestEntry request)) = any markedMessage (requestMessages request)
    briefed _ = False
-- | 规格：replayWithStores 在 store 支持下无分歧重放记忆运行。
-- 背景：带 store 的重放是记忆可排障性的关键路径。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
briefingReplayWithStores :: Assertion
briefingReplayWithStores =
  newMemoryThreadStore >>= \store ->
    threadSaveEpisode store "thread" (Episode "run-0" "earlier" 1700000000)
      *> newMemoryThreadStore
      >>= \replayStore ->
        threadSaveEpisode replayStore "thread" (Episode "run-0" "earlier" 1700000000)
          *> newMemoryFactStore
          >>= \facts ->
            newMemoryJournal
            >>= \(journal, readEntries) ->
              newMemoryState >>= \state ->
                testRuntime mainModel [] Parallel >>= \base ->
                  collectEvents base {runtimeHooks = hooks journal state store facts, runtimeJournal = Just journal} (sampleInput [])
                    >>= \events ->
                      readEntries >>= \recorded ->
                        replayWithStores replayStore facts Nothing recorded >>= \report ->
                        sequence_
                          [ fmap reportDivergence report @?= Right Nothing,
                            fmap reportEvents report @?= Right (length events)
                          ]
  where
    hooks journal state store facts = memoryHooks rollingWatcher store facts (Just journal) state
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)
-- | 规格：多运行记忆重放越过先前运行边界，只对增量用户消息产生正确注入。
-- 背景：跨运行边界是记忆重放最易出错的点；越界注入会让重放失真。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
multiRunMemoryReplay :: Assertion
multiRunMemoryReplay =
  newMemoryThreadStore >>= \store ->
    newMemoryFactStore >>= \facts ->
      newMemoryJournal >>= \(journal, readEntries) ->
        newMemoryState >>= \state ->
          testRuntime mainModel [] Parallel >>= \base ->
            let hooks = memoryHooks rollingWatcher store facts (Just journal) state
                runtime = base {runtimeHooks = hooks, runtimeJournal = Just journal}
             in collectEvents runtime firstInput
                  *> collectEvents runtime secondInput
                  *> readEntries
                  >>= \recorded ->
                    replayWithStores store facts (Just "memory-run-2") recorded >>= \report ->
                      sequence_
                        [ fmap reportDivergence report @?= Right Nothing,
                          assertBool "second watcher skips the prior user message" (any correctDelta recorded)
                        ]
  where
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "answer") $> Stop)
    firstInput =
      (sampleInput [])
        { runId = "memory-run-1",
          runMessages = [User (UserMessage "user-1" (UserText "one") Nothing)]
        }
    secondInput =
      (sampleInput [])
        { runId = "memory-run-2",
          runMessages =
            toAguiMessages
              [ ChatUser "one",
                ChatAssistant (AssistantTurn "answer-1" (Just "answer") Nothing []),
                ChatUser "two"
              ]
        }
    correctDelta (Entry _ ["memory-run-2", "memory"] _ (ModelRequestEntry request)) =
      case [text | ChatUser text <- requestMessages request] of
        [prompt] -> Text.isInfixOf "user: two" prompt && not (Text.isInfixOf "user: one" prompt)
        _ -> False
    correctDelta _ = False
-- | 规格：replayWithStores 不改变存活 ThreadStore 与 FactStore。
-- 背景：重放必须只读；副作用会把真实记忆污染成重放产物。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
storesUnchangedAfterReplay :: Assertion
storesUnchangedAfterReplay =
  newMemoryThreadStore >>= \store ->
    threadSaveEpisode store "thread" (Episode "run-0" "earlier" 1700000000)
      *> newMemoryThreadStore
      >>= \replayStore ->
        threadSaveEpisode replayStore "thread" (Episode "run-0" "earlier" 1700000000)
          *> newMemoryFactStore
          >>= \facts ->
            newMemoryJournal
            >>= \(journal, readEntries) ->
              newMemoryState >>= \state ->
                testRuntime mainModel [] Parallel >>= \base ->
                  collectEvents base {runtimeHooks = hooks journal state store facts, runtimeJournal = Just journal} (sampleInput [])
                    *> readEntries
                    >>= \recorded ->
                      threadBrief replayStore "thread" >>= \briefBefore ->
                        factList facts >>= \factsBefore ->
                          replayWithStores replayStore facts Nothing recorded >>= \report ->
                            threadBrief replayStore "thread" >>= \briefAfter ->
                              factList facts >>= \factsAfter ->
                                sequence_
                                  [ fmap reportDivergence report @?= Right Nothing,
                                    briefAfter @?= briefBefore,
                                    factsAfter @?= factsBefore
                                  ]
  where
    hooks journal state store facts = memoryHooks rollingWatcher store facts (Just journal) state
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)
-- | 规格：replayFile 拒绝含记忆注入请求的 journal，并给出 memory-injected 说明。
-- 背景：无 store 时重放记忆注入会得到错误上下文；显式拒绝优于静默失真。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
replayFileGateForMemory :: Assertion
replayFileGateForMemory =
  newMemoryThreadStore >>= \store ->
    threadSaveEpisode store "thread" (Episode "run-0" "earlier" 1700000000)
      *> newMemoryFactStore
      >>= \facts ->
        newMemoryJournal >>= \(journal, readEntries) ->
          newMemoryState >>= \state ->
            testRuntime mainModel [] Parallel >>= \base ->
              collectEvents base {runtimeHooks = hooks state store facts, runtimeJournal = Just journal} (sampleInput [])
                *> readEntries
                >>= \recorded ->
                  getTemporaryDirectory >>= \tmp ->
                    newId >>= \identifier ->
                      let dir = tmp ++ "/" ++ Text.unpack identifier
                       in createDirectoryIfMissing True dir
                            *> LazyByteString.writeFile (journalFilePath dir) (LazyByteString.concat (fmap ((<> "\n") . encode) recorded))
                            *> ( replayFile defaultHooks (journalFilePath dir) Nothing >>= \case
                                  Left msg ->
                                    assertBool "gate message mentions memory" ("memory-injected" `Text.isInfixOf` msg)
                                  Right _ -> assertFailure "expected gate rejection, got success"
                               )
  where
    hooks state store facts = memoryHooks rollingWatcher store facts Nothing state
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)
-- | 规格：滚动 watcher 只观察线程增量，跳过已见消息并携带上一轮摘要。
-- 背景：记忆增量语义是『不重复注入』的核心；重复注入会让模型分心且 journal 膨胀。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
increments :: Assertion
increments =
  newIORef [] >>= \requests ->
    newIORef (0 :: Int) >>= \calls ->
      newMemoryThreadStore >>= \store ->
        newMemoryFactStore >>= \facts ->
          newMemoryState >>= \states ->
            exercise (memoryHooks (spy requests calls) store facts Nothing states)
              *> (readIORef requests >>= verify)
  where
    input = sampleInput []
    first = [ChatUser "first"]
    second = first <> [ChatAssistant (AssistantTurn "m1" (Just "answer") Nothing []), ChatUser "second"]
    exercise hooks =
      (transformContext hooks input first >>= (@?= first))
        *> (transformContext hooks input second >>= (@?= second))
    spy requests calls =
      fakeModel $ \request emit ->
        modifyIORef' requests (bodies request :)
          *> atomicModifyIORef' calls (\count -> (count + 1, count + 1))
          >>= \count -> emit (ModelTextDelta ("memo-" <> Text.pack (show count))) $> Stop
    bodies = Text.intercalate "\n" . fmap userTextOf . requestMessages
    userTextOf (ChatUser text) = text
    userTextOf _ = ""
    verify captured =
      case reverse captured of
        [one, two] ->
          sequence_
            [ assertBool "first watch sees the first message" (Text.isInfixOf "first" one),
              assertBool "second watch sees only the increment" (Text.isInfixOf "second" two),
              assertBool "second watch skips seen messages" (not (Text.isInfixOf "first" two)),
              assertBool "second watch carries the previous summary" (Text.isInfixOf "memo-1" two)
            ]
        other -> assertFailure ("unexpected watcher calls: " <> show (length other))
-- | 规格：运行结束时线程 episode 持久化到磁盘 store。
-- 背景：记忆跨进程重启必须存活；仅内存保留等于没有记忆。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
episodeOnDisk :: Assertion
episodeOnDisk =
  getTemporaryDirectory >>= \tmp ->
    newId >>= \identifier ->
      newThreadStore (tmp ++ "/" ++ Text.unpack identifier) >>= exercise
  where
    exercise store =
      newMemoryFactStore >>= \facts ->
        newMemoryState >>= \states ->
          testRuntime mainModel [] Parallel >>= \base ->
            collectEvents base {runtimeHooks = memoryHooks watcher store facts Nothing states} (sampleInput [])
            >>= \events ->
              threadBrief store "thread"
                >>= \case
                  Just (ThreadBrief "rolling: greeted" [Episode "run" "rolling: greeted" _]) ->
                    eventType (last events) @?= "RUN_FINISHED"
                  other -> assertFailure ("unexpected thread brief: " <> show other)
    watcher = fakeModel (\_ emit -> emit (ModelTextDelta "rolling: greeted") $> Stop)
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi there") $> Stop)
-- | 规格：watcher 抛错不中断主运行，运行正常完成且不写 episode。
-- 背景：记忆是附属能力；watcher 故障拖垮主运行是不可接受的耦合。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
failureIsolation :: Assertion
failureIsolation =
  newMemoryThreadStore >>= \store ->
    newMemoryFactStore >>= \facts ->
      newMemoryState >>= \states ->
        newIORef [] >>= \seen ->
          testRuntime (capture seen) [] Parallel >>= \base ->
            collectEvents base {runtimeHooks = memoryHooks broken store facts Nothing states} (sampleInput [])
            >>= \events ->
              (,) <$> readIORef seen <*> threadBrief store "thread"
                >>= \(requests, stored) ->
                  sequence_
                    [ eventType (last events) @?= "RUN_FINISHED",
                      requests @?= [[ChatUser "hello"]],
                      stored @?= Nothing
                    ]
  where
    broken = fakeModel (\_ _ -> throwIO (ProviderFailure "watcher down"))
    capture seen =
      fakeModel $ \request emit ->
        modifyIORef' seen (requestMessages request :) *> emit (ModelTextDelta "fine") $> Stop
-- | 规格：记忆 afterRun 与业务 afterRun 钩子可组合且各自执行。
-- 背景：钩子组合是扩展点；互相覆盖会静默丢失业务逻辑或记忆。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
composition :: Assertion
composition =
  newMemoryThreadStore >>= \store ->
    newMemoryFactStore >>= \facts ->
      newMemoryState >>= \states ->
        newIORef False >>= \called ->
          testRuntime mainModel [] Parallel >>= \base ->
            collectEvents
              base {runtimeHooks = memoryHooks watcher store facts Nothing states <> business called}
            (sampleInput [])
            *> ((,) <$> readIORef called <*> threadBrief store "thread")
            >>= \(wasCalled, stored) ->
              sequence_
                [ wasCalled @?= True,
                  assertBool "memory afterRun stored an episode" (maybe False (not . null . briefEpisodes) stored)
                ]
  where
    watcher = fakeModel (\_ emit -> emit (ModelTextDelta "memo") $> Stop)
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)
    business called = defaultHooks {afterRun = \_ _ -> writeIORef called True}
