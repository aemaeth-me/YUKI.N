-- | 本地会话测试
--
-- 覆盖：索引持久化、owner 迁移、分叉、导入导出、归档清理、HTTP 路由、手动压缩与自动索引。
-- 边界：覆盖 Yuki.N.Sessions；transcript 细节见 TranscriptTest。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.SessionTest
  ( sessionTests,
    sessionIndexPersists,
    sessionOwnerMigration,
    sessionForks,
    sessionTransfers,
    sessionArchiveCleanup,
    sessionRoutes,
    sessionManualCompact,
    sessionAgentIndex,
  )
where

import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Exception ()
import Control.Monad ()
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Bool ()
import Data.ByteString ()
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable ()
import Data.Functor ()
import Data.IORef
import Data.List ()
import Data.Maybe ()
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS ()
import Network.HTTP.Types
import Network.Wai (pathInfo, queryString, requestMethod)
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test
import System.Directory (createDirectoryIfMissing)
import System.Exit ()
import System.FilePath ()
import System.Process ()
import System.Timeout ()
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event ()
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Artifact
import Yuki.N.Background ()
import Yuki.N.Context
import Yuki.N.Inspect
import Yuki.N.Model
import Yuki.N.Server
import Yuki.N.Sessions
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig
import Yuki.N.Transcript

sessionTests :: TestTree
sessionTests =
  testGroup
    "local sessions"
    [ testCase "metadata index survives reopen, rename, archive and restore" sessionIndexPersists,
      testCase "migrates legacy owners from config and makes them immutable" sessionOwnerMigration,
      testCase "forks at a stable history node without changing the source" sessionForks,
      testCase "exports and imports a complete bundle without overwriting duplicates" sessionTransfers,
      testCase "archive invokes thread cleanup" sessionArchiveCleanup,
      testCase "HTTP routes list, create, rename, archive, restore and serve empty transcripts" sessionRoutes,
      testCase "manual compaction persists a bounded transcript and local snapshot" sessionManualCompact,
      testCase "agent requests auto-index valid sessions and reject archived ones" sessionAgentIndex
    ]

-- | 规格：会话元数据索引跨重启/重命名/归档/恢复存活。
-- 背景：会话索引是客户端列表的数据源；重启丢失会让前端会话消失。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
sessionIndexPersists :: Assertion
sessionIndexPersists =
  withWorkDir $ \dir ->
    newSessionStore dir >>= \store ->
      ( createSession store "alpha" (Just "Alpha") "yuki" Nothing Nothing
          >>= \created -> fmap withoutTimes created @?= Right (meta "alpha" "Alpha" "yuki" False Nothing Nothing)
      )
        *> ( renameSession store "alpha" "Renamed"
               >>= either (assertFailure . Text.unpack) (\renamed -> sessionTitle renamed @?= "Renamed")
           )
        *> ( setSessionArchived store "alpha" True
               >>= either (assertFailure . Text.unpack) (\archived -> assertBool "archived" (sessionArchived archived))
           )
        *> ( newSessionStore dir >>= \reopened ->
               (listSessions reopened False >>= (@?= []))
                 *> ( listSessions reopened True
                        >>= \allSessions -> fmap withoutTimes allSessions @?= [meta "alpha" "Renamed" "yuki" True Nothing Nothing]
                    )
                 *> ( setSessionArchived reopened "alpha" False
                        >>= either
                          (assertFailure . Text.unpack)
                          ( \restored ->
                              sequence_
                                [ sessionArchived restored @?= False,
                                  sessionIncarnationId restored @?= "yuki"
                                ]
                          )
                    )
           )
 where
  withoutTimes value = value {sessionCreated = 0, sessionUpdated = 0}
  meta identifier title owner archived parent node = SessionMeta identifier title owner 0 0 archived parent node

