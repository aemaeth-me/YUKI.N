module Yuki.N.Cognition.SleepTest
  ( cognitionSleep,
    cognitionSleepParallelTools,
    cognitionLiveSleep,
    cognitionPreparedRecovery,
    cognitionSleepFailure,
    cognitionSleepTests,
  )
where

import Control.Exception (SomeException, throwIO, try)
import Data.Aeson
import Data.Functor (($>))
import Data.IORef
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Cognition
import Yuki.N.Context
import Yuki.N.ContextEpoch
import Yuki.N.Experience
import Yuki.N.Memory.Working
import Yuki.N.Model
import Yuki.N.TestSupport

cognitionSleep :: Assertion
cognitionSleep = withWorkDir $ \dir -> do
  cognition <- newCognition dir [sleepDecisionModel] Nothing >>= expectTextRight
  incarnation <- ensureIncarnation cognition "yuki"
  base <- testRuntime sleepDecisionModel [] Sequential
  let runtime =
        base
          { runtimeContext = Just (ContextConfig 128 2 96 8000),
            runtimeModel = sleepDecisionModel
          }
      messages =
        concat
          [ [ChatUser ("turn " <> Text.pack (show index)), ChatAssistant (AssistantTurn ("a-" <> Text.pack (show index)) (Just "working") Nothing [])]
          | index <- [1 :: Int .. 12]
          ]
  result <-
    cognitionSleepMessages cognition incarnation "task" (Just "sleep-run") SleepManual runtime messages
      >>= expectTextRight
  cycles <- workingSleepCycles (cognitionWorking cognition) "yuki"
  projected <-
    contextEpochProject
      (cognitionContexts cognition)
      (contextEpochId (sleepResultEpoch result))
      >>= expectTextRight
  focus <- workingReadFocus (cognitionWorking cognition) "yuki" "task"
  headEpoch <- contextEpochHead (cognitionContexts cognition) "yuki" "task"
  workingMemoryStatus (sleepResultHead result) @?= WorkingAwake
  sleepCycleStatus (sleepResultCycle result) @?= CycleAwake
  wakePacketContinuation (sleepResultPacket result) @?= "Continue from the verified open work."
  assertBool "sleep audits forgetting" (not (null (wakePacketForgotten (sleepResultPacket result))))
  assertBool "active context is a Wake Packet" ("[wake packet" `Text.isPrefixOf` compactionSummary (sleepResultCompaction result))
  fmap (contextSegmentKind . fst) projected @?= [SegmentWakePacket]
  assertBool "forgotten turns are absent from the wake epoch" (not (any (Text.isInfixOf "turn " . snd) projected))
  fmap contextEpochId headEpoch @?= Just (contextEpochId (sleepResultEpoch result))
  fmap focusFrameEpochId focus @?= Just (contextEpochId (sleepResultEpoch result))
  fmap focusFrameObjective focus @?= Just "Continue from the verified open work."
  fmap focusFrameActiveItems focus @?= Just ["current implementation is in progress"]
  fmap focusFrameOpenLoops focus @?= Just ["run verification"]
  length cycles @?= 1

cognitionSleepParallelTools :: Assertion
cognitionSleepParallelTools = withWorkDir $ \dir -> do
  cognition <- newCognition dir [retainEverySegmentModel] Nothing >>= expectTextRight
  incarnation <- ensureIncarnation cognition "yuki"
  base <- testRuntime okModel [] Sequential
  let runtime = base {runtimeContext = Just (ContextConfig 128 2 96 8000)}
      user = ChatUser ("parallel work " <> Text.replicate 1600 "x")
      messages =
        [ user,
          ChatAssistant (AssistantTurn "parallel-turn" (Just "checking both") Nothing calls),
          ChatToolResult "parallel-a" "first result",
          ChatToolResult "parallel-b" "second result"
        ]
  result <-
    cognitionSleepMessages cognition incarnation "parallel-sleep-task" (Just "parallel-sleep-run") SleepManual runtime messages
      >>= expectTextRight
  projected <-
    contextEpochProject
      (cognitionContexts cognition)
      (contextEpochId (sleepResultEpoch result))
      >>= expectTextRight
  let compacted = dropWhile (/= user) (compactionMessages (sleepResultCompaction result))
      replayed = projectedAguiMessages projected >>= toChatMessages
  compacted @?= messages
  fmap (contextSegmentKind . fst) projected
    @?= [ SegmentWakePacket,
          SegmentUser,
          SegmentAssistant,
          SegmentToolCall,
          SegmentToolCall,
          SegmentToolResult,
          SegmentToolResult
        ]
  fmap (contextSegmentTurnGroup . fst) projected
    @?= [Nothing, Nothing, Just "parallel-turn", Just "parallel-turn", Just "parallel-turn", Nothing, Nothing]
  either (assertFailure . Text.unpack) verifyWake replayed
 where
  calls =
    [ ModelToolCall "parallel-a" "first" "{\"value\":1}",
      ModelToolCall "parallel-b" "second" "{\"value\":2}"
    ]
  verifyWake (ChatSystem packet : retained) =
    sequence_
      [ assertBool "wake projection starts with its packet" (wakePacketMarker `Text.isPrefixOf` packet),
        retained
          @?= [ ChatUser ("parallel work " <> Text.replicate 1600 "x"),
                ChatAssistant (AssistantTurn "parallel-turn" (Just "checking both") Nothing calls),
                ChatToolResult "parallel-a" "first result",
                ChatToolResult "parallel-b" "second result"
              ]
      ]
  verifyWake messages = assertFailure ("unexpected wake projection: " <> show messages)

