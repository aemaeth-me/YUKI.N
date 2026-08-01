module Yuki.N.AgentTest
  ( agentTests,
    reasoningEvents,
    parallelTools,
    frontendTools,
    turnLimitError,
    unexpectedError,
    runError,
    retryTests,
    retryRecovers,
    retryExhausted,
    retryAfterDelta,
    retryReplay,
    fallbackTests,
    fallbackSucceeds,
    fallbackRetries,
    fallbackChainExhausted,
    fallbackEmptyChain,
    fallbackReplay,
    fallbackConfigParse,
    fallbackConfigRender,
    hooksTests,
    identity,
    ordering,
    denial,
    chaining,
    machineTests,
    textLifecycle,
    reasoningThenText,
    lateReasoning,
    toolLifecycle,
    incompleteTool,
    usageClose,
    noUsage,
  )
where

import Control.Concurrent.MVar
import Control.Exception (throwIO)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (parseMaybe)
import Data.Bifunctor (second)
import Data.Bool (bool)
import Data.Functor (($>))
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.Agent
import Yuki.N.Config
import Yuki.N.Journal
import Yuki.N.Model
import Yuki.N.Replay
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig

agentTests :: TestTree
agentTests =
  testGroup
    "agent"
    [ testCase "streams reasoning and text through normalized AG-UI events" reasoningEvents,
      testCase "executes backend tools concurrently and continues the model loop" parallelTools,
      testCase "hands client tools back without another model call" frontendTools,
      testCase "classifies the local model-turn guard distinctly" turnLimitError,
      testCase "surfaces an unexpected synchronous exception with its detail" unexpectedError,
      testCase "emits RUN_ERROR without a following RUN_FINISHED" runError
    ]

reasoningEvents :: Assertion
reasoningEvents =
  testRuntime model [] Parallel >>= collect >>= (@?= expected)
 where
  model =
    fakeModel $ \_ emit ->
      emit (ModelReasoningDelta "brief reasoning") *> emit (ModelTextDelta "hello") $> Stop
  collect runtime = eventType <$$> collectEvents runtime (sampleInput [])
  expected =
    [ "RUN_STARTED",
      "STEP_STARTED",
      "REASONING_START",
      "REASONING_MESSAGE_START",
      "REASONING_MESSAGE_CONTENT",
      "REASONING_MESSAGE_END",
      "REASONING_END",
      "TEXT_MESSAGE_START",
      "TEXT_MESSAGE_CONTENT",
      "TEXT_MESSAGE_END",
      "STEP_FINISHED",
      "RUN_FINISHED"
    ]

parallelTools :: Assertion
parallelTools =
  fixture >>= exercise
 where
  fixture =
    (,,,)
      <$> newIORef (0 :: Int)
      <*> newIORef []
      <*> newEmptyMVar
      <*> newEmptyMVar
  exercise (turns, secondRequest, leftStarted, rightStarted) =
    testRuntime
      (parallelModel turns secondRequest)
      [ barrier "left" leftStarted rightStarted "left-result",
        barrier "right" rightStarted leftStarted "right-result"
      ]
      Parallel
      >>= run secondRequest
  run secondRequest runtime =
    timeout 5000000 (collectEvents runtime (sampleInput []))
      >>= maybe
        (assertFailure "parallel tool execution deadlocked")
        (verifyParallel secondRequest)

parallelModel :: IORef Int -> IORef [ChatMessage] -> Model
parallelModel turns secondRequest =
  fakeModel $ \modelRequest emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next))
      >>= turn modelRequest emit
 where
  turn _ emit 1 =
    emit (ModelToolCallDelta 0 (Just "call-a") (Just "left") "{}")
      *> emit (ModelToolCallDelta 1 (Just "call-b") (Just "right") "{}")
      $> ToolUse
  turn modelRequest emit 2 =
    writeIORef secondRequest (requestMessages modelRequest) *> emit (ModelTextDelta "done") $> Stop
  turn _ _ _ = throwIO (ProviderFailure "unexpected model turn")
barrier :: Text -> MVar () -> MVar () -> Text -> BackendTool
barrier name own other content =
  BackendTool
    (tool name)
    (\_ _ -> (putMVar own () *> readMVar other) $> ToolOutcome content False False)
