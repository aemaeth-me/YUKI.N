module Yuki.N.TranscriptTest
  ( transcriptTests,
    aguiRoundTrip,
    storeRoundTrip,
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
import Yuki.N.Model
import Yuki.N.Server
import Yuki.N.Sessions (serviceTranscripts)
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig
import Yuki.N.Transcript

transcriptTests :: TestTree
transcriptTests =
  testGroup
    "transcripts"
    [ testCase "maps chat messages to AG-UI messages and back" aguiRoundTrip,
      testCase "file store filters system, persists under a sanitized name and reloads" storeRoundTrip,
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

threadIdPhysicalIsolation :: Assertion
threadIdPhysicalIsolation = withWorkDir $ \dir -> do
  transcripts <- newTranscriptStore dir
  configs <- newThreadConfigStore dir
  let dotHistory = [ChatUser "dot transcript"]
      dashHistory = [ChatUser "dash transcript"]
      dotConfig = emptyThreadConfig {configSystemPrompt = Just "dot config"}
      dashConfig = emptyThreadConfig {configSystemPrompt = Just "dash config"}
  transcriptSave transcripts "a.b" dotHistory
  transcriptSave transcripts "a-b" dashHistory
  threadConfigWrite configs "a.b" dotConfig
  threadConfigWrite configs "a-b" dashConfig
  physical <-
    traverse
      doesFileExist
      [ dir ++ "/transcripts/a.b.json",
        dir ++ "/transcripts/a-b.json",
        dir ++ "/threads-config/a.b.json",
        dir ++ "/threads-config/a-b.json"
      ]
  reopenedTranscripts <- newTranscriptStore dir
  reopenedConfigs <- newThreadConfigStore dir
  dotTranscript <- transcriptLoad reopenedTranscripts "a.b"
  dashTranscript <- transcriptLoad reopenedTranscripts "a-b"
  storedDotConfig <- threadConfigRead reopenedConfigs "a.b"
  storedDashConfig <- threadConfigRead reopenedConfigs "a-b"
  assertBool "thread stores did not create four distinct physical files" (and physical)
  dotTranscript @?= Just dotHistory
  dashTranscript @?= Just dashHistory
  storedDotConfig @?= dotConfig
  storedDashConfig @?= dashConfig

transcriptOverHttp :: Assertion
transcriptOverHttp = withWorkDir $ \dir -> do
  service <- sessionServiceAt dir (const (pure ()))
  transcriptSave (serviceTranscripts service) "thread" (ChatSystem "injected" : transcriptHistory)
  base <- testRuntime okModel [] Parallel
  let app = application Nothing (Just service) Nothing Nothing (const (pure base))
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
