-- | 分身认知 · 生命周期与 HTTP 测试
--
-- 覆盖：分身归档/恢复/删除、提示词修订与 Root 迁移、HTTP 端点语义、任务所有权不可变、活动运行归档守卫。
-- 边界：覆盖 Yuki.N.Incarnation 与 Yuki.N.Server 的认知路由。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.Cognition.LifecycleTest
  ( cognitionIncarnationLifecycle,
    cognitionDeleteIncarnation,
    cognitionPrompts,
    cognitionRootMigration,
    cognitionPromptRoot,
    cognitionHttp,
    cognitionLifecycleHttp,
    cognitionTaskOwnerHttp,
    cognitionArchiveActiveRun,
    cognitionLifecycleTests,
  )
where

import Control.Applicative ()
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception ()
import Control.Monad ()
import Data.Aeson
import Data.Aeson.Types ()
import Data.Bool ()
import Data.ByteString ()
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable ()
import Data.Functor ()
import Data.IORef
import Data.List ()
import Data.Maybe (isJust, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS ()
import Network.HTTP.Types
import Network.Wai (queryString)
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
import Yuki.N.AGUI.Types ()
import Yuki.N.Agent
import Yuki.N.Background ()
import Yuki.N.Cognition
import Yuki.N.Experience
import Yuki.N.Incarnation
import Yuki.N.Inspect
import Yuki.N.Memory.Archive
import Yuki.N.Memory.Impression
import Yuki.N.Memory.LongTerm
import Yuki.N.Memory.Working
import Yuki.N.Model
import Yuki.N.Provider.OpenAI ()
import Yuki.N.Runs
import Yuki.N.Server
import Yuki.N.Sessions
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig

-- | 规格：分身创建/归档/恢复闭环：归档后禁止更新与激活，恢复后 revision 递增，默认分身不可归档。
-- 背景：生命周期状态机是分身安全边界；越权操作会破坏活动分身。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionIncarnationLifecycle :: Assertion
cognitionIncarnationLifecycle =
  newMemoryIncarnationStore >>= \store ->
    incarnationCreate store "art" "Art" "Make careful visual judgments." Nothing
      >>= withTextRight
        ( \created ->
            promptAppend
              store
              (Just "art")
              IncarnationCharter
              "test charter"
              "charter"
              "test/v1"
              Nothing
              Nothing
              PromptDraft
              >>= \prompt ->
                incarnationArchive store "yuki" 1 >>= \defaultArchive ->
                  incarnationArchive store "art" (incarnationRevision created)
                    >>= withTextRight
                      ( \archived ->
                          incarnationUpdate
                            store
                            "art"
                            (incarnationRevision archived)
                            "Changed"
                            "Must remain blocked."
                            Nothing
                            >>= \blockedUpdate ->
                              promptActivate
                                store
                                "art"
                                (incarnationRevision archived)
                                (promptRevisionId prompt)
                                >>= \blockedPrompt ->
                                  incarnationRestore store "art" 1 >>= \staleRestore ->
                                    incarnationRestore store "art" (incarnationRevision archived)
                                      >>= withTextRight
                                        ( \restored ->
                                            incarnationRestore store "art" (incarnationRevision restored)
                                              >>= \repeatedRestore ->
                                                sequence_
                                                  [ assertLeft defaultArchive,
                                                    incarnationStatus archived @?= IncarnationArchived,
                                                    assertLeft blockedUpdate,
                                                    assertLeft blockedPrompt,
                                                    assertLeft staleRestore,
                                                    incarnationStatus restored @?= IncarnationActive,
                                                    incarnationRevision restored @?= incarnationRevision archived + 1,
                                                    assertLeft repeatedRestore
                                                  ]
                                        )
                      )
        )

-- | 规格：删除分身会清理其全部派生存储（档案/长期记忆/经验/工作记忆/印象/提示词）。
-- 背景：删除不彻底会残留幽灵数据，导致重新创建同名分身时看到旧数据。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionDeleteIncarnation :: Assertion
cognitionDeleteIncarnation =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing
      >>= withTextRight
        ( \cognition ->
            let identity = "yuki-del"
                incarnationStore = cognitionIncarnations cognition
             in incarnationCreate incarnationStore identity "Del" "To be deleted." Nothing
                  >>= withTextRight
                    ( \created ->
                        let expected = incarnationRevision created
                         in seedStores cognition identity
                              *> incarnationArchive incarnationStore identity expected
                              >>= withTextRight
                                ( \archived ->
                                    deleteIncarnation cognition identity (incarnationRevision archived)
                                      >>= withTextRight (\_ -> verifyGone cognition identity)
                                )
                    )
        )
 where
  seedStores cognition identity = do
    taskArchiveAppend
      (cognitionArchive cognition)
      ( ArchiveRunDraft
          identity
          "del-task"
          "del-run"
          (Just "del-intent")
          "completed"
          Nothing
          [ArchiveEntryDraft "user" ArchiveUser "delete me from the archive" Nothing Nothing Nothing]
      )
      >>= either (ioError . userError . Text.unpack) (const (pure ()))
    longTermRemember
      (cognitionLongTerm cognition)
      (RememberRequest identity MemoryPrivate "preference" "delete me from long-term memory" [] ["src"])
      >>= either (ioError . userError . Text.unpack) (const (pure ()))
    let cursor = ExperienceCursor ("experience/" <> identity) 0
    experienceAppend
      (cognitionExperiences cognition)
      Nothing
      (ExperienceDraft identity "del-op" identity Nothing Nothing Nothing Nothing Nothing "UserInputAccepted" "payload-ref" "payload-hash")
      >>= either (ioError . userError . Text.unpack) (const (pure ()))
    workingCreate (cognitionWorking cognition) identity cursor
      >>= either (ioError . userError . Text.unpack) (const (pure ()))
    impressionCommit
      (cognitionImpressions cognition)
      identity
      0
      (emptyImpressionState identity)
      (ImpressionRevision "del-impression-revision" identity "del-experience" 0 1 "test seed" [] [] "del-invocation" "test/model" 0)
      >>= either (ioError . userError . Text.unpack) (const (pure ()))
  verifyGone cognition identity =
    incarnationList (cognitionIncarnations cognition) >>= \incarnations ->
      promptList (cognitionIncarnations cognition) (Just identity) >>= \prompts ->
        taskArchiveTasks (cognitionArchive cognition) identity 20 >>= \archives ->
          experienceEvents (cognitionExperiences cognition) identity >>= \events ->
            workingRead (cognitionWorking cognition) identity >>= \working ->
              longTermCatalog (cognitionLongTerm cognition) identity 20 >>= \catalog ->
                impressionRead (cognitionImpressions cognition) identity >>= \impression ->
                  sequence_
                    [ assertBool "incarnation record removed" (all ((/= identity) . incarnationId) incarnations),
                      assertBool "charter prompts removed" (null prompts),
                      assertBool "task archive removed" (null archives),
                      assertBool "experience events removed" (null events),
                      assertBool "working memory removed" (working == Nothing),
                      assertBool "long-term catalog removed" (null catalog),
                      assertBool "impression state emptied" (null (impressionItems impression))
                    ]

-- | 规格：提示词修订可追加、激活、编译，默认提示在引导期激活且 Root 保持 v2 协议。
-- 背景：提示词是行为注入通道；激活与编译错误会让分身行为失真。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionPrompts :: Assertion
cognitionPrompts =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing
      >>= withTextRight
        ( \cognition ->
            ensureIncarnation cognition "yuki" >>= \initial ->
              ( incarnationUpdate
                  (cognitionIncarnations cognition)
                  "yuki"
                  (incarnationRevision initial)
                  ""
                  (incarnationDirection initial)
                  (incarnationImpressionModel initial)
                  >>= assertLeft
              )
                *> promptAppend
                  (cognitionIncarnations cognition)
                  (Just "yuki")
                  IncarnationCharter
                  "audit edit"
                  "A deliberately revised working style."
                  "test/v1"
                  Nothing
                  (incarnationPromptRevision initial)
                  PromptDraft
                >>= \revision ->
                  promptActivate
                    (cognitionIncarnations cognition)
                    "yuki"
                    (incarnationRevision initial)
                    (promptRevisionId revision)
                    >>= withTextRight
                      ( \activated ->
                          compileIncarnationPrompt cognition activated >>= \compiled ->
                            promptList (cognitionIncarnations cognition) (Just "yuki") >>= \revisions ->
                              promptList (cognitionIncarnations cognition) Nothing >>= \roots ->
                                sequence_
                                  [ assertBool "default prompt is active at bootstrap" (isJust (incarnationPromptRevision initial)),
                                    assertBool "compiled prompt includes root constitution" ("Root Constitution" `Text.isInfixOf` compiled),
                                    assertBool "compiled prompt includes activated charter" ("deliberately revised" `Text.isInfixOf` compiled),
                                    assertBool "prompt lineage remains auditable" (length revisions >= 2),
                                    assertBool
                                      "active Root does not contain the v2 Task Archive protocol"
                                      ( any
                                          ( \root ->
                                              promptStatus root == PromptActive
                                                && promptGeneratorRevision root == rootPromptRevision
                                                && "immutable Task archive" `Text.isInfixOf` promptContent root
                                          )
                                          roots
                                      )
                                  ]
                      )
        )

-- | 规格：遗留自动 Root 被升级到 Task Archive 协议且保持唯一活动 Root。
-- 背景：Root 是全局行为宪法；升级失败会让新协议能力不可用。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionRootMigration :: Assertion
cognitionRootMigration =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing
      >>= withTextRight
        ( \cognition ->
            promptList (cognitionIncarnations cognition) Nothing >>= \roots ->
              case listToMaybe (reverse (filter ((== PromptActive) . promptStatus) roots)) of
                Nothing -> assertFailure "fresh cognition has no active Root"
                Just active ->
                  promptAppend
                    (cognitionIncarnations cognition)
                    Nothing
                    RootConstitution
                    "kernel bootstrap"
                    "# Yuki Root Constitution · v1\nLegacy automatic root."
                    "root-constitution/v1"
                    Nothing
                    (Just (promptRevisionId active))
                    PromptDraft
                    >>= \legacy ->
                      promptActivateRoot
                        (cognitionIncarnations cognition)
                        (promptOrdinal active)
                        (promptRevisionId legacy)
                        >>= withTextRight
                          ( const
                              ( newCognition dir [] Nothing
                                  >>= withTextRight
                                    ( \reopened ->
                                        promptList (cognitionIncarnations reopened) Nothing >>= \migrated ->
                                          let activeRoots = filter ((== PromptActive) . promptStatus) migrated
                                           in sequence_
                                                [ length activeRoots @?= 1,
                                                  fmap promptGeneratorRevision activeRoots @?= [rootPromptRevision],
                                                  assertBool
                                                    "automatic Root migration lost the Task Archive protocol"
                                                    (any (Text.isInfixOf "immutable Task archive" . promptContent) activeRoots)
                                                ]
                                    )
                              )
                          )
        )

-- | 规格：生成 charter 时模型请求包含活动编辑后的 Root，生成修订记录 Root 血统。
-- 背景：Root 编辑必须传导到生成请求；否则手动修订形同虚设。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionPromptRoot :: Assertion
cognitionPromptRoot =
  withWorkDir $ \dir ->
    newIORef [] >>= \captured ->
      newCognition dir [promptCaptureModel captured] Nothing
        >>= withTextRight
          ( \cognition ->
              ensureIncarnation cognition "yuki" >>= \incarnation ->
                promptList (cognitionIncarnations cognition) Nothing >>= \roots ->
                  let expected =
                        maybe
                          0
                          promptOrdinal
                          (listToMaybe (reverse (filter ((== PromptActive) . promptStatus) roots)))
                   in promptAppend
                        (cognitionIncarnations cognition)
                        Nothing
                        RootConstitution
                        "root audit test"
                        "# CUSTOM ROOT SENTINEL\nUse the audited root."
                        "manual-root-test/v1"
                        Nothing
                        (promptRevisionId <$> listToMaybe roots)
                        PromptDraft
                        >>= \root ->
                          promptActivateRoot (cognitionIncarnations cognition) expected (promptRevisionId root)
                            >>= withTextRight
                              ( \activated ->
                                  cognitionGeneratePrompt cognition incarnation "regenerate beneath edited root"
                                    >>= withTextRight
                                      ( \generated ->
                                          readIORef captured >>= \messages ->
                                            promptList (cognitionIncarnations cognition) Nothing >>= \revisions ->
                                              sequence_
                                                [ promptStatus activated @?= PromptActive,
                                                  length (filter ((== PromptActive) . promptStatus) revisions) @?= 1,
                                                  assertBool
                                                    "generator request contains the active edited Root"
                                                    (any rootMarked messages),
                                                  assertBool
                                                    "generated charter records its Root generator lineage"
                                                    (promptRevisionId root `Text.isInfixOf` promptGeneratorRevision generated)
                                                ]
                                      )
                              )
          )
 where
  rootMarked (ChatSystem text) = "CUSTOM ROOT SENTINEL" `Text.isInfixOf` text
  rootMarked _ = False

-- | 规格：分身/印象/prompt 端点按 HTTP 语义响应（200/400 等），默认分身可见。
-- 背景：HTTP 状态语义是前端契约；错误状态会让界面分支错误。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionHttp :: Assertion
cognitionHttp =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing
      >>= withTextRight
        ( \cognition ->
            testRuntime okModel [] Parallel >>= \runtime ->
              let inspection = withCognition cognition emptyInspection
                  app = application Nothing (Just inspection) Nothing Nothing (const (pure runtime))
               in promptList (cognitionIncarnations cognition) Nothing >>= \roots ->
                    case listToMaybe roots of
                      Nothing -> assertFailure "missing Root prompt revision"
                      Just root ->
                        runSession (request (httpGet ["incarnations"])) app >>= \incarnations ->
                          runSession (request (httpGet ["incarnations", "yuki", "impression"])) app >>= \impression ->
                            runSession
                              ( srequest
                                  ( jsonRequest
                                      methodPost
                                      ["prompts", "root"]
                                      ( object
                                          [ "sourceIntent" .= (" " :: Text),
                                            "content" .= ("must not be accepted" :: Text)
                                          ]
                                      )
                                  )
                              )
                              app
                              >>= \emptyDraft ->
                                runSession
                                  ( srequest
                                      ( jsonRequest
                                          methodPost
                                          ["incarnations", "yuki", "prompts"]
                                          ( object
                                              [ "sourceIntent" .= ("invalid lineage" :: Text),
                                                "content" .= ("must remain a draft" :: Text),
                                                "parentRevision" .= promptRevisionId root
                                              ]
                                          )
                                      )
                                  )
                                  app
                                  >>= \wrongParent ->
                                    sequence_
                                      [ simpleStatus incarnations @?= status200,
                                        simpleStatus impression @?= status200,
                                        simpleStatus emptyDraft @?= status400,
                                        simpleStatus wrongParent @?= status400,
                                        assertBool
                                          "default incarnation is present"
                                          ("\"id\":\"yuki\"" `ByteString.isInfixOf` LazyByteString.toStrict (simpleBody incarnations))
                                      ]
        )

-- | 规格：分身归档/恢复经 HTTP 与线程会话联动，活动状态在列表中隐藏。
-- 背景：HTTP 生命周期必须与会话状态一致；不一致会让任务悬挂在已归档分身。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionLifecycleHttp :: Assertion
cognitionLifecycleHttp =
  withWorkDir $ \dir ->
    newCognition (dir ++ "/cognition") [] Nothing
      >>= withTextRight
        ( \cognition ->
            sessionServiceAt (dir ++ "/sessions") (const (pure ())) >>= \service ->
              testRuntime okModel [] Parallel >>= \runtime ->
                incarnationCreate
                  (cognitionIncarnations cognition)
                  "art"
                  "Art"
                  "Make careful visual judgments."
                  Nothing
                  >>= withTextRight
                    ( \created ->
                        let view = testView (serviceConfigs service)
                            inspection =
                              withCognition
                                cognition
                                (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
                            app = application Nothing (Just inspection) (Just view) Nothing (const (pure runtime))
                            post path body = runSession (srequest (jsonRequest methodPost path body)) app
                         in post
                              ["threads"]
                              ( object
                                  [ "threadId" .= ("art-task" :: Text),
                                    "title" .= ("Art task" :: Text),
                                    "incarnationId" .= ("art" :: Text)
                                  ]
                              )
                              >>= \taskCreated ->
                                threadConfigRead (serviceConfigs service) "art-task" >>= \bound ->
                                  post
                                    ["incarnations", "art", "archive"]
                                    (object ["expectedRevision" .= incarnationRevision created])
                                    >>= \archived ->
                                      runSession (request (httpGet ["incarnations"])) app >>= \activeList ->
                                        runSession
                                          (request ((httpGet ["incarnations"]) {queryString = [("archived", Just "true")]}))
                                          app
                                          >>= \allList ->
                                            runSession (request (httpGet ["incarnations", "art"])) app >>= \hidden ->
                                              findSession (serviceSessions service) "art-task" >>= \archivedTask ->
                                                post
                                                  ["threads"]
                                                  ( object
                                                      [ "threadId" .= ("rejected-task" :: Text),
                                                        "incarnationId" .= ("art" :: Text)
                                                      ]
                                                  )
                                                  >>= \rejectedCreate ->
                                                    post ["threads", "art-task", "restore"] (object [])
                                                      >>= \blockedTaskRestore ->
                                                        post ["incarnations", "art", "restore"] (object ["expectedRevision" .= (2 :: Int)])
                                                          >>= \restored ->
                                                            findSession (serviceSessions service) "art-task" >>= \stillArchived ->
                                                              post ["threads", "art-task", "restore"] (object [])
                                                                >>= \taskRestored ->
                                                                  sequence_
                                                                    [ simpleStatus taskCreated @?= status200,
                                                                      configIncarnationId bound @?= Just "art",
                                                                      simpleStatus archived @?= status200,
                                                                      assertBool
                                                                        "archived incarnation is hidden from the default list"
                                                                        (not (containsArt activeList)),
                                                                      assertBool
                                                                        "archived incarnation remains auditable"
                                                                        (containsArt allList),
                                                                      simpleStatus hidden @?= status404,
                                                                      fmap sessionArchived archivedTask @?= Just True,
                                                                      fmap sessionIncarnationId archivedTask @?= Just "art",
                                                                      simpleStatus rejectedCreate @?= status409,
                                                                      simpleStatus blockedTaskRestore @?= status409,
                                                                      simpleStatus restored @?= status200,
                                                                      fmap sessionArchived stillArchived @?= Just True,
                                                                      fmap sessionIncarnationId stillArchived @?= Just "art",
                                                                      simpleStatus taskRestored @?= status200
                                                                    ]
                    )
        )
 where
  containsArt =
    ByteString.isInfixOf "\"id\":\"art\""
      . LazyByteString.toStrict
      . simpleBody

-- | 规格：任务所有权不可变：归属分身只能通过线程 config 从 art 迁移为 yuki，直接改 config 被 409 拒绝。
-- 背景：所有权不可变是数据隔离边界；可改写会让任务跨分身漂移。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionTaskOwnerHttp :: Assertion
cognitionTaskOwnerHttp =
  withWorkDir $ \dir ->
    newCognition (dir ++ "/cognition") [] Nothing
      >>= withTextRight
        ( \cognition ->
            sessionServiceAt (dir ++ "/sessions") (const (pure ())) >>= \service ->
              testRuntime okModel [] Parallel >>= \runtime ->
                incarnationCreate
                  (cognitionIncarnations cognition)
                  "art"
                  "Art"
                  "Make careful visual judgments."
                  Nothing
                  >>= withTextRight
                    ( \_ ->
                        let view = testView (serviceConfigs service)
                            inspection =
                              withCognition
                                cognition
                                (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
                            app = application Nothing (Just inspection) (Just view) Nothing (const (pure runtime))
                            create =
                              jsonRequest
                                methodPost
                                ["threads"]
                                (object ["threadId" .= ("owned-task" :: Text), "incarnationId" .= ("art" :: Text)])
                         in runSession (srequest create) app >>= \created ->
                              runSession
                                ( srequest
                                    ( putConfig
                                        "owned-task"
                                        (encode (emptyThreadConfig {configIncarnationId = Just "yuki"}))
                                    )
                                )
                                app
                                >>= \reassigned ->
                                  runSession
                                    ( srequest
                                        ( putConfig
                                            "owned-task"
                                            (encode (emptyThreadConfig {configSystemPrompt = Just "kept"}))
                                        )
                                    )
                                    app
                                    >>= \updated ->
                                      threadConfigRead (serviceConfigs service) "owned-task" >>= \canonical ->
                                        threadConfigWrite
                                          (serviceConfigs service)
                                          "owned-task"
                                          canonical {configIncarnationId = Just "yuki"}
                                          *> runSession (request (httpGet ["incarnations", "art", "tasks"])) app
                                          >>= \artTasks ->
                                            runSession (request (httpGet ["incarnations", "yuki", "tasks"])) app
                                              >>= \yukiTasks ->
                                                findSession (serviceSessions service) "owned-task" >>= \meta ->
                                                  sequence_
                                                    [ simpleStatus created @?= status200,
                                                      simpleStatus reassigned @?= status409,
                                                      simpleStatus updated @?= status204,
                                                      configIncarnationId canonical @?= Just "art",
                                                      configSystemPrompt canonical @?= Just "kept",
                                                      fmap sessionIncarnationId meta @?= Just "art",
                                                      decodeTaskIds artTasks @?= Right ["owned-task"],
                                                      decodeTaskIds yukiTasks @?= Right []
                                                    ]
                    )
        )
 where
  decodeTaskIds response =
    fmap (fmap sessionId) (eitherDecode (simpleBody response) :: Either String [SessionMeta])

-- | 规格：有活动运行的分身拒绝归档（409），运行结束后可归档。
-- 背景：归档正在运行的分身会杀死会话或产生孤儿运行；拒绝是安全阀。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionArchiveActiveRun :: Assertion
cognitionArchiveActiveRun =
  withWorkDir $ \dir ->
    newCognition (dir ++ "/cognition") [] Nothing
      >>= withTextRight
        ( \cognition ->
            sessionServiceAt (dir ++ "/sessions") (const (pure ())) >>= \service ->
              newRunRegistry >>= \runs ->
                newEmptyMVar >>= \release ->
                  testRuntime okModel [] Parallel >>= \runtime ->
                    incarnationCreate
                      (cognitionIncarnations cognition)
                      "art"
                      "Art"
                      "Make careful visual judgments."
                      Nothing
                      >>= withTextRight
                        ( \created ->
                            createSession (serviceSessions service) "art-live-task" Nothing "art" Nothing Nothing
                              >>= withTextRight
                                ( \_ ->
                                    threadConfigWrite
                                      (serviceConfigs service)
                                      "art-live-task"
                                      emptyThreadConfig {configIncarnationId = Just "art"}
                                      *> forkIO
                                        (withRunRegistrationFor runs "art-live-run" "art-live-task" (takeMVar release))
                                      *> waitUntil (elem "art-live-task" <$> activeThreads runs)
                                      >>= \registered ->
                                        let view = testView (serviceConfigs service)
                                            inspection =
                                              withCognition
                                                cognition
                                                (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
                                            app = application Nothing (Just inspection) (Just view) (Just runs) (const (pure runtime))
                                         in runSession
                                              ( srequest
                                                  ( jsonRequest
                                                      methodPost
                                                      ["incarnations", "art", "archive"]
                                                      (object ["expectedRevision" .= incarnationRevision created])
                                                  )
                                              )
                                              app
                                              >>= \blocked ->
                                                putMVar release ()
                                                  *> waitUntil (null <$> activeThreads runs)
                                                  >>= \stopped ->
                                                    incarnationRead (cognitionIncarnations cognition) "art" >>= \current ->
                                                      findSession (serviceSessions service) "art-live-task" >>= \task ->
                                                        sequence_
                                                          [ assertBool "live run registered" registered,
                                                            simpleStatus blocked @?= status409,
                                                            assertBool "run registration released" stopped,
                                                            fmap incarnationStatus current @?= Just IncarnationActive,
                                                            fmap sessionArchived task @?= Just False
                                                          ]
                                )
                        )
        )

cognitionLifecycleTests :: TestTree
cognitionLifecycleTests =
  testGroup
    "incarnation cognition lifecycle"
    [ testCase "archives and restores non-default incarnations safely" cognitionIncarnationLifecycle,
      testCase "deletes an archived incarnation and every derived store" cognitionDeleteIncarnation,
      testCase "seeds and activates auditable prompt revisions" cognitionPrompts,
      testCase "upgrades an automatic legacy Root to the Task Archive protocol" cognitionRootMigration,
      testCase "generates charters from the active audited Root revision" cognitionPromptRoot,
      testCase "serves incarnation-first inspection endpoints" cognitionHttp,
      testCase "binds, archives and restores incarnation tasks over HTTP" cognitionLifecycleHttp,
      testCase "keeps task ownership immutable and lists by session metadata" cognitionTaskOwnerHttp,
      testCase "refuses to archive an incarnation with a live task run" cognitionArchiveActiveRun
    ]
