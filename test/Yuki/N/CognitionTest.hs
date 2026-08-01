-- | 分身认知核心测试
--
-- 覆盖：SHA-256 身份、经验流、上下文隔离、遗留迁移、终止结果、epoch 权威上下文与旧版并行工具修复。
-- 边界：这是 incarnation cognition 组的主体；档案/记忆/睡眠/生命周期见各子模块。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
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

import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Exception ()
import Control.Monad ((>=>))
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Bool ()
import Data.ByteString ()
import Data.Foldable ()
import Data.Functor (($>))
import Data.IORef
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS ()
import Network.HTTP.Types
import Network.Wai ()
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test
import System.Directory ()
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
import Yuki.N.Blob
import Yuki.N.Cognition
import Yuki.N.Context ()
import Yuki.N.ContextEpoch
import Yuki.N.Experience
import Yuki.N.Facts ()
import Yuki.N.Incarnation ()
import Yuki.N.Inspect
import Yuki.N.Journal ()
import Yuki.N.Memory.Archive
import Yuki.N.Memory.LongTerm
import Yuki.N.Memory.Working
import Yuki.N.Model
import Yuki.N.Provider.OpenAI ()
import Yuki.N.Replay ()
import Yuki.N.Server
import Yuki.N.Sessions
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig ()
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

-- | 规格：内容身份使用真实 SHA-256（空串与已知向量的标准摘要）。
-- 背景：内容寻址是一切记忆/工件去重的根基；哈希实现错误会让去重与归档全面错乱。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionSha :: Assertion
cognitionSha =
  sequence_
    [ sha256 "" @?= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      sha256 "abc" @?= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    ]

-- | 规格：per-incarnation 经验流单调追加，陈旧游标被拒绝，重启后保留。
-- 背景：经验流是记忆的时间轴；游标乱序与重启丢失都会破坏因果链。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionExperience :: Assertion
cognitionExperience =
  withWorkDir $ \dir ->
    newExperienceStore dir
      >>= withTextRight
        ( \store ->
            experienceHead store "yuki" >>= \zero ->
              experienceAppend store (Just zero) (experienceDraft "first")
                >>= withTextRight
                  ( \first ->
                      experienceAppend store (Just zero) (experienceDraft "stale") >>= \stale ->
                        newExperienceStore dir
                          >>= withTextRight
                            ( \reopened ->
                                experienceEvents reopened "yuki" >>= \events ->
                                  sequence_
                                    [ experienceSeq first @?= 1,
                                      assertLeft stale,
                                      fmap experienceSeq events @?= [1]
                                    ]
                            )
                  )
        )
 where
  experienceDraft kind =
    ExperienceDraft "yuki" "operation" "yuki" Nothing (Just "task") (Just "run") Nothing Nothing kind "sha256-payload" "sha256-payload"

-- | 规格：同一任务在不同 incarnation 的上下文头部与历史互不串扰。
-- 背景：分身隔离是产品承诺；串扰会让一个分身的记忆泄漏进另一个。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionContextIsolation :: Assertion
cognitionContextIsolation =
  newMemoryBlobStore >>= \blobs ->
    newMemoryContextEpochStore blobs >>= \store ->
      contextEpochCommit store "north" task Nothing [segment "north/1" "north first"] Nothing
        >>= withTextRight
          ( \northFirst ->
              contextEpochCommit store "south" task Nothing [segment "south/1" "south only"] Nothing
                >>= withTextRight
                  ( \southOnly ->
                      contextEpochCommit store "north" task (Just (contextEpochId northFirst)) [segment "north/2" "north second"] Nothing
                        >>= withTextRight
                          ( \northSecond ->
                              (,,,)
                                <$> contextEpochHead store "north" task
                                <*> contextEpochHead store "south" task
                                <*> contextEpochList store "north" task
                                <*> contextEpochList store "south" task
                                >>= \(northHead, southHead, northHistory, southHistory) ->
                                  sequence_
                                    [ fmap contextEpochId northHead @?= Just (contextEpochId northSecond),
                                      fmap contextEpochId southHead @?= Just (contextEpochId southOnly),
                                      fmap contextEpochId northHistory @?= fmap contextEpochId [northFirst, northSecond],
                                      fmap contextEpochId southHistory @?= [contextEpochId southOnly],
                                      fmap contextEpochIncarnationId northHistory @?= ["north", "north"],
                                      fmap contextEpochIncarnationId southHistory @?= ["south"]
                                    ]
                          )
                  )
          )
 where
  task = "same-task"
  segment source content =
    ContextSegmentInput source SegmentUser AuthorityUser content Nothing Nothing

