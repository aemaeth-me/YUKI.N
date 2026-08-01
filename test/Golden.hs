-- Golden journals：每核心场景一份录制入库的 journal，CI 回放恒定绿。
--
-- 再生成：删除 test/golden/*.jsonl 后跑 cabal test（golden 缺失即自动录制，
-- 不落败），或 GHCi 中 regenerateGoldens。录制锚在 withSandbox 临时 cwd，
-- journal 内只出现相对路径，时间戳入库前剥除，故 golden 与机器、目录无关；
-- determinism 测试（同场景录两遍逐条对账）锁住 journalNewId/注册表/队列的
-- 确定性，并把新鲜录制与已提交 golden 对账。
--
-- 变更记录：
--   - 2026-08-01: 每个场景的 replay/deterministic 拆为具名测试声明并建立回归文档基线。
module Golden (goldenTests, regenerateGoldens) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeException, throwIO, try)
import Data.Aeson
import Data.Aeson.Types (Pair)
import Data.Bool (bool)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import E2E
  ( FakeProvider (..),
    Reply (..),
    agentInput,
    decodeEvents,
    e2eSettings,
    fakeProvider,
    finishChunk,
    newFakeProvider,
    postAgent,
    roleChunk,
    textChunk,
    toolCallArgs,
    toolCallChunk,
    wiredRuntime,
    withSandbox,
  )
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.HTTP.Types (status429)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test (runSession)
import System.Directory (createDirectoryIfMissing, doesFileExist, getTemporaryDirectory)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event (Event (..))
import Yuki.N.AGUI.Types (runId)
import Yuki.N.Agent
import Yuki.N.Artifact (SpliceConfig (..), isArtifactStub, newMemoryArtifactStore)
import Yuki.N.Journal
import Yuki.N.Model
import Yuki.N.Replay
import Yuki.N.Runs (RunRegistry, newRunRegistry, steerRun)
import Yuki.N.Server (application)

goldenTests :: TestTree
goldenTests = testGroup "golden journals" (fmap scenarioTests scenarios)

-- 场景树的每个实际测试都指向具名声明（replayOf/deterministicOf 按场景分派），
-- 保证 12 个测试各有一份带文档的具名实现。
scenarioTests :: Scenario -> TestTree
scenarioTests scenario =
  testGroup
    (scenarioName scenario)
    [ testCase "the golden replays without divergence" (replayOf scenario),
      testCase "two recordings agree with the golden modulo timestamps" (deterministicOf scenario)
    ]

replayOf :: Scenario -> Assertion
replayOf scenario = case scenarioName scenario of
  "plain" -> replayPlain
  "tool" -> replayTool
  "retry" -> replayRetry
  "splice" -> replaySplice
  "steer" -> replaySteer
  "shell" -> replayShell
  other -> error ("unknown golden scenario: " <> other)

deterministicOf :: Scenario -> Assertion
deterministicOf scenario = case scenarioName scenario of
  "plain" -> deterministicPlain
  "tool" -> deterministicTool
  "retry" -> deterministicRetry
  "splice" -> deterministicSplice
  "steer" -> deterministicSteer
  "shell" -> deterministicShell
  other -> error ("unknown golden scenario: " <> other)

-- | 规格：plain 场景的已提交 golden journal 回放无分歧且满足场景断言。
-- 背景：plain 是最小端到端基线；回放分歧意味着事件管线相对已承诺基线漂移。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
replayPlain :: Assertion
replayPlain = replayGolden plain

-- | 规格：tool 场景（fs_list 工具往返）的 golden 回放无分歧。
-- 背景：工具往返是最常用路径；其结果留存（含沙箱 listing）是 golden 的核心锚点。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
replayTool :: Assertion
replayTool = replayGolden tool

-- | 规格：retry 场景（两次 429 后成功）的 golden 回放无分歧。
-- 背景：重试事件的 journal 形态决定回放是否复现真实执行；分歧会让审计失真。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
replayRetry :: Assertion
replayRetry = replayGolden retry

-- | 规格：splice 场景（context splice 触发）的 golden 回放无分歧。
-- 背景：splice 改写上下文并落 stub；回放必须复现同一 stub 视图。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
replaySplice :: Assertion
replaySplice = replayGolden splice

-- | 规格：steer 场景（运行中注入 steer）的 golden 回放无分歧。
-- 背景：steer 注入的时序与落点（step 2）是回放一致性的关键。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
replaySteer :: Assertion
replaySteer = replayGolden steer

-- | 规格：shell 场景（shell 工具执行）的 golden 回放无分歧。
-- 背景：shell 输出流与工具调用条目必须稳定入 journal；波动会破坏回放可比性。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
replayShell :: Assertion
replayShell = replayGolden shell

-- | 规格：plain 场景两次录制逐条对账且与已提交 golden 一致。
-- 背景：确定性锁住 journalNewId/注册表/队列；不确定会让审计与回放不可比。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
deterministicPlain :: Assertion
deterministicPlain = deterministicScenario plain

-- | 规格：tool 场景两次录制逐条对账且与已提交 golden 一致。
-- 背景：工具调用 id 与结果内容必须稳定复现，否则回放基线失效。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
deterministicTool :: Assertion
deterministicTool = deterministicScenario tool

-- | 规格：retry 场景两次录制逐条对账且与已提交 golden 一致。
-- 背景：重试次数与事件顺序的确定性决定回放事件数。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
deterministicRetry :: Assertion
deterministicRetry = deterministicScenario retry

-- | 规格：splice 场景两次录制逐条对账且与已提交 golden 一致。
-- 背景：stub 化边界与工件 id 必须确定，否则 golden 不可比。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
deterministicSplice :: Assertion
deterministicSplice = deterministicScenario splice

-- | 规格：steer 场景两次录制逐条对账且与已提交 golden 一致。
-- 背景：steer 落点依赖闸门时序；录制必须稳定复现 step 2 注入。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
deterministicSteer :: Assertion
deterministicSteer = deterministicScenario steer

-- | 规格：shell 场景两次录制逐条对账且与已提交 golden 一致。
-- 背景：shell 输出与条目序列的确定性是 golden 可比性的前提。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
deterministicShell :: Assertion
deterministicShell = deterministicScenario shell

-- 手动再生成全部 golden（等价于删文件后跑测试）
regenerateGoldens :: IO ()
regenerateGoldens = traverse_ (\scenario -> record scenario >>= writeGolden scenario) scenarios

data Scenario = Scenario
  { scenarioName :: String,
    scenarioRetries :: Int,
    scenarioSplice :: Maybe SpliceConfig,
    scenarioSteer :: Maybe Text,
    scenarioScript :: [Reply],
    scenarioCheck :: [Entry] -> Assertion
  }

scenarios :: [Scenario]
scenarios = [plain, tool, retry, splice, steer, shell]

plain :: Scenario
plain =
  Scenario
    { scenarioName = "plain",
      scenarioRetries = 1,
      scenarioSplice = Nothing,
      scenarioSteer = Nothing,
      scenarioScript = [Sse [roleChunk, textChunk "golden answer", finishChunk "stop"]],
      scenarioCheck = \entries ->
        sequence_
          [ hasKind "model.finish stop" (\case ModelFinishEntry Stop -> True; _ -> False) entries,
            hasKind "RUN_FINISHED" (\case AgentEventEntry (RunFinished {}) -> True; _ -> False) entries
          ]
    }

tool :: Scenario
tool =
  Scenario
    { scenarioName = "tool",
      scenarioRetries = 1,
      scenarioSplice = Nothing,
      scenarioSteer = Nothing,
      scenarioScript =
        [ Sse [roleChunk, toolCallChunk "call-fs" "fs_list", toolCallArgs "{\"path\":\".\"}", finishChunk "tool_calls"],
          Sse [roleChunk, textChunk "listed", finishChunk "stop"]
        ],
      scenarioCheck = hasKind "the fs_list outcome carrying the sandbox listing" listed
    }
 where
  listed (ToolCallEntry "call-fs" "fs_list" _ outcome) =
    "marker.txt" `Text.isInfixOf` toolOutcomeContent outcome
  listed _ = False

retry :: Scenario
retry =
  Scenario
    { scenarioName = "retry",
      scenarioRetries = 3,
      scenarioSplice = Nothing,
      scenarioSteer = Nothing,
      scenarioScript =
        [ Failure status429 "{\"error\":{\"message\":\"slow down\"}}",
          Failure status429 "{\"error\":{\"message\":\"slow down\"}}",
          Sse [roleChunk, textChunk "recovered", finishChunk "stop"]
        ],
      scenarioCheck = \entries ->
        length [() | Entry _ _ _ (AgentEventEntry (Custom "provider.retry" _)) <- entries] @?= 2
    }

splice :: Scenario
splice =
  Scenario
    { scenarioName = "splice",
      scenarioRetries = 1,
      scenarioSplice = Just (SpliceConfig 300 0),
      scenarioSteer = Nothing,
      scenarioScript =
        [ Sse [roleChunk, toolCallChunk "call-fs" "fs_write", toolCallArgs writeArgs, finishChunk "tool_calls"],
          Sse [roleChunk, textChunk "written", finishChunk "stop"]
        ],
      scenarioCheck = \entries ->
        sequence_
          [ hasKind "context.splice" (\case AgentEventEntry (Custom "context.splice" _) -> True; _ -> False) entries,
            hasKind "a stubbed model request" stubbed entries
          ]
    }
 where
  writeArgs = jsonArgs ["path" .= ("big.txt" :: Text), "content" .= bigWrite]
  stubbed (ModelRequestEntry request) = any stubbedMessage (requestMessages request)
  stubbed _ = False
  stubbedMessage (ChatToolResult _ content) = isArtifactStub content
  stubbedMessage _ = False

bigWrite :: Text
bigWrite = Text.replicate 30 "golden-line\n"

steer :: Scenario
steer =
  Scenario
    { scenarioName = "steer",
      scenarioRetries = 1,
      scenarioSplice = Nothing,
      scenarioSteer = Just "hold on",
      scenarioScript =
        [ Sse [roleChunk, toolCallChunk "call-fs" "fs_list", toolCallArgs "{\"path\":\".\"}", finishChunk "tool_calls"],
          Sse [roleChunk, textChunk "steered", finishChunk "stop"]
        ],
      scenarioCheck = \entries ->
        sequence_
          [ hasKind "the steering entry at step two" (== SteeringEntry 2 [ChatUser "hold on"]) entries,
            hasKind "steering.inject" (\case AgentEventEntry (Custom "steering.inject" _) -> True; _ -> False) entries
          ]
    }

shell :: Scenario
shell =
  Scenario
    { scenarioName = "shell",
      scenarioRetries = 1,
      scenarioSplice = Nothing,
      scenarioSteer = Nothing,
      scenarioScript =
        [ Sse [roleChunk, toolCallChunk "call-sh" "shell", toolCallArgs shellArgs, finishChunk "tool_calls"],
          Sse [roleChunk, textChunk "ran", finishChunk "stop"]
        ],
      scenarioCheck = \entries ->
        sequence_
          [ hasKind "shell.output" (\case AgentEventEntry (Custom "shell.output" _) -> True; _ -> False) entries,
            hasKind "the shell tool call" (\case ToolCallEntry _ "shell" _ _ -> True; _ -> False) entries
          ]
    }
 where
  shellArgs = jsonArgs ["command" .= ("printf 'golden shell output'" :: Text)]

jsonArgs :: [Pair] -> Text
jsonArgs = TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode . object

hasKind :: String -> (EntryKind -> Bool) -> [Entry] -> Assertion
hasKind label match entries =
  assertBool ("journal carries " <> label) (any (match . entryKind) entries)

-- 录制：假 provider 脚本 + 真 file journal（临时目录），steer 场景以闸阻塞
-- 首个 provider 应答，插话落定后放行，保证 SteeringEntry 恒落于 step 2
record :: Scenario -> IO [Entry]
record scenario = withSandbox exercise
 where
  exercise workDir =
    getTemporaryDirectory >>= \tmp ->
      newId >>= \ident ->
        let journalDir = tmp ++ "/" ++ Text.unpack ident
         in newEmptyMVar >>= \gate ->
              newFakeProvider (scenarioScript scenario) >>= \provider ->
                testWithApplication (pure (fakeProvider (gated gate provider))) (serve journalDir workDir gate provider)
  gated gate provider =
    maybe provider (const provider {providerGate = Just gate}) (scenarioSteer scenario)
  serve journalDir workDir gate provider port =
    newManager defaultManagerSettings >>= \manager ->
      newFileJournal journalDir >>= \journal ->
        newRunRegistry >>= \runs ->
          newMemoryArtifactStore >>= \artifacts ->
            wiredRuntime manager (Just artifacts) (e2eSettings port workDir (scenarioRetries scenario)) >>= \base ->
              let resolved =
                    base
                      { runtimeJournal = Just journal,
                        runtimeRuns = Just runs,
                        runtimeArtifactStore = Just artifacts,
                        runtimeSplice = scenarioSplice scenario
                      }
                  app = application Nothing Nothing Nothing (Just runs) (const (pure resolved))
               in drive app gate runs provider
                    *> ( readJournal (journalFilePath journalDir)
                           >>= either (assertFailure . Text.unpack) (pure . fmap stripTime)
                       )
  drive app gate runs provider =
    maybe (plainDrive app) (steerDrive app gate runs provider) (scenarioSteer scenario)

plainDrive :: Application -> IO ()
plainDrive app = runSession postAgent app >>= decodeEvents >>= finished

steerDrive :: Application -> MVar () -> RunRegistry -> FakeProvider -> Text -> IO ()
steerDrive app gate runs provider text =
  newEmptyMVar >>= \result ->
    forkIO (attempt result)
      *> (waitFor requested >>= bool (assertFailure "provider never received the first request") (pure ()))
      *> (steerRun runs (runId agentInput) (ChatUser text) >>= (@?= True))
      *> putMVar gate ()
      *> (timeout 10000000 (takeMVar result) >>= maybe (assertFailure "steered run did not finish") settled)
 where
  attempt :: MVar (Either SomeException [Event]) -> IO ()
  attempt result = try (runSession postAgent app >>= decodeEvents) >>= putMVar result
  requested = not . null <$> readIORef (providerBodies provider)
  settled = either throwIO finished

finished :: [Event] -> IO ()
finished events =
  case reverse events of
    (RunFinished {} : _) -> pure ()
    _ -> assertFailure "a recorded run must end with RUN_FINISHED"

waitFor :: IO Bool -> IO Bool
waitFor probe = go (200 :: Int)
 where
  go 0 = pure False
  go n = probe >>= bool (threadDelay 25000 *> go (n - 1)) (pure True)

stripTime :: Entry -> Entry
stripTime entry = entry {entryTime = Nothing}

goldenDir :: FilePath
goldenDir = "test/golden"

goldenPath :: Scenario -> FilePath
goldenPath scenario = goldenDir ++ "/" ++ scenarioName scenario ++ ".jsonl"

writeGolden :: Scenario -> [Entry] -> IO ()
writeGolden scenario entries =
  createDirectoryIfMissing True goldenDir
    *> LazyByteString.writeFile (goldenPath scenario) (LazyByteString.concat (fmap ((<> "\n") . encode) entries))

readGolden :: Scenario -> IO [Entry]
readGolden scenario =
  readJournal (goldenPath scenario) >>= either (assertFailure . Text.unpack) pure

ensureGolden :: Scenario -> IO [Entry]
ensureGolden scenario =
  doesFileExist (goldenPath scenario)
    >>= bool (record scenario >>= \entries -> entries <$ writeGolden scenario entries) (readGolden scenario)

replayGolden :: Scenario -> Assertion
replayGolden scenario =
  ensureGolden scenario >>= \entries ->
    replayFile defaultHooks (goldenPath scenario) Nothing >>= \report ->
      scenarioCheck scenario entries
        *> either (assertFailure . Text.unpack) ((@?= Nothing) . reportDivergence) report

deterministicScenario :: Scenario -> Assertion
deterministicScenario scenario =
  record scenario >>= \first ->
    record scenario >>= \second ->
      ensureGolden scenario >>= \golden ->
        sequence_
          [ first @?= second,
            first @?= golden
          ]
