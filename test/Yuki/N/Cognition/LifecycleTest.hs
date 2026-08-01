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

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (IOException, bracket_, try)
import Data.Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Maybe (isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Types
import Network.Wai (queryString)
import Network.Wai.Test
import System.Directory (createDirectory, removeDirectoryRecursive, renameFile)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Agent
import Yuki.N.Cognition
import Yuki.N.Experience
import Yuki.N.Incarnation
import Yuki.N.Inspect
import Yuki.N.Memory.Archive
import Yuki.N.Memory.Impression
import Yuki.N.Memory.LongTerm
import Yuki.N.Memory.Working
import Yuki.N.Model
import Yuki.N.Runs
import Yuki.N.Server
import Yuki.N.Sessions
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig

cognitionIncarnationLifecycle :: Assertion
cognitionIncarnationLifecycle = do
  store <- newMemoryIncarnationStore
  created <- incarnationCreate store "art" "Art" "Make careful visual judgments." Nothing >>= expectTextRight
  prompt <-
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
  defaultArchive <- incarnationArchive store "yuki" 1
  archived <- incarnationArchive store "art" (incarnationRevision created) >>= expectTextRight
  blockedUpdate <-
    incarnationUpdate
      store
      "art"
      (incarnationRevision archived)
      "Changed"
      "Must remain blocked."
      Nothing
  blockedPrompt <- promptActivate store "art" (incarnationRevision archived) (promptRevisionId prompt)
  staleRestore <- incarnationRestore store "art" 1
  restored <- incarnationRestore store "art" (incarnationRevision archived) >>= expectTextRight
  repeatedRestore <- incarnationRestore store "art" (incarnationRevision restored)
  assertLeft defaultArchive
  incarnationStatus archived @?= IncarnationArchived
  assertLeft blockedUpdate
  assertLeft blockedPrompt
  assertLeft staleRestore
  incarnationStatus restored @?= IncarnationActive
  incarnationRevision restored @?= incarnationRevision archived + 1
  assertLeft repeatedRestore

cognitionDeleteIncarnation :: Assertion
cognitionDeleteIncarnation = withWorkDir $ \dir -> do
  cognition <- newCognition dir [] Nothing >>= expectTextRight
  let identity = "yuki-del"
      incarnationStore = cognitionIncarnations cognition
  created <- incarnationCreate incarnationStore identity "Del" "To be deleted." Nothing >>= expectTextRight
  let expected = incarnationRevision created
  seedStores cognition identity
  archived <- incarnationArchive incarnationStore identity expected >>= expectTextRight
  _ <- deleteIncarnation cognition identity (incarnationRevision archived) >>= expectTextRight
  verifyGone cognition identity

-- | 档案存储持久化失败时，删除用例返回 `Left` 且不安装已更改的内存状态
-- （档案仍可见，记录与其它派生存储原样保留）。
cognitionDeleteIncarnationArchiveFailure :: Assertion
cognitionDeleteIncarnationArchiveFailure = withWorkDir $ \dir -> do
  cognition <- newCognition dir [] Nothing >>= expectTextRight
  let identity = "yuki-del-archive-fail"
      incarnationStore = cognitionIncarnations cognition
  created <- incarnationCreate incarnationStore identity "Del" "To be deleted." Nothing >>= expectTextRight
  let expected = incarnationRevision created
  seedStores cognition identity
  archived <- incarnationArchive incarnationStore identity expected >>= expectTextRight
  failure <-
    withBrokenStore (dir ++ "/task-archive/index.json") $
      deleteIncarnation cognition identity (incarnationRevision archived)
  case failure of
    Left message -> do
      assertBool ("archive failure propagated: " <> Text.unpack message) (not (Text.null message))
      verifyArchiveIntact cognition identity
    Right () -> assertFailure "archive persistence failure was reported as success"

-- | 长期记忆持久化失败时，删除用例返回 `Left` 且已失败存储的内存状态保持不变
-- （记录与长期记忆保留；其前的派生存储已按序删除属预期部分状态）。
cognitionDeleteIncarnationLongTermFailure :: Assertion
cognitionDeleteIncarnationLongTermFailure = withWorkDir $ \dir -> do
  cognition <- newCognition dir [] Nothing >>= expectTextRight
  let identity = "yuki-del-longterm-fail"
      incarnationStore = cognitionIncarnations cognition
  created <- incarnationCreate incarnationStore identity "Del" "To be deleted." Nothing >>= expectTextRight
  let expected = incarnationRevision created
  seedStores cognition identity
  archived <- incarnationArchive incarnationStore identity expected >>= expectTextRight
  failure <-
    withBrokenStore (dir ++ "/long-term.json") $
      deleteIncarnation cognition identity (incarnationRevision archived)
  case failure of
    Left message -> do
      assertBool ("long-term failure propagated: " <> Text.unpack message) (not (Text.null message))
      verifyLongTermIntact cognition identity
    Right () -> assertFailure "long-term persistence failure was reported as success"

-- | 让 store 状态文件上的下一次原子持久化必然失败：把文件移到兄弟备份、
-- 在原位放一个同名目录（POSIX rename 文件到目录必败），结束后恢复原文件。
withBrokenStore :: FilePath -> IO a -> IO a
withBrokenStore path =
  bracket_
    (renameFile path backup *> createDirectory path)
    ((try (removeDirectoryRecursive path) :: IO (Either IOException ())) *> renameFile backup path)
 where
  backup = path <> ".broken-backup"

seedStores :: Cognition -> Text -> IO ()
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

verifyArchiveIntact :: Cognition -> Text -> Assertion
verifyArchiveIntact cognition identity = do
  taskArchiveTasks (cognitionArchive cognition) identity 20 >>= \archives ->
    assertBool "archive retained its in-memory state" (not (null archives))
  verifyDerivedIntact cognition identity

verifyDerivedIntact :: Cognition -> Text -> Assertion
verifyDerivedIntact cognition identity = do
  incarnationList (cognitionIncarnations cognition) >>= \incarnations ->
    assertBool "incarnation record retained" (any ((== identity) . incarnationId) incarnations)
  longTermCatalog (cognitionLongTerm cognition) identity 20 >>= \catalog ->
    assertBool "long-term memory retained its in-memory state" (not (null catalog))
  experienceEvents (cognitionExperiences cognition) identity >>= \events ->
    assertBool "experience events retained" (not (null events))

verifyLongTermIntact :: Cognition -> Text -> Assertion
verifyLongTermIntact cognition identity = do
  incarnationList (cognitionIncarnations cognition) >>= \incarnations ->
    assertBool "incarnation record retained" (any ((== identity) . incarnationId) incarnations)
  longTermCatalog (cognitionLongTerm cognition) identity 20 >>= \catalog ->
    assertBool "long-term memory retained its in-memory state" (not (null catalog))

verifyGone :: Cognition -> Text -> Assertion
verifyGone cognition identity = do
  incarnations <- incarnationList (cognitionIncarnations cognition)
  prompts <- promptList (cognitionIncarnations cognition) (Just identity)
  archives <- taskArchiveTasks (cognitionArchive cognition) identity 20
  events <- experienceEvents (cognitionExperiences cognition) identity
  working <- workingRead (cognitionWorking cognition) identity
  catalog <- longTermCatalog (cognitionLongTerm cognition) identity 20
  impression <- impressionRead (cognitionImpressions cognition) identity
  assertBool "incarnation record removed" (all ((/= identity) . incarnationId) incarnations)
  assertBool "charter prompts removed" (null prompts)
  assertBool "task archive removed" (null archives)
  assertBool "experience events removed" (null events)
  assertBool "working memory removed" (isNothing working)
  assertBool "long-term catalog removed" (null catalog)
  assertBool "impression state emptied" (null (impressionItems impression))

cognitionPrompts :: Assertion
cognitionPrompts = withWorkDir $ \dir -> do
  cognition <- newCognition dir [] Nothing >>= expectTextRight
  initial <- ensureIncarnation cognition "yuki"
  blockedUpdate <-
    incarnationUpdate
      (cognitionIncarnations cognition)
      "yuki"
      (incarnationRevision initial)
      ""
      (incarnationDirection initial)
      (incarnationImpressionModel initial)
  assertLeft blockedUpdate
  revision <-
    promptAppend
      (cognitionIncarnations cognition)
      (Just "yuki")
      IncarnationCharter
      "audit edit"
      "A deliberately revised working style."
      "test/v1"
      Nothing
      (incarnationPromptRevision initial)
      PromptDraft
  activated <-
    promptActivate
      (cognitionIncarnations cognition)
      "yuki"
      (incarnationRevision initial)
      (promptRevisionId revision)
      >>= expectTextRight
  compiled <- compileIncarnationPrompt cognition activated
  revisions <- promptList (cognitionIncarnations cognition) (Just "yuki")
  roots <- promptList (cognitionIncarnations cognition) Nothing
  assertBool "default prompt is active at bootstrap" (isJust (incarnationPromptRevision initial))
  assertBool "compiled prompt includes root constitution" ("Root Constitution" `Text.isInfixOf` compiled)
  assertBool "compiled prompt includes activated charter" ("deliberately revised" `Text.isInfixOf` compiled)
  assertBool "prompt lineage remains auditable" (length revisions >= 2)
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

cognitionRootMigration :: Assertion
cognitionRootMigration = withWorkDir $ \dir -> do
  cognition <- newCognition dir [] Nothing >>= expectTextRight
  roots <- promptList (cognitionIncarnations cognition) Nothing
  case listToMaybe (reverse (filter ((== PromptActive) . promptStatus) roots)) of
    Nothing -> assertFailure "fresh cognition has no active Root"
    Just active -> do
      legacy <-
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
      _ <-
        promptActivateRoot
          (cognitionIncarnations cognition)
          (promptOrdinal active)
          (promptRevisionId legacy)
          >>= expectTextRight
      reopened <- newCognition dir [] Nothing >>= expectTextRight
      migrated <- promptList (cognitionIncarnations reopened) Nothing
      let activeRoots = filter ((== PromptActive) . promptStatus) migrated
      length activeRoots @?= 1
      fmap promptGeneratorRevision activeRoots @?= [rootPromptRevision]
      assertBool
        "automatic Root migration lost the Task Archive protocol"
        (any (Text.isInfixOf "immutable Task archive" . promptContent) activeRoots)

cognitionPromptRoot :: Assertion
cognitionPromptRoot = withWorkDir $ \dir -> do
  captured <- newIORef []
  cognition <- newCognition dir [promptCaptureModel captured] Nothing >>= expectTextRight
  incarnation <- ensureIncarnation cognition "yuki"
  roots <- promptList (cognitionIncarnations cognition) Nothing
  let expected =
        maybe
          0
          promptOrdinal
          (listToMaybe (reverse (filter ((== PromptActive) . promptStatus) roots)))
  root <-
    promptAppend
      (cognitionIncarnations cognition)
      Nothing
      RootConstitution
      "root audit test"
      "# CUSTOM ROOT SENTINEL\nUse the audited root."
      "manual-root-test/v1"
      Nothing
      (promptRevisionId <$> listToMaybe roots)
      PromptDraft
  activated <-
    promptActivateRoot (cognitionIncarnations cognition) expected (promptRevisionId root)
      >>= expectTextRight
  generated <-
    cognitionGeneratePrompt cognition incarnation "regenerate beneath edited root"
      >>= expectTextRight
  messages <- readIORef captured
  revisions <- promptList (cognitionIncarnations cognition) Nothing
  promptStatus activated @?= PromptActive
  length (filter ((== PromptActive) . promptStatus) revisions) @?= 1
  assertBool "generator request contains the active edited Root" (any rootMarked messages)
  assertBool
    "generated charter records its Root generator lineage"
    (promptRevisionId root `Text.isInfixOf` promptGeneratorRevision generated)
 where
  rootMarked (ChatSystem text) = "CUSTOM ROOT SENTINEL" `Text.isInfixOf` text
  rootMarked _ = False

cognitionHttp :: Assertion
cognitionHttp = withWorkDir $ \dir -> do
  cognition <- newCognition dir [] Nothing >>= expectTextRight
  runtime <- testRuntime okModel [] Parallel
  let inspection = withCognition cognition emptyInspection
      app = application Nothing (Just inspection) Nothing Nothing (const (pure runtime))
  roots <- promptList (cognitionIncarnations cognition) Nothing
  case listToMaybe roots of
    Nothing -> assertFailure "missing Root prompt revision"
    Just root -> do
      incarnations <- runSession (request (httpGet ["incarnations"])) app
      impression <- runSession (request (httpGet ["incarnations", "yuki", "impression"])) app
      emptyDraft <-
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
      wrongParent <-
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
      simpleStatus incarnations @?= status200
      simpleStatus impression @?= status200
      simpleStatus emptyDraft @?= status400
      simpleStatus wrongParent @?= status400
      assertBool
        "default incarnation is present"
        ("\"id\":\"yuki\"" `ByteString.isInfixOf` LazyByteString.toStrict (simpleBody incarnations))

cognitionLifecycleHttp :: Assertion
cognitionLifecycleHttp = withWorkDir $ \dir -> do
  cognition <- newCognition (dir ++ "/cognition") [] Nothing >>= expectTextRight
  service <- sessionServiceAt (dir ++ "/sessions") (const (pure ()))
  runtime <- testRuntime okModel [] Parallel
  created <-
    incarnationCreate
      (cognitionIncarnations cognition)
      "art"
      "Art"
      "Make careful visual judgments."
      Nothing
      >>= expectTextRight
  let view = testView (serviceConfigs service)
      inspection =
        withCognition
          cognition
          (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
      app = application Nothing (Just inspection) (Just view) Nothing (const (pure runtime))
      post path body = runSession (srequest (jsonRequest methodPost path body)) app
  taskCreated <-
    post
      ["threads"]
      ( object
          [ "threadId" .= ("art-task" :: Text),
            "title" .= ("Art task" :: Text),
            "incarnationId" .= ("art" :: Text)
          ]
      )
  bound <- threadConfigRead (serviceConfigs service) "art-task"
  archived <- post ["incarnations", "art", "archive"] (object ["expectedRevision" .= incarnationRevision created])
  activeList <- runSession (request (httpGet ["incarnations"])) app
  allList <-
    runSession
      (request ((httpGet ["incarnations"]) {queryString = [("archived", Just "true")]}))
      app
  hidden <- runSession (request (httpGet ["incarnations", "art"])) app
  archivedTask <- findSession (serviceSessions service) "art-task"
  rejectedCreate <-
    post
      ["threads"]
      ( object
          [ "threadId" .= ("rejected-task" :: Text),
            "incarnationId" .= ("art" :: Text)
          ]
      )
  blockedTaskRestore <- post ["threads", "art-task", "restore"] (object [])
  restored <- post ["incarnations", "art", "restore"] (object ["expectedRevision" .= (2 :: Int)])
  stillArchived <- findSession (serviceSessions service) "art-task"
  taskRestored <- post ["threads", "art-task", "restore"] (object [])
  simpleStatus taskCreated @?= status200
  configIncarnationId bound @?= Just "art"
  simpleStatus archived @?= status200
  assertBool "archived incarnation is hidden from the default list" (not (containsArt activeList))
  assertBool "archived incarnation remains auditable" (containsArt allList)
  simpleStatus hidden @?= status404
  fmap sessionArchived archivedTask @?= Just True
  fmap sessionIncarnationId archivedTask @?= Just "art"
  simpleStatus rejectedCreate @?= status409
  simpleStatus blockedTaskRestore @?= status409
  simpleStatus restored @?= status200
  fmap sessionArchived stillArchived @?= Just True
  fmap sessionIncarnationId stillArchived @?= Just "art"
  simpleStatus taskRestored @?= status200
 where
  containsArt =
    ByteString.isInfixOf "\"id\":\"art\""
      . LazyByteString.toStrict
      . simpleBody

cognitionTaskOwnerHttp :: Assertion
cognitionTaskOwnerHttp = withWorkDir $ \dir -> do
  cognition <- newCognition (dir ++ "/cognition") [] Nothing >>= expectTextRight
  service <- sessionServiceAt (dir ++ "/sessions") (const (pure ()))
  runtime <- testRuntime okModel [] Parallel
  _ <-
    incarnationCreate
      (cognitionIncarnations cognition)
      "art"
      "Art"
      "Make careful visual judgments."
      Nothing
      >>= expectTextRight
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
  created <- runSession (srequest create) app
  reassigned <-
    runSession
      ( srequest
          ( putConfig
              "owned-task"
              (encode (emptyThreadConfig {configIncarnationId = Just "yuki"}))
          )
      )
      app
  updated <-
    runSession
      ( srequest
          ( putConfig
              "owned-task"
              (encode (emptyThreadConfig {configSystemPrompt = Just "kept"}))
          )
      )
      app
  canonical <- threadConfigRead (serviceConfigs service) "owned-task"
  threadConfigWrite
    (serviceConfigs service)
    "owned-task"
    canonical {configIncarnationId = Just "yuki"}
  artTasks <- runSession (request (httpGet ["incarnations", "art", "tasks"])) app
  yukiTasks <- runSession (request (httpGet ["incarnations", "yuki", "tasks"])) app
  meta <- findSession (serviceSessions service) "owned-task"
  simpleStatus created @?= status200
  simpleStatus reassigned @?= status409
  simpleStatus updated @?= status204
  configIncarnationId canonical @?= Just "art"
  configSystemPrompt canonical @?= Just "kept"
  fmap sessionIncarnationId meta @?= Just "art"
  decodeTaskIds artTasks @?= Right ["owned-task"]
  decodeTaskIds yukiTasks @?= Right []
 where
  decodeTaskIds response =
    fmap (fmap sessionId) (eitherDecode (simpleBody response) :: Either String [SessionMeta])

cognitionArchiveActiveRun :: Assertion
cognitionArchiveActiveRun = withWorkDir $ \dir -> do
  cognition <- newCognition (dir ++ "/cognition") [] Nothing >>= expectTextRight
  service <- sessionServiceAt (dir ++ "/sessions") (const (pure ()))
  runs <- newRunRegistry
  release <- newEmptyMVar
  runtime <- testRuntime okModel [] Parallel
  created <-
    incarnationCreate
      (cognitionIncarnations cognition)
      "art"
      "Art"
      "Make careful visual judgments."
      Nothing
      >>= expectTextRight
  _ <-
    createSession (serviceSessions service) "art-live-task" Nothing "art" Nothing Nothing
      >>= expectTextRight
  threadConfigWrite
    (serviceConfigs service)
    "art-live-task"
    emptyThreadConfig {configIncarnationId = Just "art"}
  _ <- forkIO (withRunRegistrationFor runs "art-live-run" "art-live-task" (takeMVar release))
  registered <- waitUntil (elem "art-live-task" <$> activeThreads runs)
  let view = testView (serviceConfigs service)
      inspection =
        withCognition
          cognition
          (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
      app = application Nothing (Just inspection) (Just view) (Just runs) (const (pure runtime))
  blocked <-
    runSession
      ( srequest
          ( jsonRequest
              methodPost
              ["incarnations", "art", "archive"]
              (object ["expectedRevision" .= incarnationRevision created])
          )
      )
      app
  putMVar release ()
  stopped <- waitUntil (null <$> activeThreads runs)
  current <- incarnationRead (cognitionIncarnations cognition) "art"
  task <- findSession (serviceSessions service) "art-live-task"
  assertBool "live run registered" registered
  simpleStatus blocked @?= status409
  assertBool "run registration released" stopped
  fmap incarnationStatus current @?= Just IncarnationActive
  fmap sessionArchived task @?= Just False

cognitionLifecycleTests :: TestTree
cognitionLifecycleTests =
  testGroup
    "incarnation cognition lifecycle"
    [ testCase "archives and restores non-default incarnations safely" cognitionIncarnationLifecycle,
      testCase "deletes an archived incarnation and every derived store" cognitionDeleteIncarnation,
      testCase "propagates archive persistence failure without changing state" cognitionDeleteIncarnationArchiveFailure,
      testCase "propagates long-term persistence failure and retains the long-term store" cognitionDeleteIncarnationLongTermFailure,
      testCase "seeds and activates auditable prompt revisions" cognitionPrompts,
      testCase "upgrades an automatic legacy Root to the Task Archive protocol" cognitionRootMigration,
      testCase "generates charters from the active audited Root revision" cognitionPromptRoot,
      testCase "serves incarnation-first inspection endpoints" cognitionHttp,
      testCase "binds, archives and restores incarnation tasks over HTTP" cognitionLifecycleHttp,
      testCase "keeps task ownership immutable and lists by session metadata" cognitionTaskOwnerHttp,
      testCase "refuses to archive an incarnation with a live task run" cognitionArchiveActiveRun
    ]
