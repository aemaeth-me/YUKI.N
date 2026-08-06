module Yuki.N.RunsTest
  ( terminationTests,
    runTreeIndex,
    failureCheckpoint,
    disconnectAccounts,
    oncePerTerminal,
    steeringTests,
    steerMidRun,
    lateSteerContinues,
    followUpContinues,
    emptyDrainSilent,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (IOException, throwIO, try)
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Functor (($>))
import Data.IORef
import Data.List (find)
import Data.Text (Text)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.Agent
import Yuki.N.Model
import Yuki.N.Runs
import Yuki.N.TestSupport

terminationTests :: TestTree
terminationTests =
  testGroup
    "run termination"
    [ testCase "failure runs afterRun once with the checkpoint history" failureCheckpoint,
      testCase "a thrown emit still accounts the run and rethrows" disconnectAccounts,
      testCase "afterRun runs exactly once on success, failure and cancel" oncePerTerminal,
      testCase "run tree index tracks descriptors, children and release" runTreeIndex
    ]

runTreeIndex :: Assertion
runTreeIndex = do
  runs <- newRunRegistry
  withRunRegistrationFor runs "parent" (RunDescriptor "task-a" "yuki" Nothing RunTask (Just "do a thing")) $ do
    withRunRegistrationFor runs "child" (RunDescriptor "task-a" "yuki" (Just "parent") RunWorker (Just "sub task")) $ do
      infos <- activeRuns runs
      let byId = zip (fmap runInfoId infos) infos
          lookupInfo identifier = snd <$> find ((== identifier) . fst) byId
      length infos @?= 2
      fmap runInfoKind (lookupInfo "parent") @?= Just RunTask
      fmap runInfoKind (lookupInfo "child") @?= Just RunWorker
      fmap runInfoObjective (lookupInfo "child") @?= Just (Just "sub task")
      fmap runInfoIncarnation (lookupInfo "child") @?= Just "yuki"
      fmap ((> 0) . runInfoStartedAt) (lookupInfo "parent") @?= Just True
      kids <- childrenOf runs "parent"
      fmap runInfoId kids @?= ["child"]
      threads <- activeThreads runs
      threads @?= ["task-a"]
    released <- childrenOf runs "parent"
    released @?= []
  final <- activeRuns runs
  final @?= []
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

runStarted :: [Event] -> Bool
runStarted = any (\case RunStarted {} -> True; _ -> False)
steeringTests :: TestTree
steeringTests =
  testGroup
    "steering"
    [ testCase "a mid-run steer lands in the next model request and announces the injection" steerMidRun,
      testCase "a steer arriving during the final answer continues the run" lateSteerContinues,
      testCase "a follow-up arriving during the final answer starts the next turn" followUpContinues,
      testCase "an empty queue leaves history and events untouched" emptyDrainSilent
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

steerMidRun :: Assertion
steerMidRun = do
  gate <- newEmptyMVar
  runs <- newRunRegistry
  turns <- newIORef (0 :: Int)
  captured <- newIORef []
  events <- newIORef []
  streamed <- newEmptyMVar
  base <- testRuntime (steerModel turns captured) [gateTool gate] Sequential
  let runtime = base {runtimeRuns = Just runs}
  _ <-
    forkIO
      ( runAgent runtime (sampleInput []) (\event -> modifyIORef' events (event :))
          *> putMVar streamed ()
      )
  startedOk <- waitUntil (runStarted <$> readIORef events)
  unless startedOk (assertFailure "run never started")
  steered <- steerRun runs "run" (ChatUser "hold on")
  putMVar gate ()
  timeout 5000000 (takeMVar streamed) >>= maybe (assertFailure "steered run did not finish") pure
  streamedEvents <- reverse <$> readIORef events
  messages <- readIORef captured
  steered @?= True
  takeEnd 1 messages @?= [ChatUser "hold on"]
  [content | ChatToolResult _ content <- messages] @?= ["tool done"]
  eventType (last streamedEvents) @?= "RUN_FINISHED"
  injectValues streamedEvents
 where
  injectValues events =
    case [value | Custom "steering.inject" value <- events] of
      [value] ->
        sequence_
          [ parseMaybe (withObject "steer" (.: "step")) value @?= Just (2 :: Int),
            parseMaybe (withObject "steer" (.: "count")) value @?= Just (1 :: Int)
          ]
      other -> assertFailure ("expected one steering.inject, got " <> show (length other))

lateSteerContinues :: Assertion
lateSteerContinues = queuedAfterAnswer steerRun "steering.inject"

followUpContinues :: Assertion
followUpContinues = queuedAfterAnswer followUpRun "followup.inject"

queuedAfterAnswer :: (RunRegistry -> Text -> ChatMessage -> IO Bool) -> Text -> Assertion
queuedAfterAnswer queue kind = do
  entered <- newEmptyMVar
  release <- newEmptyMVar
  runs <- newRunRegistry
  turns <- newIORef (0 :: Int)
  captured <- newIORef []
  events <- newIORef []
  streamed <- newEmptyMVar
  base <- testRuntime (answerGateModel entered release turns captured) [] Sequential
  let runtime = base {runtimeRuns = Just runs}
  _ <-
    forkIO
      ( runAgent runtime (sampleInput []) (\event -> modifyIORef' events (event :))
          *> putMVar streamed ()
      )
  _ <- timeout 5000000 (takeMVar entered) >>= maybe (assertFailure "model answer never opened") pure
  accepted <- queue runs "run" (ChatUser "one more thing")
  putMVar release ()
  _ <- timeout 5000000 (takeMVar streamed) >>= maybe (assertFailure "queued run did not finish") pure
  streamedEvents <- reverse <$> readIORef events
  messages <- readIORef captured
  accepted @?= True
  takeEnd 1 messages @?= [ChatUser "one more thing"]
  length [() | Custom name _ <- streamedEvents, name == kind] @?= 1
  eventType (last streamedEvents) @?= "RUN_FINISHED"
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
