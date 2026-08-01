module Yuki.N.FactsTest
  ( factsTests,
    memorizeDedup,
    retrievalSlot,
    badJsonSilent,
    budgetCapped,
    cooldownThrottles,
    fileRoundTrip,
    retrievalReplay,
    archiveStale,
    invalidateByContent,
    watcherInvalidates,
    legacyLine,
    invalidateReplay,
  )
where

import Data.Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>))
import Data.IORef
import Data.Text qualified as Text
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Agent
import Yuki.N.Facts
import Yuki.N.Journal
import Yuki.N.Memory
import Yuki.N.Model
import Yuki.N.Replay
import Yuki.N.TestSupport

factsTests :: TestTree
factsTests =
  testGroup
    "facts"
    [ testCase "memorizes watcher facts, drops malformed entries and dedupes by content" memorizeDedup,
      testCase "materializes a retrieval slot after the briefing and touches hits" retrievalSlot,
      testCase "stays inert on an unparseable watcher decision" badJsonSilent,
      testCase "caps retrievals at three per run" budgetCapped,
      testCase "cools a repeated query down for five watcher rounds" cooldownThrottles,
      testCase "persists facts as jsonl across restarts" fileRoundTrip,
      testCase "replays a journaled run with a retrieval slot without divergence" retrievalReplay,
      testCase "archives old untouched facts, hiding them from search but not the list" archiveStale,
      testCase "invalidates a fact by content and reports a miss" invalidateByContent,
      testCase "voids a fact named by a watcher invalidate decision" watcherInvalidates,
      testCase "parses fact lines written before archived and void existed" legacyLine,
      testCase "replays a journaled run with an invalidate decision without divergence" invalidateReplay
    ]
slotMarked :: ChatMessage -> Bool
slotMarked (ChatSystem text) = candidatesMarker `Text.isInfixOf` text
slotMarked _ = False
invalidateWatcher :: Model
invalidateWatcher =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          "{\"summary\":\"s\",\"memorize\":[],\"retrieve\":null,\"invalidate\":[\
          \{\"content\":\"the deploy target is fly.io\",\"reason\":\"moved to railway\"},\
          \{\"content\":42}]}"
      )
      $> Stop

memorizeDedup :: Assertion
memorizeDedup = do
  facts <- newMemoryFactStore
  threads <- newMemoryThreadStore
  state <- newMemoryState
  _ <- transformContext (memoryHooks memorizeWatcher threads facts Nothing state) (sampleInput []) [ChatUser "hi"]
  listed <- factList facts
  case listed of
    [fact] -> do
      factContent fact @?= "uses ghcup for the toolchain"
      factKind fact @?= FactProject
      factSource fact @?= "run"
      factId fact @?= factIdFor "uses ghcup for the toolchain"
    other -> assertFailure ("unexpected facts: " <> show (length other))
 where
  memorizeWatcher =
    fakeModel $ \_ emit ->
      emit
        ( ModelTextDelta
            "{\"summary\":\"s\",\"memorize\":[\
            \{\"content\":\"uses ghcup for the toolchain\",\"kind\":\"project\",\"reason\":\"setup\"},\
            \{\"content\":\"uses ghcup for the toolchain\",\"kind\":\"project\",\"reason\":\"setup\"},\
            \{\"content\":\"bogus entry\",\"kind\":\"nonsense\",\"reason\":\"bad\"}],\
            \\"retrieve\":null}"
        )
        $> Stop

retrievalSlot :: Assertion
retrievalSlot = do
  facts <- newMemoryFactStore
  _ <- factAdd facts "the deploy target is fly.io" FactProject "run-0"
  threads <- newMemoryThreadStore
  threadSaveEpisode threads "thread" (Episode "run-0" "earlier" 1700000000)
  state <- newMemoryState
  once <- transformContext (memoryHooks retrieveWatcher threads facts Nothing state) (sampleInput []) [ChatUser "hi"]
  twice <- transformContext (memoryHooks retrieveWatcher threads facts Nothing state) (sampleInput []) once
  verify facts once twice
 where
  verify facts once twice =
    case once of
      [ChatSystem brief, ChatSystem slot, ChatUser "hi"] ->
        sequence_
          [ assertBool "briefing stays at the head" (briefingMarker `Text.isInfixOf` brief),
            assertBool "slot follows the briefing" (candidatesMarker `Text.isInfixOf` slot),
            assertBool "slot carries kind and content" (Text.isInfixOf "- project: the deploy target is fly.io" slot),
            twice @?= once
          ]
          *> touched facts
      other -> assertFailure ("unexpected context: " <> show (length other) <> " messages")
  touched facts =
    factList facts >>= \case
      [fact] ->
        sequence_
          [ factUseCount fact @?= 1,
            assertBool "lastUsed updated" (factLastUsed fact > 0)
          ]
      other -> assertFailure ("unexpected facts: " <> show (length other))

