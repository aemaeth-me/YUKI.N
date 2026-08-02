module Yuki.N.ActivityTest
  ( activityTests,
  )
where

import Control.Concurrent (forkIO)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client (BodyReader, brRead, defaultManagerSettings, newManager, parseRequest, responseBody, withResponse)
import Network.HTTP.Types
import Network.Wai (Application, queryString)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Agent
import Yuki.N.Cognition (newCognition)
import Yuki.N.Inspect (Inspection, newInspection, withCognition, withSessionService)
import Yuki.N.Runs
import Yuki.N.Server
import Yuki.N.Sessions (SessionService (..))
import Yuki.N.Telemetry
import Yuki.N.Telemetry.Ledger
import Yuki.N.TestSupport

activityTests :: TestTree
activityTests =
  testGroup
    "activity"
    [ testCase "activity endpoints 404 without telemetry" activity404,
      testCase "activity snapshot reflects live runs and home" activitySnapshot,
      testCase "fleet lists incarnations with state and live runs" fleetSnapshot,
      testCase "deliveries endpoint paginates and filters" deliveriesEndpoint,
      testCase "fs-changes endpoint filters by run" fsChangesEndpoint,
      testCase "activity stream sends snapshot then status frames" streamFrames
    ]

type Fixture = (Application, Telemetry, Ledger)

fixture :: Bool -> (Fixture -> Assertion) -> Assertion
fixture withCognition' use =
  withWorkDir $ \dir -> do
    ledger <- newLedger dir
    telemetry <- newTelemetry 8192
    writeIORef (telemetryLedger telemetry) (Just ledger)
    service <- sessionServiceAt dir (const (pure ()))
    runtime <- testRuntime okModel [] Parallel
    baseInspection <-
      if withCognition'
        then cognitionInspection dir service
        else pure (plainInspection service)
    let app = application Nothing (Just baseInspection) Nothing Nothing Nothing (Just telemetry) (const (pure runtime))
    use (app, telemetry, ledger)
 where
  plainInspection service =
    withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service)))

cognitionInspection :: FilePath -> SessionService -> IO Inspection
cognitionInspection dir service =
  newCognition dir [okModel] Nothing >>= \case
    Left failure -> assertFailure (Text.unpack failure)
    Right cognition ->
      pure
        ( withCognition
            cognition
            (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
        )

activity404 :: Assertion
activity404 =
  withWorkDir $ \dir -> do
    service <- sessionServiceAt dir (const (pure ()))
    runtime <- testRuntime okModel [] Parallel
    let inspection = withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service)))
        app = application Nothing (Just inspection) Nothing Nothing Nothing Nothing (const (pure runtime))
    response <- runSession (request (httpGet ["incarnations", "yuki", "activity"])) app
    simpleStatus response @?= status404

activitySnapshot :: Assertion
activitySnapshot =
  fixture False $ \(app, telemetry, _) -> do
    telemetryRunStarting telemetry "home-run" (RunDescriptor "home-yuki" "yuki" Nothing RunHome (Just "chat")) 32 "model-x"
    telemetryRunStarting telemetry "task-run" (RunDescriptor "task-1" "yuki" Nothing RunTask (Just "work")) 32 "model-x"
    telemetryRunStarting telemetry "other-run" (RunDescriptor "task-2" "art" Nothing RunTask Nothing) 32 "model-x"
    response <- runSession (request (httpGet ["incarnations", "yuki", "activity"])) app
    simpleStatus response @?= status200
    body <- expectJson (simpleBody response)
    fieldText body ["home", "activeRunId"] @?= Just "home-run"
    fmap length (fieldArray body ["runs"]) @?= Just 2
    fieldArray body ["waitingDrafts"] @?= Just []

fleetSnapshot :: Assertion
fleetSnapshot =
  fixture True $ \(app, telemetry, _) -> do
    telemetryRunStarting telemetry "run-1" (RunDescriptor "task-1" "yuki" Nothing RunTask Nothing) 32 "model-x"
    response <- runSession (request (httpGet ["fleet"])) app
    simpleStatus response @?= status200
    body <- expectJson (simpleBody response)
    entries <- maybe (assertFailure "no incarnations") pure (fieldArray body ["incarnations"])
    assertBool "fleet is non-empty" (not (null entries))
    yuki <- maybe (assertFailure "yuki missing") pure (listToMaybe [entry | entry <- entries, fieldText entry ["id"] == Just "yuki"])
    fieldText yuki ["state"] @?= Just "active"
    fieldNumber yuki ["activeRuns"] @?= Just 1
    fmap length (fieldArray body ["runs"]) @?= Just 1