-- | 规格：遗留任务迁移幂等，写入经验/上下文/工作记忆/任务档案且不提升长期记忆。
-- 背景：迁移是升级路径；非幂等会让重复迁移产生重复档案，误提升则污染长期记忆。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionLegacyTaskMigration :: Assertion
cognitionLegacyTaskMigration =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing
      >>= withTextRight
        ( \cognition ->
            ensureIncarnation cognition identity >>= \incarnation ->
              cognitionMigrateLegacyTask cognition incarnation task messages (Just candidate)
                >>= withTextRight
                  ( \() ->
                      migrationSnapshot cognition >>= \before ->
                        cognitionMigrateLegacyTask cognition incarnation task messages (Just candidate)
                          >>= withTextRight
                            ( \() ->
                                migrationSnapshot cognition >>= \repeated ->
                                  verify cognition before repeated
                            )
                  )
        )
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
      [epoch] ->
        contextEpochProject (cognitionContexts cognition) (contextEpochId epoch)
          >>= withTextRight
            ( \projected ->
                sequence_
                  [ fmap (contextSegmentKind . fst) projected @?= [SegmentUser, SegmentAssistant],
                    fmap snd projected @?= ["Restore the amber workspace.", "The workspace was restored."]
                  ]
            )
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
                  (maybe False (experienceEventId event `elem`) (focusFrameRecentOutcomeRefs <$> focus))
              ]

-- | 规格：失败与取消运行的终止载荷被记录为 RunTerminated 事件并保留状态。
-- 背景：终止状态是审计闭环；遗漏会让失败运行看起来从未发生。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionTerminalOutcomes :: Assertion
cognitionTerminalOutcomes =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing
      >>= withTextRight
        ( \cognition ->
            ensureIncarnation cognition "yuki" >>= \incarnation ->
              let hooks = cognitionHooks cognition incarnation
                  failed = (sampleInput []) {runThreadId = "failed-task", runId = "failed-run"}
                  cancelled = (sampleInput []) {runThreadId = "cancelled-task", runId = "cancelled-run"}
               in afterRunOutcome hooks failed (RunFailed "PROVIDER_ERROR" "provider down") [ChatUser "failed input"]
                    *> afterRunOutcome hooks cancelled RunWasCancelled [ChatUser "cancelled input"]
                    *> experienceEvents (cognitionExperiences cognition) "yuki"
                    >>= traverse (terminalStatus cognition)
                      . filter ((== "RunTerminated") . experienceKind)
                    >>= \statuses ->
                      Map.fromList statuses
                        @?= Map.fromList
                          [ ("failed-run", "failed"),
                            ("cancelled-run", "cancelled")
                          ]
        )
 where
  terminalStatus :: Cognition -> ExperienceEvent -> IO (Text, Text)
  terminalStatus cognition event =
    blobFetch (cognitionBlobs cognition) (experiencePayloadRef event) >>= \case
      Left failure -> assertFailure (Text.unpack failure) $> ("", "")
      Right payload ->
        case eitherDecode payload >>= parseEither (withObject "RunTerminated" (.: "status")) of
          Left failure -> assertFailure failure $> ("", "")
          Right status -> pure (fromMaybe "" (experienceRunId event), status)

