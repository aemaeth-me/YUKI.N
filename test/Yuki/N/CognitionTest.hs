module Yuki.N.CognitionTest
  ( cognitionTests,
    cognitionSha,
    cognitionExperience,
    cognitionContextIsolation,
    cognitionLegacyTaskMigration,
    cognitionTerminalOutcomes,
    cognitionAuthoritativeContext,
    cognitionLegacyParallelTools,
  )
where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Functor (($>))
import Data.IORef
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Types
import Network.Wai.Test
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Blob
import Yuki.N.Cognition
import Yuki.N.ContextEpoch
import Yuki.N.Experience
import Yuki.N.Inspect
import Yuki.N.Memory.Archive
import Yuki.N.Memory.LongTerm
import Yuki.N.Memory.Working
import Yuki.N.Model
import Yuki.N.Server
import Yuki.N.Sessions
import Yuki.N.TestSupport
import Yuki.N.Transcript

cognitionTests :: TestTree
cognitionTests =
  testGroup
    "incarnation cognition"
    [ testCase "uses real SHA-256 content identities" cognitionSha,
      testCase "persists a monotonic per-incarnation experience stream" cognitionExperience,
      testCase "isolates same-task context heads and histories by incarnation" cognitionContextIsolation,
      testCase "migrates a legacy task idempotently without promoting long-term memory" cognitionLegacyTaskMigration,
      testCase "records failed and cancelled run termination payloads" cognitionTerminalOutcomes,
      testCase "uses ContextEpoch when no transcript projection exists" cognitionAuthoritativeContext,
      testCase "repairs legacy parallel tool turns before provider replay" cognitionLegacyParallelTools
    ]

cognitionSha :: Assertion
cognitionSha =
  sequence_
    [ sha256 "" @?= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      sha256 "abc" @?= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    ]

cognitionExperience :: Assertion
cognitionExperience = withWorkDir $ \dir -> do
  store <- newExperienceStore dir >>= expectTextRight
  zero <- experienceHead store "yuki"
  first <- experienceAppend store (Just zero) (experienceDraft "first") >>= expectTextRight
  stale <- experienceAppend store (Just zero) (experienceDraft "stale")
  reopened <- newExperienceStore dir >>= expectTextRight
  events <- experienceEvents reopened "yuki"
  experienceSeq first @?= 1
  assertLeft stale
  fmap experienceSeq events @?= [1]
 where
  experienceDraft kind =
    ExperienceDraft "yuki" "operation" "yuki" Nothing (Just "task") (Just "run") Nothing Nothing kind "sha256-payload" "sha256-payload"

cognitionContextIsolation :: Assertion
cognitionContextIsolation = do
  blobs <- newMemoryBlobStore
  store <- newMemoryContextEpochStore blobs
  northFirst <- contextEpochCommit store "north" task Nothing [segment "north/1" "north first"] Nothing >>= expectTextRight
  southOnly <- contextEpochCommit store "south" task Nothing [segment "south/1" "south only"] Nothing >>= expectTextRight
  northSecond <-
    contextEpochCommit store "north" task (Just (contextEpochId northFirst)) [segment "north/2" "north second"] Nothing
      >>= expectTextRight
  northHead <- contextEpochHead store "north" task
  southHead <- contextEpochHead store "south" task
  northHistory <- contextEpochList store "north" task
  southHistory <- contextEpochList store "south" task
  fmap contextEpochId northHead @?= Just (contextEpochId northSecond)
  fmap contextEpochId southHead @?= Just (contextEpochId southOnly)
  fmap contextEpochId northHistory @?= fmap contextEpochId [northFirst, northSecond]
  fmap contextEpochId southHistory @?= [contextEpochId southOnly]
  fmap contextEpochIncarnationId northHistory @?= ["north", "north"]
  fmap contextEpochIncarnationId southHistory @?= ["south"]
 where
  task = "same-task"
  segment source content =
    ContextSegmentInput source SegmentUser AuthorityUser content Nothing Nothing

