module Yuki.N.Cognition.ArchiveTest
  ( cognitionTaskArchivePersistence,
    cognitionTaskArchiveRetrieval,
    cognitionTaskArchiveHooks,
    cognitionTaskArchiveHttp,
    cognitionTaskArchiveTests,
  )
where

import Control.Exception (throwIO)
import Data.Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Types
import Network.Wai.Test
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Blob
import Yuki.N.Cognition
import Yuki.N.Inspect
import Yuki.N.Memory.Archive
import Yuki.N.Model
import Yuki.N.Server
import Yuki.N.TestSupport

cognitionTaskArchivePersistence :: Assertion
cognitionTaskArchivePersistence = withWorkDir $ \dir -> do
  blobs <- newBlobStore dir >>= expectTextRight
  store <- newTaskArchiveStore dir blobs >>= expectTextRight
  exercise dir store
 where
  task = "archived-task"
  user = entry "user-1" ArchiveUser "Keep the complete tool evidence." Nothing Nothing Nothing
  result = entry "call-1/result" ArchiveToolResult fullResult (Just "call-1") (Just "call-1") (Just "inspect")
  reasoning = entry "turn-1/reasoning" ArchiveReasoning "I should inspect the source first." (Just "turn-1") Nothing Nothing
  answer = entry "turn-1/assistant" ArchiveAssistant "The source confirms the result." (Just "turn-1") Nothing Nothing
  call = entry "call-1/call" ArchiveToolCall (jsonText (ModelToolCall "call-1" "inspect" "{\"path\":\"source\"}")) (Just "turn-1") (Just "call-1") (Just "inspect")
  fullResult = "complete-tool-result-sentinel\n" <> Text.replicate 900 "e"
  running =
    ArchiveRunDraft "art" task "run-1" (Just "intent-1") "running" Nothing [user, result]
  completed =
    ArchiveRunDraft "art" task "run-1" (Just "intent-1") "completed" Nothing [user, reasoning, answer, call, result]
  rewritten = completed {archiveRunDraftStatus = "failed", archiveRunDraftFailure = Just "late rewrite"}
  exercise dir store = do
    _ <- taskArchiveAppend store running >>= expectTextRight
    sealed <- taskArchiveAppend store completed >>= expectTextRight
    repeated <- taskArchiveAppend store completed >>= expectTextRight
    rewrite <- taskArchiveAppend store rewritten
    blobs' <- newBlobStore dir >>= expectTextRight
    reopened <- newTaskArchiveStore dir blobs' >>= expectTextRight
    verify sealed repeated rewrite reopened
  verify sealed repeated rewrite reopened = do
    runs <- taskArchiveRuns reopened "art" (Just task)
    catalog <- taskArchiveTasks reopened "art" 20
    case archiveRunEntryIds sealed of
      _ : resultId : _ -> do
        window <- taskArchiveRead reopened (ArchiveReadRequest "art" resultId 0 0 0 20000) >>= expectTextRight
        repeated @?= sealed
        assertLeft rewrite
        fmap archiveRunStatus runs @?= ["completed"]
        fmap archiveTaskId catalog @?= [task]
        fmap archiveTaskRunCount catalog @?= [1]
        fmap archiveTaskEntryCount catalog @?= [5]
        fmap archiveSliceSeq (archiveReadResultEntries window) @?= [2 .. 5]
        fmap
          archiveSliceContent
          (filter ((== ArchiveToolResult) . archiveSliceKind) (archiveReadResultEntries window))
          @?= [fullResult]
      _ -> assertFailure "persisted Task archive did not retain its entry identities"
  entry = ArchiveEntryDraft

