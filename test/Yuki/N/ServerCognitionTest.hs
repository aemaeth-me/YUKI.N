module Yuki.N.ServerCognitionTest
  ( serverCognitionTests,
    incarnationLifecycleOverHttp,
    derivedIdOverHttp,
    memoryLifecycleOverHttp,
    workingRoutesOverHttp,
    threadTransferOverHttp,
  )
where

import Data.Aeson (Value (..), decode, eitherDecode, object, withObject, (.:), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor (($>))
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Types
import Network.Wai (Application)
import Network.Wai.Test
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Agent (Runtime (..))
import Yuki.N.Cognition (Cognition (..), newCognition)
import Yuki.N.Incarnation (Incarnation (..), IncarnationStore (..))
import Yuki.N.Inspect (newInspection, withCognition, withSessionService)
import Yuki.N.Model
import Yuki.N.Server (application)
import Yuki.N.Sessions (SessionService (..), SessionStore (..), sessionIsHome)
import Yuki.N.TestSupport
import Yuki.N.Transcript (transcriptSave)

serverCognitionTests :: TestTree
serverCognitionTests =
  testGroup
    "incarnation HTTP"
    [ testCase "incarnation create/update/archive/restore/delete lifecycle over HTTP" incarnationLifecycleOverHttp,
      testCase "incarnation id derives from name with unique suffix" derivedIdOverHttp,
      testCase "long-term memory list/detail/search/void/receipts over HTTP" memoryLifecycleOverHttp,
      testCase "working memory, sleep cycles, experiences, impression and epochs over HTTP" workingRoutesOverHttp,
      testCase "thread sleep/import/fork/export transfer over HTTP" threadTransferOverHttp,
      testCase "home session ensures idempotently and 404s unknown or archived incarnations" homeOverHttp,
      testCase "home session rejects archive, restore, fork and import" homeImmutableOverHttp
    ]

incarnationLifecycleOverHttp :: Assertion
incarnationLifecycleOverHttp =
  cognitionFixture $ \app _ _ -> do
    created <- post app ["incarnations"] (createIncarnation "north" "North" "build the tower" Nothing)
    simpleStatus created @?= status200
    decodeText "incarnation.id" (simpleBody created) >>= (@?= "north")
    decodeText "incarnation.status" (simpleBody created) >>= (@?= "active")
    decodeText "prompt.content" (simpleBody created) >>= assertBool "create boots a charter prompt" . not . Text.null
    listed <- get app ["incarnations"]
    simpleStatus listed @?= status200
    assertBool "list includes the new incarnation" (listHas "north" (simpleBody listed))
    readBack <- get app ["incarnations", "north"]
    simpleStatus readBack @?= status200
    decodeText "id" (simpleBody readBack) >>= (@?= "north")
    decodeText "status" (simpleBody readBack) >>= (@?= "active")
    -- 创建时 promptActivate 会把 store 内 revision 抬到 2，从响应读取真实值
    createRev <- decodeInt "revision" (simpleBody readBack)
    updated <- patch app ["incarnations", "north"] (object ["expectedRevision" .= createRev, "name" .= ("North v2" :: Text), "direction" .= ("rebuild" :: Text), "impressionModel" .= Null])
    simpleStatus updated @?= status200
    decodeText "incarnation.name" (simpleBody updated) >>= (@?= "North v2")
    updateRev <- decodeInt "incarnation.revision" (simpleBody updated)
    archived <- post app ["incarnations", "north", "archive"] (object ["expectedRevision" .= updateRev])
    simpleStatus archived @?= status200
    decodeText "status" (simpleBody archived) >>= (@?= "archived")
    archiveRev <- decodeInt "revision" (simpleBody archived)
    restored <- post app ["incarnations", "north", "restore"] (object ["expectedRevision" .= archiveRev])
    simpleStatus restored @?= status200
    decodeText "status" (simpleBody restored) >>= (@?= "active")
    restoreRev <- decodeInt "revision" (simpleBody restored)
    archivedAgain <- post app ["incarnations", "north", "archive"] (object ["expectedRevision" .= restoreRev])
    simpleStatus archivedAgain @?= status200
    decodeText "status" (simpleBody archivedAgain) >>= (@?= "archived")
    finalRev <- decodeInt "revision" (simpleBody archivedAgain)
    staleDelete <- post app ["incarnations", "north", "delete"] (object ["expectedRevision" .= restoreRev])
    simpleStatus staleDelete @?= status409
    deleted <- post app ["incarnations", "north", "delete"] (object ["expectedRevision" .= finalRev])
    simpleStatus deleted @?= status200
    decodeText "deleted" (simpleBody deleted) >>= (@?= "north")
    gone <- get app ["incarnations", "north"]
    simpleStatus gone @?= status404
    afterDelete <- get app ["incarnations"]
    assertBool "list no longer includes the deleted incarnation" (not (listHas "north" (simpleBody afterDelete)))

memoryLifecycleOverHttp :: Assertion
memoryLifecycleOverHttp =
  cognitionFixture $ \app _ _ -> do
    created <- post app ["incarnations"] (createIncarnation "north" "North" "build the tower" Nothing)
    simpleStatus created @?= status200
    remembered <- post app ["incarnations", "north", "memories"] (rememberMemory "deploy target is fly.io")
    simpleStatus remembered @?= status200
    memoryId <- decodeText "id" (simpleBody remembered)
    decodeText "content" (simpleBody remembered) >>= (@?= "deploy target is fly.io")
    decodeInt "revision" (simpleBody remembered) >>= (@?= 1)
    catalog <- get app ["incarnations", "north", "memories"]
    simpleStatus catalog @?= status200
    assertBool "catalog contains the remembered memory" (listHas memoryId (simpleBody catalog))
    detail <- get app ["incarnations", "north", "memories", memoryId]
    simpleStatus detail @?= status200
    decodeText "record.content" (simpleBody detail) >>= (@?= "deploy target is fly.io")
    searched <- post app ["incarnations", "north", "memories", "search"] (object ["query" .= ("fly.io" :: Text)])
    simpleStatus searched @?= status200
    assertBool "search snippets reference the memory" (snippetsHave memoryId (simpleBody searched))
    voided <- post app ["incarnations", "north", "memories", memoryId, "void"] (object ["expectedRevision" .= (1 :: Int)])
    simpleStatus voided @?= status200
    decodeText "status" (simpleBody voided) >>= (@?= "void")
    missing <- get app ["incarnations", "north", "memories", "memory-missing"]
    simpleStatus missing @?= status404
    receipts <- get app ["incarnations", "north", "memory-receipts"]
    simpleStatus receipts @?= status200
    assertBool "memory receipts recorded" (lengthOf (simpleBody receipts) >= 1)

workingRoutesOverHttp :: Assertion
workingRoutesOverHttp =
  cognitionFixture $ \app _ service -> do
    emptyWorking <- get app ["incarnations", "north", "working-memory"]
    simpleStatus emptyWorking @?= status404
    impression <- get app ["incarnations", "north", "impression"]
    simpleStatus impression @?= status200
    activations <- get app ["incarnations", "north", "impression", "activations"]
    simpleStatus activations @?= status200
    revisions <- get app ["incarnations", "north", "impression", "revisions"]
    simpleStatus revisions @?= status200
    created <- post app ["incarnations"] (createIncarnation "north" "North" "build the tower" Nothing)
    simpleStatus created @?= status200
    threadCreated <- post app ["threads"] (createThread "t1" "north")
    simpleStatus threadCreated @?= status200
    transcriptSave (serviceTranscripts service) "t1" sleepMessages
    slept <- post app ["threads", "t1", "sleep"] (object ["reason" .= ("manual" :: Text)])
    simpleStatus slept @?= status200
    decodeText "head.status" (simpleBody slept) >>= (@?= "awake")
    working <- get app ["incarnations", "north", "working-memory"]
    simpleStatus working @?= status200
    decodeText "status" (simpleBody working) >>= (@?= "awake")
    cycles <- get app ["incarnations", "north", "sleep-cycles"]
    simpleStatus cycles @?= status200
    assertBool "at least one sleep cycle recorded" (lengthOf (simpleBody cycles) >= 1)
    experiences <- get app ["incarnations", "north", "experiences"]
    simpleStatus experiences @?= status200
    epochs <- get app ["threads", "t1", "context-epochs"]
    simpleStatus epochs @?= status200
    assertBool "sleep committed a context epoch" (lengthOf (simpleBody epochs) >= 1)

threadTransferOverHttp :: Assertion
threadTransferOverHttp =
  cognitionFixture $ \app _ service -> do
    created <- post app ["incarnations"] (createIncarnation "north" "North" "build the tower" Nothing)
    simpleStatus created @?= status200
    source <- post app ["threads"] (createThread "src" "north")
    simpleStatus source @?= status200
    decodeText "id" (simpleBody source) >>= (@?= "src")
    transcriptSave (serviceTranscripts service) "src" sleepMessages
    forked <- post app ["threads", "src", "fork"] (object ["threadId" .= ("dst" :: Text), "title" .= ("Forked" :: Text), "messageId" .= Null])
    simpleStatus forked @?= status200
    decodeText "id" (simpleBody forked) >>= (@?= "dst")
    threads <- get app ["threads"]
    simpleStatus threads @?= status200
    assertBool "thread list contains src" (listHas "src" (simpleBody threads))
    assertBool "thread list contains dst" (listHas "dst" (simpleBody threads))
    exported <- get app ["threads", "src", "export"]
    simpleStatus exported @?= status200
    decodeInt "version" (simpleBody exported) >>= (@?= 1)
    decodeText "meta.id" (simpleBody exported) >>= (@?= "src")
    case decode (simpleBody exported) :: Maybe Value of
      Nothing -> assertFailure "export must decode as JSON"
      Just bundleValue -> do
        imported <- post app ["threads", "import"] (object ["bundle" .= bundleValue, "threadId" .= ("imported" :: Text)])
        simpleStatus imported @?= status200
        decodeText "id" (simpleBody imported) >>= (@?= "imported")
        duplicate <- post app ["threads", "import"] (object ["bundle" .= bundleValue, "threadId" .= ("imported" :: Text)])
        simpleStatus duplicate @?= status409
    reExported <- get app ["threads", "imported", "export"]
    simpleStatus reExported @?= status200
    decodeText "meta.id" (simpleBody reExported) >>= (@?= "imported")
    slept <- post app ["threads", "src", "sleep"] (object ["reason" .= ("manual" :: Text)])
    simpleStatus slept @?= status200
    unknownSleep <- post app ["threads", "no-such-thread", "sleep"] (object ["reason" .= ("manual" :: Text)])
    simpleStatus unknownSleep @?= status404

-- fixtures and helpers

homeOverHttp :: Assertion
homeOverHttp =
  cognitionFixture $ \app cognition service -> do
    created <- incarnationCreate (cognitionIncarnations cognition) "north" "North" "build the tower" Nothing >>= expectTextRight
    home <- get app ["incarnations", "north", "home"]
    simpleStatus home @?= status200
    decodeText "threadId" (simpleBody home) >>= (@?= "home-north")
    decodeText "meta.kind" (simpleBody home) >>= (@?= "home")
    decodeText "meta.title" (simpleBody home) >>= (@?= "North")
    decodeText "meta.incarnationId" (simpleBody home) >>= (@?= "north")
    again <- get app ["incarnations", "north", "home"]
    simpleStatus again @?= status200
    decodeText "threadId" (simpleBody again) >>= (@?= "home-north")
    metas <- listSessions (serviceSessions service) True
    assertBool "exactly one home session" (length (filter sessionIsHome metas) == 1)
    missing <- get app ["incarnations", "ghost", "home"]
    simpleStatus missing @?= status404
    archivedIncarnation <-
      incarnationArchive (cognitionIncarnations cognition) "north" (incarnationRevision created)
        >>= expectTextRight
    archivedHome <- get app ["incarnations", "north", "home"]
    simpleStatus archivedHome @?= status404
    deleted <-
      post
        app
        ["incarnations", "north", "delete"]
        (object ["expectedRevision" .= incarnationRevision archivedIncarnation])
    simpleStatus deleted @?= status200
    gone <- findSession (serviceSessions service) "home-north"
    gone @?= Nothing

homeImmutableOverHttp :: Assertion
homeImmutableOverHttp =
  cognitionFixture $ \app cognition service -> do
    _ <- incarnationCreate (cognitionIncarnations cognition) "north" "North" "build the tower" Nothing >>= expectTextRight
    home <- get app ["incarnations", "north", "home"]
    simpleStatus home @?= status200
    task <- post app ["threads"] (createThread "t1" "north")
    simpleStatus task @?= status200
    archived <- post app ["threads", "home-north", "archive"] (object [])
    restored <- post app ["threads", "home-north", "restore"] (object [])
    forked <- post app ["threads", "home-north", "fork"] (object ["threadId" .= ("home-fork" :: Text)])
    let homeMeta = object ["id" .= ("home-north" :: Text), "title" .= ("Home" :: Text), "created" .= (0 :: Int), "updated" .= (0 :: Int)]
        homeBundle = object ["version" .= (1 :: Int), "meta" .= homeMeta, "config" .= object [], "transcript" .= ([] :: [Value])]
    imported <- post app ["threads", "import"] (object ["bundle" .= homeBundle, "threadId" .= ("home-north" :: Text)])
    sequence_
      [ simpleStatus archived @?= status400,
        decodeText "error" (simpleBody archived) >>= (@?= "home_session_immutable"),
        simpleStatus restored @?= status400,
        decodeText "error" (simpleBody restored) >>= (@?= "home_session_immutable"),
        simpleStatus forked @?= status400,
        decodeText "error" (simpleBody forked) >>= (@?= "home_session_immutable"),
        simpleStatus imported @?= status400,
        decodeText "error" (simpleBody imported) >>= (@?= "home_session_immutable")
      ]
    stillHome <- findSession (serviceSessions service) "home-north"
    fmap sessionIsHome stillHome @?= Just True
    taskArchive <- post app ["threads", "t1", "archive"] (object [])
    simpleStatus taskArchive @?= status200

sleepMessages :: [ChatMessage]
sleepMessages =
  [ ChatSystem "local rules",
    ChatUser (Text.replicate 200 "u"),
    ChatAssistant (AssistantTurn "m-1" (Just (Text.replicate 200 "a")) Nothing [])
  ]

dreamModel :: Model
dreamModel =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          "{\"continuation\":\"Continue the task.\",\"activeItems\":[],\"openLoops\":[],\"forgotten\":[],\"retainedSegmentIds\":[]}"
      )
      $> Stop

