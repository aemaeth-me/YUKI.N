-- | journal 审计与存储测试
--
-- 覆盖：重放基线、篡改检测、wire 请求记录、Entry JSON 兼容、重启序列、尾部/中部损坏恢复、原子存储孤儿恢复、摘要与 trace 聚合。
-- 边界：覆盖 Yuki.N.Journal 与 Yuki.N.Replay 聚合。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.JournalTest
  ( auditTests,
    cleanReplay,
    tampered,
    wireRequest,
    entryTimeJson,
    journalRestartSequence,
    journalTailRecovery,
    journalMiddleCorruption,
    atomicStoreRecovery,
    summaryAggregates,
    traceAggregates,
  )
where

import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Exception ()
import Control.Monad ()
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Bool ()
import Data.ByteString ()
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor ()
import Data.IORef ()
import Data.List ()
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS ()
import Network.HTTP.Types ()
import Network.Wai ()
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test ()
import System.Directory ()
import System.Exit ()
import System.FilePath ()
import System.Process ()
import System.Timeout ()
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Background ()
import Yuki.N.Inspect
import Yuki.N.Journal
import Yuki.N.Memory
import Yuki.N.Model
import Yuki.N.Replay
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig
import Yuki.N.Transcript

auditTests :: TestTree
auditTests =
  testGroup
    "audit journal"
    [ testCase "replays a journaled run without divergence" cleanReplay,
      testCase "detects a tampered event" tampered,
      testCase "records the wire-level api.request entry" wireRequest,
      testCase "entry JSON round-trips with and without a timestamp" entryTimeJson,
      testCase "file journal resumes its global sequence across restarts" journalRestartSequence,
      testCase "recovers and reports an incomplete final journal line" journalTailRecovery,
      testCase "rejects corruption in the middle of a journal" journalMiddleCorruption,
      testCase "atomic stores survive orphaned crash-temporary files" atomicStoreRecovery,
      testCase "aggregates a mixed journal into a run summary" summaryAggregates,
      testCase "reduces noisy journal events into one causal run trace" traceAggregates
    ]

-- | 规格：正常 journaled 运行重放无分歧且事件数一致。
-- 背景：重放是全部审计功能的根基；基线分歧意味着记录或重放有一侧失真。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cleanReplay :: Assertion
cleanReplay =
  journaledRun >>= \(events, recorded) ->
    replayEntries defaultHooks Nothing recorded >>= \report ->
      sequence_
        [ fmap reportDivergence report @?= Right Nothing,
          fmap reportEvents report @?= Right (length events)
        ]

-- | 规格：篡改事件内容的重放被检测出分歧。
-- 背景：journal 的防篡改能力是信任前提；检测不到篡改则审计无意义。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
tampered :: Assertion
tampered =
  journaledRun >>= \(_, recorded) ->
    replayEntries defaultHooks Nothing (forge recorded) >>= \report ->
      assertBool "tampering is detected" (either (const False) (\r -> reportDivergence r /= Nothing) report)

forge :: [Entry] -> [Entry]
forge =
  fmap
    ( \entry -> case entryKind entry of
        AgentEventEntry (TextMessageContent messageId _) ->
          entry {entryKind = AgentEventEntry (TextMessageContent messageId "forged")}
        _ -> entry
    )

-- | 规格：journal 记录 wire 层 api.request 条目（模型名与消息数组）。
-- 背景：wire 请求记录用于成本审计与请求复现；缺失会让审计断链。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
wireRequest :: Assertion
wireRequest =
  journaledRun >>= \(_, recorded) ->
    case [value | Entry _ _ _ (ApiRequestEntry value) <- recorded] of
      [] -> assertFailure "missing api.request entry"
      (value : _) ->
        sequence_
          [ parseMaybe (withObject "api.request" (.: "model")) value @?= Just ("base-model" :: Text),
            parseMaybe (withObject "api.request" (.: "messages")) value
              @?= Just [object ["role" .= ("user" :: Text), "content" .= ("hello" :: Text)]]
          ]

-- | 规格：Entry 的 JSON 编码在带/不带时间戳以及旧版无时间戳格式间兼容。
-- 背景：跨版本 journal 文件必须可读；格式不兼容会让升级后历史记录报废。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
entryTimeJson :: Assertion
entryTimeJson =
  sequence_
    [ eitherDecode (encode stamped) @?= Right stamped,
      eitherDecode (encode unstamped) @?= Right unstamped,
      eitherDecode legacy @?= Right legacyEntry
    ]
 where
  stamped = Entry 7 ["run"] (Just 1700000000) (IdEntry "id-1")
  unstamped = Entry 8 ["run"] Nothing (IdEntry "id-2")
  legacyEntry = Entry 9 ["run"] Nothing (IdEntry "id-3")
  legacy =
    encode
      ( object
          [ "seq" .= (9 :: Int),
            "scope" .= (["run"] :: [Text]),
            "kind" .= ("id" :: Text),
            "value" .= ("id-3" :: Text)
          ]
      )

