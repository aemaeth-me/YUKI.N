module Yuki.N.AGUI.Event
  ( EncryptedEntity (..),
    Event (..),
    eventType,
  )
where

import Data.Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Yuki.N.AGUI.Types (Message, pair)

data Event
  = RunStarted Text Text (Maybe Text)
  | RunFinished Text Text (Maybe Value)
  | RunError Text (Maybe Text)
  | StepStarted Text
  | StepFinished Text
  | TextMessageStarted Text
  | TextMessageContent Text Text
  | TextMessageEnded Text
  | ToolCallStarted Text Text (Maybe Text)
  | ToolCallArguments Text Text
  | ToolCallEnded Text
  | ToolCallResult Text Text Text
  | StateSnapshot Value
  | StateDelta [Value]
  | MessagesSnapshot [Message]
  | ActivitySnapshot Text Text Value (Maybe Bool)
  | ActivityDelta Text Text [Value]
  | ReasoningStarted Text
  | ReasoningMessageStarted Text
  | ReasoningMessageContent Text Text
  | ReasoningMessageEnded Text
  | ReasoningEnded Text
  | ReasoningEncryptedValue EncryptedEntity Text Text
  | Raw Value (Maybe Text)
  | Custom Text Value
  deriving stock (Eq, Show)

data EncryptedEntity
  = EncryptedToolCall
  | EncryptedMessage
  deriving stock (Eq, Show)

eventType :: Event -> Text
eventType = \case
  RunStarted {} -> "RUN_STARTED"
  RunFinished {} -> "RUN_FINISHED"
  RunError {} -> "RUN_ERROR"
  StepStarted {} -> "STEP_STARTED"
  StepFinished {} -> "STEP_FINISHED"
  TextMessageStarted {} -> "TEXT_MESSAGE_START"
  TextMessageContent {} -> "TEXT_MESSAGE_CONTENT"
  TextMessageEnded {} -> "TEXT_MESSAGE_END"
  ToolCallStarted {} -> "TOOL_CALL_START"
  ToolCallArguments {} -> "TOOL_CALL_ARGS"
  ToolCallEnded {} -> "TOOL_CALL_END"
  ToolCallResult {} -> "TOOL_CALL_RESULT"
  StateSnapshot {} -> "STATE_SNAPSHOT"
  StateDelta {} -> "STATE_DELTA"
  MessagesSnapshot {} -> "MESSAGES_SNAPSHOT"
  ActivitySnapshot {} -> "ACTIVITY_SNAPSHOT"
  ActivityDelta {} -> "ACTIVITY_DELTA"
  ReasoningStarted {} -> "REASONING_START"
  ReasoningMessageStarted {} -> "REASONING_MESSAGE_START"
  ReasoningMessageContent {} -> "REASONING_MESSAGE_CONTENT"
  ReasoningMessageEnded {} -> "REASONING_MESSAGE_END"
  ReasoningEnded {} -> "REASONING_END"
  ReasoningEncryptedValue {} -> "REASONING_ENCRYPTED_VALUE"
  Raw {} -> "RAW"
  Custom {} -> "CUSTOM"

instance ToJSON Event where
  toJSON event =
    object $ ["type" .= eventType event] <> fields event
   where
    fields = \case
      RunStarted thread run parent ->
        ["threadId" .= thread, "runId" .= run] <> pair "parentRunId" parent
      RunFinished thread run result ->
        ["threadId" .= thread, "runId" .= run] <> pair "result" result
      RunError message code ->
        ["message" .= message] <> pair "code" code
      StepStarted name -> ["stepName" .= name]
      StepFinished name -> ["stepName" .= name]
      TextMessageStarted message -> ["messageId" .= message, "role" .= ("assistant" :: Text)]
      TextMessageContent message delta -> ["messageId" .= message, "delta" .= delta]
      TextMessageEnded message -> ["messageId" .= message]
      ToolCallStarted call name parent ->
        ["toolCallId" .= call, "toolCallName" .= name] <> pair "parentMessageId" parent
      ToolCallArguments call delta -> ["toolCallId" .= call, "delta" .= delta]
      ToolCallEnded call -> ["toolCallId" .= call]
      ToolCallResult message call content ->
        [ "messageId" .= message,
          "toolCallId" .= call,
          "content" .= content,
          "role" .= ("tool" :: Text)
        ]
      StateSnapshot snapshot -> ["snapshot" .= snapshot]
      StateDelta delta -> ["delta" .= delta]
      MessagesSnapshot messages -> ["messages" .= messages]
      ActivitySnapshot message activity content replace ->
        [ "messageId" .= message,
          "activityType" .= activity,
          "content" .= content
        ]
          <> pair "replace" replace
      ActivityDelta message activity patch ->
        ["messageId" .= message, "activityType" .= activity, "patch" .= patch]
      ReasoningStarted message -> ["messageId" .= message]
      ReasoningMessageStarted message ->
        ["messageId" .= message, "role" .= ("reasoning" :: Text)]
      ReasoningMessageContent message delta -> ["messageId" .= message, "delta" .= delta]
      ReasoningMessageEnded message -> ["messageId" .= message]
      ReasoningEnded message -> ["messageId" .= message]
      ReasoningEncryptedValue subtype entity value ->
        [ "subtype" .= encryptedEntity subtype,
          "entityId" .= entity,
          "encryptedValue" .= value
        ]
      Raw raw source -> ["event" .= raw] <> pair "source" source
      Custom name value -> ["name" .= name, "value" .= value]

