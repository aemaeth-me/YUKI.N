module Yuki.N.ContextTest
  ( spliceTests,
    countsChars,
    keepsRecent,
    targetGuards,
    inertWithoutStore,
    inertBelowThreshold,
    stubsAgedOnce,
    spliceConfigParse,
    contextTests,
    contextTokenEstimate,
    compactsDialogue,
    compactionUserAnchor,
    keepsToolCausality,
    contextArtifact,
    contextOverflowRetry,
    toolAfterCompaction,
    estimateAppendMonotonic,
    estimateMessageFloor,
    estimateTextPositive,
  )
where

import Control.Exception (throwIO)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Functor (($>))
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Test.QuickCheck
  ( Gen,
    Property,
    elements,
    forAll,
    listOf,
    suchThat,
  )
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck (testProperty)
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Artifact
import Yuki.N.Config
import Yuki.N.Context
import Yuki.N.Model
import Yuki.N.TestSupport
import Yuki.N.Transcript

spliceTests :: TestTree
spliceTests =
  testGroup
    "context splice"
    [ testCase "counts characters across message kinds" countsChars,
      testCase "targets only results older than the most recent keep" keepsRecent,
      testCase "skips stubs and small results when targeting" targetGuards,
      testCase "leaves history verbatim without an artifact store" inertWithoutStore,
      testCase "leaves history verbatim below the character threshold" inertBelowThreshold,
      testCase "stubs aged results once each, keeps originals fetchable and reports savings" stubsAgedOnce,
      testCase "splice env vars default, accept valid and reject invalid" spliceConfigParse
    ]
bigA, bigB, bigC, bigD :: Text
bigA = Text.replicate 30 "alpha-0123"
bigB = Text.replicate 30 "beta-98765"
bigC = Text.replicate 30 "gamma-0123"
bigD = Text.replicate 30 "delta-9876"

countsChars :: Assertion
countsChars =
  historyChars
    [ ChatSystem (Text.replicate 4 "s"),
      ChatUser (Text.replicate 8 "u"),
      ChatAssistant
        ( AssistantTurn
            "m"
            (Just (Text.replicate 4 "b"))
            (Just (Text.replicate 4 "r"))
            [ModelToolCall "c" "echo" (Text.replicate 8 "a")]
        ),
      ChatToolResult "c" (Text.replicate 16 "t")
    ]
    @?= 4 + 8 + 4 + 4 + 8 + 16

keepsRecent :: Assertion
keepsRecent =
  spliceTargets 2 history @?= [(1, "c-1", bigA), (2, "c-2", bigB)]
 where
  history =
    [ ChatUser "u",
      ChatToolResult "c-1" bigA,
      ChatToolResult "c-2" bigB,
      ChatToolResult "c-3" bigC,
      ChatToolResult "c-4" bigD
    ]

targetGuards :: Assertion
targetGuards =
  spliceTargets 0 history @?= [(2, "c-3", bigA)]
 where
  history =
    [ ChatToolResult "c-1" (artifactStub (artifactIdFor bigB) "big" bigB),
      ChatToolResult "c-2" "tiny",
      ChatToolResult "c-3" bigA
    ]

agedModel :: IORef Int -> IORef [ChatMessage] -> Model
agedModel turns captured =
  fakeModel $ \modelRequest emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next))
      >>= turn modelRequest emit
 where
  turn _ emit 1 = emit (ModelToolCallDelta 0 (Just "call-a") (Just "biga") "{}") $> ToolUse
  turn _ emit 2 = emit (ModelToolCallDelta 0 (Just "call-b") (Just "bigb") "{}") $> ToolUse
  turn _ emit 3 = emit (ModelToolCallDelta 0 (Just "call-c") (Just "bigc") "{}") $> ToolUse
  turn modelRequest emit 4 =
    writeIORef captured (requestMessages modelRequest) *> emit (ModelTextDelta "done") $> Stop
  turn _ _ _ = throwIO (ProviderFailure "unexpected model turn")
agedFixture :: Maybe ArtifactStore -> Maybe SpliceConfig -> (Runtime -> IO Runtime) -> IO ([Event], [ChatMessage])
agedFixture store splice configure = do
  turns <- newIORef (0 :: Int)
  captured <- newIORef []
  base <-
    testRuntime (agedModel turns captured) [staticTool "biga" bigA, staticTool "bigb" bigB, staticTool "bigc" bigC] Sequential
  runtime <- configure base {runtimeArtifactStore = store, runtimeSplice = splice}
  events <- collectEvents runtime (sampleInput [])
  (,) events <$> readIORef captured
spliceEvents :: [Event] -> [Value]
spliceEvents events = [value | Custom "context.splice" value <- events]

