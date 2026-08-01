module Yuki.N.MemoryTest
  ( memoryTests,
    injectionEvents,
    briefingIdempotent,
    briefingStructure,
    briefingCap,
    briefingAcrossRuns,
    briefingReplay,
    briefingReplayWithStores,
    multiRunMemoryReplay,
    storesUnchangedAfterReplay,
    replayFileGateForMemory,
    increments,
    episodeOnDisk,
    failureIsolation,
    composition,
  )
where

import Control.Exception (throwIO)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor (($>))
import Data.IORef
import Data.Text qualified as Text
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Facts
import Yuki.N.Journal
import Yuki.N.Memory
import Yuki.N.Model
import Yuki.N.Replay
import Yuki.N.TestSupport
import Yuki.N.Transcript

memoryTests :: TestTree
memoryTests =
  testGroup
    "memory"
    [ testCase "watches only the increment of a thread" increments,
      testCase "persists an episode when the run finishes" episodeOnDisk,
      testCase "watcher failure never breaks the run" failureIsolation,
      testCase "composes with business afterRun hooks" composition,
      testCase "injects the brief once when transformed twice" briefingIdempotent,
      testCase "renders the briefing at the head with marker, summary, episodes and as-of time" briefingStructure,
      testCase "caps the rolling summary at 2000 characters" briefingCap,
      testCase "carries the brief into the next run exactly once" briefingAcrossRuns,
      testCase "announces context injections as custom events" injectionEvents,
      testCase "replays a journaled run with briefing without divergence" briefingReplay,
      testCase "replays a memory-enabled journal via replayWithStores without divergence" briefingReplayWithStores,
      testCase "multi-run memory replay resumes after the prior run boundary" multiRunMemoryReplay,
      testCase "replayWithStores leaves the live ThreadStore unchanged" storesUnchangedAfterReplay,
      testCase "replayFile gates journals with memory-injected requests" replayFileGateForMemory
    ]

injectionEvents :: Assertion
injectionEvents = do
  store <- newMemoryThreadStore
  facts <- newMemoryFactStore
  state <- newMemoryState
  base <- testRuntime (fakeModel (\_ emit -> emit (ModelTextDelta "ok") $> Stop)) [] Sequential
  threadSaveEpisode store "thread" (Episode "run-0" "did things" 1700000000)
  events <- collectEvents base {runtimeHooks = memoryHooks rollingWatcher store facts Nothing state} (sampleInput [])
  case [text | Custom "context.inject" value <- events, Just text <- [injectedText value]] of
    [text] -> assertBool "injection carries the brief" (Text.isInfixOf "did things" text)
    other -> assertFailure ("expected one context.inject, got " <> show (length other))
 where
  injectedText = parseMaybe (withObject "inject" (.: "content"))

rollingWatcher :: Model
rollingWatcher = fakeModel (\_ emit -> emit (ModelTextDelta "rolling memo") $> Stop)
markedMessage :: ChatMessage -> Bool
markedMessage (ChatSystem text) = briefingMarker `Text.isInfixOf` text
markedMessage _ = False
briefingCount :: [ChatMessage] -> Int
briefingCount = length . filter markedMessage

briefingIdempotent :: Assertion
briefingIdempotent = do
  store <- newMemoryThreadStore
  threadSaveEpisode store "thread" (Episode "run-0" "did things" 1700000000)
  facts <- newMemoryFactStore
  state <- newMemoryState
  let hooks = memoryHooks rollingWatcher store facts Nothing state
      input = sampleInput []
  once <- transformContext hooks input [ChatUser "hi"]
  twice <- transformContext hooks input once
  briefingCount twice @?= 1
  twice @?= once

briefingStructure :: Assertion
briefingStructure = do
  store <- newMemoryThreadStore
  threadSaveEpisode store "thread" (Episode "run-0" "did things" 1700000000)
  threadSaveEpisode store "thread" (Episode "run-1" "shipped" 1700000100)
  facts <- newMemoryFactStore
  state <- newMemoryState
  context <- transformContext (memoryHooks rollingWatcher store facts Nothing state) (sampleInput []) [ChatUser "hi"]
  verify context
  store' <- newMemoryThreadStore
  empty facts store'
 where
  verify (ChatSystem text : rest) =
    sequence_
      [ rest @?= [ChatUser "hi"],
        init (Text.lines text)
          @?= [ briefingMarker,
                "summary: shipped",
                "episode 2023-11-14T22:13:20Z: did things",
                "episode 2023-11-14T22:15:00Z: shipped"
              ],
        assertBool "an as-of line closes the briefing" ("as of 2023-11-14T22:15:00Z" == last (Text.lines text))
      ]
  verify other = assertFailure ("briefing missing at head: " <> show (length other) <> " messages")
  empty facts store =
    newMemoryState >>= \state ->
      transformContext (memoryHooks rollingWatcher store facts Nothing state) (sampleInput []) [ChatUser "hi"]
        >>= (@?= [ChatUser "hi"])