cognitionLiveSleep :: Assertion
cognitionLiveSleep = withWorkDir $ \dir -> do
  cognition <- newCognition dir [sleepDecisionModel] Nothing >>= expectTextRight
  incarnation <- ensureIncarnation cognition "yuki"
  turns <- newIORef (0 :: Int)
  captured <- newIORef []
  base <- testRuntime (liveSleepAgentModel turns captured) [] Sequential
  runtime <-
    attachCognition
      cognition
      incarnation
      base {runtimeContext = Just (ContextConfig 128 2 96 8000)}
  let input =
        (sampleInput [])
          { runThreadId = "live-sleep-task",
            runId = "live-sleep-run",
            runMessages =
              [ User
                  ( UserMessage
                      "live-user"
                      (UserText "live-run-user-sentinel")
                      Nothing
                  )
              ]
          }
  events <- collectEvents runtime input
  secondRequest <- readIORef captured
  epoch <- contextEpochHead (cognitionContexts cognition) "yuki" "live-sleep-task"
  projected <- traverse (contextEpochProject (cognitionContexts cognition) . contextEpochId) epoch
  assertBool "run completed after sleeping" (any (\case RunFinished {} -> True; _ -> False) events)
  assertBool "next turn receives a Wake Packet" (any wakeMessage secondRequest)
  assertBool "forgotten live user input is absent" (ChatUser "live-run-user-sentinel" `notElem` secondRequest)
  assertBool "forgotten sleep call is absent" (not (any sleepCall secondRequest))
  assertBool "forgotten sleep result is absent" (not (any toolResult secondRequest))
  fmap (fmap (fmap (contextSegmentKind . fst))) projected @?= Just (Right [SegmentWakePacket, SegmentAssistant])
  assertBool
    "closed context does not resurrect the forgotten live input"
    ( maybe
        False
        (either (const False) (not . any (Text.isInfixOf "live-run-user-sentinel" . snd)))
        projected
    )
 where
  wakeMessage (ChatSystem text) = wakePacketMarker `Text.isPrefixOf` text
  wakeMessage _ = False
  sleepCall (ChatAssistant turn) = any ((== "sleep") . modelToolName) (turnToolCalls turn)
  sleepCall _ = False
  toolResult ChatToolResult {} = True
  toolResult _ = False

liveSleepAgentModel :: IORef Int -> IORef [ChatMessage] -> Model
liveSleepAgentModel turns captured =
  fakeModel $ \request emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next))
      >>= \case
        1 ->
          emit
            ( ModelToolCallDelta
                0
                (Just "sleep-call")
                (Just "sleep")
                "{\"reason\":\"clear the live working context\"}"
            )
            $> ToolUse
        2 ->
          writeIORef captured (requestMessages request)
            *> emit (ModelTextDelta "continued after waking")
            $> Stop
        _ -> throwIO (ProviderFailure "unexpected model turn after live sleep")