cognitionFixture :: (Application -> Cognition -> SessionService -> Assertion) -> Assertion
cognitionFixture use =
  withWorkDir $ \dir -> do
    cognitionResult <- newCognition dir [dreamModel] Nothing
    case cognitionResult of
      Left failure -> assertFailure (Text.unpack failure)
      Right cognition -> do
        service <- sessionServiceAt dir (const (pure ()))
        runtime <- testRuntime echoModel [] Parallel
        let inspection =
              withCognition
                cognition
                ( withSessionService
                    service
                    (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service)))
                )
            app = application Nothing (Just inspection) Nothing Nothing Nothing Nothing (const (pure runtime {runtimeContext = Just contextConfig}))
        use app cognition service

derivedIdOverHttp :: Assertion
derivedIdOverHttp =
  cognitionFixture $ \app _ _ -> do
    first <- post app ["incarnations"] (object ["name" .= ("North Wind" :: Text), "direction" .= ("build" :: Text)])
    simpleStatus first @?= status200
    decodeText "incarnation.id" (simpleBody first) >>= (@?= "north-wind")
    second <- post app ["incarnations"] (object ["name" .= ("North Wind" :: Text), "direction" .= ("rebuild" :: Text)])
    simpleStatus second @?= status200
    decodeText "incarnation.id" (simpleBody second) >>= (@?= "north-wind-2")
    third <- post app ["incarnations"] (object ["name" .= ("北风" :: Text), "direction" .= ("建造" :: Text)])
    simpleStatus third @?= status200
    derived <- decodeText "incarnation.id" (simpleBody third)
    assertBool "cjk name falls back to a yuki- prefixed hash" ("yuki-" `Text.isPrefixOf` derived)