inertWithoutStore :: Assertion
inertWithoutStore =
  agedFixture Nothing (Just (SpliceConfig 400 1)) pure >>= \(events, messages) ->
    sequence_
      [ [content | ChatToolResult _ content <- messages] @?= [bigA, bigB, bigC],
        spliceEvents events @?= []
      ]

inertBelowThreshold :: Assertion
inertBelowThreshold = do
  store <- newMemoryArtifactStore
  (events, messages) <- agedFixture (Just store) (Just (SpliceConfig 200000 1)) pure
  [content | ChatToolResult _ content <- messages] @?= [bigA, bigB, bigC]
  spliceEvents events @?= []

stubsAgedOnce :: Assertion
stubsAgedOnce = do
  store <- newMemoryArtifactStore
  (events, messages) <- agedFixture (Just store) (Just (SpliceConfig 400 1)) pure
  case [content | ChatToolResult _ content <- messages] of
    [aged, middle, recent] -> do
      aged @?= stubA
      middle @?= stubB
      recent @?= bigC
      assertBool "a stub is never re-stubbed" (Text.isInfixOf "tool=biga" aged)
      artifactFetch store (artifactIdFor bigA) >>= (@?= Just bigA)
      artifactFetch store (artifactIdFor bigB) >>= (@?= Just bigB)
      verifyEvents events
    other -> assertFailure ("unexpected tool results: " <> show (length other))
 where
  stubA = artifactStub (artifactIdFor bigA) "biga" bigA
  stubB = artifactStub (artifactIdFor bigB) "bigb" bigB
  verifyEvents events =
    case spliceEvents events of
      [first, second] ->
        sequence_
          [ parseMaybe (withObject "splice" (.: "stubbed")) first @?= Just (1 :: Int),
            parseMaybe (withObject "splice" (.: "savedChars")) first @?= Just (Text.length bigA - Text.length stubA),
            parseMaybe (withObject "splice" (.: "keep")) first @?= Just (1 :: Int),
            parseMaybe (withObject "splice" (.: "stubbed")) second @?= Just (1 :: Int),
            parseMaybe (withObject "splice" (.: "savedChars")) second @?= Just (Text.length bigB - Text.length stubB)
          ]
      other -> assertFailure ("expected two context.splice events, got " <> show (length other))

spliceConfigParse :: Assertion
spliceConfigParse =
  sequence_
    [ spliceOf [] >>= (@?= (200000, 4)),
      spliceOf [("YUKI_SPLICE_CHARS", "5000"), ("YUKI_SPLICE_KEEP", "0")] >>= (@?= (5000, 0)),
      spliceOf [("YUKI_SPLICE_CHARS", "100"), ("YUKI_SPLICE_KEEP", "12")] >>= (@?= (100, 12)),
      rejected ("YUKI_SPLICE_CHARS", "0"),
      rejected ("YUKI_SPLICE_CHARS", "many"),
      rejected ("YUKI_SPLICE_KEEP", "-1"),
      rejected ("YUKI_SPLICE_KEEP", "few")
    ]
 where
  spliceOf extra =
    either
      (assertFailure . Text.unpack)
      (pure . ((,) <$> settingsSpliceChars <*> settingsSpliceKeep))
      (resolveSettings (env extra))
  env extra = Map.fromList (("DEEPSEEK_API_KEY", "secret") : extra)
  rejected (key, value) =
    either
      (const (pure ()))
      (const (assertFailure (key ++ "=" ++ value ++ " should be rejected")))
      (resolveSettings (env [(key, value)]))

contextTests :: TestTree
contextTests =
  testGroup
    "context governance"
    [ testCase "estimates ASCII and CJK tokens conservatively" contextTokenEstimate,
      testCase "compacts old dialogue within the model budget" compactsDialogue,
      testCase "anchors an assistant-only suffix with the latest user request" compactionUserAnchor,
      testCase "keeps a tool call and result as one causal unit" keepsToolCausality,
      testCase "keeps the full dropped payload addressable as an artifact" contextArtifact,
      testCase "recognizes overflow and retries once with an emergency compaction" contextOverflowRetry,
      testCase "continues calling tools after compacting an oversized result" toolAfterCompaction,
      testProperty "appending a message never lowers the estimate" estimateAppendMonotonic,
      testProperty "message estimates respect the per-message floor" estimateMessageFloor,
      testProperty "text estimates are always positive" estimateTextPositive
    ]

contextTokenEstimate :: Assertion
contextTokenEstimate =
  sequence_
    [ estimateTextTokens "abc" @?= 1,
      estimateTextTokens "abcdef" @?= 2,
      estimateTextTokens "你好a" @?= 3,
      assertBool "overflow code recognized" (isContextOverflow (ProviderFailure "HTTP 400 context_length_exceeded")),
      assertBool "ordinary failure is not overflow" (not (isContextOverflow (ProviderFailure "connection reset")))
    ]

