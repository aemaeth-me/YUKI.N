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

import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.List (find)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Inspect
import Yuki.N.Journal
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

cleanReplay :: Assertion
cleanReplay = do
  (events, recorded) <- journaledRun
  report <- replayEntries defaultHooks Nothing recorded
  fmap reportDivergence report @?= Right Nothing
  fmap reportEvents report @?= Right (length events)

tampered :: Assertion
tampered = do
  (_, recorded) <- journaledRun
  report <- replayEntries defaultHooks Nothing (forge recorded)
  assertBool "tampering is detected" (either (const False) (isJust . reportDivergence) report)

forge :: [Entry] -> [Entry]
forge =
  fmap
    ( \entry -> case entryKind entry of
        AgentEventEntry (TextMessageContent messageId _) ->
          entry {entryKind = AgentEventEntry (TextMessageContent messageId "forged")}
        _ -> entry
    )

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

entryTimeJson :: Assertion
entryTimeJson =
  sequence_
    [ eitherDecode (encode stamped) @?= Right stamped,
      eitherDecode (encode unstamped) @?= Right unstamped,
      eitherDecode unstampedJson @?= Right unstampedEntry
    ]
 where
  stamped = Entry 7 ["run"] (Just 1700000000) (IdEntry "id-1")
  unstamped = Entry 8 ["run"] Nothing (IdEntry "id-2")
  unstampedEntry = Entry 9 ["run"] Nothing (IdEntry "id-3")
  unstampedJson =
    encode
      ( object
          [ "seq" .= (9 :: Int),
            "scope" .= (["run"] :: [Text]),
            "kind" .= ("id" :: Text),
            "value" .= ("id-3" :: Text)
          ]
      )

journalRestartSequence :: Assertion
journalRestartSequence = withWorkDir $ \dir -> do
  first <- newFileJournal dir
  recordMaybe (Just first) (IdEntry "before")
  second <- newFileJournal dir
  recordMaybe (Just second) (IdEntry "after")
  entries <- readJournal (journalFilePath dir) >>= either (assertFailure . Text.unpack) pure
  fmap entrySeq entries @?= [0, 1]

journalTailRecovery :: Assertion
journalTailRecovery = silenceStderr $ withWorkDir $ \dir -> do
  let path = journalFilePath dir
      intact =
        [ Entry 4 ["run-a"] (Just 1) (IdEntry "a"),
          Entry 9 ["run-b"] (Just 2) (IdEntry "b")
        ]
  LazyByteString.writeFile path (renderJournal intact <> "{\"seq\":10")
  snapshot <- readJournalFile path
  case snapshot of
    Left failure -> assertFailure (Text.unpack failure)
    Right loaded -> do
      journalReadEntries loaded @?= intact
      assertBool "truncated tail is reported" (maybe False (Text.isInfixOf "incomplete final line") (journalReadWarning loaded))
      journal <- newFileJournal dir
      recordMaybe (Just journal) (IdEntry "continued")
      entries <- readJournal path >>= either (assertFailure . Text.unpack) pure
      fmap entrySeq entries @?= [4, 9, 10]
      fmap entryKind entries @?= fmap entryKind intact <> [IdEntry "continued"]
 where
  renderJournal = LazyByteString.concat . fmap ((<> "\n") . encode)

journalMiddleCorruption :: Assertion
journalMiddleCorruption = withWorkDir $ \dir -> do
  let path = journalFilePath dir
      entry = Entry 0 [] Nothing (IdEntry "ok")
  LazyByteString.writeFile path (encode entry <> "\n{broken}\n" <> encode entry <> "\n")
  outcome <- readJournalFile path
  case outcome of
    Left failure -> assertBool "failure names the corrupt middle line" ("journal line 2" `Text.isInfixOf` failure)
    Right _ -> assertFailure "middle corruption was silently accepted"

atomicStoreRecovery :: Assertion
atomicStoreRecovery = silenceStderr $ withWorkDir $ \dir -> do
  transcripts <- newTranscriptStore dir
  configs <- newThreadConfigStore dir
  journal <- newFileJournal dir
  let config = emptyThreadConfig {configSystemPrompt = Just "kept"}
      history = [ChatUser "hello", ChatAssistant (AssistantTurn "answer" (Just "world") Nothing [])]
  transcriptSave transcripts "thread" history
  threadConfigWrite configs "thread" config
  recordMaybe (Just journal) (IdEntry "before-crash")
  traverse_
    (\path -> TextIO.writeFile path "{partial")
    [ dir ++ "/transcripts/thread.json.tmp-killed",
      dir ++ "/threads-config/thread.json.tmp-killed"
    ]
  LazyByteString.appendFile (journalFilePath dir) "{\"seq\":"
  reopenedTranscripts <- newTranscriptStore dir
  reopenedConfigs <- newThreadConfigStore dir
  reopenedJournal <- newFileJournal dir
  recordMaybe (Just reopenedJournal) (IdEntry "after-crash")
  savedHistory <- transcriptLoad reopenedTranscripts "thread"
  savedConfig <- threadConfigRead reopenedConfigs "thread"
  entries <- readJournal (journalFilePath dir) >>= either (assertFailure . Text.unpack) pure
  savedHistory @?= Just history
  savedConfig @?= config
  fmap entrySeq entries @?= [0, 1]
  fmap entryKind entries @?= [IdEntry "before-crash", IdEntry "after-crash"]

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
              fmap traceStepArtifactIds (find ((== "tool") . traceStepKind) traceRows)
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
journaledRun = do
  (journal, readEntries) <- newMemoryJournal
  base <- testRuntime echoModel [echoTool] Parallel
  events <- collectEvents base {runtimeJournal = Just journal} (sampleInput [])
  recorded <- readEntries
  pure (events, recorded)