verifyParallel :: IORef [ChatMessage] -> [Event] -> Assertion
verifyParallel secondRequest events =
  sequence_
    [ length (filter ((== "TOOL_CALL_RESULT") . eventType) events) @?= 2,
      eventType <$> takeEnd 2 events @?= ["STEP_FINISHED", "RUN_FINISHED"]
    ]
    *> (readIORef secondRequest >>= verifyMessages)
 where
  verifyMessages messages =
    [call | ChatToolResult call _ <- messages] @?= ["call-a", "call-b"]

frontendTools :: Assertion
frontendTools = newIORef (0 :: Int) >>= prepare
 where
  prepare calls = testRuntime (frontendModel calls) [] Parallel >>= run calls
  run calls runtime =
    collectEvents runtime (sampleInput [tool "confirm"]) >>= verifyFrontend calls

frontendModel :: IORef Int -> Model
frontendModel calls =
  fakeModel $ \_ emit ->
    modifyIORef' calls (+ 1)
      *> emit (ModelToolCallDelta 0 (Just "frontend-call") (Just "confirm") "{\"ok\":true}")
      $> ToolUse
verifyFrontend :: IORef Int -> [Event] -> Assertion
verifyFrontend calls events =
  readIORef calls
    >>= \count ->
      sequence_
        [ count @?= 1,
          assertBool
            "frontend call must not produce a backend result"
            (all ((/= "TOOL_CALL_RESULT") . eventType) events),
          eventType (last events) @?= "RUN_FINISHED"
        ]

turnLimitError :: Assertion
turnLimitError = do
  base <- testRuntime looping [echoTool] Sequential
  events <- collectEvents base {runtimeMaxTurns = 1} (sampleInput [])
  case [(message, code) | RunError message code <- events] of
    [(message, code)] -> do
      code @?= Just "MAX_TURNS_EXCEEDED"
      assertBool "error identifies the configured local limit" ("1 model turns" `Text.isInfixOf` message)
      assertBool "error identifies the configuration key" ("YUKI_MAX_TURNS" `Text.isInfixOf` message)
    failures -> assertFailure ("expected one turn-limit error, got " <> show failures)
 where
  looping =
    fakeModel $ \_ emit ->
      emit (ModelToolCallDelta 0 (Just "call-echo") (Just "echo") "{}") $> ToolUse

unexpectedError :: Assertion
unexpectedError = do
  base <- testRuntime okModel [] Parallel
  let hooks = defaultHooks {transformContext = \_ _ -> ioError (userError "context transformer exploded")}
  events <- collectEvents base {runtimeHooks = hooks} (sampleInput [])
  case [(message, code) | RunError message code <- events] of
    [(message, code)] -> do
      code @?= Just "UNHANDLED_ERROR"
      assertBool "error retains the original exception detail" ("context transformer exploded" `Text.isInfixOf` message)
    failures -> assertFailure ("expected one unhandled error, got " <> show failures)

runError :: Assertion
runError = do
  runtime <-
    testRuntime
      (fakeModel (\_ _ -> throwIO (ProviderFailure "unavailable")))
      []
      Parallel
  eventTypes <- eventType <$$> collectEvents runtime (sampleInput [])
  eventTypes @?= ["RUN_STARTED", "STEP_STARTED", "RUN_ERROR"]

retryTests :: TestTree
retryTests =
  testGroup
    "provider retry"
    [ testCase "retries before the first delta and announces the attempt" retryRecovers,
      testCase "gives up at the attempt cap" retryExhausted,
      testCase "never retries after a delta was consumed" retryAfterDelta,
      testCase "replays a journaled run with provider.retry events without divergence" retryReplay
    ]
flakyModel :: Int -> IORef Int -> Model
flakyModel failures calls =
  fakeModel $ \_ emit ->
    atomicModifyIORef' calls (\count -> (count + 1, count + 1))
      >>= \call ->
        bool
          (emit (ModelTextDelta "recovered") $> Stop)
          (throwIO (ProviderFailure "upstream 429"))
          (call <= failures)