estimateAppendMonotonic :: Property
estimateAppendMonotonic =
  forAll genMessages $ \messages ->
    forAll genMessage $ \extra ->
      estimateMessagesTokens (messages <> [extra]) >= estimateMessagesTokens messages + 4

estimateMessageFloor :: Property
estimateMessageFloor =
  forAll genMessages $ \messages ->
    estimateMessagesTokens messages >= 4 * length messages

estimateTextPositive :: Property
estimateTextPositive =
  forAll genText $ \text ->
    estimateTextTokens text >= 1

-- | 受控消息生成器：混合各消息类型，序列长度受限以防拖慢属性测试。
genMessages :: Gen [ChatMessage]
genMessages =
  listOf genMessage `suchThat` ((<= 6) . length)

genMessage :: Gen ChatMessage
genMessage =
  elements
    [ ChatSystem "system",
      ChatUser "你好",
      ChatUser "hello world",
      ChatAssistant (AssistantTurn "m" (Just "text") Nothing []),
      ChatAssistant (AssistantTurn "m" Nothing (Just "reasoning") []),
      ChatAssistant (AssistantTurn "m" Nothing Nothing [ModelToolCall "c" "tool" "{\"k\":1}"]),
      ChatToolResult "c" "result"
    ]

genText :: Gen Text
genText =
  suchThat
    (Text.pack <$> listOf (elements ['a' .. 'z']))
    ((<= 12) . Text.length)

compactsDialogue :: Assertion
compactsDialogue =
  requireCompaction (compactMessages contextConfig (Just 512) [] contextConversation) $ \compaction ->
    let compacted = compactionMessages compaction
     in sequence_
          [ assertBool "old dialogue was dropped" (not (null (compactionDropped compaction))),
            assertBool "users are summarized" (any isUser (compactionDropped compaction)),
            assertBool "assistants are summarized" (any isAssistant (compactionDropped compaction)),
            take 1 compacted @?= [ChatSystem "local rules"],
            assertBool "summary is present" (any isContextSummary compacted),
            assertBool "latest assistant remains" (any latestAssistant compacted),
            assertBool "request fits its model budget" (estimateMessagesTokens compacted <= compactionBudgetTokens compaction)
          ]
 where
  isUser ChatUser {} = True
  isUser _ = False
  isAssistant ChatAssistant {} = True
  isAssistant _ = False
  latestAssistant (ChatAssistant turn) = turnMessageId turn == "message-12"
  latestAssistant _ = False

compactionUserAnchor :: Assertion
compactionUserAnchor =
  requireCompaction (compactToBudget contextConfig {contextKeepUnits = 1} 256 history) $ \compaction ->
    case dropWhile systemMessage (compactionMessages compaction) of
      ChatUser anchor : ChatAssistant {} : _ ->
        sequence_
          [ assertBool "anchor keeps the latest user intent" ("send this request" `Text.isInfixOf` anchor),
            assertBool "anchored request remains within budget" (compactionAfterTokens compaction <= compactionBudgetTokens compaction)
          ]
      suffix -> assertFailure ("expected user/assistant suffix, got " <> show suffix)
 where
  history =
    [ ChatSystem "local rules",
      ChatUser ("send this request " <> Text.replicate 300 "u"),
      ChatAssistant (AssistantTurn "latest" (Just (Text.replicate 600 "a")) Nothing [])
    ]
  systemMessage ChatSystem {} = True
  systemMessage _ = False

keepsToolCausality :: Assertion
keepsToolCausality =
  requireCompaction (compactMessages contextConfig {contextKeepUnits = 1} (Just 512) [] history) $ \compaction ->
    sequence_
      [ assertBool "call/result pair survives together" (causalPair "call-big" "big" (compactionMessages compaction)),
        assertBool "oversized result is clipped to budget" (estimateMessagesTokens (compactionMessages compaction) <= compactionBudgetTokens compaction)
      ]
 where
  history =
    contextConversation
      <> [ ChatAssistant (AssistantTurn "tool-message" Nothing Nothing [ModelToolCall "call-big" "big" "{}"]),
           ChatToolResult "call-big" (Text.replicate 1200 "result")
         ]

contextArtifact :: Assertion
contextArtifact =
  requireCompaction (compactMessages contextConfig (Just 512) [] contextConversation) $ \initial ->
    let attached = attachCompactionArtifact "artifact-123" initial
     in sequence_
          [ assertBool "summary points to full payload" (Text.isInfixOf "artifact artifact-123" (compactionSummary attached)),
            assertBool "artifact attachment stays in budget" (compactionAfterTokens attached <= compactionBudgetTokens attached),
            assertBool "full payload is not reduced to the summary" (Text.length (compactionPayload attached) > Text.length (compactionSummary attached))
          ]

