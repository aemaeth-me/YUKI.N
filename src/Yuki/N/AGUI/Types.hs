module Yuki.N.AGUI.Types
  ( ActivityMessage (..),
    AssistantMessage (..),
    ContextItem (..),
    DeveloperMessage (..),
    FunctionCall (..),
    InputContent (..),
    InputSource (..),
    Message (..),
    ReasoningMessage (..),
    RunAgentInput (..),
    SystemMessage (..),
    ToolCall (..),
    ToolMessage (..),
    ToolSpec (..),
    UserContent (..),
    UserMessage (..),
    firstPresent,
    pair,
    userText,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson
import Data.Aeson.Types (Pair, Parser)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text

data RunAgentInput = RunAgentInput
  { runThreadId :: Text,
    runId :: Text,
    runParentId :: Maybe Text,
    runState :: Value,
    runMessages :: [Message],
    runTools :: [ToolSpec],
    runContext :: [ContextItem],
    runForwardedProps :: Value
  }
  deriving stock (Eq, Show)

data Message
  = Developer DeveloperMessage
  | System SystemMessage
  | Assistant AssistantMessage
  | User UserMessage
  | Tool ToolMessage
  | Activity ActivityMessage
  | Reasoning ReasoningMessage
  deriving stock (Eq, Show)

data DeveloperMessage = DeveloperMessage
  { developerId :: Text,
    developerContent :: Text,
    developerName :: Maybe Text
  }
  deriving stock (Eq, Show)

data SystemMessage = SystemMessage
  { systemId :: Text,
    systemContent :: Text,
    systemName :: Maybe Text
  }
  deriving stock (Eq, Show)

data AssistantMessage = AssistantMessage
  { assistantId :: Text,
    assistantContent :: Maybe Text,
    assistantName :: Maybe Text,
    assistantToolCalls :: [ToolCall]
  }
  deriving stock (Eq, Show)

data UserMessage = UserMessage
  { userId :: Text,
    userContent :: UserContent,
    userName :: Maybe Text
  }
  deriving stock (Eq, Show)

data ToolMessage = ToolMessage
  { toolMessageId :: Text,
    toolMessageContent :: Text,
    toolMessageCallId :: Text,
    toolMessageError :: Maybe Text,
    toolMessageEncryptedValue :: Maybe Text
  }
  deriving stock (Eq, Show)

data ActivityMessage = ActivityMessage
  { activityId :: Text,
    activityType :: Text,
    activityContent :: Value
  }
  deriving stock (Eq, Show)

data ReasoningMessage = ReasoningMessage
  { reasoningId :: Text,
    reasoningContent :: Text,
    reasoningEncryptedValue :: Maybe Text
  }
  deriving stock (Eq, Show)

data UserContent
  = UserText Text
  | UserParts [InputContent]
  deriving stock (Eq, Show)

data InputContent
  = InputText Text
  | InputImage InputSource (Maybe Value)
  | InputAudio InputSource (Maybe Value)
  | InputVideo InputSource (Maybe Value)
  | InputDocument InputSource (Maybe Value)
  deriving stock (Eq, Show)

data InputSource
  = DataSource
      { dataSourceValue :: Text,
        dataSourceMimeType :: Text
      }
  | UrlSource
      { urlSourceValue :: Text,
        urlSourceMimeType :: Maybe Text
      }
  deriving stock (Eq, Show)

data ToolCall = ToolCall
  { toolCallId :: Text,
    toolCallFunction :: FunctionCall,
    toolCallEncryptedValue :: Maybe Text
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

data ContextItem = ContextItem
  { contextDescription :: Text,
    contextValue :: Text
  }
  deriving stock (Eq, Show)

instance FromJSON RunAgentInput where
  parseJSON = withObject "RunAgentInput" $ \o ->
    RunAgentInput
      <$> required o "threadId" "thread_id"
      <*> required o "runId" "run_id"
      <*> optional o "parentRunId" "parent_run_id"
      <*> (o .:? "state" .!= Null)
      <*> o .: "messages"
      <*> (o .:? "tools" .!= [])
      <*> (o .:? "context" .!= [])
      <*> (fromMaybe Null <$> optional o "forwardedProps" "forwarded_props")

instance ToJSON RunAgentInput where
  toJSON input =
    object $
      [ "threadId" .= runThreadId input,
        "runId" .= runId input,
        "state" .= runState input,
        "messages" .= runMessages input,
        "tools" .= runTools input,
        "context" .= runContext input,
        "forwardedProps" .= runForwardedProps input
      ]
        <> pair "parentRunId" (runParentId input)

instance FromJSON Message where
  parseJSON value@(Object o) = o .: "role" >>= parseRole
   where
    parseRole = \case
      ("developer" :: Text) -> Developer <$> parseJSON value
      "system" -> System <$> parseJSON value
      "assistant" -> Assistant <$> parseJSON value
      "user" -> User <$> parseJSON value
      "tool" -> Tool <$> parseJSON value
      "activity" -> Activity <$> parseJSON value
      "reasoning" -> Reasoning <$> parseJSON value
      role -> fail ("unsupported AG-UI message role: " <> Text.unpack role)
  parseJSON _ = fail "AG-UI message must be an object"

instance ToJSON Message where
  toJSON = \case
    Developer message -> toJSON message
    System message -> toJSON message
    Assistant message -> toJSON message
    User message -> toJSON message
    Tool message -> toJSON message
    Activity message -> toJSON message
    Reasoning message -> toJSON message

instance FromJSON DeveloperMessage where
  parseJSON = withObject "DeveloperMessage" $ \o ->
    DeveloperMessage <$> o .: "id" <*> o .: "content" <*> o .:? "name"

instance ToJSON DeveloperMessage where
  toJSON message =
    object $
      ["id" .= developerId message, "role" .= ("developer" :: Text), "content" .= developerContent message]
        <> pair "name" (developerName message)

instance FromJSON SystemMessage where
  parseJSON = withObject "SystemMessage" $ \o ->
    SystemMessage <$> o .: "id" <*> o .: "content" <*> o .:? "name"

instance ToJSON SystemMessage where
  toJSON message =
    object $
      ["id" .= systemId message, "role" .= ("system" :: Text), "content" .= systemContent message]
        <> pair "name" (systemName message)

instance FromJSON AssistantMessage where
  parseJSON = withObject "AssistantMessage" $ \o ->
    AssistantMessage
      <$> o .: "id"
      <*> o .:? "content"
      <*> o .:? "name"
      <*> (fromMaybe [] <$> optional o "toolCalls" "tool_calls")

instance ToJSON AssistantMessage where
  toJSON message =
    object $
      ["id" .= assistantId message, "role" .= ("assistant" :: Text)]
        <> pair "content" (assistantContent message)
        <> pair "name" (assistantName message)
        <> ["toolCalls" .= assistantToolCalls message | not (null (assistantToolCalls message))]

instance FromJSON UserMessage where
  parseJSON = withObject "UserMessage" $ \o ->
    UserMessage <$> o .: "id" <*> o .: "content" <*> o .:? "name"

instance ToJSON UserMessage where
  toJSON message =
    object $
      ["id" .= userId message, "role" .= ("user" :: Text), "content" .= userContent message]
        <> pair "name" (userName message)

instance FromJSON ToolMessage where
  parseJSON = withObject "ToolMessage" $ \o ->
    ToolMessage
      <$> o .: "id"
      <*> o .: "content"
      <*> required o "toolCallId" "tool_call_id"
      <*> o .:? "error"
      <*> optional o "encryptedValue" "encrypted_value"

instance ToJSON ToolMessage where
  toJSON message =
    object $
      [ "id" .= toolMessageId message,
        "role" .= ("tool" :: Text),
        "content" .= toolMessageContent message,
        "toolCallId" .= toolMessageCallId message
      ]
        <> pair "error" (toolMessageError message)
        <> pair "encryptedValue" (toolMessageEncryptedValue message)

instance FromJSON ActivityMessage where
  parseJSON = withObject "ActivityMessage" $ \o ->
    ActivityMessage <$> o .: "id" <*> o .: "activityType" <*> o .: "content"

instance ToJSON ActivityMessage where
  toJSON message =
    object
      [ "id" .= activityId message,
        "role" .= ("activity" :: Text),
        "activityType" .= activityType message,
        "content" .= activityContent message
      ]

instance FromJSON ReasoningMessage where
  parseJSON = withObject "ReasoningMessage" $ \o ->
    ReasoningMessage <$> o .: "id" <*> o .: "content" <*> optional o "encryptedValue" "encrypted_value"

instance ToJSON ReasoningMessage where
  toJSON message =
    object $
      ["id" .= reasoningId message, "role" .= ("reasoning" :: Text), "content" .= reasoningContent message]
        <> pair "encryptedValue" (reasoningEncryptedValue message)

instance FromJSON UserContent where
  parseJSON = \case
    String text -> pure (UserText text)
    value@(Array _) -> UserParts <$> parseJSON value
    _ -> fail "user content must be text or an array of input parts"

instance ToJSON UserContent where
  toJSON = \case
    UserText text -> String text
    UserParts parts -> toJSON parts

instance FromJSON InputContent where
  parseJSON = withObject "InputContent" $ \o -> o .: "type" >>= parseKind o
   where
    parseKind o = \case
      ("text" :: Text) -> InputText <$> o .: "text"
      "image" -> InputImage <$> o .: "source" <*> o .:? "metadata"
      "audio" -> InputAudio <$> o .: "source" <*> o .:? "metadata"
      "video" -> InputVideo <$> o .: "source" <*> o .:? "metadata"
      "document" -> InputDocument <$> o .: "source" <*> o .:? "metadata"
      kind -> fail ("unsupported AG-UI input content type: " <> Text.unpack kind)

instance ToJSON InputContent where
  toJSON = \case
    InputText text -> object ["type" .= ("text" :: Text), "text" .= text]
    InputImage source metadata -> sourced "image" source metadata
    InputAudio source metadata -> sourced "audio" source metadata
    InputVideo source metadata -> sourced "video" source metadata
    InputDocument source metadata -> sourced "document" source metadata
   where
    sourced kind source metadata =
      object $ ["type" .= (kind :: Text), "source" .= source] <> pair "metadata" metadata

instance FromJSON InputSource where
  parseJSON = withObject "InputSource" $ \o -> o .: "type" >>= parseKind o
   where
    parseKind o = \case
      ("data" :: Text) -> DataSource <$> o .: "value" <*> required o "mimeType" "mime_type"
      "url" -> UrlSource <$> o .: "value" <*> optional o "mimeType" "mime_type"
      kind -> fail ("unsupported AG-UI input source type: " <> Text.unpack kind)

instance ToJSON InputSource where
  toJSON = \case
    DataSource value mimeType ->
      object ["type" .= ("data" :: Text), "value" .= value, "mimeType" .= mimeType]
    UrlSource value mimeType ->
      object $ ["type" .= ("url" :: Text), "value" .= value] <> pair "mimeType" mimeType

instance FromJSON ToolCall where
  parseJSON = withObject "ToolCall" $ \o ->
    (requireFunction =<< (o .:? "type" .!= ("function" :: Text)))
      *> ( ToolCall
             <$> o .: "id"
             <*> o .: "function"
             <*> optional o "encryptedValue" "encrypted_value"
         )

instance ToJSON ToolCall where
  toJSON call =
    object $
      [ "id" .= toolCallId call,
        "type" .= ("function" :: Text),
        "function" .= toolCallFunction call
      ]
        <> pair "encryptedValue" (toolCallEncryptedValue call)

instance FromJSON FunctionCall where
  parseJSON = withObject "FunctionCall" $ \o ->
    FunctionCall <$> o .: "name" <*> o .: "arguments"

instance ToJSON FunctionCall where
  toJSON call = object ["name" .= functionName call, "arguments" .= functionArguments call]

instance FromJSON ToolSpec where
  parseJSON = withObject "Tool" $ \o ->
    ToolSpec <$> o .: "name" <*> o .: "description" <*> o .: "parameters"

instance ToJSON ToolSpec where
  toJSON tool =
    object
      [ "name" .= toolName tool,
        "description" .= toolDescription tool,
        "parameters" .= toolParameters tool
      ]

instance FromJSON ContextItem where
  parseJSON = withObject "Context" $ \o ->
    ContextItem <$> o .: "description" <*> o .: "value"

instance ToJSON ContextItem where
  toJSON context =
    object ["description" .= contextDescription context, "value" .= contextValue context]

userText :: UserContent -> Either Text Text
userText = \case
  UserText text -> Right text
  UserParts parts -> Text.intercalate "\n" <$> traverse textOf parts
 where
  textOf (InputText text) = Right text
  textOf _ = Left "the configured model provider does not support multimodal input"

required :: (FromJSON a) => Object -> Key -> Key -> Parser a
required fields camel snake = fields .: camel <|> fields .: snake

firstPresent :: (FromJSON a) => Object -> [Key] -> Parser (Maybe a)
firstPresent fields =
  foldr (\key rest -> fields .:? key >>= maybe rest (pure . Just)) (pure Nothing)

optional :: (FromJSON a) => Object -> Key -> Key -> Parser (Maybe a)
optional fields camel snake = firstPresent fields [camel, snake]

pair :: (ToJSON a) => Key -> Maybe a -> [Pair]
pair key = maybe [] (pure . (key .=))

requireFunction :: (MonadFail m) => Text -> m ()
requireFunction "function" = pure ()
requireFunction _ = fail "AG-UI supports only function tool calls"
