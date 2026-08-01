module Yuki.N.RunsTest
  ( terminationTests,
    failureCheckpoint,
    disconnectAccounts,
    cancelOverHttp,
    browserControlE2E,
    oncePerTerminal,
    cancelReplay,
    steeringTests,
    steerMidRun,
    lateSteerContinues,
    followUpContinues,
    emptyDrainSilent,
    steerEndpoint,
    followUpEndpoint,
    steerReplay,
    queueEntryJson,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (IOException, throwIO, try)
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>))
import Data.IORef
import Data.Maybe (isJust)
import Data.Text (Text)
import Network.HTTP.Types
import Network.Wai (Application, pathInfo, requestHeaders, requestMethod)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.Agent
import Yuki.N.Journal
import Yuki.N.Model
import Yuki.N.Replay
import Yuki.N.Runs
import Yuki.N.Server
import Yuki.N.TestSupport

terminationTests :: TestTree
terminationTests =
  testGroup
    "run termination"
    [ testCase "failure runs afterRun once with the checkpoint history" failureCheckpoint,
      testCase "a thrown emit still accounts the run and rethrows" disconnectAccounts,
      testCase "cancel announces run.cancelled, finishes the stream and accounts" cancelOverHttp,
      testCase "browser control module cancels a real backend stream over loopback" browserControlE2E,
      testCase "afterRun runs exactly once on success, failure and cancel" oncePerTerminal,
      testCase "replays a cancelled journaled run without divergence" cancelReplay
    ]
failAfterTool :: IORef Int -> Model
failAfterTool turns =
  fakeModel $ \_ emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next)) >>= \case
      1 -> emit (ModelToolCallDelta 0 (Just "call-echo") (Just "echo") "{\"x\":1}") $> ToolUse
      _ -> throwIO (ProviderFailure "upstream down")

failureCheckpoint :: Assertion
failureCheckpoint = do
  turns <- newIORef (0 :: Int)
  histories <- newIORef []
  base <- testRuntime (failAfterTool turns) [echoTool] Sequential
  events <- collectEvents base {runtimeHooks = afterSpy histories} (sampleInput [])
  captured <- readIORef histories
  eventType (last events) @?= "RUN_ERROR"
  assertBool "no RUN_FINISHED on failure" (all ((/= "RUN_FINISHED") . eventType) events)
  case captured of
    [history] -> [content | ChatToolResult _ content <- history] @?= ["{\"x\":1}"]
    other -> assertFailure ("afterRun must run exactly once, got " <> show (length other))

disconnectAccounts :: Assertion
disconnectAccounts = do
  histories <- newIORef []
  base <- testRuntime okModel [] Parallel
  outcome <-
    (try (runAgent base {runtimeHooks = afterSpy histories} (sampleInput []) throwing) :: IO (Either IOException ()))
  captured <- readIORef histories
  assertBool "the failure escapes runAgent" (either (const True) (const False) outcome)
  captured @?= [[ChatUser "hello"]]
 where
  throwing (TextMessageContent {}) = throwIO (userError "client disconnected")
  throwing _ = pure ()

cancelOverHttp :: Assertion
cancelOverHttp = do
  gate <- newEmptyMVar
  runs <- newRunRegistry
  chunks <- newIORef []
  histories <- newIORef []
  streamed <- newEmptyMVar
  base <- testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel
  let runtime = base {runtimeRuns = Just runs, runtimeHooks = afterSpy histories}
      app = application Nothing Nothing Nothing (Just runs) (const (pure runtime))
  _ <- forkIO (streamAgent app chunks streamed)
  startedOk <- waitUntil (started chunks)
  unless startedOk (assertFailure "run never started")
  ghost <- runSession (srequest (cancelRequest "ghost")) app
  accepted <- runSession (srequest (cancelRequest "run")) app
  finished <- timeout 5000000 (takeMVar streamed)
  gone <- runSession (srequest (cancelRequest "run")) app
  events <- decodeChunks chunks
  captured <- readIORef histories
  simpleStatus ghost @?= status404
  simpleStatus accepted @?= status202
  simpleStatus gone @?= status404
  assertBool "the stream ends after cancel" (isJust finished)
  length [() | Custom "run.cancelled" _ <- events] @?= 1
  eventType (last events) @?= "RUN_FINISHED"
  assertBool "no RUN_ERROR on cancel" (all ((/= "RUN_ERROR") . eventType) events)
  captured @?= [[ChatUser "hello"]]
 where
  started ref =
    any (ByteString.isInfixOf "RUN_STARTED" . LazyByteString.toStrict . Builder.toLazyByteString) <$> readIORef ref