cognitionLegacyTaskMigration :: Assertion
cognitionLegacyTaskMigration = withWorkDir $ \dir -> do
  cognition <- newCognition dir [] Nothing >>= expectTextRight
  incarnation <- ensureIncarnation cognition identity
  _ <- cognitionMigrateLegacyTask cognition incarnation task messages (Just candidate) >>= expectTextRight
  before <- migrationSnapshot cognition
  _ <- cognitionMigrateLegacyTask cognition incarnation task messages (Just candidate) >>= expectTextRight
  repeated <- migrationSnapshot cognition
  verify cognition before repeated
 where
  identity = "yuki"
  task = "legacy.task"
  messages =
    [ ChatUser "Restore the amber workspace.",
      ChatAssistant (AssistantTurn "legacy-answer" (Just "The workspace was restored.") Nothing [])
    ]
  candidate =
    object
      [ "rollingSummary" .= ("legacy summary candidate" :: Text),
        "episodes" .= ([] :: [Value])
      ]
  migrationSnapshot cognition =
    (,,,,,)
      <$> experienceEvents (cognitionExperiences cognition) identity
      <*> contextEpochList (cognitionContexts cognition) identity task
      <*> workingRead (cognitionWorking cognition) identity
      <*> workingReadFocus (cognitionWorking cognition) identity task
      <*> longTermCatalog (cognitionLongTerm cognition) identity 100
      <*> taskArchiveRuns (cognitionArchive cognition) identity (Just task)
  verify cognition before@(events, epochs, head', focus, catalog, archived) repeated =
    sequence_
      [ repeated @?= before,
        fmap experienceKind events
          @?= [ "LegacyTranscriptImported",
                "LegacyWorkingMemoryCandidate",
                "LegacyTaskMigrationCompleted"
              ],
        fmap experienceSeq events @?= [1, 2, 3],
        fmap (cursorSeq . workingMemoryCursor) head' @?= Just 3,
        fmap focusFrameObjective focus @?= Just "Restore the amber workspace.",
        fmap focusFrameRecentOutcomeRefs focus @?= Just (fmap experienceEventId events),
        catalog @?= [],
        fmap archiveRunStatus archived @?= ["legacy"],
        fmap (length . archiveRunEntryIds) archived @?= [2]
      ]
      *> verifyContext cognition epochs
      *> verifyCandidate cognition events focus
  verifyContext cognition epochs =
    case epochs of
      [epoch] -> do
        projected <- contextEpochProject (cognitionContexts cognition) (contextEpochId epoch) >>= expectTextRight
        fmap (contextSegmentKind . fst) projected @?= [SegmentUser, SegmentAssistant]
        fmap snd projected @?= ["Restore the amber workspace.", "The workspace was restored."]
      _ -> assertFailure ("unexpected migrated epoch count: " <> show (length epochs))
  verifyCandidate cognition events focus =
    case find ((== "LegacyWorkingMemoryCandidate") . experienceKind) events of
      Nothing -> assertFailure "legacy working-memory candidate event is missing"
      Just event ->
        blobFetch (cognitionBlobs cognition) (experiencePayloadRef event) >>= \case
          Left failure -> assertFailure (Text.unpack failure)
          Right payload ->
            sequence_
              [ either assertFailure (@?= candidate) (eitherDecode payload >>= parseEither (withObject "legacy candidate" (.: "candidate"))),
                assertBool
                  "working focus does not reference the legacy candidate"
                  (maybe False ((experienceEventId event `elem`) . focusFrameRecentOutcomeRefs) focus)
              ]

cognitionTerminalOutcomes :: Assertion
cognitionTerminalOutcomes = withWorkDir $ \dir -> do
  cognition <- newCognition dir [] Nothing >>= expectTextRight
  incarnation <- ensureIncarnation cognition "yuki"
  let hooks = cognitionHooks cognition incarnation
      failed = (sampleInput []) {runThreadId = "failed-task", runId = "failed-run"}
      cancelled = (sampleInput []) {runThreadId = "cancelled-task", runId = "cancelled-run"}
  afterRunOutcome hooks failed (RunFailed "PROVIDER_ERROR" "provider down") [ChatUser "failed input"]
  afterRunOutcome hooks cancelled RunWasCancelled [ChatUser "cancelled input"]
  terminated <- filter ((== "RunTerminated") . experienceKind) <$> experienceEvents (cognitionExperiences cognition) "yuki"
  statuses <- traverse (terminalStatus cognition) terminated
  Map.fromList statuses
    @?= Map.fromList
      [ ("failed-run", "failed"),
        ("cancelled-run", "cancelled")
      ]
 where
  terminalStatus :: Cognition -> ExperienceEvent -> IO (Text, Text)
  terminalStatus cognition event =
    blobFetch (cognitionBlobs cognition) (experiencePayloadRef event) >>= \case
      Left failure -> assertFailure (Text.unpack failure) $> ("", "")
      Right payload ->
        case eitherDecode payload >>= parseEither (withObject "RunTerminated" (.: "status")) of
          Left failure -> assertFailure failure $> ("", "")
          Right status -> pure (fromMaybe "" (experienceRunId event), status)

cognitionAuthoritativeContext :: Assertion
cognitionAuthoritativeContext = withWorkDir $ \dir -> do
  cognition <- newCognition (dir ++ "/cognition") [] Nothing >>= expectTextRight
  service <- sessionServiceAt (dir ++ "/sessions") (const (pure ()))
  _ <-
    contextEpochCommit
      (cognitionContexts cognition)
      "yuki"
      "authority-task"
      Nothing
      [ ContextSegmentInput "old-user" SegmentUser AuthorityUser "epoch-user-sentinel" Nothing Nothing,
        ContextSegmentInput "old-answer" SegmentAssistant AuthorityAgent "epoch-assistant-sentinel" Nothing Nothing
      ]
      Nothing
      >>= expectTextRight
  captured <- newIORef []
  runtime <- testRuntime (promptCaptureModel captured) [] Sequential
  let inspection =
        withCognition
          cognition
          (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
      app = application Nothing (Just inspection) Nothing Nothing Nothing (const (pure runtime))
  stored <- transcriptLoad (serviceTranscripts service) "authority-task"
  stored @?= Nothing
  response <- runSession (srequest (agentPost "authority-task")) app
  messages <- readIORef captured
  simpleStatus response @?= status200
  assertBool "epoch user survives without transcript" (ChatUser "epoch-user-sentinel" `elem` messages)
  assertBool
    "epoch assistant survives without transcript"
    ( any
        ( \case
            ChatAssistant turn -> turnText turn == Just "epoch-assistant-sentinel"
            _ -> False
        )
        messages
    )
  assertBool "latest submitted user is appended" (ChatUser "hello" `elem` messages)

cognitionLegacyParallelTools :: Assertion
cognitionLegacyParallelTools = withWorkDir $ \dir -> do
  cognition <- newCognition (dir ++ "/cognition") [] Nothing >>= expectTextRight
  service <- sessionServiceAt (dir ++ "/sessions") (const (pure ()))
  epoch <-
    contextEpochCommit
      (cognitionContexts cognition)
      "yuki"
      task
      Nothing
      legacySegments
      Nothing
      >>= expectTextRight
  projected <- contextEpochProject (cognitionContexts cognition) (contextEpochId epoch) >>= expectTextRight
  captured <- newIORef []
  runtime <- testRuntime (promptCaptureModel captured) [] Sequential
  let inspection =
        withCognition
          cognition
          (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
      app = application Nothing (Just inspection) Nothing Nothing Nothing (const (pure runtime))
  response <- runSession (srequest (agentPost task)) app
  messages <- readIORef captured
  verifyIncomplete (cognitionContexts cognition)
  (projectedAguiMessages projected >>= toChatMessages) @?= Right history
  dropWhile (/= ChatUser "legacy parallel user") messages @?= history <> [ChatUser "hello"]
  simpleStatus response @?= status200
 where
  task = "legacy-parallel-task"
  firstCall = ModelToolCall "legacy-call-a" "first" "{\"value\":1}"
  secondCall = ModelToolCall "legacy-call-b" "second" "{\"value\":2}"
  calls = [firstCall, secondCall]
  history =
    [ ChatUser "legacy parallel user",
      ChatAssistant (AssistantTurn "legacy-turn" (Just "checking both") Nothing calls),
      ChatToolResult "legacy-call-a" "first result",
      ChatToolResult "legacy-call-b" "second result"
    ]
  legacySegments =
    [ ContextSegmentInput "legacy-user" SegmentUser AuthorityUser "legacy parallel user" Nothing Nothing,
      ContextSegmentInput "legacy-turn" SegmentAssistant AuthorityAgent "checking both" Nothing Nothing,
      ContextSegmentInput "legacy-call-a" SegmentToolCall AuthorityAgent (jsonText firstCall) (Just "legacy-call-a") Nothing,
      ContextSegmentInput "legacy-call-b" SegmentToolCall AuthorityAgent (jsonText (FunctionCall "second" "{\"value\":2}")) (Just "legacy-call-b") Nothing,
      ContextSegmentInput "legacy-result-a" SegmentToolResult AuthorityTool "first result" (Just "legacy-call-a") Nothing,
      ContextSegmentInput "legacy-result-b" SegmentToolResult AuthorityTool "second result" (Just "legacy-call-b") Nothing
    ]
  verifyIncomplete store = do
    epoch <-
      contextEpochCommit
        store
        "yuki"
        "incomplete-tool-task"
        Nothing
        [ ContextSegmentInput "incomplete-turn" SegmentAssistant AuthorityAgent "working" Nothing Nothing,
          ContextSegmentInput "incomplete-call" SegmentToolCall AuthorityAgent (jsonText (ModelToolCall "incomplete-call" "work" "{}")) (Just "incomplete-call") Nothing
        ]
        Nothing
        >>= expectTextRight
    projected <- contextEpochProject store (contextEpochId epoch) >>= expectTextRight
    assertLeft (projectedAguiMessages projected)