encryptedEntity :: EncryptedEntity -> Text
encryptedEntity = \case
  EncryptedToolCall -> "tool-call"
  EncryptedMessage -> "message"

instance FromJSON Event where
  parseJSON = withObject "Event" $ \fields ->
    fields .: "type" >>= \case
      "RUN_STARTED" ->
        RunStarted <$> fields .: "threadId" <*> fields .: "runId" <*> fields .:? "parentRunId"
      "RUN_FINISHED" ->
        RunFinished <$> fields .: "threadId" <*> fields .: "runId" <*> fields .:? "result"
      "RUN_ERROR" -> RunError <$> fields .: "message" <*> fields .:? "code"
      "STEP_STARTED" -> StepStarted <$> fields .: "stepName"
      "STEP_FINISHED" -> StepFinished <$> fields .: "stepName"
      "TEXT_MESSAGE_START" -> TextMessageStarted <$> fields .: "messageId"
      "TEXT_MESSAGE_CONTENT" -> TextMessageContent <$> fields .: "messageId" <*> fields .: "delta"
      "TEXT_MESSAGE_END" -> TextMessageEnded <$> fields .: "messageId"
      "TOOL_CALL_START" ->
        ToolCallStarted <$> fields .: "toolCallId" <*> fields .: "toolCallName" <*> fields .:? "parentMessageId"
      "TOOL_CALL_ARGS" -> ToolCallArguments <$> fields .: "toolCallId" <*> fields .: "delta"
      "TOOL_CALL_END" -> ToolCallEnded <$> fields .: "toolCallId"
      "TOOL_CALL_RESULT" ->
        ToolCallResult <$> fields .: "messageId" <*> fields .: "toolCallId" <*> fields .: "content"
      "STATE_SNAPSHOT" -> StateSnapshot <$> fields .: "snapshot"
      "STATE_DELTA" -> StateDelta <$> fields .: "delta"
      "MESSAGES_SNAPSHOT" -> MessagesSnapshot <$> fields .: "messages"
      "ACTIVITY_SNAPSHOT" ->
        ActivitySnapshot
          <$> fields .: "messageId"
          <*> fields .: "activityType"
          <*> fields .: "content"
          <*> fields .:? "replace"
      "ACTIVITY_DELTA" ->
        ActivityDelta <$> fields .: "messageId" <*> fields .: "activityType" <*> fields .: "patch"
      "REASONING_START" -> ReasoningStarted <$> fields .: "messageId"
      "REASONING_MESSAGE_START" -> ReasoningMessageStarted <$> fields .: "messageId"
      "REASONING_MESSAGE_CONTENT" ->
        ReasoningMessageContent <$> fields .: "messageId" <*> fields .: "delta"
      "REASONING_MESSAGE_END" -> ReasoningMessageEnded <$> fields .: "messageId"
      "REASONING_END" -> ReasoningEnded <$> fields .: "messageId"
      "REASONING_ENCRYPTED_VALUE" ->
        ReasoningEncryptedValue
          <$> (fields .: "subtype" >>= parseEntity)
          <*> fields .: "entityId"
          <*> fields .: "encryptedValue"
      "RAW" -> Raw <$> fields .: "event" <*> fields .:? "source"
      "CUSTOM" -> Custom <$> fields .: "name" <*> fields .: "value"
      other -> fail ("unknown AG-UI event type: " <> other)
   where
    parseEntity = \case
      ("tool-call" :: Text) -> pure EncryptedToolCall
      "message" -> pure EncryptedMessage
      other -> fail ("unknown encrypted entity: " <> Text.unpack other)