browserControlE2E :: Assertion
browserControlE2E = do
  gate <- newEmptyMVar
  runs <- newRunRegistry
  base <- testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel
  let runId = "browser-control-e2e"
      runtime = base {runtimeRuns = Just runs}
      app = application Nothing Nothing Nothing (Just runs) (const (pure runtime))
  testWithApplication (pure app) $ \port -> do
    result <-
      timeout
        60000000
        ( readProcessWithExitCode
            "node"
            ["frontend/test/backend-control-e2e.mjs", "http://127.0.0.1:" <> show port <> "/"]
            ""
        )
    _ <- cancelRun runs runId
    maybe (assertFailure "browser control test timed out") verify result
 where
  verify (ExitSuccess, _, _) = pure ()
  verify (code, stdout, stderr) =
    assertFailure
      ( "browser control test failed with "
          <> show code
          <> "\nstdout:\n"
          <> stdout
          <> "\nstderr:\n"
          <> stderr
      )

oncePerTerminal :: Assertion
oncePerTerminal = do
  count <- newIORef (0 :: Int)
  let hooks = defaultHooks {afterRun = \_ _ -> modifyIORef' count (+ 1)}
  _ <- succeed hooks
  _ <- failed hooks
  cancelled hooks
  readIORef count >>= (@?= 3)
 where
  succeed hooks = do
    base <- testRuntime okModel [] Parallel
    collectEvents base {runtimeHooks = hooks} (sampleInput [])
  failed hooks = do
    base <- testRuntime (fakeModel (\_ _ -> throwIO (ProviderFailure "down"))) [] Parallel
    collectEvents base {runtimeHooks = hooks} (sampleInput [])
  cancelled hooks = do
    gate <- newEmptyMVar
    runs <- newRunRegistry
    events <- newIORef []
    done <- newEmptyMVar
    base <- testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel
    _ <-
      forkIO
        ( runAgent
            base {runtimeRuns = Just runs, runtimeHooks = hooks}
            (sampleInput [])
            (\event -> modifyIORef' events (event :))
            *> putMVar done ()
        )
    startedOk <- waitUntil (runStarted <$> readIORef events)
    unless startedOk (assertFailure "run never started")
    _ <- cancelRun runs "run"
    timeout 5000000 (takeMVar done) >>= maybe (assertFailure "cancel did not finish the run") pure

cancelReplay :: Assertion
cancelReplay = do
  gate <- newEmptyMVar
  (journal, readEntries) <- newMemoryJournal
  runs <- newRunRegistry
  events <- newIORef []
  done <- newEmptyMVar
  base <- testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel
  _ <-
    forkIO
      ( runAgent
          base {runtimeRuns = Just runs, runtimeJournal = Just journal}
          (sampleInput [])
          (\event -> modifyIORef' events (event :))
          *> putMVar done ()
      )
  startedOk <- waitUntil (runStarted <$> readIORef events)
  unless startedOk (assertFailure "run never started")
  _ <- cancelRun runs "run"
  _ <- timeout 5000000 (takeMVar done) >>= maybe (assertFailure "cancel did not finish the run") pure
  recorded <- readEntries
  report <- replayEntries defaultHooks Nothing recorded
  assertBool "journal records run.cancelled" (any journaled recorded)
  fmap reportDivergence report @?= Right Nothing
  fmap reportEvents report @?= Right 4
 where
  journaled (Entry _ _ _ (AgentEventEntry (Custom "run.cancelled" _))) = True
  journaled _ = False

runStarted :: [Event] -> Bool
runStarted = any (\case RunStarted {} -> True; _ -> False)
streamAgent :: Application -> IORef [Builder.Builder] -> MVar () -> IO ()
streamAgent app = streamInput app (sampleInput [])
steeringTests :: TestTree
steeringTests =
  testGroup
    "steering"
    [ testCase "a mid-run steer lands in the next model request and announces the injection" steerMidRun,
      testCase "a steer arriving during the final answer continues the run" lateSteerContinues,
      testCase "a follow-up arriving during the final answer starts the next turn" followUpContinues,
      testCase "an empty queue leaves history and events untouched" emptyDrainSilent,
      testCase "POST /agent/steer answers 202, 404 and 400" steerEndpoint,
      testCase "POST /agent/follow-up queues separately" followUpEndpoint,
      testCase "replays a journaled run with steering without divergence" steerReplay,
      testCase "steering and follow-up entries JSON round-trip" queueEntryJson
    ]
steerModel :: IORef Int -> IORef [ChatMessage] -> Model
steerModel turns captured =
  fakeModel $ \req emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next)) >>= \case
      1 -> emit (ModelToolCallDelta 0 (Just "call-gate") (Just "gate") "{}") $> ToolUse
      _ -> writeIORef captured (requestMessages req) *> emit (ModelTextDelta "done") $> Stop
gateTool :: MVar () -> BackendTool
gateTool gate =
  BackendTool (tool "gate") (\_ _ -> takeMVar gate $> ToolOutcome "tool done" False False)
steerPost :: Text -> Text -> SRequest
steerPost run text =
  SRequest
    { simpleRequest =
        defaultRequest
          { requestMethod = methodPost,
            pathInfo = ["agent", "steer"],
            requestHeaders = [(hContentType, "application/json")]
          },
      simpleRequestBody = encode (object ["runId" .= run, "text" .= text])
    }
followUpPost :: Text -> Text -> SRequest
followUpPost run text = (steerPost run text) {simpleRequest = waiRequest}
 where
  waiRequest = (simpleRequest (steerPost run text)) {pathInfo = ["agent", "follow-up"]}

steerMidRun :: Assertion
steerMidRun = do
  gate <- newEmptyMVar
  runs <- newRunRegistry
  turns <- newIORef (0 :: Int)
  captured <- newIORef []
  chunks <- newIORef []
  streamed <- newEmptyMVar
  base <- testRuntime (steerModel turns captured) [gateTool gate] Sequential
  let runtime = base {runtimeRuns = Just runs}
      app = application Nothing Nothing Nothing (Just runs) (const (pure runtime))
  _ <- forkIO (streamAgent app chunks streamed)
  startedOk <- waitUntil (started chunks)
  unless startedOk (assertFailure "run never started")
  ghost <- runSession (srequest (steerPost "ghost" "late")) app
  accepted <- runSession (srequest (steerPost "run" "hold on")) app
  putMVar gate ()
  _ <- timeout 5000000 (takeMVar streamed) >>= maybe (assertFailure "steered run did not finish") pure
  events <- decodeChunks chunks
  messages <- readIORef captured
  simpleStatus ghost @?= status404
  simpleStatus accepted @?= status202
  takeEnd 1 messages @?= [ChatUser "hold on"]
  [content | ChatToolResult _ content <- messages] @?= ["tool done"]
  eventType (last events) @?= "RUN_FINISHED"
  injectValues events
 where
  started ref =
    any (ByteString.isInfixOf "RUN_STARTED" . LazyByteString.toStrict . Builder.toLazyByteString) <$> readIORef ref
  injectValues events =
    case [value | Custom "steering.inject" value <- events] of
      [value] ->
        sequence_
          [ parseMaybe (withObject "steer" (.: "step")) value @?= Just (2 :: Int),
            parseMaybe (withObject "steer" (.: "count")) value @?= Just (1 :: Int)
          ]
      other -> assertFailure ("expected one steering.inject, got " <> show (length other))

lateSteerContinues :: Assertion
lateSteerContinues = queuedAfterAnswer steerPost "steering.inject"

followUpContinues :: Assertion
followUpContinues = queuedAfterAnswer followUpPost "followup.inject"

queuedAfterAnswer :: (Text -> Text -> SRequest) -> Text -> Assertion
queuedAfterAnswer post kind = do
  entered <- newEmptyMVar
  release <- newEmptyMVar
  runs <- newRunRegistry
  turns <- newIORef (0 :: Int)
  captured <- newIORef []
  chunks <- newIORef []
  streamed <- newEmptyMVar
  base <- testRuntime (answerGateModel entered release turns captured) [] Sequential
  let app = application Nothing Nothing Nothing (Just runs) (const (pure base {runtimeRuns = Just runs}))
  _ <- forkIO (streamAgent app chunks streamed)
  _ <- timeout 5000000 (takeMVar entered) >>= maybe (assertFailure "model answer never opened") pure
  accepted <- runSession (srequest (post "run" "one more thing")) app
  putMVar release ()
  _ <- timeout 5000000 (takeMVar streamed) >>= maybe (assertFailure "queued run did not finish") pure
  events <- decodeChunks chunks
  messages <- readIORef captured
  simpleStatus accepted @?= status202
  takeEnd 1 messages @?= [ChatUser "one more thing"]
  length [() | Custom name _ <- events, name == kind] @?= 1
  eventType (last events) @?= "RUN_FINISHED"
answerGateModel :: MVar () -> MVar () -> IORef Int -> IORef [ChatMessage] -> Model
answerGateModel entered release turns captured =
  fakeModel $ \req emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next)) >>= \case
      1 -> emit (ModelTextDelta "first") *> putMVar entered () *> takeMVar release $> Stop
      _ -> writeIORef captured (requestMessages req) *> emit (ModelTextDelta "second") $> Stop

