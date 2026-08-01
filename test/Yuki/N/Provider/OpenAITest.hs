module Yuki.N.Provider.OpenAITest
  ( providerTests,
    chunkDeltas,
    chunkFinish,
    chunkErrorRejected,
    wireOptions,
    thinkingWire,
    responsesWire,
    usageFrame,
    sseChunkingEquivalence,
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List (nub, sort)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Test.QuickCheck
  ( Gen,
    Property,
    chooseInt,
    elements,
    forAll,
    listOf,
    suchThat,
    (.&&.),
    (===),
  )
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck (testProperty)
import Yuki.N.AGUI.Types
import Yuki.N.Model
import Yuki.N.Provider.OpenAI
import Yuki.N.TestSupport

providerTests :: TestTree
providerTests =
  testGroup
    "provider stream"
    [ testCase "maps chunk deltas to model events" chunkDeltas,
      testCase "parses finish reasons" chunkFinish,
      testCase "rejects provider error chunks" chunkErrorRejected,
      testCase "requests usage on the wire" wireOptions,
      testCase "serializes provider-specific thinking controls" thinkingWire,
      testCase "serializes DeepSeek Responses input and tools" responsesWire,
      testCase "attaches usage from the final frame" usageFrame,
      testProperty "any chunking of an SSE stream decodes to the same payloads" sseChunkingEquivalence
    ]

chunkDeltas :: Assertion
chunkDeltas =
  chunkEvents
    ( ChatChunk
        [ ChatChoice
            0
            ( ChatDelta
                (Just "text")
                (Just "reasoning")
                [DeltaToolCall 1 (Just "call") (Just (DeltaFunction (Just "echo") (Just "a")))]
            )
            Nothing
        ]
        Nothing
        Nothing
    )
    @?= Right
      ( [ ModelReasoningDelta "reasoning",
          ModelTextDelta "text",
          ModelToolCallDelta 1 (Just "call") (Just "echo") "a"
        ],
        Nothing
      )

chunkFinish :: Assertion
chunkFinish =
  chunkEvents (ChatChunk [ChatChoice 0 emptyDelta' (Just "tool_calls")] Nothing Nothing)
    @?= Right ([], Just ToolUse)

chunkErrorRejected :: Assertion
chunkErrorRejected =
  assertLeft (chunkEvents (ChatChunk [] (Just (object ["message" .= ("boom" :: Text)])) Nothing))

wireOptions :: Assertion
wireOptions =
  ( parseMaybe (withObject "wire" (.: "stream_options")) rendered
      >>= parseMaybe (withObject "options" (.: "include_usage"))
  )
    @?= Just True
 where
  rendered = requestValue testProvider (ModelRequest [] [])

thinkingWire :: Assertion
thinkingWire =
  let deepseek = testProvider {openAIProvider = "deepseek", openAIDialect = DeepSeek, openAIThinking = ThinkingEnabled Max}
      zai = testProvider {openAIProvider = "zai", openAIThinking = ThinkingEnabled High}
      kimi = testProvider {openAIProvider = "kimi-coding", openAIThinking = ThinkingEnabled Low}
      history = ModelRequest [ChatAssistant (AssistantTurn "assistant" Nothing (Just "kept") [])] []
      field name = parseMaybe (withObject "request" (maybe (fail "missing") pure . KeyMap.lookup name))
      thinkingType = (>>= parseMaybe (withObject "thinking" (.: "type"))) . field "thinking"
      effort = (>>= parseMaybe (withText "effort" pure)) . field "reasoning_effort"
      responseEffort = (>>= parseMaybe (withObject "reasoning" (.: "effort"))) . field "reasoning"
      reasoning =
        field "messages" (requestValue kimi history)
          >>= parseMaybe parseJSON
          >>= listToMaybe
          >>= parseMaybe (withObject "message" (.: "reasoning_content"))
   in sequence_
        [ thinkingType (requestValue deepseek (ModelRequest [] [])) @?= Nothing,
          responseEffort (requestValue deepseek (ModelRequest [] [])) @?= Just ("max" :: Text),
          thinkingType (requestValue zai (ModelRequest [] [])) @?= Just ("enabled" :: Text),
          field "reasoning_effort" (requestValue zai (ModelRequest [] [])) @?= Nothing,
          field "thinking" (requestValue kimi (ModelRequest [] [])) @?= Nothing,
          effort (requestValue kimi (ModelRequest [] [])) @?= Just ("low" :: Text),
          reasoning @?= Just ("kept" :: Text)
        ]

responsesWire :: Assertion
responsesWire =
  let provider = testProvider {openAIProvider = "deepseek", openAIModelName = "deepseek-v4-flash", openAIDialect = DeepSeek}
      call = ModelToolCall "call-1" "lookup" "{\"query\":\"yuki\"}"
      turn = AssistantTurn "assistant-1" (Just "answer") (Just "thought") [call]
      toolSpec = ToolSpec "lookup" "Find something" (object ["type" .= ("object" :: Text)])
      rendered = requestValue provider (ModelRequest [ChatSystem "system", ChatUser "hello", ChatAssistant turn, ChatToolResult "call-1" "found"] [toolSpec])
      field name = parseMaybe (withObject "request" (maybe (fail "missing") pure . KeyMap.lookup name)) rendered
      input = parseMaybe (withObject "request" (.: "input")) rendered :: Maybe [Value]
      tools = parseMaybe (withObject "request" (.: "tools")) rendered :: Maybe [Value]
      inputTypes :: Maybe [Text]
      inputTypes = input >>= traverse (parseMaybe (withObject "item" (.: "type")))
      toolNames :: Maybe [Text]
      toolNames = tools >>= traverse (parseMaybe (withObject "tool" (.: "name")))
      callIds :: Maybe [Maybe Text]
      callIds = input >>= traverse (parseMaybe (withObject "item" (.:? "call_id")))
   in sequence_
        [ field "messages" @?= Nothing,
          field "stream_options" @?= Nothing,
          field "model" @?= Just (String "deepseek-v4-flash"),
          inputTypes @?= Just ["message", "message", "reasoning", "message", "function_call", "function_call_output"],
          toolNames @?= Just ["lookup"],
          fmap (Just "call-1" `elem`) callIds @?= Just True
        ]

usageFrame :: Assertion
usageFrame =
  either assertFailure assertEvents (eitherDecodeStrict' frame)
 where
  frame =
    "{\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"prompt_cache_hit_tokens\":3,\"prompt_cache_miss_tokens\":7}}"
  assertEvents chunk =
    chunkEvents chunk @?= Right ([ModelUsage (Usage (Just 10) (Just 5) (Just 3) (Just 7))], Nothing)

sseChunkingEquivalence :: Property
sseChunkingEquivalence =
  forAll genPayloads $ \payloads ->
    forAll (genChunks (frameBytes payloads)) $ \chunks ->
      let (decoder, chunkedEvents) = feedChunks chunks
          (_, chunkedFinal) = finishSse decoder
          (wholeDecoder, wholeEvents) = feedSse emptySseDecoder (frameBytes payloads)
          (_, wholeFinal) = finishSse wholeDecoder
       in (chunkedEvents <> chunkedFinal) === (wholeEvents <> wholeFinal)
            .&&. (chunkedEvents <> chunkedFinal) === payloads
 where
  feedChunks = foldl step (emptySseDecoder, [])
  step (decoder, acc) chunk =
    let (decoder', emitted) = feedSse decoder chunk
     in (decoder', acc <> emitted)
  -- 每个 payload 一行一个 data 字段（空 payload 也占一行），事件以 \r\n 空行结束，
  -- 同时覆盖多行 data 连接与 CRLF 剥离
  frameBytes payloads =
    ByteString.concat
      [ ByteString.concat (fmap (\line -> "data: " <> line <> "\n") (linesOf payload))
          <> "\r\n"
      | payload <- payloads
      ]
  linesOf payload
    | ByteString.null payload = [""]
    | otherwise = ByteString.split 10 payload

genPayloads :: Gen [ByteString]
genPayloads =
  listOf genPayload `suchThat` ((<= 5) . length)
 where
  -- '\n' 覆盖多行 data 字段的连接语义；任意字节切分覆盖帧边界与 CRLF 拆分
  genPayload =
    suchThat
      (ByteString.pack . fmap (fromIntegral . fromEnum) <$> listOf (elements (['a' .. 'z'] ++ ['\n'])))
      ((<= 12) . ByteString.length)

-- | 将给定字节流任意切分为若干块（可含空块被滤除），保证拼接后等于原流。
genChunks :: ByteString -> Gen [ByteString]
genChunks bytes = do
  cuts <- listOf (chooseInt (0, ByteString.length bytes))
  let sorted = nub (sort (0 : ByteString.length bytes : cuts))
      pieces =
        [ ByteString.take (b - a) (ByteString.drop a bytes)
        | (a, b) <- zip sorted (drop 1 sorted)
        ]
  pure (filter (not . ByteString.null) pieces)

emptyDelta' :: ChatDelta
emptyDelta' = ChatDelta Nothing Nothing []