retryEvents :: [Event] -> [Value]
retryEvents events = [value | Custom "provider.retry" value <- events]

retryRecovers :: Assertion
retryRecovers = do
  calls <- newIORef (0 :: Int)
  base <- testRuntime (flakyModel 1 calls) [] Parallel
  events <- collectEvents base {runtimeProviderRetries = 3} (sampleInput [])
  attempts <- readIORef calls
  attempts @?= 2
  [delta | TextMessageContent _ delta <- events] @?= ["recovered"]
  eventType (last events) @?= "RUN_FINISHED"
  case retryEvents events of
    [value] -> do
      parseMaybe (withObject "retry" (.: "attempt")) value @?= Just (1 :: Int)
      parseMaybe (withObject "retry" (.: "maxAttempts")) value @?= Just (3 :: Int)
      parseMaybe (withObject "retry" (.: "delayMs")) value @?= Just (1000 :: Int)
      parseMaybe (withObject "retry" (.: "reason")) value @?= Just ("upstream 429" :: Text)
    other -> assertFailure ("expected one provider.retry, got " <> show (length other))

retryExhausted :: Assertion
retryExhausted = do
  calls <- newIORef (0 :: Int)
  base <- testRuntime (flakyModel 9 calls) [] Parallel
  events <- collectEvents base {runtimeProviderRetries = 2} (sampleInput [])
  attempts <- readIORef calls
  attempts @?= 2
  length (retryEvents events) @?= 1
  eventType (last events) @?= "RUN_ERROR"
  [code | RunError _ (Just code) <- events] @?= ["PROVIDER_ERROR"]

retryAfterDelta :: Assertion
retryAfterDelta = do
  base <- testRuntime midStreamFailure [] Parallel
  events <- collectEvents base {runtimeProviderRetries = 3} (sampleInput [])
  [delta | TextMessageContent _ delta <- events] @?= ["partial"]
  retryEvents events @?= []
  eventType (last events) @?= "RUN_ERROR"
 where
  midStreamFailure =
    fakeModel $ \_ emit ->
      emit (ModelTextDelta "partial") *> throwIO (ProviderFailure "connection reset")

retryReplay :: Assertion
retryReplay = do
  (journal, readEntries) <- newMemoryJournal
  calls <- newIORef (0 :: Int)
  base <- testRuntime (flakyModel 1 calls) [] Parallel
  events <- collectEvents base {runtimeJournal = Just journal, runtimeProviderRetries = 3} (sampleInput [])
  recorded <- readEntries
  report <- replayEntries defaultHooks Nothing recorded
  assertBool "journal records provider.retry" (any journaled recorded)
  fmap reportDivergence report @?= Right Nothing
  fmap reportEvents report @?= Right (length (filter (not . isRetry) events))
 where
  journaled (Entry _ _ _ (AgentEventEntry (Custom "provider.retry" _))) = True
  journaled _ = False
  isRetry (Custom "provider.retry" _) = True
  isRetry _ = False

fallbackTests :: TestTree
fallbackTests =
  testGroup
    "provider fallback"
    [ testCase "falls back after the primary exhausts its retries" fallbackSucceeds,
      testCase "gives each fallback its own retry budget" fallbackRetries,
      testCase "walks the chain and rethrows the last failure" fallbackChainExhausted,
      testCase "an empty chain keeps the single-provider behavior" fallbackEmptyChain,
      testCase "replays a journaled fallback run without divergence" fallbackReplay,
      testCase "fallback env var defaults, parses a list and rejects empty names" fallbackConfigParse,
      testCase "global config exposes the fallback roster" fallbackConfigRender
    ]