emptyDrainSilent :: Assertion
emptyDrainSilent = do
  runs <- newRunRegistry
  turns <- newIORef (0 :: Int)
  captured <- newIORef []
  base <- testRuntime (steerModel turns captured) [staticTool "gate" "tool done"] Sequential
  events <- collectEvents base {runtimeRuns = Just runs} (sampleInput [])
  messages <- readIORef captured
  assertBool "no steering.inject without a steer" (null [() | Custom "steering.inject" _ <- events])
  messages
    @?= [ ChatUser "hello",
          ChatAssistant (AssistantTurn "id-1" Nothing Nothing [ModelToolCall "call-gate" "gate" "{}"]),
          ChatToolResult "call-gate" "tool done"
        ]

steerEndpoint :: Assertion
steerEndpoint = do
  runs <- newRunRegistry
  base <- testRuntime okModel [] Parallel
  let app = application Nothing Nothing Nothing (Just runs) (const (pure base))
  withRunRegistration runs "run" $ do
    accepted <- runSession (srequest (steerPost "run" "hold on")) app
    ghost <- runSession (srequest (steerPost "ghost" "late")) app
    invalid <- runSession (srequest badSteer) app
    queued <- drainSteering runs "run"
    simpleStatus accepted @?= status202
    simpleStatus ghost @?= status404
    simpleStatus invalid @?= status400
    queued @?= [ChatUser "hold on"]
 where
  badSteer =
    SRequest
      { simpleRequest =
          defaultRequest
            { requestMethod = methodPost,
              pathInfo = ["agent", "steer"],
              requestHeaders = [(hContentType, "application/json")]
            },
        simpleRequestBody = "{\"runId\":1}"
      }