contextOverflowRetry :: Assertion
contextOverflowRetry = do
  calls <- newIORef (0 :: Int)
  requests <- newIORef []
  base <- testRuntime (overflowContextModel calls requests) [] Sequential
  events <-
    collectEvents
      base
        { runtimeContext = Just contextConfig,
          runtimeProviderRetries = 3,
          runtimeSystemPrompt = "local rules"
        }
      (conversationInput (take 10 (drop 1 contextConversation)))
  seen <- readIORef requests
  verifyOverflow seen events

verifyOverflow :: [ModelRequest] -> [Event] -> Assertion
verifyOverflow [first, second] events =
  sequence_
    [ assertBool "first request is above emergency budget" (estimateMessagesTokens (requestMessages first) > 256),
      assertBool "retry request is emergency-sized" (estimateMessagesTokens (requestMessages second) <= 256),
      length (contextCompactEvents events) @?= 1,
      assertBool "compaction is marked emergency" (all emergencyEvent (contextCompactEvents events)),
      assertBool "overflow bypasses ordinary backoff" (not (any providerRetry events))
    ]
verifyOverflow seen _ = assertFailure ("expected two model requests, got " <> show (length seen))
overflowContextModel :: IORef Int -> IORef [ModelRequest] -> Model
overflowContextModel calls requests =
  Model "fake" "overflow-once" (Just 512) stream (const (object []))
 where
  stream request emit =
    modifyIORef' requests (<> [request])
      *> atomicModifyIORef' calls (\count -> let next = count + 1 in (next, next))
      >>= \case
        1 -> throwIO (ProviderFailure "context_length_exceeded")
        _ -> emit (ModelTextDelta "recovered") $> Stop

toolAfterCompaction :: Assertion
toolAfterCompaction = do
  turns <- newIORef (0 :: Int)
  second <- newIORef []
  third <- newIORef []
  base <-
    testRuntime
      (compactingToolModel turns second third)
      [staticTool "big" (Text.replicate 1200 "result"), staticTool "echo" "ok"]
      Sequential
  events <- collectEvents base {runtimeContext = Just contextConfig} (sampleInput [])
  afterBig <- readIORef second
  afterEcho <- readIORef third
  assertBool "oversized tool pair stays causal" (causalPair "call-big" "big" afterBig)
  assertBool "first compaction leaves a summary" (any isContextSummary afterBig)
  assertBool "a later tool call also stays causal" (causalPair "call-echo" "echo" afterEcho)
  assertBool "tool execution completed after compaction" (any echoResult events)
  assertBool "oversized result triggered compaction" (not (null (contextCompactEvents events)))
 where
  echoResult (ToolCallResult _ "call-echo" "ok") = True
  echoResult _ = False

compactingToolModel :: IORef Int -> IORef [ChatMessage] -> IORef [ChatMessage] -> Model
compactingToolModel turns second third =
  Model "fake" "tool-after-compaction" (Just 512) stream (const (object []))
 where
  stream request emit =
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next)) >>= turn request emit
  turn _ emit 1 = emit (ModelToolCallDelta 0 (Just "call-big") (Just "big") "{}") $> ToolUse
  turn request emit 2 =
    writeIORef second (requestMessages request)
      *> emit (ModelToolCallDelta 0 (Just "call-echo") (Just "echo") "{}")
      $> ToolUse
  turn request emit 3 = writeIORef third (requestMessages request) *> emit (ModelTextDelta "done") $> Stop
  turn _ _ _ = throwIO (ProviderFailure "unexpected model turn")
conversationInput :: [ChatMessage] -> RunAgentInput
conversationInput messages = (sampleInput []) {runMessages = toAguiMessages messages}
contextCompactEvents :: [Event] -> [Value]
contextCompactEvents events = [value | Custom "context.compact" value <- events]
emergencyEvent :: Value -> Bool
emergencyEvent = fromMaybe False . parseMaybe (withObject "context.compact" (.: "emergency"))
providerRetry :: Event -> Bool
providerRetry (Custom "provider.retry" _) = True
providerRetry _ = False
causalPair :: Text -> Text -> [ChatMessage] -> Bool
causalPair callId name messages = any paired (zip messages (drop 1 messages))
 where
  paired (ChatAssistant turn, ChatToolResult resultId _) =
    resultId == callId && any (\call -> modelToolCallId call == callId && modelToolName call == name) (turnToolCalls turn)
  paired _ = False
requireCompaction :: Maybe Compaction -> (Compaction -> Assertion) -> Assertion
requireCompaction planned verify = maybe (assertFailure "expected context compaction") verify planned
