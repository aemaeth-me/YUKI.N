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

import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Types
import Network.Wai (pathInfo, queryString, requestMethod)
import Network.Wai.Test
import System.Directory (createDirectoryIfMissing)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Artifact
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
      testCase "agent requests auto-index valid sessions and reject archived ones" sessionAgentIndex,
      testCase "session meta roundtrips through JSON including kind" sessionKindRoundtrip,
      testCase "session meta JSON without kind defaults to task" sessionKindDefaultsToTask,
      testCase "sessionIsHome distinguishes home from task" sessionIsHomePredicate,
      testCase "ensureHomeSession is idempotent and one per incarnation" sessionHomeEnsure,
      testCase "thread list filters by kind over HTTP" sessionKindFilterOverHttp
    ]

sessionIndexPersists :: Assertion
sessionIndexPersists = withWorkDir $ \dir -> do
  store <- newSessionStore dir
  created <- createSession store "alpha" (Just "Alpha") "yuki" Nothing Nothing
  fmap withoutTimes created @?= Right (meta "alpha" "Alpha" "yuki" False Nothing Nothing)
  renamed <- renameSession store "alpha" "Renamed" >>= either (assertFailure . Text.unpack) pure
  sessionTitle renamed @?= "Renamed"
  archived <- setSessionArchived store "alpha" True >>= either (assertFailure . Text.unpack) pure
  assertBool "archived" (sessionArchived archived)
  reopened <- newSessionStore dir
  emptyList <- listSessions reopened False
  emptyList @?= []
  allSessions <- listSessions reopened True
  fmap withoutTimes allSessions @?= [meta "alpha" "Renamed" "yuki" True Nothing Nothing]
  restored <- setSessionArchived reopened "alpha" False >>= either (assertFailure . Text.unpack) pure
  sessionArchived restored @?= False
  sessionIncarnationId restored @?= "yuki"
 where
  withoutTimes value = value {sessionCreated = 0, sessionUpdated = 0}
  meta identifier title owner archived parent node = SessionMeta identifier title owner 0 0 archived parent node SessionTask

sessionOwnerMigration :: Assertion
sessionOwnerMigration = withWorkDir $ \dir -> do
  let path = dir ++ "/sessions/index.json"
      legacy identifier =
        object
          [ "id" .= (identifier :: Text),
            "title" .= identifier,
            "created" .= (1 :: Int),
            "updated" .= (1 :: Int),
            "archived" .= False
          ]
  createDirectoryIfMissing True (dir ++ "/sessions")
  LazyByteString.writeFile path (encode [legacy "legacy-art", legacy "legacy-yuki"])
  sessions <- newSessionStore dir
  configs <- newThreadConfigStore dir
  threadConfigWrite configs "legacy-art" emptyThreadConfig {configIncarnationId = Just "art"}
  _ <- migrateSessionOwners sessions configs >>= expectTextRight
  art <- findSession sessions "legacy-art"
  yuki <- findSession sessions "legacy-yuki"
  artConfig <- threadConfigRead configs "legacy-art"
  yukiConfig <- threadConfigRead configs "legacy-yuki"
  reassigned <- claimSessionOwner sessions "legacy-art" "yuki"
  reopened <- newSessionStore dir
  stored <- findSession reopened "legacy-art"
  fmap sessionIncarnationId art @?= Just "art"
  fmap sessionIncarnationId yuki @?= Just "yuki"
  configIncarnationId artConfig @?= Just "art"
  configIncarnationId yukiConfig @?= Just "yuki"
  assertLeft reassigned
  fmap sessionIncarnationId stored @?= Just "art"

