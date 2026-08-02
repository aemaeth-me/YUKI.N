module Yuki.N.SubAgentTest
  ( subAgentTests,
    capabilityDescription,
    inheritedShell,
    registration,
    delegation,
    depthExhausted,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Parser, parseEither, parseMaybe)
import Data.Functor (($>))
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client.TLS (newTlsManager)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent
import Yuki.N.Cognition (Cognition (..), attachCognition, ensureIncarnation, newCognition)
import Yuki.N.Experience (ExperienceEvent (..), ExperienceStore (..))
import Yuki.N.Journal
import Yuki.N.Model
import Yuki.N.Replay
import Yuki.N.Runs
import Yuki.N.SubAgent
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig

subAgentTests :: TestTree
subAgentTests =
  testGroup
    "sub-agents"
    [ testCase "delegates to a scoped sub-run and replays cleanly" delegation,
      testCase "refuses delegation at depth zero" depthExhausted,
      testCase "advertises the child's exact inherited tools" capabilityDescription,
      testCase "a resolved cwd lets the child execute a local shell request" inheritedShell,
      testCase "resolveRuntime registers sub_agent only above depth zero" registration,
      testGroup
        "completion table"
        [ testCase "retains completions until the parent run unregisters" completionTable,
          testCase "records succeeded, failed and cancelled conclusions" completionOutcomes
        ],
      testGroup
        "async workers"
        [ testCase "spawn returns immediately and the parent sees the worker notice" spawnAsync,
          testCase "spawn enforces the per-run parallel limit" parallelLimit,
          testCase "wait returns finished results and times out blocked workers" waitToolTest,
          testCase "send, status, list and cancel are scoped to spawned workers" scopedTools,
          testCase "cancelling a run cascades to its workers" cascadeCancel,
          testCase "worker experience events carry the spawn delegation id" delegationIdTest
        ]
    ]

capabilityDescription :: Assertion
capabilityDescription =
  testRuntime okModel [staticTool "shell" "ok", staticTool "fs_read" "ok"] Parallel
    >>= \base ->
      case Map.lookup "sub_agent" (runtimeTools (registerSubAgent base)) of
        Nothing -> assertFailure "missing sub_agent"
        Just backend ->
          let description = toolDescription (backendToolSpec backend)
           in sequence_
                [ assertBool "description names shell" ("shell" `Text.isInfixOf` description),
                  assertBool "description names fs_read" ("fs_read" `Text.isInfixOf` description),
                  assertBool "description excludes itself" (not ("sub_agent" `Text.isInfixOf` description))
                ]

inheritedShell :: Assertion
inheritedShell = withWorkDir $ \dir -> do
  manager <- newTlsManager
  base <- testRuntime subShellModel [] Sequential
  runtime <-
    resolveRuntime
      manager
      testProvider
      Nothing
      base
      (emptyThreadConfig {configCwd = CwdPath dir})
      Map.empty
      Map.empty
  events <- collectEvents runtime (sampleInput [])
  assertBool "parent receives the child answer" (any childAnswer events)
  assertBool "nested event exposes the shell call" (any nestedShell events)

childAnswer :: Event -> Bool
childAnswer (ToolCallResult _ "call-delegate" content) = "child-ok" `Text.isInfixOf` content
childAnswer _ = False
nestedShell :: Event -> Bool
nestedShell (Custom "agent.sub" value) =
  parseMaybe
    ( withObject "agent.sub" $ \fields ->
        fields .: "event"
          >>= withObject
            "event"
            (\event -> (,) <$> event .: "type" <*> event .:? "toolCallName")
    )
    value
    == Just ("TOOL_CALL_START" :: Text, Just ("shell" :: Text))
nestedShell _ = False

registration :: Assertion
registration = do
  manager <- newTlsManager
  base <- testRuntime okModel [] Parallel
  let resolved depth = resolveRuntime manager testProvider Nothing base {runtimeDepth = depth} emptyThreadConfig Map.empty Map.empty
  one <- resolved 1
  two <- resolved 2
  zero <- resolved 0
  assertBool "depth one registers" (Map.member "sub_agent" (runtimeTools one))
  assertBool "deeper still registers" (Map.member "sub_agent" (runtimeTools two))
  assertBool "depth zero omits" (Map.notMember "sub_agent" (runtimeTools zero))
  assertBool "async family registers alongside" (Map.member "sub_agent_spawn" (runtimeTools one))
  runtimeDepth one @?= 1