downModel :: IORef Int -> Text -> Text -> Text -> Model
downModel calls provider name reason =
  Model provider name Nothing (\_ _ -> modifyIORef' calls (+ 1) *> throwIO (ProviderFailure reason)) (const (object []))
answeringModel :: IORef Int -> Text -> Text -> Text -> Model
answeringModel calls provider name answer =
  Model provider name Nothing (\_ emit -> modifyIORef' calls (+ 1) *> emit (ModelTextDelta answer) $> Stop) (const (object []))
fallbackField :: Value -> Text -> Maybe Text
fallbackField value key = parseMaybe (withObject "fallback" (.: Key.fromText key)) value

fallbackSucceeds :: Assertion
fallbackSucceeds = do
  primaryCalls <- newIORef (0 :: Int)
  backupCalls <- newIORef (0 :: Int)
  base <- testRuntime (downModel primaryCalls "alpha" "a1" "alpha down") [] Parallel
  events <-
    collectEvents
      base
        { runtimeProviderRetries = 3,
          runtimeFallbacks = [answeringModel backupCalls "beta" "b1" "second wind"]
        }
      (sampleInput [])
  primary <- readIORef primaryCalls
  backup <- readIORef backupCalls
  (primary, backup) @?= (3, 1)
  [name | Custom name _ <- events] @?= ["provider.retry", "provider.retry", "provider.fallback"]
  case [value | Custom "provider.fallback" value <- events] of
    [value] -> do
      fallbackField value "from" @?= Just "alpha/a1"
      fallbackField value "to" @?= Just "beta/b1"
      fallbackField value "reason" @?= Just "alpha down"
    other -> assertFailure ("expected one provider.fallback, got " <> show (length other))
  [delta | TextMessageContent _ delta <- events] @?= ["second wind"]
  eventType (last events) @?= "RUN_FINISHED"

fallbackRetries :: Assertion
fallbackRetries = do
  primaryCalls <- newIORef (0 :: Int)
  backupCalls <- newIORef (0 :: Int)
  base <- testRuntime (downModel primaryCalls "alpha" "a1" "alpha down") [] Parallel
  events <-
    collectEvents
      base
        { runtimeProviderRetries = 2,
          runtimeFallbacks = [(flakyModel 1 backupCalls) {modelProvider = "beta", modelName = "b1"}]
        }
      (sampleInput [])
  primary <- readIORef primaryCalls
  backup <- readIORef backupCalls
  (primary, backup) @?= (2, 2)
  [name | Custom name _ <- events] @?= ["provider.retry", "provider.fallback", "provider.retry"]
  [delta | TextMessageContent _ delta <- events] @?= ["recovered"]
  eventType (last events) @?= "RUN_FINISHED"

fallbackChainExhausted :: Assertion
fallbackChainExhausted = do
  callsA <- newIORef (0 :: Int)
  callsB <- newIORef (0 :: Int)
  callsC <- newIORef (0 :: Int)
  base <- testRuntime (downModel callsA "alpha" "a1" "alpha down") [] Parallel
  events <-
    collectEvents
      base
        { runtimeProviderRetries = 1,
          runtimeFallbacks =
            [ downModel callsB "beta" "b1" "beta down",
              downModel callsC "gamma" "g1" "gamma down"
            ]
        }
      (sampleInput [])
  calls <- (,,) <$> readIORef callsA <*> readIORef callsB <*> readIORef callsC
  calls @?= (1, 1, 1)
  [name | Custom name _ <- events] @?= ["provider.fallback", "provider.fallback"]
  [to | Custom "provider.fallback" value <- events, Just to <- [fallbackField value "to"]]
    @?= ["beta/b1", "gamma/g1"]
  [message | RunError message _ <- events] @?= ["gamma down"]
  [code | RunError _ (Just code) <- events] @?= ["PROVIDER_ERROR"]

fallbackEmptyChain :: Assertion
fallbackEmptyChain = do
  calls <- newIORef (0 :: Int)
  base <- testRuntime (downModel calls "alpha" "a1" "alpha down") [] Parallel
  events <- collectEvents base {runtimeProviderRetries = 2} (sampleInput [])
  attempts <- readIORef calls
  attempts @?= 2
  [() | Custom "provider.fallback" _ <- events] @?= []
  eventType (last events) @?= "RUN_ERROR"
  [code | RunError _ (Just code) <- events] @?= ["PROVIDER_ERROR"]

fallbackReplay :: Assertion
fallbackReplay = do
  (journal, readEntries) <- newMemoryJournal
  calls <- newIORef (0 :: Int)
  base <- testRuntime (downModel calls "alpha" "a1" "alpha down") [] Parallel
  events <-
    collectEvents
      base
        { runtimeJournal = Just journal,
          runtimeProviderRetries = 2,
          runtimeFallbacks = [answeringModel calls "beta" "b1" "second wind"]
        }
      (sampleInput [])
  recorded <- readEntries
  report <- replayEntries defaultHooks Nothing recorded
  assertBool "journal records provider.fallback" (any journaled recorded)
  fmap reportDivergence report @?= Right Nothing
  fmap reportEvents report @?= Right (length (filter (not . transient) events))
 where
  journaled (Entry _ _ _ (AgentEventEntry (Custom "provider.fallback" _))) = True
  journaled _ = False
  transient (Custom "provider.retry" _) = True
  transient (Custom "provider.fallback" _) = True
  transient _ = False

fallbackConfigParse :: Assertion
fallbackConfigParse =
  sequence_
    [ fallbacksOf [] >>= (@?= []),
      fallbacksOf [("YUKI_FALLBACK_PROVIDERS", "zai,kimi-coding")] >>= (@?= ["zai", "kimi-coding"]),
      fallbacksOf [("YUKI_FALLBACK_PROVIDERS", " zai , kimi-coding ")] >>= (@?= ["zai", "kimi-coding"]),
      fallbacksOf [("YUKI_FALLBACK_PROVIDERS", "")] >>= (@?= []),
      rejected "zai,,kimi-coding",
      rejected ",",
      rejected "zai,"
    ]
 where
  fallbacksOf extra =
    either (assertFailure . Text.unpack) (pure . settingsFallbackProviders) (resolveSettings (env extra))
  env extra = Map.fromList (("DEEPSEEK_API_KEY", "secret") : extra)
  rejected value =
    either
      (const (pure ()))
      (const (assertFailure ("YUKI_FALLBACK_PROVIDERS=" <> value <> " should be rejected")))
      (resolveSettings (env [("YUKI_FALLBACK_PROVIDERS", value)]))

fallbackConfigRender :: Assertion
fallbackConfigRender =
  either (assertFailure . Text.unpack) pure (resolveSettings env) >>= \settings ->
    parseMaybe names (renderGlobalConfig settings (globalThreadConfig settings))
      @?= Just (["zai", "kimi-coding"] :: [Text])
 where
  env = Map.fromList [("DEEPSEEK_API_KEY", "secret"), ("YUKI_FALLBACK_PROVIDERS", "zai,kimi-coding")]
  names = withObject "config" $ \fields ->
    fields .: "settings" >>= withObject "settings" (.: "fallbackProviders")

hooksTests :: TestTree
hooksTests =
  testGroup
    "agent hooks"
    [ testCase "mempty is neutral" identity,
      testCase "steering appends in order" ordering,
      testCase "beforeToolCall stops at the first denial" denial,
      testCase "afterToolCall chains" chaining
    ]

identity :: Assertion
identity =
  (getSteeringMessages (steering "x") (sampleInput []) >>= (@?= [ChatSystem "x"]))
    *> (getSteeringMessages (steering "x") (sampleInput []) >>= (@?= [ChatSystem "x"]))

ordering :: Assertion
ordering =
  getSteeringMessages (steering "a" <> steering "b") (sampleInput [])
    >>= (@?= [ChatSystem "a", ChatSystem "b"])

denial :: Assertion
denial = do
  called <- newIORef False
  result <- beforeToolCall (deny <> spy called) someCall
  wasCalled <- readIORef called
  result @?= Left "no"
  wasCalled @?= False

chaining :: Assertion
chaining =
  afterToolCall (mark "a" <> mark "b") someCall (ToolOutcome "x" False False)
    >>= (@?= ToolOutcome "xab" False False)

steering :: Text -> AgentHooks
steering text = defaultHooks {getSteeringMessages = const (pure [ChatSystem text])}
deny :: AgentHooks
deny = defaultHooks {beforeToolCall = const (pure (Left "no"))}
spy :: IORef Bool -> AgentHooks
spy ref = defaultHooks {beforeToolCall = const (writeIORef ref True $> Right ())}
mark :: Text -> AgentHooks
mark suffix =
  defaultHooks
    { afterToolCall = \_ outcome ->
        pure outcome {toolOutcomeContent = toolOutcomeContent outcome <> suffix}
    }
someCall :: ModelToolCall
someCall = ModelToolCall "call" "echo" "{}"
machineTests :: TestTree
machineTests =
  testGroup
    "response machine"
    [ testCase "emits text lifecycle in order" textLifecycle,
      testCase "closes reasoning before text" reasoningThenText,
      testCase "rejects reasoning after final content" lateReasoning,
      testCase "announces a tool call once and completes it at close" toolLifecycle,
      testCase "rejects an incomplete tool call at close" incompleteTool,
      testCase "emits collected usage at close" usageClose,
      testCase "omits the usage event without usage" noUsage
    ]

textLifecycle :: Assertion
textLifecycle =
  ( steps [ModelTextDelta "hello"] >>= \(state, events) ->
      closeModelTurn "m" "r" state >>= \closed ->
        Right (events, closed)
  )
    @?= Right
      ( [TextMessageStarted "m", TextMessageContent "m" "hello"],
        ([TextMessageEnded "m"], AssistantTurn "m" (Just "hello") Nothing [])
      )

reasoningThenText :: Assertion
reasoningThenText =
  fmap snd (steps [ModelReasoningDelta "r1", ModelTextDelta "t"])
    @?= Right
      [ ReasoningStarted "r",
        ReasoningMessageStarted "r",
        ReasoningMessageContent "r" "r1",
        ReasoningMessageEnded "r",
        ReasoningEnded "r",
        TextMessageStarted "m",
        TextMessageContent "m" "t"
      ]

lateReasoning :: Assertion
lateReasoning =
  assertLeft (steps [ModelTextDelta "t", ModelReasoningDelta "x"])

toolLifecycle :: Assertion
toolLifecycle =
  ( steps
      [ ModelToolCallDelta 0 (Just "c") (Just "f") "{\"a\":",
        ModelToolCallDelta 0 Nothing Nothing "1}"
      ]
      >>= \(state, events) ->
        closeModelTurn "m" "r" state >>= \closed ->
          Right (events, closed)
  )
    @?= Right
      ( [ ToolCallStarted "c" "f" (Just "m"),
          ToolCallArguments "c" "{\"a\":",
          ToolCallArguments "c" "1}"
        ],
        ([ToolCallEnded "c"], AssistantTurn "m" Nothing Nothing [ModelToolCall "c" "f" "{\"a\":1}"])
      )

incompleteTool :: Assertion
incompleteTool =
  assertLeft (steps [ModelToolCallDelta 0 (Just "c") Nothing "{}"] >>= closeModelTurn "m" "r" . fst)

usageClose :: Assertion
usageClose =
  ( steps [ModelTextDelta "hi", ModelUsage (Usage (Just 10) (Just 5) (Just 3) (Just 7))]
      >>= \(state, events) ->
        closeModelTurn "m" "r" state >>= \closed ->
          Right (events, closed)
  )
    @?= Right
      ( [TextMessageStarted "m", TextMessageContent "m" "hi"],
        ( [ TextMessageEnded "m",
            Custom
              "usage"
              ( object
                  [ "promptTokens" .= (10 :: Int),
                    "completionTokens" .= (5 :: Int),
                    "cacheHitTokens" .= (3 :: Int),
                    "cacheMissTokens" .= (7 :: Int)
                  ]
              )
          ],
          AssistantTurn "m" (Just "hi") Nothing []
        )
      )

noUsage :: Assertion
noUsage =
  (steps [ModelTextDelta "hi"] >>= \(state, _) -> fst <$> closeModelTurn "m" "r" state)
    @?= Right [TextMessageEnded "m"]

steps :: [ModelEvent] -> Either ProviderFailure (ResponseState, [Event])
steps = foldl apply (Right (emptyResponse, []))
 where
  apply acc event =
    acc >>= \(state, events) ->
      second (events <>) <$> stepModelEvent "m" "r" state event
infixl 4 <$$>

(<$$>) :: (Functor outer, Functor inner) => (a -> b) -> outer (inner a) -> outer (inner b)
(<$$>) = fmap . fmap