-- | 规格：遗留会话从 config 迁移出 owner 且所有权不可改写。
-- 背景：所有权迁移是升级路径；不可改写防止跨分身窃取。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
sessionOwnerMigration :: Assertion
sessionOwnerMigration =
  withWorkDir $ \dir ->
    let path = dir ++ "/sessions/index.json"
        legacy identifier =
          object
            [ "id" .= (identifier :: Text),
              "title" .= identifier,
              "created" .= (1 :: Int),
              "updated" .= (1 :: Int),
              "archived" .= False
            ]
     in createDirectoryIfMissing True (dir ++ "/sessions")
          *> LazyByteString.writeFile path (encode [legacy "legacy-art", legacy "legacy-yuki"])
          *> newSessionStore dir
          >>= \sessions ->
            newThreadConfigStore dir >>= \configs ->
              threadConfigWrite configs "legacy-art" emptyThreadConfig {configIncarnationId = Just "art"}
                *> migrateSessionOwners sessions configs
                >>= withTextRight
                  ( \() ->
                      (,,,)
                        <$> findSession sessions "legacy-art"
                        <*> findSession sessions "legacy-yuki"
                        <*> threadConfigRead configs "legacy-art"
                        <*> threadConfigRead configs "legacy-yuki"
                        >>= \(art, yuki, artConfig, yukiConfig) ->
                          claimSessionOwner sessions "legacy-art" "yuki" >>= \reassigned ->
                            newSessionStore dir >>= \reopened ->
                              findSession reopened "legacy-art" >>= \stored ->
                                sequence_
                                  [ fmap sessionIncarnationId art @?= Just "art",
                                    fmap sessionIncarnationId yuki @?= Just "yuki",
                                    configIncarnationId artConfig @?= Just "art",
                                    configIncarnationId yukiConfig @?= Just "yuki",
                                    assertLeft reassigned,
                                    fmap sessionIncarnationId stored @?= Just "art"
                                  ]
                  )

-- | 规格：会话在稳定历史节点分叉，源会话不变，错误节点被拒。
-- 背景：分叉是版本化工作的基础；污染源会话会破坏所有下游。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
sessionForks :: Assertion
sessionForks =
  withWorkDir $ \dir ->
    sessionServiceAt dir (const (pure ())) >>= \service ->
      let sessions = serviceSessions service
          transcripts = serviceTranscripts service
          configs = serviceConfigs service
          config = emptyThreadConfig {configIncarnationId = Just "art", configSystemPrompt = Just "forked"}
       in createSession sessions "source" (Just "Source") "art" Nothing Nothing
            *> transcriptSave transcripts "source" transcriptHistory
            *> threadConfigWrite configs "source" config
            *> ( forkSession service "source" "branch" (Just "m-1") (Just "Branch")
                   >>= either (assertFailure . Text.unpack) verifyMeta
               )
            *> (transcriptLoad transcripts "source" >>= (@?= Just transcriptHistory))
            *> (transcriptLoad transcripts "branch" >>= (@?= Just (take 2 transcriptHistory)))
            *> (threadConfigRead configs "branch" >>= (@?= config))
            *> (forkSession service "source" "missing-node" (Just "absent") Nothing >>= assertLeft)
            *> (transcriptLoad transcripts "missing-node" >>= (@?= Nothing))
 where
  verifyMeta result =
    sequence_
      [ sessionId result @?= "branch",
        sessionIncarnationId result @?= "art",
        sessionParent result @?= Just "source",
        sessionForkNode result @?= Just "m-1"
      ]

