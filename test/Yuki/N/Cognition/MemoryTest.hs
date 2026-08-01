-- | 分身认知 · 长期记忆与印象测试
--
-- 覆盖：长期记忆留痕与隔离；印象激活/跨任务/失败/闭包与各守卫、误报迁移。
-- 边界：覆盖 Yuki.N.Memory.LongTerm 与 Yuki.N.Memory.Impression。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.Cognition.MemoryTest
  ( cognitionLongTermTest,
    cognitionImpression,
    cognitionImpressionAcrossTasks,
    cognitionImpressionFailure,
    cognitionImpressionClosure,
    cognitionImpressionProposalGuard,
    cognitionImpressionEvidenceGuard,
    cognitionImpressionDiagnosticGuard,
    cognitionImpressionFalseMigration,
    cognitionMemoryTests,
  )
where

import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Exception ()
import Control.Monad ()
import Data.Aeson
import Data.Aeson.Types ()
import Data.Bool ()
import Data.ByteString ()
import Data.Foldable ()
import Data.Functor (($>))
import Data.IORef
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
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
import Yuki.N.AGUI.Event ()
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Background ()
import Yuki.N.Cognition
import Yuki.N.Experience
import Yuki.N.Memory.Impression
import Yuki.N.Memory.LongTerm
import Yuki.N.Model
import Yuki.N.TestSupport

-- | 规格：长期记忆按分身隔离：记住、目录、grep、读取均留痕并持久化。
-- 背景：长期记忆是唯一持久知识层；隔离与留痕错误会泄漏或不可审计。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionLongTermTest :: Assertion
cognitionLongTermTest =
  withWorkDir $ \dir ->
    newLongTermStore dir
      >>= withTextRight
        ( \store ->
            longTermRemember
              store
              (RememberRequest "yuki" MemoryPrivate "preference" "琥珀色是这个分身的参考色" ["琥珀", "color"] ["experience/1"])
              >>= withTextRight
                ( \memory ->
                    longTermCatalog store "yuki" 10 >>= \own ->
                      longTermCatalog store "other" 10 >>= \other ->
                        longTermGrep store (GrepRequest "yuki" "琥珀" Nothing 8)
                          >>= withTextRight
                            ( \_ ->
                                longTermRead store (ReadRequest "yuki" (longMemoryId memory) Nothing)
                                  >>= withTextRight
                                    ( \_ ->
                                        newLongTermStore dir
                                          >>= withTextRight
                                            ( \reopened ->
                                                longTermReceipts reopened "yuki" >>= \receipts ->
                                                  sequence_
                                                    [ fmap memoryCatalogId own @?= [longMemoryId memory],
                                                      other @?= [],
                                                      length receipts @?= 2,
                                                      sort (fmap memoryReadReceiptAction receipts) @?= ["grep", "read"]
                                                    ]
                                            )
                                    )
                            )
                )
        )

-- | 规格：印象激活注入非事实性提示（不注入记忆原文）并指引 memory_grep。
-- 背景：印象只是线索而非事实注入；注入原文会让模型把提示当事实。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionImpression :: Assertion
cognitionImpression =
  newMemoryLongTermStore >>= \longTerm ->
    longTermRemember
      longTerm
      (RememberRequest "yuki" MemoryPrivate "preference" "secret amber memory content" ["amber"] ["source"])
      >>= withTextRight
        ( \memory ->
            newMemoryImpressionStore >>= \impressions ->
              longTermCatalog longTerm "yuki" 8 >>= \catalog ->
                activateImpression
                  [impressionCueModel (longMemoryId memory)]
                  Nothing
                  impressions
                  "yuki"
                  (ImpressionScope "task" "run" "intent")
                  "pick a color"
                  [longMemoryId memory]
                  (jsonText catalog)
                  >>= withTextRight
                    ( \activation ->
                        let injected = impressionActivationInjectedText activation
                         in sequence_
                              [ assertBool "cue is explicitly non-factual" ("non-factual" `Text.isInfixOf` injected),
                                assertBool "cue tells the agent to grep" ("memory_grep" `Text.isInfixOf` injected),
                                assertBool "long-term content is not injected" (not ("secret amber memory content" `Text.isInfixOf` injected))
                              ]
                    )
        )