cognitionTaskArchiveRetrieval :: Assertion
cognitionTaskArchiveRetrieval = do
  blobs <- newMemoryBlobStore
  store <- newMemoryTaskArchiveStore blobs
  _ <- taskArchiveAppend store primary >>= expectTextRight
  _ <- taskArchiveAppend store secondary >>= expectTextRight
  _ <- taskArchiveAppend store otherRun >>= expectTextRight
  verify store
 where
  task = "task-a"
  turn = "turn-a"
  callA = "call-a"
  callB = "call-b"
  primary =
    ArchiveRunDraft
      "art"
      task
      "run-a"
      Nothing
      "completed"
      Nothing
      [ entry "user-a" ArchiveUser "第一行\nAlpha NEEDLE beta\nrepeat repeat repeat\n第三行" Nothing Nothing Nothing,
        entry "reasoning-a" ArchiveReasoning (padded "secret-reasoning") (Just turn) Nothing Nothing,
        entry "assistant-a" ArchiveAssistant (padded "answer-without-query") (Just turn) Nothing Nothing,
        entry "call-a/call" ArchiveToolCall (padded "call-a-input") (Just turn) (Just callA) (Just "shell"),
        entry "call-b/call" ArchiveToolCall (padded "call-b-input") (Just turn) (Just callB) (Just "second"),
        entry "call-memory/call" ArchiveToolCall "{\"query\":\"recursive-noise\"}" (Just turn) (Just "call-memory") (Just "memory_grep"),
        entry "call-a/result" ArchiveToolResult (padded "tool-A-evidence" <> "\n[artifact art-source-a: full shell output]") (Just callA) (Just callA) (Just "shell"),
        entry "call-b/result" ArchiveToolResult (padded "tool-B-evidence") (Just callB) (Just callB) (Just "second"),
        entry "call-memory/result" ArchiveToolResult "{\"hits\":[{\"excerpt\":\"recursive-noise\"}],\"scannedEntries\":8}" (Just "call-memory") (Just "call-memory") (Just "memory_grep")
      ]
  secondary =
    ArchiveRunDraft
      "art"
      "task-b"
      "run-b"
      Nothing
      "completed"
      Nothing
      [entry "user-b" ArchiveUser "Needle in another archived Task." Nothing Nothing Nothing]
  otherRun =
    ArchiveRunDraft
      "other"
      "task-c"
      "run-c"
      Nothing
      "completed"
      Nothing
      [entry "user-c" ArchiveUser "NEEDLE must remain isolated." Nothing Nothing Nothing]
  verify store = do
    insensitive <- search store (ArchiveGrepRequest "art" "needle" (Just task) [] False 20 0 False Nothing)
    sensitive <- search store (ArchiveGrepRequest "art" "needle" (Just task) [] True 20 0 False Nothing)
    defaultReasoning <- search store (ArchiveGrepRequest "art" "secret-reasoning" Nothing [] False 20 0 False Nothing)
    explicitReasoning <- search store (ArchiveGrepRequest "art" "secret-reasoning" Nothing [ArchiveReasoning] False 20 0 False Nothing)
    allOwn <- search store (ArchiveGrepRequest "art" "needle" Nothing [] False 20 0 False Nothing)
    excluded <- search store (ArchiveGrepRequest "art" "needle" Nothing [] False 20 0 False (Just task))
    anchorSearch <- search store (ArchiveGrepRequest "art" "tool-A-evidence" (Just task) [] False 20 0 False Nothing)
    repeated <- search store (ArchiveGrepRequest "art" "repeat" (Just task) [] True 20 0 False Nothing)
    firstPage <- search store (ArchiveGrepRequest "art" "needle" Nothing [] False 1 0 False Nothing)
    secondPage <- search store (ArchiveGrepRequest "art" "needle" Nothing [] False 1 1 False Nothing)
    processHidden <- search store (ArchiveGrepRequest "art" "recursive-noise" (Just task) [] True 20 0 False Nothing)
    processShown <- search store (ArchiveGrepRequest "art" "recursive-noise" (Just task) [] True 20 0 True Nothing)
    catalog <- taskArchiveTasks store "art" 20
    case archiveGrepResultHits anchorSearch of
      [anchor] -> do
        window <-
          taskArchiveRead store (ArchiveReadRequest "art" (archiveHitEntryId anchor) 0 0 (archiveHitMatchOffset anchor) 256)
            >>= expectTextRight
        verifyWindow store insensitive sensitive defaultReasoning explicitReasoning allOwn excluded repeated firstPage secondPage processHidden processShown catalog anchor window
      hits -> assertFailure ("unexpected Task archive anchor hits: " <> show (length hits))
  verifyWindow store insensitive sensitive defaultReasoning explicitReasoning allOwn excluded repeated firstPage secondPage processHidden processShown catalog anchor window = do
    tiny <-
      taskArchiveRead store (ArchiveReadRequest "art" (archiveHitEntryId anchor) 0 0 (archiveHitMatchOffset anchor) 1)
        >>= expectTextRight
    foreignRead <- taskArchiveRead store (ArchiveReadRequest "other" (archiveHitEntryId anchor) 0 0 0 256)
    let entries = archiveReadResultEntries window
        tinyEntries = archiveReadResultEntries tiny
    fmap archiveHitLineNumber (archiveGrepResultHits insensitive) @?= [2]
    fmap archiveHitMatchOffset (archiveGrepResultHits insensitive) @?= [10]
    archiveGrepResultHits sensitive @?= []
    archiveGrepResultHits defaultReasoning @?= []
    fmap archiveHitKind (archiveGrepResultHits explicitReasoning) @?= [ArchiveReasoning]
    sort (fmap archiveHitTaskId (archiveGrepResultHits allOwn)) @?= [task, "task-b"]
    sort (fmap archiveHitTaskId (archiveGrepResultHits excluded)) @?= ["task-b"]
    fmap archiveHitEntryMatchIndex (archiveGrepResultHits repeated) @?= [1, 2, 3]
    fmap archiveHitEntryMatchCount (archiveGrepResultHits repeated) @?= [3, 3, 3]
    archiveGrepResultTotalHits firstPage @?= 2
    archiveGrepResultReturnedHits firstPage @?= 1
    archiveGrepResultNextOffset firstPage @?= Just 1
    archiveGrepResultHasMore firstPage @?= True
    archiveGrepResultNextOffset secondPage @?= Nothing
    archiveGrepResultHasMore secondPage @?= False
    archiveGrepResultHits processHidden @?= []
    fmap archiveHitEvidenceClass (archiveGrepResultHits processShown) @?= ["process", "process"]
    archiveHitSourceCompleteness anchor @?= "artifact-backed"
    archiveHitArtifactIds anchor @?= ["art-source-a"]
    sort (fmap archiveTaskId catalog) @?= [task, "task-b"]
    fmap archiveSliceKind entries
      @?= [ ArchiveReasoning,
            ArchiveAssistant,
            ArchiveToolCall,
            ArchiveToolCall,
            ArchiveToolCall,
            ArchiveToolResult,
            ArchiveToolResult,
            ArchiveToolResult
          ]
    assertBool "causal read exceeded its global character budget" (sum (fmap (Text.length . archiveSliceContent) entries) <= 256)
    assertBool "anchor text was not centered into the bounded read" ("tool-A-evidence" `Text.isInfixOf` archiveSliceContent (entries !! 5))
    sum (fmap (Text.length . archiveSliceContent) tinyEntries) @?= 1
    Text.length (archiveSliceContent (tinyEntries !! 5)) @?= 1
    assertLeft foreignRead
  search store grepRequest =
    taskArchiveGrep store grepRequest >>= either (throwIO . userError . Text.unpack) pure
  padded label = label <> ":" <> Text.replicate 500 "x"
  entry = ArchiveEntryDraft