-- | 规格：会话导出/导入完整 bundle，重复导入不覆盖既有数据。
-- 背景：迁移工具必须不丢数据；重复导入覆盖会销毁目标会话。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
sessionTransfers :: Assertion
sessionTransfers =
  withWorkDir $ \dir ->
    sessionServiceAt dir (const (pure ())) >>= \service ->
      let sessions = serviceSessions service
          transcripts = serviceTranscripts service
          configs = serviceConfigs service
          config = emptyThreadConfig {configCwd = CwdNone, configIncarnationId = Just "art", configMemory = Just False}
       in createSession sessions "source" (Just "Portable") "art" Nothing Nothing
            *> transcriptSave transcripts "source" transcriptHistory
            *> threadConfigWrite configs "source" config
            *> exportSession service "source"
            >>= maybe (assertFailure "missing export") (transfer service config)
 where
  transfer service config bundle =
    (eitherDecode (encode bundle) @?= Right bundle)
      *> ( importSession service (ImportRequest bundle (Just "imported") (Just "Imported"))
             >>= either
               (assertFailure . Text.unpack)
               ( \result ->
                   sequence_
                     [ sessionTitle result @?= "Imported",
                       sessionIncarnationId result @?= "art"
                     ]
               )
         )
      *> (transcriptLoad (serviceTranscripts service) "imported" >>= (@?= Just transcriptHistory))
      *> (threadConfigRead (serviceConfigs service) "imported" >>= (@?= config))
      *> ( importSession
             service
             ( ImportRequest
                 bundle
                   { bundleMeta =
                       (bundleMeta bundle) {sessionIncarnationId = ""}
                   }
                 (Just "legacy-imported")
                 Nothing
             )
             >>= either
               (assertFailure . Text.unpack)
               (\result -> sessionIncarnationId result @?= "art")
         )
      *> (threadConfigRead (serviceConfigs service) "legacy-imported" >>= \stored -> configIncarnationId stored @?= Just "art")
      *> transcriptSave (serviceTranscripts service) "imported" [ChatUser "keep"]
      *> (importSession service (ImportRequest bundle (Just "imported") Nothing) >>= assertLeft)
      *> (transcriptLoad (serviceTranscripts service) "imported" >>= (@?= Just [ChatUser "keep"]))

-- | 规格：归档触发线程清理回调，恢复不重复触发。
-- 背景：归档是资源回收时机；漏清理会泄漏句柄与进程。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
sessionArchiveCleanup :: Assertion
sessionArchiveCleanup =
  withWorkDir $ \dir ->
    newIORef [] >>= \cleaned ->
      sessionServiceAt dir (\threadId -> modifyIORef' cleaned (threadId :)) >>= \service ->
        createSession (serviceSessions service) "thread" Nothing "yuki" Nothing Nothing
          *> (archiveSession service "thread" >>= either (assertFailure . Text.unpack) (const (pure ())))
          *> (restoreSession service "thread" >>= either (assertFailure . Text.unpack) (const (pure ())))
          *> (readIORef cleaned >>= (@?= ["thread"]))

-- | 规格：会话 HTTP 路由覆盖创建/重命名/归档/恢复/空 transcript 服务。
-- 背景：路由是会话管理的对外契约；状态码错误会让前端操作失效。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
sessionRoutes :: Assertion
sessionRoutes =
  withWorkDir $ \dir ->
    sessionServiceAt dir (const (pure ())) >>= \service ->
      testRuntime okModel [] Parallel >>= \base ->
        let inspection = withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service)))
            app = application Nothing (Just inspection) Nothing Nothing (const (pure base))
         in runSession (srequest (jsonRequest methodPost ["threads"] (object ["threadId" .= ("route" :: Text), "title" .= ("Route" :: Text)]))) app >>= \created ->
              runSession (srequest (jsonRequest methodPatch ["threads", "route"] (object ["title" .= ("Named" :: Text)]))) app >>= \renamed ->
                runSession (srequest (jsonRequest methodPost ["threads", "route", "archive"] (object []))) app >>= \archived ->
                  runSession (request (httpGet ["threads"])) app >>= \active ->
                    runSession (request ((httpGet ["threads"]) {queryString = [("archived", Just "true")]})) app >>= \allSessions ->
                      runSession (request (httpGet ["threads", "route", "transcript"])) app >>= \emptyTranscript ->
                        runSession (srequest (jsonRequest methodPost ["threads", "route", "restore"] (object []))) app >>= \restored ->
                          sequence_
                            [ simpleStatus created @?= status200,
                              simpleStatus renamed @?= status200,
                              simpleStatus archived @?= status200,
                              either assertFailure (@?= ([] :: [SessionMeta])) (eitherDecode (simpleBody active)),
                              either assertFailure (\sessions -> fmap sessionTitle sessions @?= ["Named"]) (eitherDecode (simpleBody allSessions)),
                              simpleStatus emptyTranscript @?= status200,
                              simpleStatus restored @?= status200
                            ]