delegation :: Assertion
delegation = do
  (journal, readEntries) <- newMemoryJournal
  runtime <- delegateRuntime journal 1
  events <- collectEvents runtime (sampleInput [])
  recorded <- readEntries
  report <- replayEntries defaultHooks Nothing recorded
  [content | ToolCallResult _ "call-delegate" content <- events] @?= ["sub result"]
  assertBool "sub-run events are scoped" (any isSubEvent events)
  assertBool "journal nests the sub-run scope" (any ((== 2) . length . entryScope) recorded)
  fmap reportDivergence report @?= Right Nothing

depthExhausted :: Assertion
depthExhausted = do
  (journal, _) <- newMemoryJournal
  runtime <- delegateRuntime journal 0
  events <- collectEvents runtime (sampleInput [])
  [content | ToolCallResult _ "call-delegate" content <- events] @?= ["delegation depth exhausted"]
  assertBool "no sub-run events" (not (any isSubEvent events))

isSubEvent :: Event -> Bool
isSubEvent (Custom "agent.sub" _) = True
isSubEvent _ = False
subShellModel :: Model
subShellModel =
  fakeModel $ \request emit ->
    case lastMessage request of
      Just (ChatToolResult "call-delegate" _) -> emit (ModelTextDelta "parent done") $> Stop
      Just (ChatToolResult "call-shell" content) -> emit (ModelTextDelta content) $> Stop
      Just (ChatUser "run local shell") ->
        emit (ModelToolCallDelta 0 (Just "call-shell") (Just "shell") "{\"command\":\"printf child-ok\"}")
          $> ToolUse
      _ ->
        emit (ModelToolCallDelta 0 (Just "call-delegate") (Just "sub_agent") "{\"prompt\":\"run local shell\"}")
          $> ToolUse
delegateRuntime :: Journal -> Int -> IO Runtime
delegateRuntime journal depth =
  testRuntime subAgentModel [] Parallel >>= \base ->
    let tools = Map.fromList [("delegate", subAgentTool "delegate" "run a sub-agent" runtime)]
        runtime = base {runtimeJournal = Just journal, runtimeTools = tools, runtimeDepth = depth}
     in pure runtime
subAgentModel :: Model
subAgentModel =
  fakeModel $ \request emit ->
    case lastMessage request of
      Just (ChatToolResult {}) -> emit (ModelTextDelta "parent done") $> Stop
      Just (ChatUser "sub task") -> emit (ModelTextDelta "sub result") $> Stop
      _ ->
        emit (ModelToolCallDelta 0 (Just "call-delegate") (Just "delegate") "{\"prompt\":\"sub task\"}")
          $> ToolUse

completionTable :: Assertion
completionTable = do
  runs <- newRunRegistry
  withRunRegistrationFor runs "parent" (RunDescriptor "task" "yuki" Nothing RunTask (Just "parent task")) $ do
    writeCompletion runs "parent" Nothing Completed "parent result"
    withRunRegistrationFor runs "child" (RunDescriptor "task" "yuki" (Just "parent") RunWorker (Just "child task")) $ do
      writeCompletion runs "child" (Just "parent") (Failed "boom") "child result"
      child <- completionFor runs "child"
      fmap completionOutcome child @?= Just (Failed "boom")
      fmap completionResult child @?= Just "child result"
      fmap completionParent child @?= Just (Just "parent")
    kids <- completionsOf runs "parent"
    fmap completionRunId kids @?= ["child"]
    completionFor runs "child" >>= maybe (assertFailure "child completion must survive its own unregister") (const (pure ()))
  completionFor runs "parent" >>= assertBool "root completion dropped at root unregister" . isNothing
  completionFor runs "child" >>= assertBool "child completion dropped with the parent" . isNothing