briefingCap :: Assertion
briefingCap = do
  store <- newMemoryThreadStore
  threadSaveEpisode store "thread" (Episode "run-0" (Text.replicate 3000 "x") 1700000000)
  facts <- newMemoryFactStore
  state <- newMemoryState
  context <- transformContext (memoryHooks rollingWatcher store facts Nothing state) (sampleInput []) [ChatUser "hi"]
  case context of
    (ChatSystem text : _) -> Text.lines text !! 1 @?= "summary: " <> Text.replicate 2000 "x"
    _ -> assertFailure "briefing missing at head"

briefingAcrossRuns :: Assertion
briefingAcrossRuns = do
  store <- newMemoryThreadStore
  facts <- newMemoryFactStore
  state <- newMemoryState
  captured <- newIORef []
  base <- testRuntime (captureModel captured) [echoTool] Sequential
  _ <- collectEvents base {runtimeHooks = hooks state store facts} (input "run-1")
  _ <- collectEvents base {runtimeHooks = hooks state store facts} (input "run-2")
  capturedMessages <- reverse <$> readIORef captured
  verify capturedMessages
 where
  hooks state store facts = memoryHooks rollingWatcher store facts Nothing state
  input runId = (sampleInput [tool "echo"]) {runId = runId}
  verify [first, second, third, fourth] =
    sequence_
      [ briefingCount first @?= 0,
        briefingCount second @?= 0,
        briefingCount third @?= 1,
        briefingCount fourth @?= 1,
        case third of
          (ChatSystem text : _) ->
            assertBool "briefing carries the rolling summary" (Text.isInfixOf "rolling memo" text)
          _ -> assertFailure "briefing is not at the head"
      ]
  verify other = assertFailure ("unexpected request count: " <> show (length other))

captureModel :: IORef [[ChatMessage]] -> Model
captureModel captured =
  fakeModel $ \request emit ->
    modifyIORef' captured (requestMessages request :)
      *> case lastMessage request of
        Just (ChatToolResult {}) -> emit (ModelTextDelta "done") $> Stop
        _ -> emit (ModelToolCallDelta 0 (Just "call-echo") (Just "echo") "{\"x\":1}") $> ToolUse

briefingReplay :: Assertion
briefingReplay = do
  store <- newMemoryThreadStore
  threadSaveEpisode store "thread" (Episode "run-0" "earlier" 1700000000)
  facts <- newMemoryFactStore
  (journal, readEntries) <- newMemoryJournal
  state <- newMemoryState
  base <- testRuntime mainModel [] Parallel
  events <- collectEvents base {runtimeHooks = hooks state store facts, runtimeJournal = Just journal} (sampleInput [])
  recorded <- readEntries
  replayStore <- newMemoryThreadStore
  threadSaveEpisode replayStore "thread" (Episode "run-0" "earlier" 1700000000)
  replayState <- newMemoryState
  report <- replayEntries (hooks replayState replayStore facts) Nothing recorded
  fmap reportDivergence report @?= Right Nothing
  fmap reportEvents report @?= Right (length events)
  assertBool "journaled request carries the briefing" (any briefed recorded)
 where
  hooks state store facts = memoryHooks rollingWatcher store facts Nothing state
  mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)
  briefed (Entry _ _ _ (ModelRequestEntry request)) = any markedMessage (requestMessages request)
  briefed _ = False

