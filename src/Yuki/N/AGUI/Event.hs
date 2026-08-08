module Yuki.N.AGUI.Event (Event (..)) where

import Data.Aeson
import Data.Aeson.Types (Pair)
import Data.Text (Text)

data Event
  = RunStarted Text Text
  | RunFinished Text Text
  | RunCancelled Text
  | RunError Text Text
  | StepStarted Text
  | StepFinished Text
  | TextMessageStarted Text
  | TextMessageContent Text Text
  | TextMessageEnded Text
  | ToolCallStarted Text Text
  | ToolCallArguments Text Text
  | ToolCallEnded Text
  | ToolCallResult Text Text Text
  | ReasoningStarted Text
  | ReasoningMessageStarted Text
  | ReasoningMessageContent Text Text
  | ReasoningMessageEnded Text
  | ReasoningEnded Text
  | Custom Text Value
  deriving stock (Eq, Show)

instance ToJSON Event where
  toJSON = \case
    RunStarted thread run -> event "RUN_STARTED" ["threadId" .= thread, "runId" .= run]
    RunFinished thread run -> event "RUN_FINISHED" ["threadId" .= thread, "runId" .= run]
    RunCancelled run -> event "RUN_CANCELLED" ["runId" .= run]
    RunError message code -> event "RUN_ERROR" ["message" .= message, "code" .= code]
    StepStarted name -> event "STEP_STARTED" ["stepName" .= name]
    StepFinished name -> event "STEP_FINISHED" ["stepName" .= name]
    TextMessageStarted message ->
      event "TEXT_MESSAGE_START" ["messageId" .= message]
    TextMessageContent message delta ->
      event "TEXT_MESSAGE_CONTENT" ["messageId" .= message, "delta" .= delta]
    TextMessageEnded message -> event "TEXT_MESSAGE_END" ["messageId" .= message]
    ToolCallStarted call name ->
      event "TOOL_CALL_START" ["toolCallId" .= call, "toolCallName" .= name]
    ToolCallArguments call delta ->
      event "TOOL_CALL_ARGS" ["toolCallId" .= call, "delta" .= delta]
    ToolCallEnded call -> event "TOOL_CALL_END" ["toolCallId" .= call]
    ToolCallResult message call content ->
      event
        "TOOL_CALL_RESULT"
        [ "messageId" .= message,
          "toolCallId" .= call,
          "content" .= content
        ]
    ReasoningStarted message -> event "REASONING_START" ["messageId" .= message]
    ReasoningMessageStarted message ->
      event "REASONING_MESSAGE_START" ["messageId" .= message]
    ReasoningMessageContent message delta ->
      event "REASONING_MESSAGE_CONTENT" ["messageId" .= message, "delta" .= delta]
    ReasoningMessageEnded message -> event "REASONING_MESSAGE_END" ["messageId" .= message]
    ReasoningEnded message -> event "REASONING_END" ["messageId" .= message]
    Custom name value -> event "CUSTOM" ["name" .= name, "value" .= value]
   where
    event :: Text -> [Pair] -> Value
    event kind fields = object (["type" .= kind] <> fields)
