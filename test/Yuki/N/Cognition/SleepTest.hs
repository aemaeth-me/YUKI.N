-- | 分身认知 · 睡眠测试
--
-- 覆盖：睡眠/唤醒决策、并行工具回合保留、活动上下文睡眠、预制备恢复与失败显式化。
-- 边界：覆盖 Yuki.N.Memory.Working 睡眠协议与 Yuki.N.Cognition.sleep。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.Cognition.SleepTest
  ( cognitionSleep,
    cognitionSleepParallelTools,
    cognitionLiveSleep,
    cognitionPreparedRecovery,
    cognitionSleepFailure,
    cognitionSleepTests
  )
where
import Control.Exception (SomeException, throwIO, try)
import Data.List (nub)
import Data.Functor (($>))
import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Monad ()
import Data.Aeson
import Data.Aeson.Types ()
import Data.Bool ()
import Data.ByteString ()
import Data.Foldable ()
import Data.IORef
import Data.Maybe ()
import Data.Text (Text)
import qualified Data.Text as Text
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS ()
import Network.HTTP.Types ()
import Network.Wai ()
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test ()
import System.Directory ()
import System.Exit ()
import System.FilePath ()
import System.Process ()
import System.Timeout ()
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Cognition
import Yuki.N.ContextEpoch
import Yuki.N.Memory.Working
import Yuki.N.Agent
import Yuki.N.Model
import Yuki.N.Context
import Yuki.N.AGUI.Types
import Yuki.N.AGUI.Event
import Yuki.N.Background ()
import Yuki.N.Experience
import Yuki.N.TestSupport


-- | 规格：睡眠决策生成 Wake Packet：遗忘被审计、活动上下文为 wake packet 投影、epoch/焦点/周期一致。
-- 背景：睡眠/唤醒是长任务记忆的核心；包内不一致会让唤醒后的模型迷失。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionSleep :: Assertion
cognitionSleep =
  withWorkDir $ \dir ->
    newCognition dir [sleepDecisionModel] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \incarnation ->
        testRuntime sleepDecisionModel [] Sequential >>= \base ->
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
           in cognitionSleepMessages cognition incarnation "task" (Just "sleep-run") SleepManual runtime messages
                >>= withTextRight (\result ->
                  workingSleepCycles (cognitionWorking cognition) "yuki" >>= \cycles ->
                    contextEpochProject
                      (cognitionContexts cognition)
                      (contextEpochId (sleepResultEpoch result))
                      >>= withTextRight
                        ( \projected ->
                            workingReadFocus (cognitionWorking cognition) "yuki" "task" >>= \focus ->
                              contextEpochHead (cognitionContexts cognition) "yuki" "task" >>= \headEpoch ->
                                sequence_
                                  [ workingMemoryStatus (sleepResultHead result) @?= WorkingAwake,
                                    sleepCycleStatus (sleepResultCycle result) @?= CycleAwake,
                                    wakePacketContinuation (sleepResultPacket result) @?= "Continue from the verified open work.",
                                    assertBool "sleep audits forgetting" (not (null (wakePacketForgotten (sleepResultPacket result)))),
                                    assertBool "active context is a Wake Packet" ("[wake packet" `Text.isPrefixOf` compactionSummary (sleepResultCompaction result)),
                                    fmap (contextSegmentKind . fst) projected @?= [SegmentWakePacket],
                                    assertBool
                                      "forgotten turns are absent from the wake epoch"
                                      (all (not . Text.isInfixOf "turn " . snd) projected),
                                    fmap contextEpochId headEpoch @?= Just (contextEpochId (sleepResultEpoch result)),
                                    fmap focusFrameEpochId focus @?= Just (contextEpochId (sleepResultEpoch result)),
                                    fmap focusFrameObjective focus @?= Just "Continue from the verified open work.",
                                    fmap focusFrameActiveItems focus @?= Just ["current implementation is in progress"],
                                    fmap focusFrameOpenLoops focus @?= Just ["run verification"],
                                    length cycles @?= 1
                                  ]
                        )))