createIncarnation :: Text -> Text -> Text -> Maybe Text -> Value
createIncarnation identifier name direction impressionModel =
  object
    [ "id" .= identifier,
      "name" .= name,
      "direction" .= direction,
      "impressionModel" .= impressionModel
    ]

createThread :: Text -> Text -> Value
createThread threadId incarnationId =
  object
    [ "threadId" .= threadId,
      "title" .= ("thread " <> threadId),
      "incarnationId" .= incarnationId
    ]

rememberMemory :: Text -> Value
rememberMemory content =
  object
    [ "kind" .= ("preference" :: Text),
      "content" .= content,
      "keywords" .= (["deploy", "target"] :: [Text]),
      "sourceRefs" .= (["run-1"] :: [Text])
    ]

post :: Application -> [Text] -> Value -> IO SResponse
post app path body = runSession (srequest (jsonRequest methodPost path body)) app

get :: Application -> [Text] -> IO SResponse
get app path = runSession (request (httpGet path)) app

patch :: Application -> [Text] -> Value -> IO SResponse
patch app path body = runSession (srequest (jsonRequest methodPatch path body)) app

decodeText :: String -> LazyByteString.ByteString -> IO Text
decodeText selector body =
  case eitherDecode body of
    Left message -> assertFailure ("decode failed: " <> message) $> ""
    Right value ->
      case fieldPath (Text.pack selector) value of
        Just (String text) -> pure text
        _ -> assertFailure ("missing or non-text field " <> selector) $> ""