deliveriesEndpoint :: Assertion
deliveriesEndpoint =
  fixture False $ \(app, telemetry, ledger) -> do
    recordDelivery ledger telemetry (delivery "t-1" "r-1")
    recordDelivery ledger telemetry (delivery "t-1" "r-1")
    recordDelivery ledger telemetry (delivery "t-2" "r-2")
    everything <- runSession (request (httpGet ["incarnations", "yuki", "deliveries"])) app
    body <- expectJson (simpleBody everything)
    fmap length (fieldArray body ["items"]) @?= Just 3
    filtered <- runSession (request ((httpGet ["incarnations", "yuki", "deliveries"]) {queryString = [("threadId", Just "t-1")]})) app
    filteredBody <- expectJson (simpleBody filtered)
    fmap length (fieldArray filteredBody ["items"]) @?= Just 2
    paged <- runSession (request ((httpGet ["incarnations", "yuki", "deliveries"]) {queryString = [("limit", Just "1")]})) app
    pagedBody <- expectJson (simpleBody paged)
    fmap length (fieldArray pagedBody ["items"]) @?= Just 1
    fieldBool pagedBody ["hasMore"] @?= Just True

fsChangesEndpoint :: Assertion
fsChangesEndpoint =
  fixture False $ \(app, telemetry, ledger) -> do
    recordFsChange ledger telemetry (change "r-1")
    hits <- runSession (request ((httpGet ["incarnations", "yuki", "fs-changes"]) {queryString = [("runId", Just "r-1")]})) app
    body <- expectJson (simpleBody hits)
    fmap length (fieldArray body ["items"]) @?= Just 1
    misses <- runSession (request ((httpGet ["incarnations", "yuki", "fs-changes"]) {queryString = [("runId", Just "other")]})) app
    missBody <- expectJson (simpleBody misses)
    fmap length (fieldArray missBody ["items"]) @?= Just 0

streamFrames :: Assertion
streamFrames =
  withWorkDir $ \dir -> do
    ledger <- newLedger dir
    telemetry <- newTelemetry 8192
    writeIORef (telemetryLedger telemetry) (Just ledger)
    service <- sessionServiceAt dir (const (pure ()))
    runtime <- testRuntime okModel [] Parallel
    let inspection = withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service)))
        app = application Nothing (Just inspection) Nothing Nothing Nothing (Just telemetry) (const (pure runtime))
    testWithApplication (pure app) $ \port -> do
      manager <- newManager defaultManagerSettings
      httpRequest <- parseRequest ("http://127.0.0.1:" <> show port <> "/activity/stream")
      withResponse httpRequest manager $ \response -> do
        preamble <- readUntil (responseBody response) "event: snapshot"
        assertBool "snapshot frame first" preamble
        _ <- forkIO (telemetryRunStarting telemetry "stream-run" (RunDescriptor "task-1" "yuki" Nothing RunTask (Just "streamed")) 32 "model-x")
        framed <- readUntil (responseBody response) "stream-run"
        assertBool "status frame carries the run" framed

delivery :: Text -> Text -> DeliveryRecord
delivery threadId runId =
  DeliveryRecord
    { deliveryId = "",
      deliveryRunId = runId,
      deliveryThreadId = threadId,
      deliveryIncarnation = "yuki",
      deliveryRunKind = RunTask,
      deliveryKind = DeliveryAnswer,
      deliveryTitle = "answer",
      deliveryRef = runId,
      deliveryBytes = Nothing,
      deliveryAt = 0
    }

change :: Text -> FsChangeRecord
change runId =
  FsChangeRecord
    { fsChangeId = "",
      fsChangeRunId = runId,
      fsChangeThreadId = "t-1",
      fsChangeIncarnation = "yuki",
      fsChangePath = "src/Main.hs",
      fsChangeOp = FsModified,
      fsChangeOrigin = OriginTool "fs_write" "call-1",
      fsChangeDiff = Just "@@ -1 +1 @@",
      fsChangeStat = Nothing,
      fsChangeAt = 0
    }

expectJson :: LazyByteString.ByteString -> IO Value
expectJson = maybe (assertFailure "invalid json") pure . decode

field :: (FromJSON a) => Value -> [Text] -> Maybe a
field = dig
 where
  dig current [] = parseMaybe parseJSON current
  dig current (key : rest) =
    parseMaybe (withObject "value" (.: Key.fromText key)) current >>= \next -> dig next rest

fieldText :: Value -> [Text] -> Maybe Text
fieldText = field

fieldArray :: Value -> [Text] -> Maybe [Value]
fieldArray = field

fieldNumber :: Value -> [Text] -> Maybe Int
fieldNumber = field

fieldBool :: Value -> [Text] -> Maybe Bool
fieldBool = field

readUntil :: BodyReader -> ByteString.ByteString -> IO Bool
readUntil reader needle = go mempty (100 :: Int)
 where
  go _ 0 = pure False
  go acc remaining =
    timeout 2000000 (brRead reader) >>= \case
      Nothing -> pure False
      Just chunk
        | needle `ByteString.isInfixOf` (acc <> chunk) -> pure True
        | otherwise -> go (acc <> chunk) (remaining - 1)