-- | 规格：睡眠保留并行工具回合的完整因果形状（调用+结果成对）。
-- 背景：并行回合是唤醒后最易破坏的结构；拆散会让模型看到悬空调用。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionSleepParallelTools :: Assertion
cognitionSleepParallelTools =
  withWorkDir $ \dir ->
    newCognition dir [retainEverySegmentModel] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \incarnation ->
        testRuntime okModel [] Sequential >>= \base ->
          let runtime = base {runtimeContext = Just (ContextConfig 128 2 96 8000)}
              user = ChatUser ("parallel work " <> Text.replicate 1600 "x")
              messages =
                [ user,
                  ChatAssistant (AssistantTurn "parallel-turn" (Just "checking both") Nothing calls),
                  ChatToolResult "parallel-a" "first result",
                  ChatToolResult "parallel-b" "second result"
                ]
           in cognitionSleepMessages cognition incarnation "parallel-sleep-task" (Just "parallel-sleep-run") SleepManual runtime messages
                >>= withTextRight
                  ( \result ->
                      contextEpochProject
                        (cognitionContexts cognition)
                        (contextEpochId (sleepResultEpoch result))
                        >>= withTextRight
                          ( \projected ->
                              let compacted = dropWhile (/= user) (compactionMessages (sleepResultCompaction result))
                                  replayed = projectedAguiMessages projected >>= toChatMessages
                               in sequence_
                                    [ compacted @?= messages,
                                      fmap (contextSegmentKind . fst) projected
                                        @?= [ SegmentWakePacket,
                                              SegmentUser,
                                              SegmentAssistant,
                                              SegmentToolCall,
                                              SegmentToolCall,
                                              SegmentToolResult,
                                              SegmentToolResult
                                            ],
                                      fmap (contextSegmentTurnGroup . fst) projected
                                        @?= [Nothing, Nothing, Just "parallel-turn", Just "parallel-turn", Just "parallel-turn", Nothing, Nothing],
                                      either (assertFailure . Text.unpack) verifyWake replayed
                                    ]
                          )
                  ))
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
-- | 规格：睡眠作用于活动运行上下文而非初始请求：遗忘输入/睡眠调用/结果，唤醒注入包。
-- 背景：运行中睡眠必须基于当前上下文；基于初始请求会恢复出过期状态。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionLiveSleep :: Assertion
cognitionLiveSleep =
  withWorkDir $ \dir ->
    newCognition dir [sleepDecisionModel] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \incarnation ->
        newIORef (0 :: Int) >>= \turns ->
          newIORef [] >>= \captured ->
            testRuntime (liveSleepAgentModel turns captured) [] Sequential >>= \base ->
              attachCognition
                cognition
                incarnation
                base {runtimeContext = Just (ContextConfig 128 2 96 8000)}
                >>= \runtime ->
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
                   in collectEvents runtime input >>= \events ->
                        readIORef captured >>= \secondRequest ->
                          contextEpochHead (cognitionContexts cognition) "yuki" "live-sleep-task" >>= \epoch ->
                            traverse
                              (contextEpochProject (cognitionContexts cognition) . contextEpochId)
                              epoch
                              >>= \projected ->
                                sequence_
                                  [ assertBool "run completed after sleeping" (any (\case RunFinished {} -> True; _ -> False) events),
                                    assertBool "next turn receives a Wake Packet" (any wakeMessage secondRequest),
                                    assertBool "forgotten live user input is absent" (ChatUser "live-run-user-sentinel" `notElem` secondRequest),
                                    assertBool "forgotten sleep call is absent" (not (any sleepCall secondRequest)),
                                    assertBool "forgotten sleep result is absent" (not (any toolResult secondRequest)),
                                    fmap (fmap (fmap (contextSegmentKind . fst))) projected
                                      @?= Just (Right [SegmentWakePacket, SegmentAssistant]),
                                    assertBool
                                      "closed context does not resurrect the forgotten live input"
                                      ( maybe
                                          False
                                          (either (const False) (all (not . Text.isInfixOf "live-run-user-sentinel" . snd)))
                                          projected
                                      )
                                  ])
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
-- | 规格：预制备的检查点+Wake Packet 在重启后恢复为一个连贯唤醒纪元。
-- 背景：预制备恢复是崩溃恢复路径；恢复不一致会让用户丢失全部进度。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionPreparedRecovery :: Assertion
cognitionPreparedRecovery =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\before ->
      ensureIncarnation before "yuki" >>= \_ ->
        contextEpochCommit
          (cognitionContexts before)
          "yuki"
          "recovery-task"
          Nothing
          [ContextSegmentInput "recovery-user" SegmentUser AuthorityUser "recover this task" Nothing Nothing]
          Nothing
          >>= withTextRight
            ( \baseEpoch ->
                experienceHead (cognitionExperiences before) "yuki" >>= \cursor ->
                  workingCreate (cognitionWorking before) "yuki" cursor >>= withTextRight (\created ->
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
                     in workingPutFocus
                          (cognitionWorking before)
                          "yuki"
                          (workingMemoryRevision created)
                          frame
                          >>= withTextRight
                            ( \focused ->
                                workingRequestSleep
                                  (cognitionWorking before)
                                  "yuki"
                                  (workingMemoryRevision focused)
                                  "prepared-cycle"
                                  "recovery-task"
                                  (Just "recovery-run")
                                  (contextEpochId baseEpoch)
                                  SleepManual
                                  >>= withTextRight
                                    ( \(quiescing, _) ->
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
                                         in workingPrepareCheckpoint
                                              (cognitionWorking before)
                                              "yuki"
                                              (workingMemoryRevision quiescing)
                                              "prepared-cycle"
                                              checkpoint
                                              packet
                                              >>= withTextRight
                                                ( const
                                                    ( newCognition dir [] Nothing >>= withTextRight verifyRecovered
                                                    )
                                                )
                                    )
                            )
                  )
            ))
  where
    verifyRecovered recovered =
      workingRead (cognitionWorking recovered) "yuki" >>= \head' ->
        workingReadFocus (cognitionWorking recovered) "yuki" "recovery-task" >>= \focus ->
          workingReadSleepCycle (cognitionWorking recovered) "prepared-cycle" >>= \cycle' ->
            contextEpochHead (cognitionContexts recovered) "yuki" "recovery-task" >>= \epoch ->
              sequence_
                [ fmap workingMemoryStatus head' @?= Just WorkingAwake,
                  fmap sleepCycleStatus cycle' @?= Just CycleAwake,
                  fmap contextEpochWakePacketId epoch @?= Just (Just "prepared-packet"),
                  fmap focusFrameEpochId focus @?= (contextEpochId <$> epoch),
                  fmap focusFrameObjective focus @?= Just "wake objective",
                  fmap focusFrameActiveItems focus @?= Just ["wake active"],
                  fmap focusFrameOpenLoops focus @?= Just ["wake loop"],
                  fmap focusFrameProvisionalClaims focus @?= Just []
                ]