followUpEndpoint :: Assertion
followUpEndpoint = do
  runs <- newRunRegistry
  base <- testRuntime okModel [] Parallel
  let app = application Nothing Nothing Nothing (Just runs) (const (pure base))
  withRunRegistration runs "run" $ do
    accepted <- runSession (srequest (followUpPost "run" "later")) app
    ghost <- runSession (srequest (followUpPost "ghost" "late")) app
    steering <- drainSteering runs "run"
    followUps <- drainFollowUps runs "run"
    simpleStatus accepted @?= status202
    simpleStatus ghost @?= status404
    steering @?= []
    followUps @?= [ChatUser "later"]

steerReplay :: Assertion
steerReplay = do
  started <- newEmptyMVar
  gate <- newEmptyMVar
  runs <- newRunRegistry
  (journal, readEntries) <- newMemoryJournal
  turns <- newIORef (0 :: Int)
  captured <- newIORef []
  events <- newIORef []
  done <- newEmptyMVar
  base <- testRuntime (steerModel turns captured) [blockingTool started gate] Sequential
  _ <-
    forkIO
      ( runAgent
          base {runtimeRuns = Just runs, runtimeJournal = Just journal}
          (sampleInput [])
          (\event -> modifyIORef' events (event :))
          *> putMVar done ()
      )
  _ <- timeout 5000000 (takeMVar started) >>= maybe (assertFailure "tool never ran") pure
  steered <- steerRun runs "run" (ChatUser "hold on")
  steered @?= True
  putMVar gate ()
  _ <- timeout 5000000 (takeMVar done) >>= maybe (assertFailure "steered run did not finish") pure
  recorded <- readEntries
  live <- readIORef events
  report <- replayEntries defaultHooks Nothing recorded
  assertBool "journal records the steering entry" (any journaled recorded)
  assertBool "journal records the injection event" (any announced recorded)
  fmap reportDivergence report @?= Right Nothing
  fmap reportEvents report @?= Right (length live)
 where
  blockingTool started gate =
    BackendTool (tool "gate") (\_ _ -> (putMVar started () *> takeMVar gate) $> ToolOutcome "tool done" False False)
  journaled (Entry _ _ _ (SteeringEntry 2 [ChatUser "hold on"])) = True
  journaled _ = False
  announced (Entry _ _ _ (AgentEventEntry (Custom "steering.inject" _))) = True
  announced _ = False

queueEntryJson :: Assertion
queueEntryJson =
  traverse_ (\entry -> eitherDecode (encode entry) @?= Right entry) entries
 where
  entries =
    [ Entry 11 ["run"] (Just 1700000000) (SteeringEntry 2 [ChatUser "hold on"]),
      Entry 12 ["run"] (Just 1700000001) (FollowUpEntry 3 [ChatUser "later"])
    ]