decodeInt :: String -> LazyByteString.ByteString -> IO Int
decodeInt selector body =
  case eitherDecode body of
    Left message -> assertFailure ("decode failed: " <> message) $> 0
    Right value ->
      case fieldPath (Text.pack selector) value of
        Just (Number number) -> pure (truncate number)
        _ -> assertFailure ("missing or non-numeric field " <> selector) $> 0

fieldPath :: Text -> Value -> Maybe Value
fieldPath selector = go (Text.splitOn "." selector)
 where
  go [] _ = Nothing
  go [key] (Object fields) = KeyMap.lookup (Key.fromText key) fields
  go (key : rest) (Object fields) = KeyMap.lookup (Key.fromText key) fields >>= go rest
  go _ _ = Nothing

listHas :: Text -> LazyByteString.ByteString -> Bool
listHas needle body =
  case eitherDecode body :: Either String [Value] of
    Right items -> any hasNeedle items
    Left _ -> False
 where
  hasNeedle (Object fields) = KeyMap.lookup "id" fields == Just (String needle)
  hasNeedle _ = False

snippetsHave :: Text -> LazyByteString.ByteString -> Bool
snippetsHave needle body =
  case eitherDecode body >>= parseEither parse of
    Right hits -> needle `elem` hits
    Left _ -> False
 where
  parse =
    withObject "search" $ \fields -> do
      snippets <- fields .: "snippets"
      mapM snippetRef (snippets :: [Value])
  snippetRef =
    withObject
      "snippet"
      (\s -> s .: "ref" >>= withObject "ref" (.: "id"))

lengthOf :: LazyByteString.ByteString -> Int
lengthOf body =
  case eitherDecode body :: Either String [Value] of
    Right items -> length items
    Left _ -> 0
