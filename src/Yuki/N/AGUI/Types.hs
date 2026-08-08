module Yuki.N.AGUI.Types
  ( AssistantMessage (..),
    FunctionCall (..),
    Message (..),
    ReasoningMessage (..),
    RunAgentInput (..),
    SystemMessage (..),
    ToolCall (..),
    ToolMessage (..),
    ToolSpec (..),
    UserMessage (..),
  )
where

import Data.Aeson
import Data.Aeson.Types (Pair)
import Data.Text (Text)
import Data.Text qualified as Text

data RunAgentInput = RunAgentInput
  { runThreadId :: Text,
    runId :: Text,
    runParentId :: Maybe Text,
    runMessages :: [Message]
  }
  deriving stock (Eq, Show)

data Message
  = System SystemMessage
  | Assistant AssistantMessage
  | User UserMessage
  | Tool ToolMessage
  | Reasoning ReasoningMessage
  deriving stock (Eq, Show)

data SystemMessage = SystemMessage
  { systemId :: Text,
    systemContent :: Text
  }
  deriving stock (Eq, Show)

data AssistantMessage = AssistantMessage
  { assistantId :: Text,
    assistantContent :: Maybe Text,
    assistantToolCalls :: [ToolCall]
  }
  deriving stock (Eq, Show)

data UserMessage = UserMessage
  { userId :: Text,
    userContent :: Text
  }
  deriving stock (Eq, Show)

data ToolMessage = ToolMessage
  { toolMessageId :: Text,
    toolMessageContent :: Text,
    toolMessageCallId :: Text
  }
  deriving stock (Eq, Show)

data ReasoningMessage = ReasoningMessage
  { reasoningId :: Text,
    reasoningContent :: Text
  }
  deriving stock (Eq, Show)

data ToolCall = ToolCall
  { toolCallId :: Text,
    toolCallFunction :: FunctionCall
  }
  deriving stock (Eq, Show)

data FunctionCall = FunctionCall
  { functionName :: Text,
    functionArguments :: Text
  }
  deriving stock (Eq, Show)

data ToolSpec = ToolSpec
  { toolName :: Text,
    toolDescription :: Text,
    toolParameters :: Value
  }
  deriving stock (Eq, Show)

instance FromJSON RunAgentInput where
  parseJSON = withObject "RunAgentInput" $ \fields ->
    RunAgentInput
      <$> fields .: "threadId"
      <*> fields .: "runId"
      <*> fields .:? "parentRunId"
      <*> fields .: "messages"

instance FromJSON Message where
  parseJSON value@(Object fields) = fields .: "role" >>= parseRole
   where
    parseRole = \case
      ("assistant" :: Text) -> Assistant <$> parseJSON value
      "user" -> User <$> parseJSON value
      "tool" -> Tool <$> parseJSON value
      "reasoning" -> Reasoning <$> parseJSON value
      role -> fail ("unsupported AG-UI message role: " <> Text.unpack role)
  parseJSON _ = fail "AG-UI message must be an object"

instance ToJSON Message where
  toJSON = \case
    System message -> toJSON message
    Assistant message -> toJSON message
    User message -> toJSON message
    Tool message -> toJSON message
    Reasoning message -> toJSON message

instance ToJSON SystemMessage where
  toJSON message =
    object
      [ "id" .= systemId message,
        "role" .= ("system" :: Text),
        "content" .= systemContent message
      ]

instance FromJSON AssistantMessage where
  parseJSON = withObject "AssistantMessage" $ \fields ->
    AssistantMessage
      <$> fields .: "id"
      <*> fields .:? "content"
      <*> fields .:? "toolCalls" .!= []

instance ToJSON AssistantMessage where
  toJSON message =
    object $
      ["id" .= assistantId message, "role" .= ("assistant" :: Text)]
        <> pair "content" (assistantContent message)
        <> ["toolCalls" .= assistantToolCalls message | not (null (assistantToolCalls message))]

instance FromJSON UserMessage where
  parseJSON = withObject "UserMessage" $ \fields ->
    UserMessage <$> fields .: "id" <*> fields .: "content"

instance ToJSON UserMessage where
  toJSON message =
    object ["id" .= userId message, "role" .= ("user" :: Text), "content" .= userContent message]

instance FromJSON ToolMessage where
  parseJSON = withObject "ToolMessage" $ \fields ->
    ToolMessage
      <$> fields .: "id"
      <*> fields .: "content"
      <*> fields .: "toolCallId"

instance ToJSON ToolMessage where
  toJSON message =
    object
      [ "id" .= toolMessageId message,
        "role" .= ("tool" :: Text),
        "content" .= toolMessageContent message,
        "toolCallId" .= toolMessageCallId message
      ]

instance FromJSON ReasoningMessage where
  parseJSON = withObject "ReasoningMessage" $ \fields ->
    ReasoningMessage <$> fields .: "id" <*> fields .: "content"

instance ToJSON ReasoningMessage where
  toJSON message =
    object ["id" .= reasoningId message, "role" .= ("reasoning" :: Text), "content" .= reasoningContent message]

instance FromJSON ToolCall where
  parseJSON = withObject "ToolCall" $ \fields ->
    (requireFunction =<< (fields .:? "type" .!= ("function" :: Text)))
      *> ( ToolCall
             <$> fields .: "id"
             <*> fields .: "function"
         )

instance ToJSON ToolCall where
  toJSON call =
    object
      [ "id" .= toolCallId call,
        "type" .= ("function" :: Text),
        "function" .= toolCallFunction call
      ]

instance FromJSON FunctionCall where
  parseJSON = withObject "FunctionCall" $ \fields ->
    FunctionCall <$> fields .: "name" <*> fields .: "arguments"

instance ToJSON FunctionCall where
  toJSON call = object ["name" .= functionName call, "arguments" .= functionArguments call]

instance ToJSON ToolSpec where
  toJSON tool =
    object
      [ "name" .= toolName tool,
        "description" .= toolDescription tool,
        "parameters" .= toolParameters tool
      ]

pair :: (ToJSON a) => Key -> Maybe a -> [Pair]
pair key = maybe [] (pure . (key .=))

requireFunction :: (MonadFail m) => Text -> m ()
requireFunction "function" = pure ()
requireFunction _ = fail "AG-UI supports only function tool calls"