completionOutcomes :: Assertion
completionOutcomes = do
  runs <- newRunRegistry
  withRunRegistrationFor runs "parent" (RunDescriptor "task" "yuki" Nothing RunTask Nothing) $ do
    succeeded <- childConclusion runs okModel
    failedResult <- childConclusion runs (fakeModel (\_ _ -> throwIO (ProviderFailure "down")))
    cancelledResult <- childCancelled runs
    fmap completionOutcome succeeded @?= Just Completed
    fmap completionResult succeeded @?= Just "ok"
    fmap completionOutcome failedResult @?= Just (Failed "PROVIDER_ERROR: down")
    fmap completionOutcome cancelledResult @?= Just Cancelled
 where
  childInput = (sampleInput []) {runId = "child", runParentId = Just "parent"}
  childConclusion runs model = do
    base <- testRuntime model [] Parallel
    _ <- collectEvents base {runtimeRuns = Just runs} childInput
    completionFor runs "child"
  childCancelled runs = do
    gate <- newEmptyMVar
    events <- newIORef []
    done <- newEmptyMVar
    base <- testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel
    _ <- forkIO (runAgent base {runtimeRuns = Just runs} childInput (\event -> modifyIORef' events (event :)) *> putMVar done ())
    startedOk <- waitUntil (runStarted <$> readIORef events)
    unless startedOk (assertFailure "child never started")
    _ <- cancelRun runs "child"
    _ <- timeout 5000000 (takeMVar done) >>= maybe (assertFailure "cancel did not finish the child") pure
    completionFor runs "child"

spawnAsync :: Assertion
spawnAsync = do
  runs <- newRunRegistry
  parentGate <- newEmptyMVar
  workerGate <- newEmptyMVar
  captured <- newIORef []
  events <- newIORef []
  done <- newEmptyMVar
  base <- testRuntime (asyncWorkerModel parentGate workerGate captured) [] Parallel
  let runtime = registerSubAgent (base {runtimeRuns = Just runs})
  _ <- forkIO (runAgent runtime (sampleInput []) (\event -> modifyIORef' events (event :)) *> putMVar done ())
  spawnedOk <- waitUntil (not . null <$> childrenOf runs "run")
  unless spawnedOk (assertFailure "worker never spawned")
  early <- readIORef events
  case [content | ToolCallResult _ "call-spawn" content <- early] of
    [content] -> do
      workerId <- outcomeValue (ToolOutcome content False False) >>= parseField "agentId"
      spawnStatus <- outcomeValue (ToolOutcome content False False) >>= parseField "status"
      spawnStatus @?= "running"
      kids <- childrenOf runs "run"
      fmap runInfoId kids @?= [workerId]
      fmap runInfoKind kids @?= [RunWorker]
      putMVar workerGate ()
      completedOk <- waitUntil (isJust <$> completionFor runs workerId)
      unless completedOk (assertFailure "worker completion never appeared")
      completionFor runs workerId >>= maybe (pure ()) (\c -> (completionOutcome c, completionResult c) @?= (Completed, "worker result"))
      putMVar parentGate ()
      _ <- timeout 5000000 (takeMVar done) >>= maybe (assertFailure "parent run did not finish") pure
      final <- readIORef events
      requests <- readIORef captured
      let workerLines = [text | ChatSystem text <- requests, "[worker " `Text.isPrefixOf` text]
      workerLines @?= ["[worker " <> workerId <> " completed] sub task\nworker result"]
      assertBool "parent announced the steering injection" (any (isCustom "steering.inject") final)
      assertBool "parent announced worker completion" (length [() | Custom "worker.notice" _ <- final] == 1)
      notices final workerId
    other -> assertFailure ("expected one spawn result, got " <> show (length other))
 where
  notices final workerId =
    case [value | Custom "worker.notice" value <- final] of
      [value] -> do
        runId <- parseField "runId" value
        parent <- parseField "parentRunId" value
        outcome <- parseField "outcome" value
        runId @?= workerId
        parent @?= "run"
        outcome @?= "completed"
      other -> assertFailure ("expected one worker.notice, got " <> show (length other))
  isCustom name = \case
    Custom eventName _ | eventName == name -> True
    _ -> False

parallelLimit :: Assertion
parallelLimit = do
  runs <- newRunRegistry
  gate <- newEmptyMVar
  base <- testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel
  let runtime = registerSubAgent (base {runtimeRuns = Just runs, runtimeSubAgentMaxParallel = 2})
      context = ToolContext "run" "thread" "call" (const (pure ())) Nothing ""
  spawnBackend <- requireTool runtime "sub_agent_spawn"
  withRunRegistration runs "run" $ do
    first <- runBackendTool spawnBackend context (spawnArgs "task one")
    firstStatus <- outcomeValue first >>= parseField "status"
    firstStatus @?= "running"
    firstReady <- waitUntil ((== 1) . length <$> childrenOf runs "run")
    unless firstReady (assertFailure "first worker never registered")
    second <- runBackendTool spawnBackend context (spawnArgs "task two")
    secondStatus <- outcomeValue second >>= parseField "status"
    secondStatus @?= "running"
    secondReady <- waitUntil ((== 2) . length <$> childrenOf runs "run")
    unless secondReady (assertFailure "second worker never registered")
    third <- runBackendTool spawnBackend context (spawnArgs "task three")
    toolOutcomeError third @?= True
    toolOutcomeContent third @?= "worker parallel limit reached"
    putMVar gate ()
    putMVar gate ()
    drained <- waitUntil (null <$> childrenOf runs "run")
    unless drained (assertFailure "workers did not finish")
 where
  spawnArgs prompt = object ["prompt" .= (prompt :: Text)]

waitToolTest :: Assertion
waitToolTest = do
  runs <- newRunRegistry
  gateA <- newEmptyMVar
  gateB <- newEmptyMVar
  base <- testRuntime (waitModel gateA gateB) [] Parallel
  let runtime = registerSubAgent (base {runtimeRuns = Just runs})
      context = ToolContext "run" "thread" "call" (const (pure ())) Nothing ""
  spawnBackend <- requireTool runtime "sub_agent_spawn"
  waitBackend <- requireTool runtime "sub_agent_wait"
  withRunRegistration runs "run" $ do
    _ <- runBackendTool spawnBackend context (object ["prompt" .= ("quick task" :: Text)])
    _ <- runBackendTool spawnBackend context (object ["prompt" .= ("slow task" :: Text)])
    spawnedOk <- waitUntil ((== 2) . length <$> childrenOf runs "run")
    unless spawnedOk (assertFailure "workers never spawned")
    ids <- fmap runInfoId <$> childrenOf runs "run"
    putMVar gateA ()
    appeared <- waitUntil (any isJust <$> traverse (completionFor runs) ids)
    unless appeared (assertFailure "quick worker never completed")
    completed <- catMaybes <$> traverse (completionFor runs) ids
    case completed of
      [completion] -> do
        let completedId = completionRunId completion
            blockedId = fromJustText (filter (/= completedId) ids)
        completionResult completion @?= "quick result"
        outcome <- runBackendTool waitBackend context (object ["agentIds" .= [completedId, blockedId], "timeoutSeconds" .= (1 :: Int)])
        value <- outcomeValue outcome
        results <- parseResults value
        timedOut <- parseTimedOut value
        results @?= [(completedId, "completed", Just "quick result")]
        timedOut @?= [blockedId]
        putMVar gateB ()
      other -> assertFailure ("expected one completed worker, got " <> show (length other))

scopedTools :: Assertion
scopedTools = do
  runs <- newRunRegistry
  gate <- newEmptyMVar
  base <- testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel
  let runtime = registerSubAgent (base {runtimeRuns = Just runs})
      parentContext = ToolContext "run" "thread" "call" (const (pure ())) Nothing ""
      otherContext = ToolContext "other" "thread" "call" (const (pure ())) Nothing ""
  spawnBackend <- requireTool runtime "sub_agent_spawn"
  sendBackend <- requireTool runtime "sub_agent_send"
  statusBackend <- requireTool runtime "sub_agent_status"
  listBackend <- requireTool runtime "sub_agent_list"
  cancelBackend <- requireTool runtime "sub_agent_cancel"
  withRunRegistration runs "run" $ do
    withRunRegistration runs "other" $ do
      spawned <- runBackendTool spawnBackend parentContext (object ["prompt" .= ("sub task" :: Text)])
      workerId <- outcomeValue spawned >>= parseField "agentId"
      spawnedOk <- waitUntil (not . null <$> childrenOf runs "run")
      unless spawnedOk (assertFailure "worker never spawned")
      runningValue <- outcomeValue =<< runBackendTool statusBackend parentContext (object ["agentId" .= workerId])
      parseField "status" runningValue >>= (@?= "running")
      strangerStatus <- runBackendTool statusBackend otherContext (object ["agentId" .= workerId])
      toolOutcomeError strangerStatus @?= True
      toolOutcomeContent strangerStatus @?= "unknown worker"
      listed <- outcomeValue =<< runBackendTool listBackend parentContext (object [])
      workerCount listed >>= (@?= 1)
      strangeList <- outcomeValue =<< runBackendTool listBackend otherContext (object [])
      workerCount strangeList >>= (@?= 0)
      strangerSend <- runBackendTool sendBackend otherContext (object ["agentId" .= workerId, "text" .= ("focus" :: Text)])
      toolOutcomeError strangerSend @?= True
      delivered <- outcomeValue =<< runBackendTool sendBackend parentContext (object ["agentId" .= workerId, "text" .= ("focus" :: Text)])
      parseFieldBool "delivered" delivered >>= (@?= True)
      queued <- drainSteering runs workerId
      queued @?= [ChatUser "focus"]
      strangerCancel <- runBackendTool cancelBackend otherContext (object ["agentId" .= workerId])
      toolOutcomeError strangerCancel @?= True
      cancelled <- outcomeValue =<< runBackendTool cancelBackend parentContext (object ["agentId" .= workerId])
      parseFieldBool "cancelled" cancelled >>= (@?= True)
      putMVar gate ()
      terminalOk <- waitUntil (isJust <$> completionFor runs workerId)
      unless terminalOk (assertFailure "cancelled worker never completed")
      terminal <- outcomeValue =<< runBackendTool statusBackend parentContext (object ["agentId" .= workerId])
      parseField "status" terminal >>= (@?= "cancelled")

cascadeCancel :: Assertion
cascadeCancel = do
  runs <- newRunRegistry
  workerGate <- newEmptyMVar
  parentGate <- newEmptyMVar
  childHookGate <- newEmptyMVar
  turns <- newIORef (0 :: Int)
  events <- newIORef []
  done <- newEmptyMVar
  base <- testRuntime (cascadeParentModel turns parentGate workerGate) [] Parallel
  let cascadeHooks =
        defaultHooks
          { afterRunOutcome = \input _ _ ->
              case AGUI.runParentId input of
                Just _ -> takeMVar childHookGate
                Nothing -> pure ()
          }
      runtime = registerSubAgent (base {runtimeRuns = Just runs, runtimeHooks = cascadeHooks})
  _ <- forkIO (runAgent runtime (sampleInput []) (\event -> modifyIORef' events (event :)) *> putMVar done ())
  spawnedOk <- waitUntil ((== 2) . length <$> childrenOf runs "run")
  unless spawnedOk (assertFailure "workers never spawned")
  ids <- fmap runInfoId <$> childrenOf runs "run"
  _ <- cancelRun runs "run"
  parentDone <- waitUntil (isJust <$> tryTakeMVar done)
  unless parentDone (assertFailure "parent run did not finish")
  putMVar childHookGate ()
  putMVar childHookGate ()
  finished <- waitUntil (all isJust <$> traverse (completionFor runs) ids)
  unless finished (assertFailure "cascade-cancelled workers never completed")
  completions <- catMaybes <$> traverse (completionFor runs) ids
  assertBool "cascaded workers show cancelled" (all ((== Cancelled) . completionOutcome) completions)
  announced <- readIORef events
  assertBool "parent announced its cancellation" (any (\case Custom "run.cancelled" _ -> True; _ -> False) announced)

delegationIdTest :: Assertion
delegationIdTest = withWorkDir $ \dir -> do
  runs <- newRunRegistry
  parentGate <- newEmptyMVar
  workerGate <- newEmptyMVar
  captured <- newIORef []
  events <- newIORef []
  done <- newEmptyMVar
  cognition <- newCognition dir [asyncWorkerModel parentGate workerGate captured] Nothing >>= expectTextRight
  incarnation <- ensureIncarnation cognition "yuki"
  base <- testRuntime (asyncWorkerModel parentGate workerGate captured) [] Parallel
  cognitive <- attachCognition cognition incarnation (base {runtimeRuns = Just runs})
  let runtime = registerSubAgent cognitive
  _ <- forkIO (runAgent runtime (sampleInput []) (\event -> modifyIORef' events (event :)) *> putMVar done ())
  spawnedOk <- waitUntil (not . null <$> childrenOf runs "run")
  unless spawnedOk (assertFailure "worker never spawned")
  kids <- childrenOf runs "run"
  workerId <- maybe (assertFailure "worker missing from registry") (pure . runInfoId) (listToMaybe kids)
  putMVar workerGate ()
  completedOk <- waitUntil (isJust <$> completionFor runs workerId)
  unless completedOk (assertFailure "worker never completed")
  putMVar parentGate ()
  _ <- timeout 10000000 (takeMVar done) >>= maybe (assertFailure "root run did not finish") pure
  stream <- experienceEvents (cognitionExperiences cognition) "yuki"
  let workerEvents = [event | event <- stream, experienceRunId event == Just workerId]
      rootEvents = [event | event <- stream, experienceRunId event == Just "run"]
  assertBool "worker wrote experience events" (not (null workerEvents))
  assertBool "root wrote experience events" (not (null rootEvents))
  fmap experienceDelegationId workerEvents @?= replicate (length workerEvents) (Just "call-spawn")
  fmap experienceDelegationId rootEvents @?= replicate (length rootEvents) Nothing

asyncWorkerModel :: MVar () -> MVar () -> IORef [ChatMessage] -> Model
asyncWorkerModel parentGate workerGate captured =
  fakeModel $ \request emit ->
    case lastMessage request of
      Just (ChatToolResult "call-spawn" _) ->
        takeMVar parentGate *> emit (ModelTextDelta "parent done") $> Stop
      Just (ChatUser "sub task") ->
        takeMVar workerGate *> emit (ModelTextDelta "worker result") $> Stop
      Just (ChatSystem _) ->
        writeIORef captured (requestMessages request)
          *> emit (ModelTextDelta "parent final")
          $> Stop
      _ ->
        emit (ModelToolCallDelta 0 (Just "call-spawn") (Just "sub_agent_spawn") "{\"prompt\":\"sub task\"}")
          $> ToolUse

waitModel :: MVar () -> MVar () -> Model
waitModel gateA gateB =
  fakeModel $ \request emit ->
    case lastMessage request of
      Just (ChatUser prompt)
        | "quick" `Text.isInfixOf` prompt -> takeMVar gateA *> emit (ModelTextDelta "quick result") $> Stop
        | otherwise -> takeMVar gateB *> emit (ModelTextDelta "slow result") $> Stop
      _ -> emit (ModelTextDelta "idle") $> Stop

cascadeParentModel :: IORef Int -> MVar () -> MVar () -> Model
cascadeParentModel turns parentGate workerGate =
  fakeModel $ \request emit ->
    case lastMessage request of
      Just (ChatUser "sub task") ->
        takeMVar workerGate *> emit (ModelTextDelta "worker result") $> Stop
      _ ->
        atomicModifyIORef' turns (\count -> (count + 1, count + 1)) >>= \case
          1 ->
            emit (ModelToolCallDelta 0 (Just "call-spawn-1") (Just "sub_agent_spawn") "{\"prompt\":\"sub task\"}")
              $> ToolUse
          2 ->
            emit (ModelToolCallDelta 0 (Just "call-spawn-2") (Just "sub_agent_spawn") "{\"prompt\":\"sub task\"}")
              $> ToolUse
          _ -> takeMVar parentGate *> emit (ModelTextDelta "parent done") $> Stop

requireTool :: Runtime -> Text -> IO BackendTool
requireTool runtime name =
  maybe (assertFailure ("missing tool: " <> Text.unpack name)) pure (Map.lookup name (runtimeTools runtime))

parseField :: Text -> Value -> IO Text
parseField key value =
  either assertFailure pure (parseEither (withObject "field" (\fields -> fields .: Key.fromText key)) value)

parseFieldBool :: Text -> Value -> IO Bool
parseFieldBool key value =
  either assertFailure pure (parseEither (withObject "field" (\fields -> fields .: Key.fromText key)) value)

workerCount :: Value -> IO Int
workerCount value = either assertFailure pure (parseEither (withObject "list" count) value)
 where
  count fields = length <$> (fields .: "workers" :: Parser [Value])

parseResults :: Value -> IO [(Text, Text, Maybe Text)]
parseResults value = either assertFailure pure (parseEither parse value)
 where
  parse = withObject "wait" $ \fields -> fields .: "results" >>= traverse result
  result = withObject "result" $ \fields ->
    (,,) <$> fields .: "agentId" <*> fields .: "status" <*> fields .:? "result"

parseTimedOut :: Value -> IO [Text]
parseTimedOut value =
  either assertFailure pure (parseEither (withObject "wait" (.: "timedOut")) value)

runStarted :: [Event] -> Bool
runStarted = any (\case RunStarted {} -> True; _ -> False)

fromJustText :: [Text] -> Text
fromJustText = fromMaybe (error "expected a single worker id") . listToMaybe