-- | 规格：文件 journal 跨重启续接全局 seq，不重复不跳号。
-- 背景：seq 是因果排序键；重启后重复或跳号会破坏重放顺序。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
journalRestartSequence :: Assertion
journalRestartSequence =
  withWorkDir $ \dir ->
    newFileJournal dir >>= \first ->
      recordMaybe (Just first) (IdEntry "before")
        *> newFileJournal dir
        >>= \second ->
          recordMaybe (Just second) (IdEntry "after")
            *> readJournal (journalFilePath dir)
            >>= either (assertFailure . Text.unpack) (\entries -> fmap entrySeq entries @?= [0, 1])

-- | 规格：不完整的末行被报告为警告且后续记录不受影响。
-- 背景：崩溃常留下截断尾行；能恢复并继续记录是持久化可靠性的底线。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
journalTailRecovery :: Assertion
journalTailRecovery =
  withWorkDir $ \dir ->
    let path = journalFilePath dir
        intact =
          [ Entry 4 ["run-a"] (Just 1) (IdEntry "a"),
            Entry 9 ["run-b"] (Just 2) (IdEntry "b")
          ]
     in LazyByteString.writeFile path (renderJournal intact <> "{\"seq\":10")
          *> readJournalFile path
          >>= \case
            Left failure -> assertFailure (Text.unpack failure)
            Right snapshot ->
              sequence_
                [ journalReadEntries snapshot @?= intact,
                  assertBool "truncated tail is reported" (maybe False (Text.isInfixOf "incomplete final line") (journalReadWarning snapshot))
                ]
                *> newFileJournal dir
                >>= \journal ->
                  recordMaybe (Just journal) (IdEntry "continued")
                    *> readJournal path
                    >>= either
                      (assertFailure . Text.unpack)
                      (\entries -> sequence_ [fmap entrySeq entries @?= [4, 9, 10], fmap entryKind entries @?= fmap entryKind intact <> [IdEntry "continued"]])
 where
  renderJournal = LazyByteString.concat . fmap ((<> "\n") . encode)

-- | 规格：中段损坏的 journal 行被定位并拒绝读取。
-- 背景：静默接受中段损坏会让重放基于不完整数据得出错误结论。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
journalMiddleCorruption :: Assertion
journalMiddleCorruption =
  withWorkDir $ \dir ->
    let path = journalFilePath dir
        entry = Entry 0 [] Nothing (IdEntry "ok")
     in LazyByteString.writeFile path (encode entry <> "\n{broken}\n" <> encode entry <> "\n")
          *> readJournalFile path
          >>= either
            (\failure -> assertBool "failure names the corrupt middle line" ("journal line 2" `Text.isInfixOf` failure))
            (const (assertFailure "middle corruption was silently accepted"))

-- | 规格：崩溃遗留的 .tmp-killed 孤儿文件不干扰 transcript/config/thread/journal 各存储重开。
-- 背景：原子写的中途崩溃是常态；孤儿文件若被视为数据会污染恢复结果。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
atomicStoreRecovery :: Assertion
atomicStoreRecovery =
  withWorkDir $ \dir ->
    newTranscriptStore dir >>= \transcripts ->
      newThreadConfigStore dir >>= \configs ->
        newThreadStore dir >>= \threads ->
          newFileJournal dir >>= \journal ->
            let config = emptyThreadConfig {configSystemPrompt = Just "kept"}
                history = [ChatUser "hello", ChatAssistant (AssistantTurn "answer" (Just "world") Nothing [])]
             in transcriptSave transcripts "thread" history
                  *> threadConfigWrite configs "thread" config
                  *> threadSaveEpisode threads "thread" (Episode "run-1" "memory" 1700000000)
                  *> recordMaybe (Just journal) (IdEntry "before-crash")
                  *> traverse_
                    (\path -> TextIO.writeFile path "{partial")
                    [ dir ++ "/transcripts/thread.json.tmp-killed",
                      dir ++ "/threads-config/thread.json.tmp-killed",
                      dir ++ "/threads/thread.json.tmp-killed"
                    ]
                  *> LazyByteString.appendFile (journalFilePath dir) "{\"seq\":"
                  *> newTranscriptStore dir
                  >>= \reopenedTranscripts ->
                    newThreadConfigStore dir >>= \reopenedConfigs ->
                      newThreadStore dir >>= \reopenedThreads ->
                        newFileJournal dir >>= \reopenedJournal ->
                          recordMaybe (Just reopenedJournal) (IdEntry "after-crash")
                            *> transcriptLoad reopenedTranscripts "thread"
                            >>= \savedHistory ->
                              threadConfigRead reopenedConfigs "thread" >>= \savedConfig ->
                                threadBrief reopenedThreads "thread" >>= \savedBrief ->
                                  readJournal (journalFilePath dir)
                                    >>= either
                                      (assertFailure . Text.unpack)
                                      ( \entries ->
                                          sequence_
                                            [ savedHistory @?= Just history,
                                              savedConfig @?= config,
                                              fmap briefRollingSummary savedBrief @?= Just "memory",
                                              fmap entrySeq entries @?= [0, 1],
                                              fmap entryKind entries @?= [IdEntry "before-crash", IdEntry "after-crash"]
                                            ]
                                      )

