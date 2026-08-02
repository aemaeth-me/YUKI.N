module Yuki.N.TelemetryTest
  ( telemetryTests,
  )
where

import Control.Concurrent (Chan, forkIO, readChan)
import Control.Concurrent.MVar
import Data.Aeson (object, (.=))
import Data.Functor (($>))
import Data.IORef
import Data.Text (Text)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent
import Yuki.N.Model
import Yuki.N.Runs
import Yuki.N.Telemetry
import Yuki.N.TestSupport

telemetryTests :: TestTree
telemetryTests =
  testGroup
    "telemetry"
    [ testCase "starting publishes a live status with descriptor fields" startingStatus,
      testCase "events project phase, turn, tools, context and usage" eventProjection,
      testCase "terminal events finalize with outcome and drop the status" terminalFinalizes,
      testCase "stopping without a terminal event backstops as failed" stoppingBackstop,
      testCase "worker counts track child start and finish" workerCounts,
      testCase "status frames are throttled per run" throttling,
      testCase "cancelling marks the phase" cancelling,
      testCase "a wired runAgent reports live status and run.end" wiredRun
    ]

startingStatus :: Assertion
startingStatus = do
  (telemetry, _) <- fakeClock
  chan <- subscribe telemetry
  telemetryRunStarting telemetry "run-1" (RunDescriptor "task-a" "yuki" Nothing RunTask (Just "do a thing")) 32 "model-x"
  status <- expectFrame chan
  liveRunId status @?= "run-1"
  liveKind status @?= RunTask
  liveIncarnation status @?= "yuki"
  liveObjective status @?= Just "do a thing"
  liveMaxTurns status @?= 32
  liveModel status @?= "model-x"
  livePhase status @?= PhaseRunning

eventProjection :: Assertion
eventProjection = do
  (telemetry, advance) <- fakeClock
  _ <- subscribe telemetry
  telemetryRunStarting telemetry "run-1" (RunDescriptor "task-a" "yuki" Nothing RunTask Nothing) 32 "model-x"
  noteEvent telemetry "run-1" (StepStarted "s1")
  advance 300000
  noteEvent telemetry "run-1" (ToolCallStarted "c1" "fs_write" Nothing)
  noteEvent telemetry "run-1" (Custom "context.status" (object ["tokens" .= (100 :: Int), "budgetTokens" .= (200 :: Int), "windowTokens" .= (1000 :: Int)]))
  noteEvent telemetry "run-1" (Custom "usage" (object ["promptTokens" .= (10 :: Int), "completionTokens" .= (4 :: Int)]))
  [status] <- liveRuns telemetry
  liveTurn status @?= 1
  livePhase status @?= PhaseAwaitingTool
  fmap activeToolName (liveActiveTools status) @?= ["fs_write"]
  fmap contextEstimated (liveContext status) @?= Just 100
  liveUsagePrompt status @?= 10
  liveUsageCompletion status @?= 4
  advance 300000
  noteEvent telemetry "run-1" (ToolCallResult "m1" "c1" "done")
  [settled] <- liveRuns telemetry
  livePhase settled @?= PhaseRunning
  liveActiveTools settled @?= []

terminalFinalizes :: Assertion
terminalFinalizes = do
  (telemetry, _) <- fakeClock
  chan <- subscribe telemetry
  telemetryRunStarting telemetry "run-1" (RunDescriptor "task-a" "yuki" Nothing RunTask Nothing) 32 "model-x"
  _ <- readChan chan
  noteEvent telemetry "run-1" (RunFinished "task-a" "run-1" Nothing)
  ended <- expectEnd chan
  ended @?= ("run-1", "completed")
  remaining <- liveRuns telemetry
  remaining @?= []

stoppingBackstop :: Assertion
stoppingBackstop = do
  (telemetry, _) <- fakeClock
  chan <- subscribe telemetry
  telemetryRunStarting telemetry "run-1" (RunDescriptor "task-a" "yuki" Nothing RunTask Nothing) 32 "model-x"
  _ <- readChan chan
  telemetryRunStopping telemetry "run-1"
  ended <- expectEnd chan
  ended @?= ("run-1", "failed")
  remaining <- liveRuns telemetry
  remaining @?= []

