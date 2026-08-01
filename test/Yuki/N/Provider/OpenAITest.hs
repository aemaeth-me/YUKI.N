-- | OpenAI provider 流式解码测试
--
-- 覆盖：SSE 分帧/多行合并、chunk→ModelEvent 映射、finish reason、错误块、wire 选项与 DeepSeek Responses 方言渲染。
-- 边界：不覆盖真实网络（见 E2E）；全部使用确定性内存数据。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.Provider.OpenAITest
  ( providerTests,
    fragmented,
    multiline,
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

import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Exception ()
import Control.Monad ()
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseMaybe)
import Data.Bool ()
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Foldable ()
import Data.Functor ()
import Data.IORef ()
import Data.List (nub, sort)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS ()
import Network.HTTP.Types ()
import Network.Wai ()
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test ()
import System.Directory ()
import System.Exit ()
import System.FilePath ()
import System.Process ()
import System.Timeout ()
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
    [ testCase "decodes fragmented CRLF SSE frames" fragmented,
      testCase "joins multiline SSE data fields" multiline,
      testCase "maps chunk deltas to model events" chunkDeltas,
      testCase "parses finish reasons" chunkFinish,
      testCase "rejects provider error chunks" chunkErrorRejected,
      testCase "requests usage on the wire" wireOptions,
      testCase "serializes provider-specific thinking controls" thinkingWire,
      testCase "serializes DeepSeek Responses input and tools" responsesWire,
      testCase "attaches usage from the final frame" usageFrame,
      testProperty "any chunking of an SSE stream decodes to the same payloads" sseChunkingEquivalence
    ]

-- | 规格：SSE 解码器把跨多个二进制块拆分的 CRLF 帧合并为完整 payload。
-- 背景：真实 HTTP 流不会按帧边界切块；解码器若依赖单块完整帧，任何网络缓冲都会丢事件。该用例失败代表流式解码在真实分块下不可用。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
fragmented :: Assertion
fragmented =
  let (first, firstEvents) = feedSse emptySseDecoder "data: {\"value\":"
      (second, secondEvents) = feedSse first "1}\r\n\r\n"
      (_, finalEvents) = finishSse second
   in sequence_ [firstEvents @?= [], secondEvents <> finalEvents @?= ["{\"value\":1}"]]

-- | 规格：SSE 多行 data 字段按换行连接为单个 payload。
-- 背景：模型输出经代理转发时常以多行 data 形式出现；连接语义错位会污染对话内容。该用例失败代表 payload 重组错误。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
multiline :: Assertion
multiline =
  let (decoder, events) = feedSse emptySseDecoder "data: one\ndata: two\n\n"
      (_, finalEvents) = finishSse decoder
   in events <> finalEvents @?= ["one\ntwo"]

-- | 规格：Chat 分块把增量映射为归一化 ModelEvent（reasoning/text/tool call）。
-- 背景：增量归一化是上游进入 agent 事件管线的唯一入口；映射错误会让推理、文本与工具调用交错或丢失。该用例失败代表事件流形状违约。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
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

-- | 规格：finish_reason=tool_calls 的块解析为 ToolUse 终止原因。
-- 背景：agent 循环靠该标记决定是否进入工具执行分支；解析失败会把工具回合误判为回答结束。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
chunkFinish :: Assertion
chunkFinish =
  chunkEvents (ChatChunk [ChatChoice 0 emptyDelta' (Just "tool_calls")] Nothing Nothing)
    @?= Right ([], Just ToolUse)

-- | 规格：携带 error 消息的块被拒绝为 Left，而不是被当作普通增量。
-- 背景：provider 错误块混在增量流中时若被静默吞掉，用户会看到假成功；显式失败才能驱动重试/降级。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
chunkErrorRejected :: Assertion
chunkErrorRejected =
  assertLeft (chunkEvents (ChatChunk [] (Just (object ["message" .= ("boom" :: Text)])) Nothing))

-- | 规格：请求体携带 stream_options.include_usage 以在最终帧附加用量。
-- 背景：用量统计依赖该开关；缺失会让 token 计费与上下文预算失去数据源。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
wireOptions :: Assertion
wireOptions =
  ( parseMaybe (withObject "wire" (.: "stream_options")) rendered
      >>= parseMaybe (withObject "options" (.: "include_usage"))
  )
    @?= Just True
 where
  rendered = requestValue testProvider (ModelRequest [] [])

-- | 规格：各 provider 方言的思考控制序列化到 wire（deepseek reasoning_effort、zai thinking、kimi reasoning_content 回填）。
-- 背景：思考控制是各家 API 的关键差异点；串错字段会被 provider 静默忽略或 400 拒绝，导致推理能力配置失效。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
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

-- | 规格：DeepSeek Responses 方言把历史与工具规整为 input/tools 数组而非 messages。
-- 背景：Responses 协议不接受 messages 字段；渲染错误会直接 400，工具与思考回填也会丢失。该用例失败代表 DeepSeek 方言断线。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
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

-- | 规格：最终帧的 usage 字段被解析并作为 ModelUsage 事件上抛。
-- 背景：计费与预算闭环依赖最终帧用量；解析失败会让每次调用都报告零 token。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
usageFrame :: Assertion
usageFrame =
  either assertFailure assertEvents (eitherDecodeStrict' frame)
 where
  frame =
    "{\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"prompt_cache_hit_tokens\":3,\"prompt_cache_miss_tokens\":7}}"
  assertEvents chunk =
    chunkEvents chunk @?= Right ([ModelUsage (Usage (Just 10) (Just 5) (Just 3) (Just 7))], Nothing)

-- | 规格：任意 payload 序列经任意字节切分喂给 feedSse，产出的 payload 与整块喂入完全一致。
-- 背景：真实 HTTP 流不会按帧边界切块；等价性是解码器对分块鲁棒性的最直接契约。
-- 变更记录：- 2026-08-01: 补充 SSE 分块等价性的属性覆盖。
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
  frameBytes payloads =
    ByteString.concat ["data: " <> payload <> "\r\n\r\n" | payload <- payloads]

genPayloads :: Gen [ByteString]
genPayloads =
  listOf genPayload `suchThat` ((<= 5) . length)
 where
  genPayload =
    suchThat
      (ByteString.pack . fmap (fromIntegral . fromEnum) <$> listOf (elements ['a' .. 'z']))
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