briefingReplayWithStores :: Assertion
briefingReplayWithStores = do
  store <- newMemoryThreadStore
  threadSaveEpisode store "thread" (Episode "run-0" "earlier" 1700000000)
  replayStore <- newMemoryThreadStore
  threadSaveEpisode replayStore "thread" (Episode "run-0" "earlier" 1700000000)
  facts <- newMemoryFactStore
  (journal, readEntries) <- newMemoryJournal
  state <- newMemoryState
  base <- testRuntime mainModel [] Parallel
  events <- collectEvents base {runtimeHooks = hooks journal state store facts, runtimeJournal = Just journal} (sampleInput [])
  recorded <- readEntries
  report <- replayWithStores replayStore facts Nothing recorded
  fmap reportDivergence report @?= Right Nothing
  fmap reportEvents report @?= Right (length events)
 where
  hooks journal state store facts = memoryHooks rollingWatcher store facts (Just journal) state
  mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)

multiRunMemoryReplay :: Assertion
multiRunMemoryReplay = do
  store <- newMemoryThreadStore
  facts <- newMemoryFactStore
  (journal, readEntries) <- newMemoryJournal
  state <- newMemoryState
  base <- testRuntime mainModel [] Parallel
  let hooks = memoryHooks rollingWatcher store facts (Just journal) state
      runtime = base {runtimeHooks = hooks, runtimeJournal = Just journal}
  _ <- collectEvents runtime firstInput
  _ <- collectEvents runtime secondInput
  recorded <- readEntries
  report <- replayWithStores store facts (Just "memory-run-2") recorded
  fmap reportDivergence report @?= Right Nothing
  assertBool "second watcher skips the prior user message" (any correctDelta recorded)
 where
  mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "answer") $> Stop)
  firstInput =
    (sampleInput [])
      { runId = "memory-run-1",
        runMessages = [User (UserMessage "user-1" (UserText "one") Nothing)]
      }
  secondInput =
    (sampleInput [])
      { runId = "memory-run-2",
        runMessages =
          toAguiMessages
            [ ChatUser "one",
              ChatAssistant (AssistantTurn "answer-1" (Just "answer") Nothing []),
              ChatUser "two"
            ]
      }
  correctDelta (Entry _ ["memory-run-2", "memory"] _ (ModelRequestEntry request)) =
    case [text | ChatUser text <- requestMessages request] of
      [prompt] -> Text.isInfixOf "user: two" prompt && not (Text.isInfixOf "user: one" prompt)
      _ -> False
  correctDelta _ = False

storesUnchangedAfterReplay :: Assertion
storesUnchangedAfterReplay = do
  store <- newMemoryThreadStore
  threadSaveEpisode store "thread" (Episode "run-0" "earlier" 1700000000)
  replayStore <- newMemoryThreadStore
  threadSaveEpisode replayStore "thread" (Episode "run-0" "earlier" 1700000000)
  facts <- newMemoryFactStore
  (journal, readEntries) <- newMemoryJournal
  state <- newMemoryState
  base <- testRuntime mainModel [] Parallel
  _ <- collectEvents base {runtimeHooks = hooks journal state store facts, runtimeJournal = Just journal} (sampleInput [])
  recorded <- readEntries
  briefBefore <- threadBrief replayStore "thread"
  factsBefore <- factList facts
  report <- replayWithStores replayStore facts Nothing recorded
  briefAfter <- threadBrief replayStore "thread"
  factsAfter <- factList facts
  fmap reportDivergence report @?= Right Nothing
  briefAfter @?= briefBefore
  factsAfter @?= factsBefore
 where
  hooks journal state store facts = memoryHooks rollingWatcher store facts (Just journal) state
  mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)

replayFileGateForMemory :: Assertion
replayFileGateForMemory = do
  store <- newMemoryThreadStore
  threadSaveEpisode store "thread" (Episode "run-0" "earlier" 1700000000)
  facts <- newMemoryFactStore
  (journal, readEntries) <- newMemoryJournal
  state <- newMemoryState
  base <- testRuntime mainModel [] Parallel
  _ <- collectEvents base {runtimeHooks = hooks state store facts, runtimeJournal = Just journal} (sampleInput [])
  recorded <- readEntries
  tmp <- getTemporaryDirectory
  identifier <- newId
  let dir = tmp ++ "/" ++ Text.unpack identifier
  createDirectoryIfMissing True dir
  LazyByteString.writeFile (journalFilePath dir) (LazyByteString.concat (fmap ((<> "\n") . encode) recorded))
  outcome <- replayFile defaultHooks (journalFilePath dir) Nothing
  case outcome of
    Left msg -> assertBool "gate message mentions memory" ("memory-injected" `Text.isInfixOf` msg)
    Right _ -> assertFailure "expected gate rejection, got success"
 where
  hooks state store facts = memoryHooks rollingWatcher store facts Nothing state
  mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)