-- | 规格：混合 journal 聚合为 run 摘要（回合数、工具数、用量、时间窗、状态）。
-- 背景：摘要端点是运维视图的数据源；聚合错误会误导成本与状态判断。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
summaryAggregates :: Assertion
summaryAggregates =
  sequence_
    [ runSummary "run-a" mixed @?= Just expectedA,
      fmap summaryStatus (runSummary "run-b" mixed) @?= Just "open",
      runSummary "run-c" mixed @?= Nothing
    ]
 where
  inputA = (sampleInput []) {runId = "run-a"}
  inputB = (sampleInput []) {runId = "run-b"}
  settings = RunSettings 8 Parallel "" 1 Nothing Nothing Nothing
  usageEvent' prompt completion hit =
    Custom
      "usage"
      ( object
          [ "promptTokens" .= prompt,
            "completionTokens" .= completion,
            "cacheHitTokens" .= hit
          ]
      )
  mixed =
    [ Entry 1 ["run-a"] (Just 100) (RunBegin inputA settings),
      Entry 2 ["run-a"] (Just 110) (ModelRequestEntry (ModelRequest [] [])),
      Entry 3 ["run-a"] (Just 120) (ApiRequestEntry (object ["model" .= ("m" :: Text)])),
      Entry 4 ["run-a"] (Just 130) (AgentEventEntry (usageEvent' (10 :: Int) (5 :: Int) (3 :: Int))),
      Entry 5 ["run-a"] (Just 140) (ToolCallEntry "c1" "echo" "{}" (ToolOutcome "ok" False False)),
      Entry 6 ["run-a", "memory"] (Just 150) (ModelRequestEntry (ModelRequest [] [])),
      Entry 7 ["run-a"] (Just 160) (AgentEventEntry (Custom "usage" (object ["promptTokens" .= (2 :: Int)]))),
      Entry 8 ["run-a"] (Just 170) (AgentEventEntry (RunFinished "thread" "run-a" Nothing)),
      Entry 9 ["run-b"] Nothing (RunBegin inputB settings)
    ]
  expectedA =
    RunSummary
      "run-a"
      "thread"
      8
      2
      1
      3
      1
      (UsageSum 12 5 3)
      1
      "finished"
      1
      8
      (Just 100)
      (Just 170)

-- | 规格：噪音事件被归约为单一因果 trace（assistant/tool/terminal 步骤与工件引用）。
-- 背景：trace 是排障的时间线视图；去噪错误会让根因分析迷失。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
traceAggregates :: Assertion
traceAggregates =
  case runTrace "run-trace" entries of
    Nothing -> assertFailure "trace was not built"
    Just trace ->
      let traceRows = traceSteps trace
       in sequence_
            [ traceStatus trace @?= "finished",
              length (filter ((== "assistant") . traceStepKind) traceRows) @?= 1,
              length (filter ((== "tool") . traceStepKind) traceRows) @?= 1,
              length (filter ((== "terminal") . traceStepKind) traceRows) @?= 1,
              fmap traceStepArtifactIds (listToMaybe (filter ((== "tool") . traceStepKind) traceRows))
                @?= Just ["art-abc123"]
            ]
 where
  input = (sampleInput []) {runId = "run-trace"}
  settings = RunSettings 8 Parallel "" 1 Nothing Nothing Nothing
  entries =
    [ Entry 1 ["run-trace"] (Just 100) (RunBegin input settings),
      Entry 2 ["run-trace"] (Just 101) (ModelRequestEntry (ModelRequest [] [])),
      Entry 3 ["run-trace"] (Just 102) (AgentEventEntry (ReasoningStarted "reason-1")),
      Entry 4 ["run-trace"] (Just 103) (AgentEventEntry (ReasoningEnded "reason-1")),
      Entry 5 ["run-trace"] (Just 104) (AgentEventEntry (TextMessageContent "message-1" "answer")),
      Entry 6 ["run-trace"] (Just 105) (AgentEventEntry (TextMessageContent "message-1" "answer")),
      Entry 7 ["run-trace"] (Just 106) (ToolCallEntry "call-1" "inspect" "{\"path\":\"x\"}" (ToolOutcome "[artifact art-abc123]" False False)),
      Entry 8 ["run-trace"] (Just 107) (AgentEventEntry (RunFinished "thread" "run-trace" Nothing)),
      Entry 9 ["run-trace"] (Just 108) (AgentEventEntry (RunFinished "thread" "run-trace" Nothing))
    ]

journaledRun :: IO ([Event], [Entry])
journaledRun =
  newMemoryJournal >>= \(journal, readEntries) ->
    testRuntime echoModel [echoTool] Parallel >>= \base ->
      collectEvents base {runtimeJournal = Just journal} (sampleInput [])
        >>= \events -> readEntries >>= \recorded -> pure (events, recorded)