-- | 规格：印象激活跨任务留痕（task/run/intent），每次激活都注入线索。
-- 背景：激活审计是印象机制的可信度来源；跨任务漏记会让滥用不可追踪。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionImpressionAcrossTasks :: Assertion
cognitionImpressionAcrossTasks =
  withWorkDir $ \dir ->
    newCognition dir [impressionCueWithoutMemoryModel] Nothing
      >>= withTextRight
        ( \cognition ->
            ensureIncarnation cognition "yuki" >>= \incarnation ->
              let hooks = cognitionHooks cognition incarnation
                  first = impressionInput "task-a" "run-a" "intent-a" "first direction"
                  second = impressionInput "task-b" "run-b" "intent-b" "second direction"
                  activate input = transformContext hooks input [ChatUser (latestUser input)]
               in activate first >>= \firstContext ->
                    activate second >>= \secondContext ->
                      activate second
                        *> impressionActivations (cognitionImpressions cognition) "yuki"
                        >>= \activations ->
                          sequence_
                            [ fmap impressionActivationTaskId activations @?= ["task-a", "task-b"],
                              fmap impressionActivationRunId activations @?= ["run-a", "run-b"],
                              fmap impressionActivationIntentId activations @?= ["intent-a", "intent-b"],
                              fmap impressionActivationError activations @?= [Nothing, Nothing],
                              assertBool "first task received an impression cue" (any impressionCue firstContext),
                              assertBool "second task received an impression cue" (any impressionCue secondContext)
                            ]
        )
 where
  latestUser input =
    fromMaybe "" . listToMaybe . reverse $
      [text | User message <- runMessages input, Right text <- [userText (userContent message)]]
  impressionCue (ChatSystem content) = "non-factual" `Text.isInfixOf` content
  impressionCue _ = False

-- | 规格：模型链耗尽的激活失败被记录并携带任务范围。
-- 背景：失败也要入账；静默失败会让运维误以为激活成功。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionImpressionFailure :: Assertion
cognitionImpressionFailure =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing
      >>= withTextRight
        ( \cognition ->
            ensureIncarnation cognition "yuki" >>= \incarnation ->
              let input = impressionInput "task-failed" "run-failed" "intent-failed" "unavailable profile"
               in transformContext (cognitionHooks cognition incarnation) input [ChatUser "unavailable profile"]
                    *> impressionActivations (cognitionImpressions cognition) "yuki"
                    >>= \activations ->
                      case activations of
                        [activation] ->
                          sequence_
                            [ impressionActivationTaskId activation @?= "task-failed",
                              impressionActivationRunId activation @?= "run-failed",
                              impressionActivationIntentId activation @?= "intent-failed",
                              impressionActivationError activation @?= Just "model chain exhausted"
                            ]
                        _ -> assertFailure ("unexpected activation failure count: " <> show (length activations))
        )

impressionInput :: Text -> Text -> Text -> Text -> RunAgentInput
impressionInput task run intent content =
  (sampleInput [])
    { runThreadId = task,
      runId = run,
      runMessages = [User (UserMessage intent (UserText content) Nothing)]
    }

