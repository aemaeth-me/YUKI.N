-- Golden journals：每核心场景一份录制入库的 journal，回放恒定绿。
-- 再生成：删除 test/golden/*.jsonl 后跑测试（golden 缺失即自动录制），
-- 或 GHCi 中 regenerateGoldens。录制锚在 withSandbox 临时 cwd，journal 内只出现
-- 相对路径，时间戳入库前剥除；determinism 测试（同场景录两遍逐条对账）锁住
-- journalNewId/注册表/队列的确定性，并把新鲜录制与已提交 golden 对账。
module Golden (goldenTests, regenerateGoldens) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (unless)
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

scenarioTests :: Scenario -> TestTree
scenarioTests scenario =
  testGroup
    (scenarioName scenario)
    [ testCase "the golden replays without divergence" (replayGolden scenario),
      testCase "two recordings agree with the golden modulo timestamps" (deterministicScenario scenario)
    ]

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
  exercise workDir = do
    tmp <- getTemporaryDirectory
    ident <- newId
    let journalDir = tmp ++ "/" ++ Text.unpack ident
    gate <- newEmptyMVar
    provider <- newFakeProvider (scenarioScript scenario)
    testWithApplication (pure (fakeProvider (gated gate provider))) (serve journalDir workDir gate provider)
  gated gate provider =
    maybe provider (const provider {providerGate = Just gate}) (scenarioSteer scenario)
  serve journalDir workDir gate provider port = do
    manager <- newManager defaultManagerSettings
    journal <- newFileJournal journalDir
    runs <- newRunRegistry
    artifacts <- newMemoryArtifactStore
    base <- wiredRuntime manager (Just artifacts) (e2eSettings port workDir (scenarioRetries scenario))
    let resolved =
          base
            { runtimeJournal = Just journal,
              runtimeRuns = Just runs,
              runtimeArtifactStore = Just artifacts,
              runtimeSplice = scenarioSplice scenario
            }
        app = application Nothing Nothing Nothing (Just runs) Nothing (const (pure resolved))
    drive app gate runs provider
    entries <- readJournal (journalFilePath journalDir) >>= either (assertFailure . Text.unpack) pure
    pure (fmap stripTime entries)
  drive app gate runs provider =
    maybe (plainDrive app) (steerDrive app gate runs provider) (scenarioSteer scenario)

plainDrive :: Application -> IO ()
plainDrive app = runSession postAgent app >>= decodeEvents >>= finished

steerDrive :: Application -> MVar () -> RunRegistry -> FakeProvider -> Text -> IO ()
steerDrive app gate runs provider text = do
  result <- newEmptyMVar
  _ <- forkIO (attempt result)
  requestedOk <- waitFor requested
  unless requestedOk (assertFailure "provider never received the first request")
  steered <- steerRun runs (runId agentInput) (ChatUser text)
  steered @?= True
  putMVar gate ()
  outcome <- timeout 10000000 (takeMVar result)
  maybe (assertFailure "steered run did not finish") settled outcome
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
replayGolden scenario = do
  entries <- ensureGolden scenario
  report <- replayFile defaultHooks (goldenPath scenario) Nothing
  scenarioCheck scenario entries
  either (assertFailure . Text.unpack) ((@?= Nothing) . reportDivergence) report

deterministicScenario :: Scenario -> Assertion
deterministicScenario scenario = do
  first <- record scenario
  second <- record scenario
  golden <- ensureGolden scenario
  first @?= second
  first @?= golden