-- | 规格：无 transcript 投影时以 ContextEpoch 为权威上下文来源。
-- 背景：epoch 权威是会话重建的兜底；缺失会让重启后的任务丢失全部上下文。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionAuthoritativeContext :: Assertion
cognitionAuthoritativeContext =
  withWorkDir $ \dir ->
    newCognition (dir ++ "/cognition") [] Nothing
      >>= withTextRight
        ( \cognition ->
            sessionServiceAt (dir ++ "/sessions") (const (pure ())) >>= \service ->
              contextEpochCommit
                (cognitionContexts cognition)
                "yuki"
                "authority-task"
                Nothing
                [ ContextSegmentInput "old-user" SegmentUser AuthorityUser "epoch-user-sentinel" Nothing Nothing,
                  ContextSegmentInput "old-answer" SegmentAssistant AuthorityAgent "epoch-assistant-sentinel" Nothing Nothing
                ]
                Nothing
                >>= withTextRight
                  ( \_ ->
                      newIORef [] >>= \captured ->
                        testRuntime (promptCaptureModel captured) [] Sequential >>= \runtime ->
                          let inspection =
                                withCognition
                                  cognition
                                  (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
                              app = application Nothing (Just inspection) Nothing Nothing (const (pure runtime))
                           in transcriptLoad (serviceTranscripts service) "authority-task" >>= \stored ->
                                (stored @?= Nothing)
                                  *> runSession (srequest (agentPost "authority-task")) app
                                  >>= \response ->
                                    readIORef captured >>= \messages ->
                                      sequence_
                                        [ simpleStatus response @?= status200,
                                          assertBool "epoch user survives without transcript" (ChatUser "epoch-user-sentinel" `elem` messages),
                                          assertBool
                                            "epoch assistant survives without transcript"
                                            ( any
                                                ( \case
                                                    ChatAssistant turn -> turnText turn == Just "epoch-assistant-sentinel"
                                                    _ -> False
                                                )
                                                messages
                                            ),
                                          assertBool "latest submitted user is appended" (ChatUser "hello" `elem` messages)
                                        ]
                  )
        )

-- | 规格：旧版拆分的并行工具回合在投影前被修复为因果形状，残缺回合被拒绝。
-- 背景：旧数据修复必须发生在 provider 看到请求之前；不修复会让模型收到悬空调用。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionLegacyParallelTools :: Assertion
cognitionLegacyParallelTools =
  withWorkDir $ \dir ->
    newCognition (dir ++ "/cognition") [] Nothing
      >>= withTextRight
        ( \cognition ->
            sessionServiceAt (dir ++ "/sessions") (const (pure ())) >>= \service ->
              contextEpochCommit
                (cognitionContexts cognition)
                "yuki"
                task
                Nothing
                legacySegments
                Nothing
                >>= withTextRight
                  ( \epoch ->
                      contextEpochProject (cognitionContexts cognition) (contextEpochId epoch)
                        >>= withTextRight
                          ( \projected ->
                              newIORef [] >>= \captured ->
                                testRuntime (promptCaptureModel captured) [] Sequential >>= \runtime ->
                                  let inspection =
                                        withCognition
                                          cognition
                                          (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
                                      app = application Nothing (Just inspection) Nothing Nothing (const (pure runtime))
                                   in runSession (srequest (agentPost task)) app >>= \response ->
                                        readIORef captured >>= \messages ->
                                          verifyIncomplete (cognitionContexts cognition)
                                            *> sequence_
                                              [ (projectedAguiMessages projected >>= toChatMessages) @?= Right history,
                                                dropWhile (/= ChatUser "legacy parallel user") messages
                                                  @?= history <> [ChatUser "hello"],
                                                simpleStatus response @?= status200
                                              ]
                          )
                  )
        )
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
  verifyIncomplete store =
    contextEpochCommit
      store
      "yuki"
      "incomplete-tool-task"
      Nothing
      [ ContextSegmentInput "incomplete-turn" SegmentAssistant AuthorityAgent "working" Nothing Nothing,
        ContextSegmentInput "incomplete-call" SegmentToolCall AuthorityAgent (jsonText (ModelToolCall "incomplete-call" "work" "{}")) (Just "incomplete-call") Nothing
      ]
      Nothing
      >>= withTextRight
        ( contextEpochProject store . contextEpochId
            >=> withTextRight (assertLeft . projectedAguiMessages)
        )