workerCounts :: Assertion
workerCounts = do
  (telemetry, _) <- fakeClock
  _ <- subscribe telemetry
  telemetryRunStarting telemetry "parent" (RunDescriptor "task-a" "yuki" Nothing RunTask Nothing) 32 "model-x"
  telemetryRunStarting telemetry "child" (RunDescriptor "task-a" "yuki" (Just "parent") RunWorker (Just "sub task")) 32 "model-x"
  [parent] <- filter ((== "parent") . liveRunId) <$> liveRuns telemetry
  liveWorkers parent @?= 1
  noteEvent telemetry "child" (RunFinished "task-a" "child" Nothing)
  [settled] <- liveRuns telemetry
  liveRunId settled @?= "parent"
  liveWorkers settled @?= 0

throttling :: Assertion
throttling = do
  (telemetry, advance) <- fakeClock
  chan <- subscribe telemetry
  telemetryRunStarting telemetry "run-1" (RunDescriptor "task-a" "yuki" Nothing RunTask Nothing) 32 "model-x"
  _ <- readChan chan
  noteEvent telemetry "run-1" (StepStarted "s1")
  noteEvent telemetry "run-1" (StepStarted "s2")
  silent <- timeout 100000 (readChan chan)
  silent @?= Nothing
  advance 300000
  noteEvent telemetry "run-1" (StepStarted "s3")
  status <- expectFrame chan
  liveTurn status @?= 3

cancelling :: Assertion
cancelling = do
  (telemetry, _) <- fakeClock
  _ <- subscribe telemetry
  telemetryRunStarting telemetry "run-1" (RunDescriptor "task-a" "yuki" Nothing RunTask Nothing) 32 "model-x"
  noteCancelling telemetry "run-1"
  [status] <- liveRuns telemetry
  livePhase status @?= PhaseCancelling

wiredRun :: Assertion
wiredRun = do
  gate <- newEmptyMVar
  runs <- newRunRegistry
  (telemetry, _) <- fakeClock
  chan <- subscribe telemetry
  base <- testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel
  done <- newEmptyMVar
  _ <-
    forkIO
      ( runAgent
          base
            { runtimeRuns = Just runs,
              runtimeTelemetry = Just telemetry,
              runtimeHooks = defaultHooks {observeEvent = \input event -> noteEvent telemetry (AGUI.runId input) event}
            }
          (sampleInput [])
          (\_ -> pure ())
          *> putMVar done ()
      )
  started <- waitUntil (not . null <$> liveRuns telemetry)
  started @?= True
  [status] <- liveRuns telemetry
  liveKind status @?= RunTask
  putMVar gate ()
  _ <- timeout 5000000 (takeMVar done)
  finished <- waitUntil (null <$> liveRuns telemetry)
  finished @?= True
  frames <- drainFrames chan
  assertBool "run.end completed observed" (any isCompletedEnd frames)
 where
  isCompletedEnd (FrameRunEnd _ "completed") = True
  isCompletedEnd _ = False

fakeClock :: IO (Telemetry, Integer -> IO ())
fakeClock = do
  ref <- newIORef (1000000 :: Integer)
  telemetry <- newTelemetryWithClock (readIORef ref)
  pure (telemetry, \delta -> modifyIORef' ref (+ delta))

expectFrame :: Chan ActivityFrame -> IO LiveStatus
expectFrame chan =
  timeout 2000000 (readChan chan) >>= \case
    Just (FrameStatus status) -> pure status
    Just (FrameRunEnd {}) -> assertFailure "expected status frame"
    Just (FrameDelivery {}) -> assertFailure "expected status frame"
    Just (FrameFsChange {}) -> assertFailure "expected status frame"
    Nothing -> assertFailure "no frame"

expectEnd :: Chan ActivityFrame -> IO (Text, Text)
expectEnd chan =
  timeout 2000000 (readChan chan) >>= \case
    Just (FrameRunEnd runId outcome) -> pure (runId, outcome)
    Just (FrameStatus {}) -> assertFailure "expected run.end frame"
    Just (FrameDelivery {}) -> assertFailure "expected run.end frame"
    Just (FrameFsChange {}) -> assertFailure "expected run.end frame"
    Nothing -> assertFailure "no frame"

drainFrames :: Chan ActivityFrame -> IO [ActivityFrame]
drainFrames chan = go []
 where
  go acc =
    timeout 50000 (readChan chan) >>= \case
      Nothing -> pure (reverse acc)
      Just frame -> go (frame : acc)