cognitionTaskArchiveHooks :: Assertion
cognitionTaskArchiveHooks = withWorkDir $ \dir -> do
  cognition <- newCognition dir [] Nothing >>= expectTextRight
  incarnation <- ensureIncarnation cognition "yuki"
  let hooks = cognitionHooks cognition incarnation
      input =
        (sampleInput [])
          { runThreadId = "raw-hook-task",
            runId = "raw-hook-run",
            runMessages = [User (UserMessage "intent-raw" (UserText accepted) Nothing)]
          }
      call = ModelToolCall "raw-call" "inspect" "{\"path\":\"large\"}"
      finalMessages =
        [ ChatUser accepted,
          ChatAssistant (AssistantTurn "raw-turn" (Just "I inspected it.") Nothing [call]),
          ChatToolResult "raw-call" projected
        ]
  observeEvent hooks input (RunStarted "raw-hook-task" "raw-hook-run" Nothing)
  observeEvent hooks input (ToolCallResult "raw-tool-message" "raw-call" completeResult)
  afterRunOutcome hooks input RunSucceeded finalMessages
  full <-
    taskArchiveGrep
      (cognitionArchive cognition)
      (ArchiveGrepRequest "yuki" "complete-result-sentinel" (Just "raw-hook-task") [] True 20 0 False Nothing)
      >>= expectTextRight
  stub <-
    taskArchiveGrep
      (cognitionArchive cognition)
      (ArchiveGrepRequest "yuki" "projected-result-stub" (Just "raw-hook-task") [] True 20 0 False Nothing)
      >>= expectTextRight
  user <-
    taskArchiveGrep
      (cognitionArchive cognition)
      (ArchiveGrepRequest "yuki" accepted (Just "raw-hook-task") [] True 20 0 False Nothing)
      >>= expectTextRight
  runs <- taskArchiveRuns (cognitionArchive cognition) "yuki" (Just "raw-hook-task")
  fmap archiveHitKind (archiveGrepResultHits full) @?= [ArchiveToolResult]
  archiveGrepResultHits stub @?= []
  fmap archiveHitKind (archiveGrepResultHits user) @?= [ArchiveUser]
  fmap archiveRunStatus runs @?= ["completed"]
 where
  accepted = "accepted-input-sentinel"
  completeResult = "complete-result-sentinel\n" <> Text.replicate 2000 "原"
  projected = "projected-result-stub"

