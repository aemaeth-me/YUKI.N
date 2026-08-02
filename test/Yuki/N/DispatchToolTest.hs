module Yuki.N.DispatchToolTest
  ( dispatchToolTests,
  )
where

import Control.Concurrent (forkIO, readChan)
import Control.Concurrent.MVar
import Data.Aeson
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types
import Network.Wai.Test
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event (Event (..))
import Yuki.N.Agent
import Yuki.N.Cognition (Cognition (..), newCognition)
import Yuki.N.Dispatch
import Yuki.N.DispatchTool (proposeDispatchTool)
import Yuki.N.Inspect
import Yuki.N.Invocation (invokeModel)
import Yuki.N.Server
import Yuki.N.Sessions (SessionService (..))
import Yuki.N.SubAgent (childRuntime, delegableTools)
import Yuki.N.Telemetry (ActivityFrame (..), newTelemetry, subscribe)
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig

dispatchToolTests :: TestTree
dispatchToolTests =
  testGroup
    "dispatch tool"
    [ testCase "propose_dispatch is registered for root runtimes and stripped from workers" toolVisibility,
      testCase "execution drafts with agent source, emits dispatch.draft and publishes a draft frame" toolExecution,
      testCase "confirmed proposal returns the threadId" confirmedProposal,
      testCase "cancelled proposal returns an error" cancelledProposal,
      testCase "proposal awaiting confirmation times out" timedOutProposal,
      testCase "confirm and cancel routes publish draft.resolved frames" resolvedFrames
    ]

toolVisibility :: Assertion
toolVisibility = withWorkDir $ \dir -> do
  manager <- newTlsManager
  store <- newDispatchStore dir
  base <- testRuntime okModel [] Parallel
  resolved <-
    resolveRuntime
      manager
      testProvider
      Nothing
      base
        { runtimeDispatchStore = Just store,
          runtimeDispatchConfirmTimeout = 600
        }
      emptyThreadConfig
      Map.empty
      Map.empty
  Map.member "propose_dispatch" (runtimeTools resolved) @?= True
  Map.notMember "propose_dispatch" (delegableTools resolved) @?= True
  let context = ToolContext "run" "thread" "call" (const (pure ())) Nothing ""
  Map.notMember "propose_dispatch" (runtimeTools (childRuntime resolved context)) @?= True

