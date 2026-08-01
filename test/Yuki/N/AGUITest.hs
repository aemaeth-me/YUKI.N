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