badJsonSilent :: Assertion
badJsonSilent = do
  facts <- newMemoryFactStore
  threads <- newMemoryThreadStore
  state <- newMemoryState
  messages <- transformContext (memoryHooks broken threads facts Nothing state) (sampleInput []) [ChatUser "hi"]
  stored <- factList facts
  messages @?= [ChatUser "hi"]
  stored @?= []
 where
  broken = fakeModel (\_ emit -> emit (ModelTextDelta "{\"summary\": broken") $> Stop)

budgetCapped :: Assertion
budgetCapped = do
  facts <- newMemoryFactStore
  searches <- newIORef (0 :: Int)
  calls <- newIORef (0 :: Int)
  threads <- newMemoryThreadStore
  state <- newMemoryState
  let hooks = memoryHooks (rotatingWatcher calls) threads (spySearch searches facts) Nothing state
  traverse_ (transformContext hooks (sampleInput [])) (stagesFor 4)
  searchCount <- readIORef searches
  searchCount @?= 3

cooldownThrottles :: Assertion
cooldownThrottles = do
  facts <- newMemoryFactStore
  searches <- newIORef (0 :: Int)
  threads <- newMemoryThreadStore
  state <- newMemoryState
  let hooks = memoryHooks retrieveWatcher threads (spySearch searches facts) Nothing state
  traverse_ (transformContext hooks (sampleInput [])) (stagesFor 7)
  searchCount <- readIORef searches
  searchCount @?= 2

rotatingWatcher :: IORef Int -> Model
rotatingWatcher counter =
  fakeModel $ \_ emit ->
    atomicModifyIORef' counter (\count -> (count + 1, count + 1))
      >>= \count ->
        emit
          ( ModelTextDelta
              ( "{\"summary\":\"s\",\"memorize\":[],\"retrieve\":{\"query\":\"q-"
                  <> Text.pack (show count)
                  <> "\",\"reason\":\"r\"}}"
              )
          )
          $> Stop
spySearch :: IORef Int -> FactStore -> FactStore
spySearch counter store =
  store {factSearch = \query -> modifyIORef' counter (+ 1) *> factSearch store query}
stagesFor :: Int -> [[ChatMessage]]
stagesFor rounds = [take amount dialog | amount <- take rounds [1, 3 ..]]
 where
  dialog =
    concatMap
      (\index -> [ChatUser ("u-" <> Text.pack (show index)), assistantReply])
      [(1 :: Int) ..]
assistantReply :: ChatMessage
assistantReply = ChatAssistant (AssistantTurn "m" (Just "ok") Nothing [])

fileRoundTrip :: Assertion
fileRoundTrip = do
  tmp <- getTemporaryDirectory
  identifier <- newId
  let dir = tmp ++ "/" ++ Text.unpack identifier
  store <- newFactStore dir
  fact <- factAdd store "prefers point-free style" FactPreference "run-1"
  _ <- factAdd store "prefers point-free style" FactPreference "run-1"
  factTouch store [fact]
  reloaded <- newFactStore dir
  verify reloaded
 where
  verify reloaded =
    factList reloaded >>= \case
      [fact] ->
        sequence_
          [ factId fact @?= factIdFor "prefers point-free style",
            factUseCount fact @?= 1,
            assertBool "lastUsed persisted" (factLastUsed fact > 0)
          ]
      other -> assertFailure ("unexpected facts: " <> show (length other))

retrievalReplay :: Assertion
retrievalReplay = do
  facts <- newMemoryFactStore
  _ <- factAdd facts "the deploy target is fly.io" FactProject "run-0"
  threads <- newMemoryThreadStore
  (journal, readEntries) <- newMemoryJournal
  state <- newMemoryState
  base <- testRuntime mainModel [] Parallel
  events <- collectEvents base {runtimeHooks = hooks facts threads journal state, runtimeJournal = Just journal} (sampleInput [])
  recorded <- readEntries
  report <- replayWithStores threads facts Nothing recorded
  fmap reportDivergence report @?= Right Nothing
  fmap reportEvents report @?= Right (length events)
  assertBool "journaled request carries the retrieval slot" (any slotted recorded)
 where
  hooks facts threads journal = memoryHooks retrieveWatcher threads facts (Just journal)
  mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)
  slotted (Entry _ _ _ (ModelRequestEntry request)) = any slotMarked (requestMessages request)
  slotted _ = False