toolExecution :: Assertion
toolExecution = withWorkDir $ \dir -> do
  store <- newDispatchStore dir
  telemetry <- newTelemetry 8192
  chan <- subscribe telemetry
  events <- newIORef []
  outcomeVar <- newEmptyMVar
  let context = ToolContext "run-1" "thread-1" "call-1" (modifyIORef' events . (:)) Nothing "art"
      arguments = object ["title" .= ("Build the report" :: Text), "prompt" .= ("Write it" :: Text), "reason" .= ("long work" :: Text)]
  _ <- forkIO (runBackendTool (proposeDispatchTool 60 store (Just telemetry)) context arguments >>= putMVar outcomeVar)
  started <- waitUntil (not . null <$> listDispatches store "art" (Just Draft))
  started @?= True
  [draft] <- listDispatches store "art" (Just Draft)
  dispatchSource draft @?= DispatchAgent "run-1" "call-1"
  dispatchGeneration draft @?= GeneratedAgent
  dispatchIncarnationId draft @?= "art"
  dispatchTitle draft @?= "Build the report"
  dispatchPrompt draft @?= "Write it"
  dispatchInput draft @?= "long work"
  emitted <- reverse <$> readIORef events
  assertBool "dispatch.draft emitted" (any isDispatchDraft emitted)
  frame <- timeout 2000000 (readChan chan) >>= maybe (assertFailure "no draft frame") pure
  case frame of
    FrameDraft published -> dispatchId published @?= dispatchId draft
    other -> assertFailure ("expected draft frame, got " <> show other)
  _ <- markDispatchCancelled store (dispatchId draft) >>= expectTextRight
  outcome <- timeout 5000000 (takeMVar outcomeVar) >>= maybe (assertFailure "tool did not return") pure
  assertBool "cancel rejected" (toolOutcomeError outcome)
  assertBool "cancel message" ("cancelled by user" `Text.isInfixOf` toolOutcomeContent outcome)
 where
  isDispatchDraft (Custom "dispatch.draft" _) = True
  isDispatchDraft _ = False

confirmedProposal :: Assertion
confirmedProposal = withWorkDir $ \dir -> do
  store <- newDispatchStore dir
  outcomeVar <- newEmptyMVar
  let context = ToolContext "run-1" "thread-1" "call-1" (const (pure ())) Nothing "art"
  _ <- forkIO (runBackendTool (proposeDispatchTool 60 store Nothing) context proposalArguments >>= putMVar outcomeVar)
  started <- waitUntil (not . null <$> listDispatches store "art" (Just Draft))
  started @?= True
  [draft] <- listDispatches store "art" (Just Draft)
  _ <- markDispatchDispatched store (dispatchId draft) "thread-9" >>= expectTextRight
  outcome <- timeout 5000000 (takeMVar outcomeVar) >>= maybe (assertFailure "tool did not return") pure
  toolOutcomeError outcome @?= False
  value <- outcomeValue outcome
  value @?= object ["threadId" .= ("thread-9" :: Text), "status" .= ("dispatched" :: Text)]

cancelledProposal :: Assertion
cancelledProposal = withWorkDir $ \dir -> do
  store <- newDispatchStore dir
  outcomeVar <- newEmptyMVar
  let context = ToolContext "run-1" "thread-1" "call-1" (const (pure ())) Nothing "art"
  _ <- forkIO (runBackendTool (proposeDispatchTool 60 store Nothing) context proposalArguments >>= putMVar outcomeVar)
  started <- waitUntil (not . null <$> listDispatches store "art" (Just Draft))
  started @?= True
  [draft] <- listDispatches store "art" (Just Draft)
  _ <- markDispatchCancelled store (dispatchId draft) >>= expectTextRight
  outcome <- timeout 5000000 (takeMVar outcomeVar) >>= maybe (assertFailure "tool did not return") pure
  toolOutcomeError outcome @?= True
  assertBool "cancel message" ("cancelled by user" `Text.isInfixOf` toolOutcomeContent outcome)

timedOutProposal :: Assertion
timedOutProposal = withWorkDir $ \dir -> do
  store <- newDispatchStore dir
  outcomeVar <- newEmptyMVar
  let context = ToolContext "run-1" "thread-1" "call-1" (const (pure ())) Nothing "art"
  _ <- forkIO (runBackendTool (proposeDispatchTool 1 store Nothing) context proposalArguments >>= putMVar outcomeVar)
  started <- waitUntil (not . null <$> listDispatches store "art" (Just Draft))
  started @?= True
  outcome <- timeout 5000000 (takeMVar outcomeVar) >>= maybe (assertFailure "tool did not return") pure
  toolOutcomeError outcome @?= True
  assertBool "timeout message" ("confirmation timed out" `Text.isInfixOf` toolOutcomeContent outcome)

resolvedFrames :: Assertion
resolvedFrames = withWorkDir $ \dir -> do
  cognitionResult <- newCognition (dir ++ "/cognition") [okModel] Nothing
  cognition <- either (assertFailure . Text.unpack) pure cognitionResult
  service <- sessionServiceAt dir (const (pure ()))
  dispatches <- newDispatchStore dir
  telemetry <- newTelemetry 8192
  chan <- subscribe telemetry
  base <- testRuntime okModel [] Parallel
  let dispatchService =
        newDispatchService
          dispatches
          service
          (cognitionIncarnations cognition)
          (pure "route-thread")
          (\incarnation input -> generateDraft invokeModel [okModel] 20 Nothing incarnation input)
      inspection =
        withCognition
          cognition
          (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
      app = application Nothing (Just inspection) Nothing Nothing (Just dispatchService) (Just telemetry) (const (pure base))
  dispatched <- createDispatch dispatches (NewDispatch DispatchUser "yuki" "input" "Mission" "Do it" emptyThreadConfig GeneratedFallback)
  confirmed <- runSession (srequest (jsonRequest methodPost ["dispatches", dispatchId dispatched, "confirm"] (object []))) app
  simpleStatus confirmed @?= status201
  firstFrame <- timeout 2000000 (readChan chan) >>= maybe (assertFailure "no resolved frame") pure
  firstFrame @?= FrameDraftResolved (dispatchId dispatched) "dispatched" (Just "route-thread")
  cancelledDraft <- createDispatch dispatches (NewDispatch DispatchUser "yuki" "input" "Mission 2" "Do it too" emptyThreadConfig GeneratedFallback)
  cancelled <- runSession (srequest (jsonRequest methodPost ["dispatches", dispatchId cancelledDraft, "cancel"] (object []))) app
  simpleStatus cancelled @?= status200
  secondFrame <- timeout 2000000 (readChan chan) >>= maybe (assertFailure "no resolved frame") pure
  secondFrame @?= FrameDraftResolved (dispatchId cancelledDraft) "cancelled" Nothing

proposalArguments :: Value
proposalArguments =
  object
    [ "title" .= ("Build the report" :: Text),
      "prompt" .= ("Write it" :: Text)
    ]