sessionForks :: Assertion
sessionForks = withWorkDir $ \dir -> do
  service <- sessionServiceAt dir (const (pure ()))
  let sessions = serviceSessions service
      transcripts = serviceTranscripts service
      configs = serviceConfigs service
      config = emptyThreadConfig {configIncarnationId = Just "art", configSystemPrompt = Just "forked"}
  _ <- createSession sessions "source" (Just "Source") "art" Nothing Nothing
  transcriptSave transcripts "source" transcriptHistory
  threadConfigWrite configs "source" config
  forkResult <- forkSession service "source" "branch" (Just "m-1") (Just "Branch")
  either (assertFailure . Text.unpack) verifyMeta forkResult
  sourceTranscript <- transcriptLoad transcripts "source"
  sourceTranscript @?= Just transcriptHistory
  branchTranscript <- transcriptLoad transcripts "branch"
  branchTranscript @?= Just (take 2 transcriptHistory)
  branchConfig <- threadConfigRead configs "branch"
  branchConfig @?= config
  missingNode <- forkSession service "source" "missing-node" (Just "absent") Nothing
  assertLeft missingNode
  missingTranscript <- transcriptLoad transcripts "missing-node"
  missingTranscript @?= Nothing
 where
  verifyMeta result =
    sequence_
      [ sessionId result @?= "branch",
        sessionIncarnationId result @?= "art",
        sessionParent result @?= Just "source",
        sessionForkNode result @?= Just "m-1"
      ]

sessionTransfers :: Assertion
sessionTransfers = withWorkDir $ \dir -> do
  service <- sessionServiceAt dir (const (pure ()))
  let sessions = serviceSessions service
      transcripts = serviceTranscripts service
      configs = serviceConfigs service
      config = emptyThreadConfig {configCwd = CwdNone, configIncarnationId = Just "art", configMemory = Just False}
  _ <- createSession sessions "source" (Just "Portable") "art" Nothing Nothing >>= expectTextRight
  transcriptSave transcripts "source" transcriptHistory
  threadConfigWrite configs "source" config
  exported <- exportSession service "source"
  maybe (assertFailure "missing export") (transfer service config) exported
 where
  transfer service config bundle = do
    eitherDecode (encode bundle) @?= Right bundle
    imported <- importSession service (ImportRequest bundle (Just "imported") (Just "Imported")) >>= expectTextRight
    sessionTitle imported @?= "Imported"
    sessionIncarnationId imported @?= "art"
    transcriptLoad (serviceTranscripts service) "imported" >>= (@?= Just transcriptHistory)
    threadConfigRead (serviceConfigs service) "imported" >>= (@?= config)
    legacy <-
      importSession
        service
        ( ImportRequest
            bundle
              { bundleMeta =
                  (bundleMeta bundle) {sessionIncarnationId = ""}
              }
            (Just "legacy-imported")
            Nothing
        )
        >>= expectTextRight
    sessionIncarnationId legacy @?= "art"
    stored <- threadConfigRead (serviceConfigs service) "legacy-imported"
    configIncarnationId stored @?= Just "art"
    transcriptSave (serviceTranscripts service) "imported" [ChatUser "keep"]
    assertLeft =<< importSession service (ImportRequest bundle (Just "imported") Nothing)
    transcriptLoad (serviceTranscripts service) "imported" >>= (@?= Just [ChatUser "keep"])

