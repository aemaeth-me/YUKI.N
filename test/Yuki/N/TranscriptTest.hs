-- | transcript 存储测试
--
-- 覆盖：AG-UI 往返、文件过滤/净化/重启、Wake Packet 保留、线程名物理隔离、HTTP 服务与根运行写入。
-- 边界：覆盖 Yuki.N.Transcript；会话层见 SessionTest。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.TranscriptTest
  ( transcriptTests,
    aguiRoundTrip,
    storeRoundTrip,
    wakePacketRoundTrip,
    threadIdPhysicalIsolation,
    transcriptOverHttp,
    rootOnlyWrites,
  )
where

import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Exception ()
import Control.Monad ()
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Bool ()
import Data.ByteString ()
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable ()
import Data.Functor ()
import Data.IORef ()
import Data.List ()
import Data.Maybe ()
import Data.Text (Text)
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS ()
import Network.HTTP.Types
import Network.Wai ()
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test
import System.Directory (doesFileExist)
import System.Exit ()
import System.FilePath ()
import System.Process ()
import System.Timeout ()
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event ()
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Background ()
import Yuki.N.Context ()
import Yuki.N.Inspect
import Yuki.N.Memory
import Yuki.N.Memory.Working
import Yuki.N.Model
import Yuki.N.Server
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig
import Yuki.N.Transcript

transcriptTests :: TestTree
transcriptTests =
  testGroup
    "transcripts"
    [ testCase "maps chat messages to AG-UI messages and back" aguiRoundTrip,
      testCase "file store filters system, persists under a sanitized name and reloads" storeRoundTrip,
      testCase "file store preserves a Wake Packet across reload" wakePacketRoundTrip,
      testCase "a.b and a-b remain physically isolated across thread stores" threadIdPhysicalIsolation,
      testCase "serves the transcript as AG-UI messages, 404 when unknown" transcriptOverHttp,
      testCase "root runs persist the transcript, sub runs do not overwrite it" rootOnlyWrites
    ]

-- | 规格：chat 消息与 AG-UI 消息互转无损，system 消息被过滤。
-- 背景：互转是前端显示与内部历史的桥；丢失内容会让会话记录不完整。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
aguiRoundTrip :: Assertion
aguiRoundTrip =
  sequence_
    [ toAguiMessages transcriptHistory @?= agui,
      toChatMessages (toAguiMessages transcriptHistory) @?= Right transcriptHistory,
      toAguiMessages (ChatSystem "injected" : transcriptHistory) @?= agui
    ]
 where
  agui =
    [ User (UserMessage "tr-0" (UserText "hi") Nothing),
      Reasoning (ReasoningMessage "tr-1-reasoning" "thinking" Nothing),
      Assistant (AssistantMessage "m-1" (Just "working") Nothing [ToolCall "c-1" (FunctionCall "echo" "{\"x\":1}") Nothing]),
      Tool (ToolMessage "tr-2" "echoed" "c-1" Nothing Nothing),
      Assistant (AssistantMessage "m-2" (Just "done") Nothing [])
    ]

-- | 规格：transcript 文件存储过滤 system、净化文件名并跨重启读回。
-- 背景：transcript 是会话持久化基础；过滤与净化错误会污染记录。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
storeRoundTrip :: Assertion
storeRoundTrip =
  withWorkDir $ \dir ->
    newTranscriptStore dir >>= \store ->
      transcriptSave store "th/read:me" (ChatSystem "injected briefing" : transcriptHistory)
        *> (transcriptLoad store "th/read:me" >>= (@?= Just transcriptHistory))
        *> (doesFileExist (dir ++ "/transcripts/th-read-me.json") >>= assertBool "transcript file uses the sanitized name")
        *> (newTranscriptStore dir >>= \reopened -> transcriptLoad reopened "th/read:me" >>= (@?= Just transcriptHistory))
        *> (transcriptLoad store "absent" >>= (@?= Nothing))

-- | 规格：Wake Packet 以 developer 消息保存并在重启后恢复为 packet。
-- 背景：唤醒包是睡眠记忆的载体；丢失会让唤醒后的上下文断裂。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
wakePacketRoundTrip :: Assertion
wakePacketRoundTrip =
  withWorkDir $ \dir ->
    let packet = ChatSystem (wakePacketMarker <> "\nContinue from the retained open loop.")
        retained = [ChatUser "before sleep", packet, ChatAssistant (AssistantTurn "awake" (Just "continued") Nothing [])]
     in newTranscriptStore dir >>= \store ->
          transcriptSave store "sleeping-task" (ChatSystem "ephemeral instruction" : retained)
            *> newTranscriptStore dir
            >>= \reopened ->
              transcriptLoad reopened "sleeping-task" >>= \saved ->
                sequence_
                  [ saved @?= Just retained,
                    fmap toAguiMessages saved
                      @?= Just
                        [ User (UserMessage "tr-0" (UserText "before sleep") Nothing),
                          Developer (DeveloperMessage "tr-1" (wakePacketMarker <> "\nContinue from the retained open loop.") (Just "wake-packet")),
                          Assistant (AssistantMessage "awake" (Just "continued") Nothing [])
                        ]
                  ]