increments :: Assertion
increments = do
  requests <- newIORef []
  calls <- newIORef (0 :: Int)
  store <- newMemoryThreadStore
  facts <- newMemoryFactStore
  states <- newMemoryState
  exercise (memoryHooks (spy requests calls) store facts Nothing states)
  seen <- readIORef requests
  verify seen
 where
  input = sampleInput []
  first = [ChatUser "first"]
  second = first <> [ChatAssistant (AssistantTurn "m1" (Just "answer") Nothing []), ChatUser "second"]
  exercise hooks =
    (transformContext hooks input first >>= (@?= first))
      *> (transformContext hooks input second >>= (@?= second))
  spy requests calls =
    fakeModel $ \request emit ->
      modifyIORef' requests (bodies request :)
        *> atomicModifyIORef' calls (\count -> (count + 1, count + 1))
        >>= \count -> emit (ModelTextDelta ("memo-" <> Text.pack (show count))) $> Stop
  bodies = Text.intercalate "\n" . fmap userTextOf . requestMessages
  userTextOf (ChatUser text) = text
  userTextOf _ = ""
  verify captured =
    case reverse captured of
      [one, two] ->
        sequence_
          [ assertBool "first watch sees the first message" (Text.isInfixOf "first" one),
            assertBool "second watch sees only the increment" (Text.isInfixOf "second" two),
            assertBool "second watch skips seen messages" (not (Text.isInfixOf "first" two)),
            assertBool "second watch carries the previous summary" (Text.isInfixOf "memo-1" two)
          ]
      other -> assertFailure ("unexpected watcher calls: " <> show (length other))

episodeOnDisk :: Assertion
episodeOnDisk = do
  tmp <- getTemporaryDirectory
  identifier <- newId
  store <- newThreadStore (tmp ++ "/" ++ Text.unpack identifier)
  facts <- newMemoryFactStore
  states <- newMemoryState
  base <- testRuntime mainModel [] Parallel
  events <- collectEvents base {runtimeHooks = memoryHooks watcher store facts Nothing states} (sampleInput [])
  brief <- threadBrief store "thread"
  case brief of
    Just (ThreadBrief "rolling: greeted" [Episode "run" "rolling: greeted" _]) ->
      eventType (last events) @?= "RUN_FINISHED"
    other -> assertFailure ("unexpected thread brief: " <> show other)
 where
  watcher = fakeModel (\_ emit -> emit (ModelTextDelta "rolling: greeted") $> Stop)
  mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi there") $> Stop)

failureIsolation :: Assertion
failureIsolation = do
  store <- newMemoryThreadStore
  facts <- newMemoryFactStore
  states <- newMemoryState
  seen <- newIORef []
  base <- testRuntime (capture seen) [] Parallel
  events <- collectEvents base {runtimeHooks = memoryHooks broken store facts Nothing states} (sampleInput [])
  requests <- readIORef seen
  stored <- threadBrief store "thread"
  eventType (last events) @?= "RUN_FINISHED"
  requests @?= [[ChatUser "hello"]]
  stored @?= Nothing
 where
  broken = fakeModel (\_ _ -> throwIO (ProviderFailure "watcher down"))
  capture seen =
    fakeModel $ \request emit ->
      modifyIORef' seen (requestMessages request :) *> emit (ModelTextDelta "fine") $> Stop

composition :: Assertion
composition = do
  store <- newMemoryThreadStore
  facts <- newMemoryFactStore
  states <- newMemoryState
  called <- newIORef False
  base <- testRuntime mainModel [] Parallel
  _ <-
    collectEvents
      base {runtimeHooks = memoryHooks watcher store facts Nothing states <> business called}
      (sampleInput [])
  wasCalled <- readIORef called
  stored <- threadBrief store "thread"
  wasCalled @?= True
  assertBool "memory afterRun stored an episode" (maybe False (not . null . briefEpisodes) stored)
 where
  watcher = fakeModel (\_ emit -> emit (ModelTextDelta "memo") $> Stop)
  mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)
  business called = defaultHooks {afterRun = \_ _ -> writeIORef called True}