-- | 规格：印象整合使用真实经验载荷闭包，修订版本携带源经验引用。
-- 背景：闭包错误会让印象基于错误输入形成，污染后续决策。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionImpressionClosure :: Assertion
cognitionImpressionClosure =
  withWorkDir $ \dir ->
    newIORef [] >>= \captured ->
      newCognition dir [impressionConsolidationModel captured] Nothing
        >>= withTextRight
          ( \cognition ->
              ensureIncarnation cognition "yuki" >>= \incarnation ->
                let input =
                      (sampleInput [])
                        { runThreadId = "closure-task",
                          runId = "closure-run",
                          runMessages =
                            [ User
                                ( UserMessage
                                    "closure-user"
                                    (UserText "actual-user-payload-sentinel")
                                    Nothing
                                )
                            ]
                        }
                    messages =
                      [ ChatUser "actual-user-payload-sentinel",
                        ChatAssistant
                          (AssistantTurn "closure-answer" (Just "actual-assistant-payload-sentinel") Nothing [])
                      ]
                 in afterRunOutcome (cognitionHooks cognition incarnation) input RunSucceeded messages
                      *> waitUntil
                        ( any ((== "ImpressionConsolidationSucceeded") . experienceKind)
                            <$> experienceEvents (cognitionExperiences cognition) "yuki"
                        )
                      >>= \finished ->
                        readIORef captured >>= \requestMessages' ->
                          impressionRead (cognitionImpressions cognition) "yuki" >>= \state ->
                            impressionRevisions (cognitionImpressions cognition) "yuki" >>= \revisions ->
                              let rendered =
                                    Text.intercalate
                                      "\n"
                                      [text | ChatUser text <- requestMessages']
                                  source =
                                    impressionRevisionExperienceRef
                                      <$> listToMaybe (reverse revisions)
                               in sequence_
                                    [ assertBool "consolidation completed" finished,
                                      assertBool "closure contains the real user payload" ("actual-user-payload-sentinel" `Text.isInfixOf` rendered),
                                      assertBool "closure contains the real assistant payload" ("actual-assistant-payload-sentinel" `Text.isInfixOf` rendered),
                                      assertBool "revision carries its source experience" (maybe False (not . Text.null) source),
                                      impressionRevision state @?= 1
                                    ]
          )

-- | 规格：无证据支撑的记忆提案被拒绝。
-- 背景：印象管线禁止凭空写记忆；守卫失效会让记忆库充满噪音。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionImpressionProposalGuard :: Assertion
cognitionImpressionProposalGuard =
  newMemoryImpressionStore >>= \impressions ->
    consolidateImpression
      [ungroundedProposalModel]
      Nothing
      impressions
      "yuki"
      "experience-1"
      []
      ["experience-1"]
      "{}"
      >>= assertLeft

-- | 规格：无源经验引用的印象被拒绝。
-- 背景：每个印象必须锚定经验；无锚印象不可审计。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionImpressionEvidenceGuard :: Assertion
cognitionImpressionEvidenceGuard =
  newMemoryImpressionStore >>= \impressions ->
    consolidateImpression
      [impressionDecisionModel "continuity" "This direction may continue." []]
      Nothing
      impressions
      "yuki"
      "experience-1"
      []
      ["experience-1"]
      "{}"
      >>= assertLeft

-- | 规格：把工具诊断误当印象的记忆提案被拒绝。
-- 背景：诊断信息不是印象；误收会让记忆库混入实现噪音。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionImpressionDiagnosticGuard :: Assertion
cognitionImpressionDiagnosticGuard =
  newMemoryImpressionStore >>= \impressions ->
    consolidateImpression
      [impressionDecisionModel "grep lesson" "A truncated memory_grep result requires memory_read." ["experience-1"]]
      Nothing
      impressions
      "yuki"
      "experience-1"
      []
      ["experience-1"]
      "{}"
      >>= assertLeft

-- | 规格：已知误报 grep 印象被迁移为 void 提案并记录来源。
-- 背景：历史坏数据必须显式作废而非删除；作废记录是审计要求。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionImpressionFalseMigration :: Assertion
cognitionImpressionFalseMigration =
  withWorkDir $ \dir ->
    encodeFile (dir ++ "/impressions.json") legacy
      *> newImpressionStore dir
      >>= withTextRight
        ( \store ->
            impressionRead store "yuki-8nckh0" >>= \state ->
              impressionRevisions store "yuki-8nckh0" >>= \revisions ->
                newImpressionStore dir
                  >>= withTextRight
                    ( \reopened ->
                        impressionRead reopened "yuki-8nckh0" >>= \again ->
                          sequence_
                            [ impressionRevision state @?= 4,
                              impressionItems state @?= [],
                              impressionRevision again @?= 4,
                              assertBool
                                "migration records the voided impression"
                                ( any
                                    (elem "impression-q1r2s3" . impressionRevisionVoidProposals)
                                    revisions
                                )
                            ]
                    )
        )
 where
  legacy =
    object
      [ "states"
          .= ( Map.fromList
                 [ ( "yuki-8nckh0" :: Text,
                     object
                       [ "incarnationId" .= ("yuki-8nckh0" :: Text),
                         "revision" .= (3 :: Int),
                         "items"
                           .= [ object
                                  [ "id" .= ("impression-q1r2s3" :: Text),
                                    "label" .= ("GrepTruncationAwareness" :: Text),
                                    "intuition" .= ("memory_grep scannedEntries hid 改天孙观为婺女观." :: Text),
                                    "strength" .= (0.9 :: Double),
                                    "sourceMemoryIds" .= ([] :: [Text]),
                                    "sourceExperienceRefs" .= ["event-1" :: Text],
                                    "updated" .= (1 :: Int)
                                  ]
                              ],
                         "generatorRevision" .= ("impression-consolidation/v2" :: Text),
                         "effectiveHash" .= ("old" :: Text),
                         "updated" .= (1 :: Int)
                       ]
                   )
                 ]
             ),
        "activations" .= ([] :: [Value]),
        "revisions" .= ([] :: [Value])
      ]

ungroundedProposalModel :: Model
ungroundedProposalModel =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "impressions" .= ([] :: [Value]),
                    "memoryProposals"
                      .= [ object
                             [ "content" .= ("remember this without evidence" :: Text),
                               "kind" .= ("preference" :: Text),
                               "visibility" .= ("private" :: Text),
                               "sourceRefs" .= ([] :: [Text]),
                               "reason" .= ("model suggestion" :: Text)
                             ]
                         ],
                    "voidProposals" .= ([] :: [Text]),
                    "reason" .= ("proposal audit" :: Text)
                  ]
              )
          )
      )
      $> Stop