-- | 规格：睡眠失败显式抛错而非静默压缩，工作周期与 epoch 保持原状。
-- 背景：静默降级为压缩会丢失睡眠语义；显式失败让调用方决定处理。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionSleepFailure :: Assertion
cognitionSleepFailure =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \incarnation ->
        testRuntime okModel [] Sequential >>= \base ->
          let runtime = base {runtimeContext = Just contextConfig}
              input = (sampleInput []) {runThreadId = "failed-sleep-task", runId = "failed-sleep-run"}
              messages = [ChatUser "work that must not disappear"]
           in case forcedCompaction runtime [] messages of
                Nothing -> assertFailure "missing forced compaction fixture"
                Just compaction ->
                  ( try
                      (afterCompaction (cognitionHooks cognition incarnation) input 1 False True messages compaction) ::
                      IO (Either SomeException Compaction)
                  )
                    >>= \attempt ->
                      workingSleepCycles (cognitionWorking cognition) "yuki" >>= \cycles ->
                        contextEpochHead (cognitionContexts cognition) "yuki" "failed-sleep-task" >>= \epoch ->
                          sequence_
                            [ either (const (pure ())) (const (assertFailure "sleep failure was silently accepted")) attempt,
                              cycles @?= [],
                              fmap contextEpochWakePacketId epoch @?= Just Nothing
                            ])
sleepDecisionModel :: Model
sleepDecisionModel =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "continuation" .= ("Continue from the verified open work." :: Text),
                    "activeItems" .= [("current implementation is in progress" :: Text)],
                    "openLoops" .= [("run verification" :: Text)],
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
    [
      testCase "sleeps, forgets, wakes and continues with a Wake Packet" cognitionSleep,
      testCase "preserves one parallel tool turn through sleep and wake" cognitionSleepParallelTools,
      testCase "sleeps over the live run context rather than its initial request" cognitionLiveSleep,
      testCase "fails explicitly rather than silently compacting when sleep fails" cognitionSleepFailure,
      testCase "recovers a prepared sleep into one coherent wake epoch" cognitionPreparedRecovery
    ]
