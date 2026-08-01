-- | AG-UI 协议边界测试
--
-- 覆盖：AG-UI 输入别名解析、TOOL_CALL_RESULT 事件编码，以及全部公开事件构造器的
-- JSON 契约（type 字段 + decode . encode round-trip）与受控生成器属性。
-- 边界：只覆盖协议层纯函数；不涉及 agent 运行时。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
--   - 2026-08-01: 补充全部公开事件构造器 JSON 契约与 round-trip 属性的回归覆盖。
module Yuki.N.AGUITest
  ( protocolTests,
    eventJsonTests,
    aliases,
    normalizedToolResultEvent,
    eventJsonContract,
    eventJsonRoundTrip,
  )
where

import Data.Aeson (Value (..), eitherDecode, encode, object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Test.QuickCheck
  ( Gen,
    Property,
    elements,
    forAll,
    frequency,
    listOf,
    oneof,
    suchThat,
    (===),
  )
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck (testProperty)
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
  ( ActivityMessage (..),
    AssistantMessage (..),
    Message (..),
    ReasoningMessage (..),
    RunAgentInput (..),
    SystemMessage (..),
    ToolMessage (..),
    UserContent (..),
    UserMessage (..),
  )

protocolTests :: TestTree
protocolTests =
  testGroup
    "AG-UI protocol"
    [ testCase "accepts snake_case aliases at the boundary" aliases,
      testCase "encodes normalized tool-result events" normalizedToolResultEvent
    ]

eventJsonTests :: TestTree
eventJsonTests =
  testGroup
    "AG-UI event JSON contract"
    [ testCase "all public constructors round-trip with a stable type field" eventJsonContract,
      testProperty "decode . encode == Right for generated events" eventJsonRoundTrip
    ]

-- | 规格：AG-UI 边界接受 snake_case 别名并保持 JSON round-trip 等价。
-- 背景：HTTP 客户（前端、脚本）与 AG-UI 规范通常混用 snake_case 与 camelCase；边界若拒绝别名，既有调用方会整体失效。该用例失败代表协议解析层收缩，而非测试环境问题。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
aliases :: Assertion
aliases =
  either assertFailure verify . eitherDecode $
    "{\"thread_id\":\"thread\",\"run_id\":\"run\",\"messages\":[{\"id\":\"user\",\"role\":\"user\",\"content\":\"hello\"}]}"

verify :: RunAgentInput -> Assertion
verify input =
  sequence_
    [ runThreadId input @?= "thread",
      runId input @?= "run",
      runMessages input @?= [User (UserMessage "user" (UserText "hello") Nothing)]
    ]

-- | 规格：TOOL_CALL_RESULT 事件按规范化字段（type/messageId/toolCallId/content/role）编码。
-- 背景：前端依赖该事件的固定 JSON 形状渲染工具结果；字段漂移会造成前端静默丢失结果。该用例失败代表事件编码契约被破坏。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
normalizedToolResultEvent :: Assertion
normalizedToolResultEvent =
  toJSON (ToolCallResult "message" "call" "ok")
    @?= object
      [ "type" .= ("TOOL_CALL_RESULT" :: Text),
        "messageId" .= ("message" :: Text),
        "toolCallId" .= ("call" :: Text),
        "content" .= ("ok" :: Text),
        "role" .= ("tool" :: Text)
      ]

-- | 规格：全部 26 个公开事件构造器的 JSON 携带稳定 type 字段且 decode . encode 恒等。
-- 背景：事件流是前端与审计的唯一通道；任一构造器的字段漂移都会造成消费端静默丢失。
-- 变更记录：- 2026-08-01: 补充事件 JSON 契约表驱动覆盖。
eventJsonContract :: Assertion
eventJsonContract =
  sequence_ [assertRoundTrip event expectedType | (event, expectedType) <- contractRows]

assertRoundTrip :: Event -> Text -> Assertion
assertRoundTrip event expectedType =
  sequence_
    [ typeOf event @?= Just expectedType,
      either assertFailure (@?= event) (eitherDecode (encode event))
    ]

typeOf :: Event -> Maybe Text
typeOf = parseMaybe (withObject "event" (.: "type")) . toJSON

contractRows :: [(Event, Text)]
contractRows =
  [ (RunStarted "t" "r" Nothing, "RUN_STARTED"),
    (RunStarted "t" "r" (Just "parent"), "RUN_STARTED"),
    (RunFinished "t" "r" Nothing, "RUN_FINISHED"),
    (RunFinished "t" "r" (Just (object ["value" .= (1 :: Int)])), "RUN_FINISHED"),
    (RunError "boom" Nothing, "RUN_ERROR"),
    (RunError "boom" (Just "code"), "RUN_ERROR"),
    (StepStarted "step", "STEP_STARTED"),
    (StepFinished "step", "STEP_FINISHED"),
    (TextMessageStarted "m", "TEXT_MESSAGE_START"),
    (TextMessageContent "m" "delta", "TEXT_MESSAGE_CONTENT"),
    (TextMessageEnded "m", "TEXT_MESSAGE_END"),
    (ToolCallStarted "c" "fn" Nothing, "TOOL_CALL_START"),
    (ToolCallStarted "c" "fn" (Just "parent"), "TOOL_CALL_START"),
    (ToolCallArguments "c" "{\"x\":", "TOOL_CALL_ARGS"),
    (ToolCallEnded "c", "TOOL_CALL_END"),
    (ToolCallResult "m" "c" "content", "TOOL_CALL_RESULT"),
    (StateSnapshot (object ["a" .= (1 :: Int)]), "STATE_SNAPSHOT"),
    (StateDelta [object ["a" .= (1 :: Int)], object ["b" .= (2 :: Int)]], "STATE_DELTA"),
    (MessagesSnapshot [sampleAssistant, sampleUser], "MESSAGES_SNAPSHOT"),
    (ActivitySnapshot "m" "run.status" (object ["status" .= ("running" :: Text)]) Nothing, "ACTIVITY_SNAPSHOT"),
    (ActivitySnapshot "m" "run.status" (object ["status" .= ("done" :: Text)]) (Just True), "ACTIVITY_SNAPSHOT"),
    (ActivityDelta "m" "run.patch" [object ["op" .= ("replace" :: Text)]], "ACTIVITY_DELTA"),
    (ReasoningStarted "m", "REASONING_START"),
    (ReasoningMessageStarted "m", "REASONING_MESSAGE_START"),
    (ReasoningMessageContent "m" "thought", "REASONING_MESSAGE_CONTENT"),
    (ReasoningMessageEnded "m", "REASONING_MESSAGE_END"),
    (ReasoningEnded "m", "REASONING_END"),
    (ReasoningEncryptedValue EncryptedToolCall "e" "cipher", "REASONING_ENCRYPTED_VALUE"),
    (ReasoningEncryptedValue EncryptedMessage "e" "cipher", "REASONING_ENCRYPTED_VALUE"),
    (Raw (object ["raw" .= (1 :: Int)]) Nothing, "RAW"),
    (Raw (object ["raw" .= (1 :: Int)]) (Just "ws"), "RAW"),
    (Custom "context.status" (object ["tokens" .= (3 :: Int)]), "CUSTOM")
  ]

sampleAssistant :: Message
sampleAssistant = Assistant (AssistantMessage "a" (Just "answer") Nothing [])

sampleUser :: Message
sampleUser = User (UserMessage "u" (UserText "hello") Nothing)

-- | 规格：受控生成器产生的任意事件 decode . encode == Right（与表驱动用例互补）。
-- 背景：表驱动覆盖固定样本，属性覆盖构造器组合的任意取值，防止可选字段回归。
-- 变更记录：- 2026-08-01: 补充事件 JSON round-trip 属性覆盖。
eventJsonRoundTrip :: Property
eventJsonRoundTrip =
  forAll genEvent $ \event ->
    eitherDecode (encode event) === Right (event :: Event)

-- | 受控事件生成器：所有构造器按频率混合，文本与 JSON 取值受限以防失控。
genEvent :: Gen Event
genEvent =
  frequency
    [ (3, RunStarted <$> genText <*> genText <*> genMaybeText),
      (2, RunFinished <$> genText <*> genText <*> genMaybeValue),
      (2, RunError <$> genText <*> genMaybeText),
      (2, StepStarted <$> genText),
      (2, StepFinished <$> genText),
      (2, TextMessageStarted <$> genText),
      (3, TextMessageContent <$> genText <*> genText),
      (2, TextMessageEnded <$> genText),
      (2, ToolCallStarted <$> genText <*> genText <*> genMaybeText),
      (3, ToolCallArguments <$> genText <*> genText),
      (2, ToolCallEnded <$> genText),
      (3, ToolCallResult <$> genText <*> genText <*> genText),
      (2, StateSnapshot <$> genValue),
      (2, StateDelta <$> genValues),
      (1, MessagesSnapshot <$> genMessages),
      (2, ActivitySnapshot <$> genText <*> genText <*> genValue <*> genMaybeBool),
      (2, ActivityDelta <$> genText <*> genText <*> genValues),
      (2, ReasoningStarted <$> genText),
      (2, ReasoningMessageStarted <$> genText),
      (3, ReasoningMessageContent <$> genText <*> genText),
      (2, ReasoningMessageEnded <$> genText),
      (2, ReasoningEnded <$> genText),
      (2, ReasoningEncryptedValue <$> genEntity <*> genText <*> genText),
      (2, Raw <$> genValue <*> genMaybeText),
      (2, Custom <$> genText <*> genValue)
    ]
 where
  genValues = listOf genValue `suchThat` ((<= 3) . length)
  genMessages = listOf genMessage `suchThat` ((<= 3) . length)
  genMaybeText = oneof [pure Nothing, Just <$> genText]
  genMaybeBool = oneof [pure Nothing, Just <$> elements [False, True]]
  -- 注意：aeson 的 .:? 把 JSON null 视为缺失，Just Null 无法 round-trip，故不生成。
  genMaybeValue = oneof [pure Nothing, pure (Just (String "v")), pure (Just (Bool True)), pure (Just (Number 1)), pure (Just (object ["k" .= ("v" :: Text)]))]
  genEntity = elements [EncryptedToolCall, EncryptedMessage]

genText :: Gen Text
genText =
  suchThat
    (Text.pack <$> listOf (elements ['a' .. 'c']))
    ((<= 6) . Text.length)

genValue :: Gen Value
genValue =
  elements
    [ Null,
      Bool True,
      Number 1,
      String "v",
      object ["k" .= ("v" :: Text)],
      toJSON [1 :: Int, 2]
    ]

genMessage :: Gen Message
genMessage =
  elements
    [ Assistant (AssistantMessage "a" (Just "t") Nothing []),
      User (UserMessage "u" (UserText "hi") Nothing),
      System (SystemMessage "s" "sys" Nothing),
      Tool (ToolMessage "t" "content" "call" Nothing Nothing),
      Activity (ActivityMessage "act" "run.status" (object ["status" .= ("ok" :: Text)])),
      Reasoning (ReasoningMessage "r" "thought" Nothing)
    ]
