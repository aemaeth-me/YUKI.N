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

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Network.HTTP.Types
import Network.Wai.Test
import System.Directory (doesFileExist)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Types
import Yuki.N.Agent
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

storeRoundTrip :: Assertion
storeRoundTrip = withWorkDir $ \dir -> do
  store <- newTranscriptStore dir
  transcriptSave store "th/read:me" (ChatSystem "injected briefing" : transcriptHistory)
  transcriptLoad store "th/read:me" >>= (@?= Just transcriptHistory)
  doesFileExist (dir ++ "/transcripts/th-read-me.json") >>= assertBool "transcript file uses the sanitized name"
  reopened <- newTranscriptStore dir
  transcriptLoad reopened "th/read:me" >>= (@?= Just transcriptHistory)
  transcriptLoad store "absent" >>= (@?= Nothing)

wakePacketRoundTrip :: Assertion
wakePacketRoundTrip = withWorkDir $ \dir -> do
  let packet = ChatSystem (wakePacketMarker <> "\nContinue from the retained open loop.")
      retained = [ChatUser "before sleep", packet, ChatAssistant (AssistantTurn "awake" (Just "continued") Nothing [])]
  store <- newTranscriptStore dir
  transcriptSave store "sleeping-task" (ChatSystem "ephemeral instruction" : retained)
  reopened <- newTranscriptStore dir
  saved <- transcriptLoad reopened "sleeping-task"
  saved @?= Just retained
  fmap toAguiMessages saved
    @?= Just
      [ User (UserMessage "tr-0" (UserText "before sleep") Nothing),
        Developer (DeveloperMessage "tr-1" (wakePacketMarker <> "\nContinue from the retained open loop.") (Just "wake-packet")),
        Assistant (AssistantMessage "awake" (Just "continued") Nothing [])
      ]

threadIdPhysicalIsolation :: Assertion
threadIdPhysicalIsolation = withWorkDir $ \dir -> do
  transcripts <- newTranscriptStore dir
  configs <- newThreadConfigStore dir
  briefs <- newThreadStore dir
  let dotHistory = [ChatUser "dot transcript"]
      dashHistory = [ChatUser "dash transcript"]
      dotConfig = emptyThreadConfig {configSystemPrompt = Just "dot config"}
      dashConfig = emptyThreadConfig {configSystemPrompt = Just "dash config"}
      dotBrief = Episode "dot-run" "dot brief" 1
      dashBrief = Episode "dash-run" "dash brief" 2
  transcriptSave transcripts "a.b" dotHistory
  transcriptSave transcripts "a-b" dashHistory
  threadConfigWrite configs "a.b" dotConfig
  threadConfigWrite configs "a-b" dashConfig
  threadSaveEpisode briefs "a.b" dotBrief
  threadSaveEpisode briefs "a-b" dashBrief
  physical <-
    traverse
      doesFileExist
      [ dir ++ "/transcripts/a.b.json",
        dir ++ "/transcripts/a-b.json",
        dir ++ "/threads-config/a.b.json",
        dir ++ "/threads-config/a-b.json",
        dir ++ "/threads/a.b.json",
        dir ++ "/threads/a-b.json"
      ]
  reopenedTranscripts <- newTranscriptStore dir
  reopenedConfigs <- newThreadConfigStore dir
  reopenedBriefs <- newThreadStore dir
  dotTranscript <- transcriptLoad reopenedTranscripts "a.b"
  dashTranscript <- transcriptLoad reopenedTranscripts "a-b"
  storedDotConfig <- threadConfigRead reopenedConfigs "a.b"
  storedDashConfig <- threadConfigRead reopenedConfigs "a-b"
  storedDotBrief <- threadBrief reopenedBriefs "a.b"
  storedDashBrief <- threadBrief reopenedBriefs "a-b"
  assertBool "thread stores did not create six distinct physical files" (and physical)
  dotTranscript @?= Just dotHistory
  dashTranscript @?= Just dashHistory
  storedDotConfig @?= dotConfig
  storedDashConfig @?= dashConfig
  fmap briefRollingSummary storedDotBrief @?= Just "dot brief"
  fmap briefRollingSummary storedDashBrief @?= Just "dash brief"

transcriptOverHttp :: Assertion
transcriptOverHttp = do
  store <- newMemoryTranscriptStore
  transcriptSave store "thread" (ChatSystem "injected" : transcriptHistory)
  base <- testRuntime okModel [] Parallel
  let app = application Nothing (Just (newInspection Nothing Nothing Nothing (Just store))) Nothing Nothing (const (pure base))
  found <- runSession (request (httpGet ["threads", "thread", "transcript"])) app
  unknown <- runSession (request (httpGet ["threads", "unknown", "transcript"])) app
  simpleStatus found @?= status200
  simpleStatus unknown @?= status404
  either assertFailure (@?= ("thread", toAguiMessages transcriptHistory)) (decodeDocument (simpleBody found))
 where
  decodeDocument :: LazyByteString.ByteString -> Either String (Text, [Message])
  decodeDocument body =
    eitherDecode body
      >>= parseEither (withObject "transcript" (\fields -> (,) <$> fields .: "threadId" <*> fields .: "messages"))

rootOnlyWrites :: Assertion
rootOnlyWrites = withWorkDir $ \dir -> do
  store <- newTranscriptStore dir
  base <- testRuntime okModel [] Parallel
  let wired = base {runtimeHooks = transcriptHooks store}
  _ <- collectEvents wired (sampleInput [])
  _ <- collectEvents wired ((sampleInput []) {runId = "run-sub", runParentId = Just "run"})
  transcriptLoad store "thread" >>= (@?= Just root)
 where
  root = [ChatUser "hello", ChatAssistant (AssistantTurn "id-1" (Just "ok") Nothing [])]