-- | 规格：手动压缩持久化有界 transcript 与摘要，并生成压缩工件。
-- 背景：手动压缩是上下文治理的显式手段；结果不可持久化等于没有压缩。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
sessionManualCompact :: Assertion
sessionManualCompact =
  withWorkDir $ \dir ->
    sessionServiceAt dir (const (pure ())) >>= \service ->
      newMemoryArtifactStore >>= \artifacts ->
        testRuntime (okModel {modelContextTokens = Just 512}) [] Parallel >>= \base ->
          let inspection =
                withSessionService
                  service
                  (newInspection Nothing (Just artifacts) Nothing (Just (serviceTranscripts service)))
              runtime = base {runtimeArtifactStore = Just artifacts, runtimeContext = Just contextConfig}
              app = application Nothing (Just inspection) Nothing Nothing (const (pure runtime))
           in createSession (serviceSessions service) "compact-me" Nothing "yuki" Nothing Nothing
                *> transcriptSave (serviceTranscripts service) "compact-me" contextConversation
                *> runSession
                  (request defaultRequest {requestMethod = methodPost, pathInfo = ["threads", "compact-me", "compact"]})
                  app
                >>= \response ->
                  transcriptLoad (serviceTranscripts service) "compact-me" >>= \stored ->
                    artifactList artifacts >>= \metas ->
                      case eitherDecode (simpleBody response) :: Either String Value of
                        Left message -> assertFailure message
                        Right body ->
                          sequence_
                            [ simpleStatus response @?= status200,
                              parseMaybe (withObject "compact" (.: "changed")) body @?= Just True,
                              assertBool
                                "persisted transcript is bounded"
                                (maybe False ((<= 256) . estimateMessagesTokens) stored),
                              assertBool
                                "persisted transcript keeps a summary"
                                (maybe False (any isContextSummary) stored),
                              fmap artifactMetaToolName metas @?= ["context_compaction"]
                            ]

-- | 规格：agent 请求自动索引会话，归档会话被 409 拒绝。
-- 背景：自动索引提供零配置会话；归档会话可写会造成数据复活。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
sessionAgentIndex :: Assertion
sessionAgentIndex =
  withWorkDir $ \dir ->
    sessionServiceAt dir (const (pure ())) >>= \service ->
      testRuntime okModel [] Parallel >>= \base ->
        let inspection = withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service)))
            app = application Nothing (Just inspection) Nothing Nothing (const (pure base))
            input = (sampleInput []) {runThreadId = "auto", runId = "auto-run"}
         in runSession (srequest (jsonRequest methodPost ["agent"] input)) app >>= \first ->
              findSession (serviceSessions service) "auto" >>= \created ->
                ensureSession (serviceSessions service) "auto" (Just "second title") "yuki" >>= \unchanged ->
                  archiveSession service "auto"
                    *> runSession (srequest (jsonRequest methodPost ["agent"] input {runId = "archived-run"})) app
                    >>= \rejected ->
                      sequence_
                        [ simpleStatus first @?= status200,
                          fmap sessionTitle created @?= Just "hello",
                          sessionTitle unchanged @?= "hello",
                          simpleStatus rejected @?= status409
                        ]