archiveStale :: Assertion
archiveStale = do
  tmp <- getTemporaryDirectory
  identifier <- newId
  let dir = tmp ++ "/" ++ Text.unpack identifier
  createDirectoryIfMissing True dir
  LazyByteString.writeFile (dir ++ "/facts.jsonl") seed
  store <- newFactStore dir
  exercise dir store
 where
  seed = LazyByteString.intercalate "\n" (fmap encode specimens) <> "\n"
  specimens =
    [ Fact (factIdFor "legacy deploy target") "legacy deploy target" FactProject "run-0" 1000 0 0 False False,
      Fact (factIdFor "touched old detail") "touched old detail" FactProject "run-0" 1000 100 3 False False,
      Fact (factIdFor "fresh detail") "fresh detail" FactProject "run-0" 2000 0 0 False False
    ]
  exercise dir store = do
    count <- factArchiveOlderThan store 1500
    hits <- factSearch store "legacy deploy"
    survivors <- factSearch store "fresh"
    listed <- factList store
    reloaded <- newFactStore dir
    persisted <- factList reloaded
    count @?= 1
    hits @?= []
    length survivors @?= 1
    fmap factArchived listed @?= [False, True, False]
    fmap factArchived persisted @?= [False, True, False]

invalidateByContent :: Assertion
invalidateByContent = do
  facts <- newMemoryFactStore
  _ <- factAdd facts "the deploy target is fly.io" FactProject "run-0"
  hit <- factInvalidate facts "the deploy target is fly.io"
  miss <- factInvalidate facts "no such fact"
  hits <- factSearch facts "deploy target"
  listed <- factList facts
  hit @?= True
  miss @?= False
  hits @?= []
  fmap factVoid listed @?= [True]

watcherInvalidates :: Assertion
watcherInvalidates = do
  facts <- newMemoryFactStore
  _ <- factAdd facts "the deploy target is fly.io" FactProject "run-0"
  threads <- newMemoryThreadStore
  state <- newMemoryState
  _ <- transformContext (memoryHooks invalidateWatcher threads facts Nothing state) (sampleInput []) [ChatUser "hi"]
  listed <- factList facts
  hits <- factSearch facts "deploy target"
  fmap factVoid listed @?= [True]
  hits @?= []

legacyLine :: Assertion
legacyLine =
  either assertFailure verify $
    eitherDecode
      "{\"id\":\"fact-x\",\"content\":\"old line\",\"kind\":\"user\",\"source\":\"run\",\"created\":1,\"lastUsed\":2,\"useCount\":3}"
 where
  verify fact =
    sequence_
      [ factArchived fact @?= False,
        factVoid fact @?= False,
        factUseCount fact @?= 3
      ]

invalidateReplay :: Assertion
invalidateReplay = do
  facts <- newMemoryFactStore
  _ <- factAdd facts "the deploy target is fly.io" FactProject "run-0"
  threads <- newMemoryThreadStore
  (journal, readEntries) <- newMemoryJournal
  state <- newMemoryState
  base <- testRuntime mainModel [] Parallel
  events <- collectEvents base {runtimeHooks = hooks facts threads journal state, runtimeJournal = Just journal} (sampleInput [])
  recorded <- readEntries
  report <- replayWithStores threads facts Nothing recorded
  fmap reportDivergence report @?= Right Nothing
  fmap reportEvents report @?= Right (length events)
 where
  hooks facts threads journal = memoryHooks invalidateWatcher threads facts (Just journal)
  mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)