sessionArchiveCleanup :: Assertion
sessionArchiveCleanup = withWorkDir $ \dir -> do
  cleaned <- newIORef []
  service <- sessionServiceAt dir (\threadId -> modifyIORef' cleaned (threadId :))
  _ <- createSession (serviceSessions service) "thread" Nothing "yuki" Nothing Nothing >>= expectTextRight
  _ <- archiveSession service "thread" >>= either (assertFailure . Text.unpack) pure
  _ <- restoreSession service "thread" >>= either (assertFailure . Text.unpack) pure
  readIORef cleaned >>= (@?= ["thread"])

sessionRoutes :: Assertion
sessionRoutes = withWorkDir $ \dir -> do
  service <- sessionServiceAt dir (const (pure ()))
  base <- testRuntime okModel [] Parallel
  let inspection = withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service)))
      app = application Nothing (Just inspection) Nothing Nothing (const (pure base))
  created <- runSession (srequest (jsonRequest methodPost ["threads"] (object ["threadId" .= ("route" :: Text), "title" .= ("Route" :: Text)]))) app
  renamed <- runSession (srequest (jsonRequest methodPatch ["threads", "route"] (object ["title" .= ("Named" :: Text)]))) app
  archived <- runSession (srequest (jsonRequest methodPost ["threads", "route", "archive"] (object []))) app
  active <- runSession (request (httpGet ["threads"])) app
  allSessions <- runSession (request ((httpGet ["threads"]) {queryString = [("archived", Just "true")]})) app
  emptyTranscript <- runSession (request (httpGet ["threads", "route", "transcript"])) app
  restored <- runSession (srequest (jsonRequest methodPost ["threads", "route", "restore"] (object []))) app
  simpleStatus created @?= status200
  simpleStatus renamed @?= status200
  simpleStatus archived @?= status200
  either assertFailure (@?= ([] :: [SessionMeta])) (eitherDecode (simpleBody active))
  either assertFailure (\sessions -> fmap sessionTitle sessions @?= ["Named"]) (eitherDecode (simpleBody allSessions))
  simpleStatus emptyTranscript @?= status200
  simpleStatus restored @?= status200

sessionManualCompact :: Assertion
sessionManualCompact = withWorkDir $ \dir -> do
  service <- sessionServiceAt dir (const (pure ()))
  artifacts <- newMemoryArtifactStore
  base <- testRuntime (okModel {modelContextTokens = Just 512}) [] Parallel
  let inspection =
        withSessionService
          service
          (newInspection Nothing (Just artifacts) Nothing (Just (serviceTranscripts service)))
      runtime = base {runtimeArtifactStore = Just artifacts, runtimeContext = Just contextConfig}
      app = application Nothing (Just inspection) Nothing Nothing (const (pure runtime))
  _ <- createSession (serviceSessions service) "compact-me" Nothing "yuki" Nothing Nothing >>= expectTextRight
  transcriptSave (serviceTranscripts service) "compact-me" contextConversation
  response <-
    runSession
      (request defaultRequest {requestMethod = methodPost, pathInfo = ["threads", "compact-me", "compact"]})
      app
  stored <- transcriptLoad (serviceTranscripts service) "compact-me"
  metas <- artifactList artifacts
  case eitherDecode (simpleBody response) :: Either String Value of
    Left message -> assertFailure message
    Right body -> do
      simpleStatus response @?= status200
      parseMaybe (withObject "compact" (.: "changed")) body @?= Just True
      assertBool "persisted transcript is bounded" (maybe False ((<= 256) . estimateMessagesTokens) stored)
      assertBool "persisted transcript keeps a summary" (maybe False (any isContextSummary) stored)
      fmap artifactMetaToolName metas @?= ["context_compaction"]

sessionAgentIndex :: Assertion
sessionAgentIndex = withWorkDir $ \dir -> do
  service <- sessionServiceAt dir (const (pure ()))
  base <- testRuntime okModel [] Parallel
  let inspection = withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service)))
      app = application Nothing (Just inspection) Nothing Nothing (const (pure base))
      input = (sampleInput []) {runThreadId = "auto", runId = "auto-run"}
  first <- runSession (srequest (jsonRequest methodPost ["agent"] input)) app
  created <- findSession (serviceSessions service) "auto"
  unchanged <- ensureSession (serviceSessions service) "auto" (Just "second title") "yuki"
  _ <- archiveSession service "auto" >>= expectTextRight
  rejected <- runSession (srequest (jsonRequest methodPost ["agent"] input {runId = "archived-run"})) app
  simpleStatus first @?= status200
  fmap sessionTitle created @?= Just "hello"
  sessionTitle unchanged @?= "hello"
  simpleStatus rejected @?= status409

