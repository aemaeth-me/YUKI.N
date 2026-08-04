module Yuki.N.CognitionTest
  ( cognitionTests,
    cognitionSha,
    cognitionExperience,
    cognitionContextIsolation,
    cognitionTerminalOutcomes,
    cognitionAuthoritativeContext,
  )
where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Functor (($>))
import Data.IORef
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
      testCase "records failed and cancelled run termination payloads" cognitionTerminalOutcomes,
      testCase "uses ContextEpoch when no transcript projection exists" cognitionAuthoritativeContext
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
          (withSessionService service (newInspection Nothing Nothing (Just (serviceTranscripts service))))
      app = application Nothing (Just inspection) Nothing Nothing Nothing Nothing (const (pure runtime))
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