impressionDecisionModel :: Text -> Text -> [Text] -> Model
impressionDecisionModel label intuition sources =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "impressions"
                      .= [ object
                             [ "id" .= ("" :: Text),
                               "label" .= label,
                               "intuition" .= intuition,
                               "strength" .= (0.7 :: Double),
                               "sourceMemoryIds" .= ([] :: [Text]),
                               "sourceExperienceRefs" .= sources
                             ]
                         ],
                    "memoryProposals" .= ([] :: [Value]),
                    "voidProposals" .= ([] :: [Text]),
                    "reason" .= ("test" :: Text)
                  ]
              )
          )
      )
      $> Stop
impressionConsolidationModel :: IORef [ChatMessage] -> Model
impressionConsolidationModel captured =
  fakeModel $ \request emit ->
    writeIORef captured (requestMessages request)
      *> emit
        ( ModelTextDelta
            ( jsonText
                ( object
                    [ "impressions" .= ([] :: [Value]),
                      "memoryProposals" .= ([] :: [Value]),
                      "voidProposals" .= ([] :: [Text]),
                      "reason" .= ("integrated the completed experience" :: Text)
                    ]
                )
            )
        )
      $> Stop
impressionCueModel :: Text -> Model
impressionCueModel memoryId =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "cues"
                      .= [ object
                             [ "hint" .= ("A color preference may be relevant." :: Text),
                               "suggestedQuery" .= ("amber" :: Text),
                               "memoryIds" .= [memoryId],
                               "confidence" .= (0.8 :: Double),
                               "reason" .= ("intent resembles a prior preference" :: Text)
                             ]
                         ]
                  ]
              )
          )
      )
      $> Stop
impressionCueWithoutMemoryModel :: Model
impressionCueWithoutMemoryModel =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "cues"
                      .= [ object
                             [ "hint" .= ("A prior direction may be relevant." :: Text),
                               "suggestedQuery" .= Null,
                               "memoryIds" .= ([] :: [Text]),
                               "confidence" .= (0.7 :: Double),
                               "reason" .= ("the intent resembles an established working direction" :: Text)
                             ]
                         ]
                  ]
              )
          )
      )
      $> Stop
cognitionMemoryTests :: TestTree
cognitionMemoryTests =
  testGroup
    "incarnation cognition memory"
    [ testCase "keeps long-term memory explicit, scoped and receipt-audited" cognitionLongTermTest,
      testCase "activates non-factual impressions without injecting memory content" cognitionImpression,
      testCase "activates and audits impressions across tasks" cognitionImpressionAcrossTasks,
      testCase "records impression activation failures with task scope" cognitionImpressionFailure,
      testCase "consolidates impressions from the actual experience payload closure" cognitionImpressionClosure,
      testCase "rejects ungrounded impression memory proposals" cognitionImpressionProposalGuard,
      testCase "requires current evidence for new impressions" cognitionImpressionEvidenceGuard,
      testCase "keeps tool diagnostics out of impressions" cognitionImpressionDiagnosticGuard,
      testCase "migrates the known false grep impression with provenance" cognitionImpressionFalseMigration
    ]