cognitionTaskArchiveHttp :: Assertion
cognitionTaskArchiveHttp = withWorkDir $ \dir -> do
  cognition <- newCognition dir [] Nothing >>= expectTextRight
  runtime <- testRuntime okModel [] Parallel
  stored <-
    taskArchiveAppend
      (cognitionArchive cognition)
      ( ArchiveRunDraft
          "yuki"
          "route-task"
          "route-run"
          Nothing
          "completed"
          Nothing
          [ArchiveEntryDraft "route-user" ArchiveUser "route-memory-sentinel" Nothing Nothing Nothing]
      )
      >>= expectTextRight
  case archiveRunEntryIds stored of
    [entryId] -> do
      let app = application Nothing (Just (withCognition cognition emptyInspection)) Nothing Nothing (const (pure runtime))
      catalog <- runSession (request (httpGet ["incarnations", "yuki", "task-records"])) app
      searched <-
        runSession
          ( srequest
              ( jsonRequest
                  methodPost
                  ["incarnations", "yuki", "task-records", "search"]
                  ( object
                      [ "query" .= ("route-memory-sentinel" :: Text),
                        "caseSensitive" .= True,
                        "limit" .= (20 :: Int)
                      ]
                  )
              )
          )
          app
      readBack <- runSession (request (httpGet ["incarnations", "yuki", "task-records", entryId])) app
      missingEntry <- runSession (request (httpGet ["incarnations", "yuki", "task-records", "missing-entry"])) app
      simpleStatus catalog @?= status200
      simpleStatus searched @?= status200
      simpleStatus readBack @?= status200
      simpleStatus missingEntry @?= status404
      responseContains "route-task" catalog
      responseContains "\"mode\":\"fixed\"" searched
      responseContains "route-memory-sentinel" searched
      responseContains "route-memory-sentinel" readBack
    identifiers -> assertFailure ("unexpected Task archive entry count: " <> show (length identifiers))
 where
  responseContains needle =
    assertBool
      ("response body does not contain " <> needle)
      . ByteString.isInfixOf (TextEncoding.encodeUtf8 (Text.pack needle))
      . LazyByteString.toStrict
      . simpleBody

cognitionTaskArchiveTests :: TestTree
cognitionTaskArchiveTests =
  testGroup
    "incarnation cognition task archive"
    [ testCase "persists immutable structured Task archives across restart" cognitionTaskArchivePersistence,
      testCase "greps Task archives and reads causal windows" cognitionTaskArchiveRetrieval,
      testCase "captures accepted input and full tool results before projection" cognitionTaskArchiveHooks,
      testCase "serves Task archive catalog, grep and anchored read endpoints" cognitionTaskArchiveHttp
    ]