-- | 规格：a.b 与 a-b 在 transcript/config/thread 三存储中物理隔离。
-- 背景：线程名混淆是数据串扰源头；物理隔离失败会串会话。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
threadIdPhysicalIsolation :: Assertion
threadIdPhysicalIsolation =
  withWorkDir $ \dir ->
    newTranscriptStore dir >>= \transcripts ->
      newThreadConfigStore dir >>= \configs ->
        newThreadStore dir >>= \briefs ->
          let dotHistory = [ChatUser "dot transcript"]
              dashHistory = [ChatUser "dash transcript"]
              dotConfig = emptyThreadConfig {configSystemPrompt = Just "dot config"}
              dashConfig = emptyThreadConfig {configSystemPrompt = Just "dash config"}
              dotBrief = Episode "dot-run" "dot brief" 1
              dashBrief = Episode "dash-run" "dash brief" 2
           in transcriptSave transcripts "a.b" dotHistory
                *> transcriptSave transcripts "a-b" dashHistory
                *> threadConfigWrite configs "a.b" dotConfig
                *> threadConfigWrite configs "a-b" dashConfig
                *> threadSaveEpisode briefs "a.b" dotBrief
                *> threadSaveEpisode briefs "a-b" dashBrief
                *> traverse
                  doesFileExist
                  [ dir ++ "/transcripts/a.b.json",
                    dir ++ "/transcripts/a-b.json",
                    dir ++ "/threads-config/a.b.json",
                    dir ++ "/threads-config/a-b.json",
                    dir ++ "/threads/a.b.json",
                    dir ++ "/threads/a-b.json"
                  ]
                >>= \physical ->
                  newTranscriptStore dir >>= \reopenedTranscripts ->
                    newThreadConfigStore dir >>= \reopenedConfigs ->
                      newThreadStore dir >>= \reopenedBriefs ->
                        (,,,,,)
                          <$> transcriptLoad reopenedTranscripts "a.b"
                          <*> transcriptLoad reopenedTranscripts "a-b"
                          <*> threadConfigRead reopenedConfigs "a.b"
                          <*> threadConfigRead reopenedConfigs "a-b"
                          <*> threadBrief reopenedBriefs "a.b"
                          <*> threadBrief reopenedBriefs "a-b"
                          >>= \(dotTranscript, dashTranscript, storedDotConfig, storedDashConfig, storedDotBrief, storedDashBrief) ->
                            sequence_
                              [ assertBool "thread stores did not create six distinct physical files" (and physical),
                                dotTranscript @?= Just dotHistory,
                                dashTranscript @?= Just dashHistory,
                                storedDotConfig @?= dotConfig,
                                storedDashConfig @?= dashConfig,
                                fmap briefRollingSummary storedDotBrief @?= Just "dot brief",
                                fmap briefRollingSummary storedDashBrief @?= Just "dash brief"
                              ]

-- | 规格：GET /threads/:id/transcript 返回 AG-UI 消息，未知线程 404。
-- 背景：transcript 端点是历史回看的数据源；404 错误会误导前端。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
transcriptOverHttp :: Assertion
transcriptOverHttp =
  newMemoryTranscriptStore >>= \store ->
    transcriptSave store "thread" (ChatSystem "injected" : transcriptHistory)
      *> testRuntime okModel [] Parallel
      >>= \base ->
        let app = application Nothing (Just (newInspection Nothing Nothing Nothing (Just store))) Nothing Nothing (const (pure base))
         in runSession (request (httpGet ["threads", "thread", "transcript"])) app >>= \found ->
              runSession (request (httpGet ["threads", "unknown", "transcript"])) app >>= \unknown ->
                sequence_
                  [ simpleStatus found @?= status200,
                    simpleStatus unknown @?= status404,
                    either assertFailure (@?= ("thread", toAguiMessages transcriptHistory)) (decodeDocument (simpleBody found))
                  ]
 where
  decodeDocument :: LazyByteString.ByteString -> Either String (Text, [Message])
  decodeDocument body =
    eitherDecode body
      >>= parseEither (withObject "transcript" (\fields -> (,) <$> fields .: "threadId" <*> fields .: "messages"))

-- | 规格：根运行写 transcript，子运行不覆盖。
-- 背景：子代理运行写入根 transcript 会撕裂历史；根只写是因果边界。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
rootOnlyWrites :: Assertion
rootOnlyWrites =
  withWorkDir $ \dir ->
    newTranscriptStore dir >>= \store ->
      testRuntime okModel [] Parallel >>= \base ->
        let wired = base {runtimeHooks = transcriptHooks store}
         in collectEvents wired (sampleInput [])
              *> collectEvents wired ((sampleInput []) {runId = "run-sub", runParentId = Just "run"})
              *> (transcriptLoad store "thread" >>= (@?= Just root))
 where
  root = [ChatUser "hello", ChatAssistant (AssistantTurn "id-1" (Just "ok") Nothing [])]