sessionKindRoundtrip :: Assertion
sessionKindRoundtrip = do
  let roundtrip meta = eitherDecode (encode meta) @?= Right meta
  roundtrip task
  roundtrip home
  assertBool "home kind serializes" ("\"kind\":\"home\"" `Text.isInfixOf` jsonText home)
  assertBool "task kind serializes" ("\"kind\":\"task\"" `Text.isInfixOf` jsonText task)
 where
  task = SessionMeta "alpha" "Alpha" "yuki" 0 0 False Nothing Nothing SessionTask
  home = task {sessionKind = SessionHome}

sessionKindDefaultsToTask :: Assertion
sessionKindDefaultsToTask = fromJSON legacy @?= Success task
 where
  task = SessionMeta "alpha" "Alpha" "yuki" 0 0 False Nothing Nothing SessionTask
  legacy =
    object
      [ "id" .= ("alpha" :: Text),
        "title" .= ("Alpha" :: Text),
        "incarnationId" .= ("yuki" :: Text),
        "created" .= (0 :: Int),
        "updated" .= (0 :: Int),
        "archived" .= False,
        "parent" .= (Nothing :: Maybe Text),
        "forkNode" .= (Nothing :: Maybe Text)
      ]

sessionIsHomePredicate :: Assertion
sessionIsHomePredicate = do
  let meta = SessionMeta "alpha" "Alpha" "yuki" 0 0 False Nothing Nothing
  sessionIsHome (meta SessionHome) @?= True
  sessionIsHome (meta SessionTask) @?= False

sessionHomeEnsure :: Assertion
sessionHomeEnsure = withWorkDir $ \dir -> do
  store <- newSessionStore dir
  first <- ensureHomeSession store "art" (Just "Art")
  sessionId first @?= "home-art"
  sessionKind first @?= SessionHome
  sessionIncarnationId first @?= "art"
  sessionTitle first @?= "Art"
  second <- ensureHomeSession store "art" (Just "Art")
  sessionId second @?= "home-art"
  sessionKind second @?= SessionHome
  sessionTitle second @?= "Art"
  found <- findSession store "home-art"
  fmap sessionKind found @?= Just SessionHome
  allSessions <- listSessions store True
  assertBool "one home session per incarnation" (length (filter sessionIsHome allSessions) == 1)
  unnamed <- ensureHomeSession store "zen" Nothing
  sessionId unnamed @?= "home-zen"
  sessionKind unnamed @?= SessionHome
  sessionTitle unnamed @?= "zen"
  expanded <- listSessions store True
  assertBool "one home session per each incarnation" (length (filter sessionIsHome expanded) == 2)
  reopened <- newSessionStore dir
  persisted <- findSession reopened "home-art"
  fmap sessionKind persisted @?= Just SessionHome
  fmap sessionTitle persisted @?= Just "Art"

sessionKindFilterOverHttp :: Assertion
sessionKindFilterOverHttp = withWorkDir $ \dir -> do
  service <- sessionServiceAt dir (const (pure ()))
  base <- testRuntime okModel [] Parallel
  let inspection = withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service)))
      app = application Nothing (Just inspection) Nothing Nothing (const (pure base))
  _ <- createSession (serviceSessions service) "task-a" (Just "Task A") "yuki" Nothing Nothing >>= expectTextRight
  _ <- ensureHomeSession (serviceSessions service) "yuki" (Just "Yuki")
  allThreads <- runSession (request (httpGet ["threads"])) app
  tasks <- runSession (request ((httpGet ["threads"]) {queryString = [("kind", Just "task")]})) app
  homes <- runSession (request ((httpGet ["threads"]) {queryString = [("kind", Just "home")]})) app
  unknown <- runSession (request ((httpGet ["threads"]) {queryString = [("kind", Just "bogus")]})) app
  let ids body = either assertFailure (pure . sort . fmap sessionId) (eitherDecode body :: Either String [SessionMeta])
  ids (simpleBody allThreads) >>= (@?= ["home-yuki", "task-a"])
  ids (simpleBody tasks) >>= (@?= ["task-a"])
  ids (simpleBody homes) >>= (@?= ["home-yuki"])
  ids (simpleBody unknown) >>= (@?= ["home-yuki", "task-a"])