cognitionPreparedRecovery :: Assertion
cognitionPreparedRecovery = withWorkDir $ \dir -> do
  before <- newCognition dir [] Nothing >>= expectTextRight
  _ <- ensureIncarnation before "yuki"
  baseEpoch <-
    contextEpochCommit
      (cognitionContexts before)
      "yuki"
      "recovery-task"
      Nothing
      [ContextSegmentInput "recovery-user" SegmentUser AuthorityUser "recover this task" Nothing Nothing]
      Nothing
      >>= expectTextRight
  cursor <- experienceHead (cognitionExperiences before) "yuki"
  created <- workingCreate (cognitionWorking before) "yuki" cursor >>= expectTextRight
  let frame =
        FocusFrame
          "focus/yuki/recovery-task"
          "yuki"
          "recovery-task"
          1
          FocusActive
          (contextEpochId baseEpoch)
          "pre-sleep objective"
          ["old active"]
          ["old loop"]
          ["discard this provisional claim"]
          []
          []
          cursor
          0
  focused <-
    workingPutFocus
      (cognitionWorking before)
      "yuki"
      (workingMemoryRevision created)
      frame
      >>= expectTextRight
  (quiescing, _) <-
    workingRequestSleep
      (cognitionWorking before)
      "yuki"
      (workingMemoryRevision focused)
      "prepared-cycle"
      "recovery-task"
      (Just "recovery-run")
      (contextEpochId baseEpoch)
      SleepManual
      >>= expectTextRight
  let packet =
        WakePacket
          "prepared-packet"
          "yuki"
          "recovery-task"
          (Just "recovery-run")
          (contextEpochId baseEpoch)
          SleepManual
          "wake objective"
          ["wake active"]
          ["wake loop"]
          [ForgetDecision "noise" "not needed" []]
          []
          "packet-payload"
          sleepDreamRevision
          "sleep-invocation"
          0
      checkpoint =
        WorkingMemoryCheckpoint
          "prepared-checkpoint"
          "yuki"
          (workingMemoryRevision quiescing)
          cursor
          (workingMemoryFocusFrames quiescing)
          (workingMemoryActiveTaskId quiescing)
          "checkpoint-payload"
          "checkpoint-closure"
          "prepared-packet"
          sleepDreamRevision
          0
  _ <-
    workingPrepareCheckpoint
      (cognitionWorking before)
      "yuki"
      (workingMemoryRevision quiescing)
      "prepared-cycle"
      checkpoint
      packet
      >>= expectTextRight
  recovered <- newCognition dir [] Nothing >>= expectTextRight
  verifyRecovered recovered
 where
  verifyRecovered recovered = do
    head' <- workingRead (cognitionWorking recovered) "yuki"
    focus <- workingReadFocus (cognitionWorking recovered) "yuki" "recovery-task"
    cycle' <- workingReadSleepCycle (cognitionWorking recovered) "prepared-cycle"
    epoch <- contextEpochHead (cognitionContexts recovered) "yuki" "recovery-task"
    fmap workingMemoryStatus head' @?= Just WorkingAwake
    fmap sleepCycleStatus cycle' @?= Just CycleAwake
    fmap contextEpochWakePacketId epoch @?= Just (Just "prepared-packet")
    fmap focusFrameEpochId focus @?= (contextEpochId <$> epoch)
    fmap focusFrameObjective focus @?= Just "wake objective"
    fmap focusFrameActiveItems focus @?= Just ["wake active"]
    fmap focusFrameOpenLoops focus @?= Just ["wake loop"]
    fmap focusFrameProvisionalClaims focus @?= Just []

cognitionSleepFailure :: Assertion
cognitionSleepFailure = withWorkDir $ \dir -> do
  cognition <- newCognition dir [] Nothing >>= expectTextRight
  incarnation <- ensureIncarnation cognition "yuki"
  base <- testRuntime okModel [] Sequential
  let runtime = base {runtimeContext = Just contextConfig}
      input = (sampleInput []) {runThreadId = "failed-sleep-task", runId = "failed-sleep-run"}
      messages = [ChatUser "work that must not disappear"]
  case forcedCompaction runtime [] messages of
    Nothing -> assertFailure "missing forced compaction fixture"
    Just compaction -> do
      attempt <-
        ( try
            (afterCompaction (cognitionHooks cognition incarnation) input 1 False True messages compaction) ::
            IO (Either SomeException Compaction)
        )
      cycles <- workingSleepCycles (cognitionWorking cognition) "yuki"
      epoch <- contextEpochHead (cognitionContexts cognition) "yuki" "failed-sleep-task"
      either (const (pure ())) (const (assertFailure "sleep failure was silently accepted")) attempt
      cycles @?= []
      fmap contextEpochWakePacketId epoch @?= Just Nothing

sleepDecisionModel :: Model
sleepDecisionModel =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "continuation" .= ("Continue from the verified open work." :: Text),
                    "activeItems" .= ["current implementation is in progress" :: Text],
                    "openLoops" .= ["run verification" :: Text],
                    "forgotten"
                      .= [ object
                             [ "subject" .= ("superseded conversational detail" :: Text),
                               "reason" .= ("not needed for the next action" :: Text),
                               "sourceSegmentIds" .= ([] :: [Text])
                             ]
                         ],
                    "retainedSegmentIds" .= ([] :: [Text])
                  ]
              )
          )
      )
      $> Stop
retainEverySegmentModel :: Model
retainEverySegmentModel =
  fakeModel $ \request emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( DreamDecision
                  "Continue the parallel tool work."
                  ["parallel tool work is active"]
                  ["finish the response"]
                  []
                  (take 12 (nub (concatMap segmentIds [text | ChatUser text <- requestMessages request])))
              )
          )
      )
      $> Stop
 where
  segmentIds text
    | Text.null suffix = []
    | otherwise = Text.take 40 suffix : segmentIds (Text.drop 40 suffix)
   where
    (_, suffix) = Text.breakOn "segment-" text
cognitionSleepTests :: TestTree
cognitionSleepTests =
  testGroup
    "incarnation cognition sleep"
    [ testCase "sleeps, forgets, wakes and continues with a Wake Packet" cognitionSleep,
      testCase "preserves one parallel tool turn through sleep and wake" cognitionSleepParallelTools,
      testCase "sleeps over the live run context rather than its initial request" cognitionLiveSleep,
      testCase "fails explicitly rather than silently compacting when sleep fails" cognitionSleepFailure,
      testCase "recovers a prepared sleep into one coherent wake epoch" cognitionPreparedRecovery
    ]
