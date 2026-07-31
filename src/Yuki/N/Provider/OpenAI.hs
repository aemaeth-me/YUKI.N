module Yuki.N.Provider.OpenAI
  ( ApiDialect (..),
    ChatChunk (..),
    ChatChoice (..),
    ChatDelta (..),
    DeltaFunction (..),
    DeltaToolCall (..),
    OpenAIConfig (..),
    ReasoningEffort (..),
    SseDecoder,
    ThinkingMode (..),
    chunkEvents,
    emptySseDecoder,
    feedSse,
    fetchModelIds,
    finishSse,
    openAIModel,
    requestValue,
  )
where

import Control.Applicative ((<|>))
import Control.Exception (catch, throwIO, try)
import Control.Monad (foldM, mfilter)
import Data.Aeson
import Data.Aeson.Types (Pair, parseMaybe)
import Data.Bifunctor (first)
import Data.Bool (bool)
import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor ((<&>))
import Data.Maybe (fromMaybe, maybeToList)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Network.HTTP.Client
import Network.HTTP.Types.Header (hAccept, hAuthorization, hContentType)
import Network.HTTP.Types.Status (Status, statusCode, statusMessage)
import Yuki.N.AGUI.Types (ToolSpec (..), firstPresent, pair)
import Yuki.N.Model

data OpenAIConfig = OpenAIConfig
  { openAIProvider :: Text,
    openAIModelName :: Text,
    openAIBaseUrl :: Text,
    openAIApiKey :: Text,
    openAIDialect :: ApiDialect,
    openAIThinking :: ThinkingMode,
    openAIMaxTokens :: Maybe Int,
    openAIContextTokens :: Maybe Int
  }

data ApiDialect
  = DeepSeek
  | OpenAICompatible
  deriving stock (Eq, Show)

data ThinkingMode
  = ThinkingDisabled
  | ThinkingEnabled ReasoningEffort
  deriving stock (Eq, Show)

data ReasoningEffort
  = Low
  | High
  | Max
  deriving stock (Eq, Show)

instance ToJSON ReasoningEffort where
  toJSON = String . effortText

instance FromJSON ReasoningEffort where
  parseJSON = withText "ReasoningEffort" $ either (fail . Text.unpack) pure . effortFromText

openAIModel :: Manager -> OpenAIConfig -> Model
openAIModel manager config =
  Model
    { modelProvider = openAIProvider config,
      modelName = openAIModelName config,
      modelContextTokens = openAIContextTokens config,
      streamModel = streamProvider manager config,
      modelRender = requestValue config
    }

streamProvider ::
  Manager ->
  OpenAIConfig ->
  ModelRequest ->
  (ModelEvent -> IO ()) ->
  IO FinishReason
streamProvider manager config modelRequest emit =
  action `catch` rethrowHttp
  where
    action = buildRequest config modelRequest >>= \request -> withResponse request manager (consumeResponse (openAIDialect config) emit)
    rethrowHttp = throwIO . ProviderFailure . ("provider request failed: " <>) . httpError

buildRequest :: OpenAIConfig -> ModelRequest -> IO Request
buildRequest config modelRequest =
  parseRequest (Text.unpack (apiEndpoint config))
    <&> \request ->
      request
        { method = "POST",
          requestHeaders =
            [ (hAuthorization, "Bearer " <> TextEncoding.encodeUtf8 (openAIApiKey config)),
              (hContentType, "application/json"),
              (hAccept, "text/event-stream")
            ],
          requestBody = RequestBodyLBS (encode (requestValue config modelRequest)),
          responseTimeout = responseTimeoutNone
        }

apiEndpoint :: OpenAIConfig -> Text
apiEndpoint config =
  apiRoot (openAIBaseUrl config)
    <> case openAIDialect config of
      DeepSeek -> "/responses"
      OpenAICompatible -> "/chat/completions"

apiRoot :: Text -> Text
apiRoot base =
  fromMaybe trimmed (Text.stripSuffix "/chat/completions" trimmed <|> Text.stripSuffix "/responses" trimmed <|> Text.stripSuffix "/models" trimmed)
  where
    trimmed = Text.dropWhileEnd (== '/') base

fetchModelIds :: Manager -> OpenAIConfig -> IO (Either Text [Text])
fetchModelIds manager config =
  try request >>= either (pure . Left . Text.pack . showHttp) inspect
  where
    request =
      parseRequest (Text.unpack (modelsEndpoint (openAIBaseUrl config)))
        >>= \req ->
          httpLbs req {requestHeaders = [(hAuthorization, "Bearer " <> TextEncoding.encodeUtf8 (openAIApiKey config))]} manager
    showHttp (exception :: HttpException) = show exception
    inspect response
      | statusCode (responseStatus response) > 299 =
          pure (Left ("provider returned HTTP " <> Text.pack (show (statusCode (responseStatus response)))))
      | otherwise =
          pure (maybe (Left "models payload unrecognized") Right (decode (responseBody response) >>= parseMaybe modelList))
    modelList = withObject "ModelList" (\body -> body .: "data" >>= mapM (withObject "model" (.: "id")))

modelsEndpoint :: Text -> Text
modelsEndpoint = (<> "/models") . apiRoot

requestValue :: OpenAIConfig -> ModelRequest -> Value
requestValue config =
  case openAIDialect config of
    DeepSeek -> responsesRequestValue config
    OpenAICompatible -> chatRequestValue config

chatRequestValue :: OpenAIConfig -> ModelRequest -> Value
chatRequestValue config modelRequest =
  object $
    [ "model" .= openAIModelName config,
      "messages" .= fmap (chatMessageValue config) (requestMessages modelRequest),
      "stream" .= True,
      "stream_options" .= object ["include_usage" .= True]
    ]
      <> pair "tools" tools
      <> pair "max_tokens" (openAIMaxTokens config)
      <> thinkingFields config
  where
    tools = nonEmpty (toolValue <$> requestTools modelRequest)

responsesRequestValue :: OpenAIConfig -> ModelRequest -> Value
responsesRequestValue config modelRequest =
  object $
    [ "model" .= openAIModelName config,
      "input" .= concatMap responseInputValues (requestMessages modelRequest),
      "stream" .= True
    ]
      <> pair "tools" tools
      <> pair "max_output_tokens" (openAIMaxTokens config)
      <> responseReasoningFields (openAIThinking config)
  where
    tools = nonEmpty (responseToolValue <$> requestTools modelRequest)

responseReasoningFields :: ThinkingMode -> [Pair]
responseReasoningFields ThinkingDisabled = []
responseReasoningFields (ThinkingEnabled effort) = ["reasoning" .= object ["effort" .= effortText effort]]

responseInputValues :: ChatMessage -> [Value]
responseInputValues = \case
  ChatSystem content -> [responseMessage "system" content]
  ChatUser content -> [responseMessage "user" content]
  ChatToolResult call content ->
    [ object
        [ "type" .= ("function_call_output" :: Text),
          "call_id" .= call,
          "output" .= content
        ]
    ]
  ChatAssistant turn ->
    maybeToList (responseReasoningValue turn)
      <> maybeToList (responseAssistantValue turn)
      <> fmap responseToolCallValue (turnToolCalls turn)

responseMessage :: Text -> Text -> Value
responseMessage role content =
  object
    [ "type" .= ("message" :: Text),
      "role" .= role,
      "content" .= content
    ]

responseReasoningValue :: AssistantTurn -> Maybe Value
responseReasoningValue turn =
  turnReasoning turn <&> \content ->
    object
      [ "type" .= ("reasoning" :: Text),
        "content"
          .= [ object
                 [ "type" .= ("reasoning_text" :: Text),
                   "text" .= content
                 ]
             ]
      ]

responseAssistantValue :: AssistantTurn -> Maybe Value
responseAssistantValue turn = responseMessage "assistant" <$> turnText turn

responseToolCallValue :: ModelToolCall -> Value
responseToolCallValue call =
  object
    [ "type" .= ("function_call" :: Text),
      "call_id" .= modelToolCallId call,
      "name" .= modelToolName call,
      "arguments" .= modelToolArguments call
    ]

responseToolValue :: ToolSpec -> Value
responseToolValue tool =
  object
    [ "type" .= ("function" :: Text),
      "name" .= toolName tool,
      "description" .= toolDescription tool,
      "parameters" .= toolParameters tool
    ]

thinkingFields :: OpenAIConfig -> [Pair]
thinkingFields config
  | openAIProvider config == "kimi-coding" =
      case openAIThinking config of
        ThinkingDisabled -> []
        ThinkingEnabled effort -> ["reasoning_effort" .= effortText effort]
  | openAIProvider config == "zai" =
      thinkingToggle (openAIThinking config)
thinkingFields OpenAIConfig {openAIDialect = DeepSeek, openAIThinking = ThinkingDisabled} =
  ["thinking" .= object ["type" .= ("disabled" :: Text)]]
thinkingFields OpenAIConfig {openAIDialect = DeepSeek, openAIThinking = ThinkingEnabled effort} =
  [ "thinking" .= object ["type" .= ("enabled" :: Text)],
    "reasoning_effort" .= effortText effort
  ]
thinkingFields _ = []

thinkingToggle :: ThinkingMode -> [Pair]
thinkingToggle ThinkingDisabled = ["thinking" .= object ["type" .= ("disabled" :: Text)]]
thinkingToggle (ThinkingEnabled _) = ["thinking" .= object ["type" .= ("enabled" :: Text)]]

chatMessageValue :: OpenAIConfig -> ChatMessage -> Value
chatMessageValue config = \case
  ChatSystem content -> object ["role" .= ("system" :: Text), "content" .= content]
  ChatUser content -> object ["role" .= ("user" :: Text), "content" .= content]
  ChatToolResult call content ->
    object ["role" .= ("tool" :: Text), "tool_call_id" .= call, "content" .= content]
  ChatAssistant turn ->
    object $
      ["role" .= ("assistant" :: Text), "content" .= turnText turn]
        <> reasoningField config turn
        <> pair "tool_calls" (nonEmpty (toolCallValue <$> turnToolCalls turn))

reasoningField :: OpenAIConfig -> AssistantTurn -> [Pair]
reasoningField config
  | openAIDialect config == DeepSeek || openAIProvider config == "kimi-coding" =
      pair "reasoning_content" . turnReasoning
  | otherwise = const []

toolCallValue :: ModelToolCall -> Value
toolCallValue call =
  object
    [ "id" .= modelToolCallId call,
      "type" .= ("function" :: Text),
      "function"
        .= object
          [ "name" .= modelToolName call,
            "arguments" .= modelToolArguments call
          ]
    ]

toolValue :: ToolSpec -> Value
toolValue tool =
  object
    [ "type" .= ("function" :: Text),
      "function"
        .= object
          [ "name" .= toolName tool,
            "description" .= toolDescription tool,
            "parameters" .= toolParameters tool
          ]
    ]

effortText :: ReasoningEffort -> Text
effortText Low = "low"
effortText High = "high"
effortText Max = "max"

effortFromText :: Text -> Either Text ReasoningEffort
effortFromText "low" = Right Low
effortFromText "high" = Right High
effortFromText "max" = Right Max
effortFromText value = Left ("reasoningEffort must be low, high, or max; got " <> value)

consumeResponse :: ApiDialect -> (ModelEvent -> IO ()) -> Response BodyReader -> IO FinishReason
consumeResponse dialect emit response
  | statusCode status < 200 || statusCode status >= 300 =
      brConsume (responseBody response)
        >>= throwIO . ProviderFailure . responseError status . ByteString.concat
  | otherwise = readBody emptySseDecoder Nothing
  where
    status = responseStatus response
    reader = responseBody response

    readBody decoder reason = brRead reader >>= consumeBody decoder reason
    consumeBody decoder reason chunk
      | ByteString.null chunk =
          consumePayloads dialect emit reason (snd (finishSse decoder)) >>= requireFinish . fst
      | otherwise =
          let (decoder', payloads) = feedSse decoder chunk
           in consumePayloads dialect emit reason payloads >>= continue decoder'
    continue _ (reason, True) = requireFinish reason
    continue decoder (reason, False) = readBody decoder reason

consumePayloads ::
  ApiDialect ->
  (ModelEvent -> IO ()) ->
  Maybe FinishReason ->
  [ByteString] ->
  IO (Maybe FinishReason, Bool)
consumePayloads dialect emit initial = foldM consume (initial, False)
  where
    consume result@(_, True) _ = pure result
    consume (reason, False) payload
      | payload == "[DONE]" = pure (reason, True)
      | otherwise = either throwIO apply (providerPayload dialect payload)
      where
        apply (events, reason', done) =
          traverse_ emit events
            *> pure
              ( reason' <|> reason <|> bool Nothing (Just Stop) (done && dialect == DeepSeek),
                done
              )

providerPayload :: ApiDialect -> ByteString -> Either ProviderFailure ([ModelEvent], Maybe FinishReason, Bool)
providerPayload DeepSeek payload = decodeResponsesEvent payload >>= responseEvent
providerPayload OpenAICompatible payload =
  decodeChunk payload >>= chunkEvents <&> \(events, reason) -> (events, reason, False)

responseEvent :: ResponsesEvent -> Either ProviderFailure ([ModelEvent], Maybe FinishReason, Bool)
responseEvent event =
  case responsesEventType event of
    "response.output_text.delta" -> Right (textDelta ModelTextDelta, Nothing, False)
    "response.reasoning_text.delta" -> Right (textDelta ModelReasoningDelta, Nothing, False)
    "response.function_call_arguments.delta" -> Right (argumentDelta, Nothing, False)
    "response.output_item.added" -> Right (itemEvents, itemFinish, False)
    "response.completed" -> Right (usage, Nothing, True)
    "response.incomplete" -> Right (usage, Just Length, True)
    "response.failed" -> Left (ProviderFailure ("provider response failed: " <> failure))
    "error" -> Left (ProviderFailure ("provider stream error: " <> failure))
    _ -> Right ([], Nothing, False)
  where
    textDelta constructor = maybeToList (constructor <$> mfilter (not . Text.null) (responsesEventDelta event))
    argumentDelta = maybeToList (ModelToolCallDelta (responsesEventOutputIndex event) Nothing Nothing <$> responsesEventDelta event)
    itemEvents = maybe [] (responseItemEvents (responsesEventOutputIndex event)) (responsesEventItem event)
    itemFinish = bool Nothing (Just ToolUse) (maybe False ((== "function_call") . responseItemType) (responsesEventItem event))
    usage = maybeToList (ModelUsage . responseUsageValue <$> responseUsage event)
    failure = maybe "unknown response failure" compactValue (responseFailure event)

responseItemEvents :: Int -> ResponseItem -> [ModelEvent]
responseItemEvents index item
  | responseItemType item /= "function_call" = []
  | otherwise =
      [ ModelToolCallDelta
          index
          (responseItemCallId item <|> responseItemId item)
          (responseItemName item)
          (fromMaybe "" (responseItemArguments item))
      ]

responseUsage :: ResponsesEvent -> Maybe ResponseUsage
responseUsage event =
  responsesEventResponse event
    >>= parseMaybe (withObject "response" (.:? "usage"))
    >>= id

responseFailure :: ResponsesEvent -> Maybe Value
responseFailure event =
  responsesEventError event
    <|> ( responsesEventResponse event
            >>= parseMaybe (withObject "response" (.:? "error"))
            >>= id
        )

responseUsageValue :: ResponseUsage -> Usage
responseUsageValue usage =
  Usage
    (responseInputTokens usage)
    (responseOutputTokens usage)
    (responseCachedTokens usage)
    ((-) <$> responseInputTokens usage <*> responseCachedTokens usage)

decodeResponsesEvent :: ByteString -> Either ProviderFailure ResponsesEvent
decodeResponsesEvent =
  first (ProviderFailure . ("invalid Responses API stream event: " <>) . Text.pack) . eitherDecodeStrict'

chunkEvents :: ChatChunk -> Either ProviderFailure ([ModelEvent], Maybe FinishReason)
chunkEvents chunk
  | Just err <- chunkError chunk =
      Left (ProviderFailure ("provider stream error: " <> compactValue err))
  | otherwise =
      let choices = filter ((== 0) . choiceIndex) (chunkChoices chunk)
          finish = foldl (\acc choice -> choiceFinishReason choice <|> acc) Nothing choices
       in (,) (concatMap choiceEvents choices <> usageEvents chunk) <$> traverse parseFinish finish

usageEvents :: ChatChunk -> [ModelEvent]
usageEvents = maybeToList . fmap ModelUsage . chunkUsage

choiceEvents :: ChatChoice -> [ModelEvent]
choiceEvents choice =
  maybeToList (ModelReasoningDelta <$> mfilter (not . Text.null) (deltaReasoning delta))
    <> maybeToList (ModelTextDelta <$> mfilter (not . Text.null) (deltaContent delta))
    <> fmap toolDelta (deltaToolCalls delta)
  where
    delta = choiceDelta choice

    toolDelta tool =
      ModelToolCallDelta
        { deltaToolIndex = deltaToolIndex' tool,
          deltaToolId = deltaToolId' tool,
          deltaToolName = deltaFunctionName =<< deltaToolFunction tool,
          deltaToolArguments = fromMaybe "" (deltaFunctionArguments =<< deltaToolFunction tool)
        }

parseFinish :: Text -> Either ProviderFailure FinishReason
parseFinish = \case
  "stop" -> Right Stop
  "end" -> Right Stop
  "tool_calls" -> Right ToolUse
  "function_call" -> Right ToolUse
  "length" -> Right Length
  reason -> Left (ProviderFailure ("provider finish reason: " <> reason))

requireFinish :: Maybe FinishReason -> IO FinishReason
requireFinish = maybe (throwIO (ProviderFailure "provider stream ended without a finish reason")) pure

bodySuffix :: ByteString -> Text
bodySuffix body
  | ByteString.null body = ""
  | otherwise = ": " <> Text.take 4096 (TextEncoding.decodeUtf8With lenientDecode body)

compactValue :: Value -> Text
compactValue = Text.take 4096 . TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

decodeChunk :: ByteString -> Either ProviderFailure ChatChunk
decodeChunk =
  first (ProviderFailure . ("invalid provider stream event: " <>) . Text.pack) . eitherDecodeStrict'

responseError :: Status -> ByteString -> Text
responseError status body =
  "provider returned HTTP "
    <> Text.pack (show (statusCode status))
    <> " "
    <> TextEncoding.decodeUtf8With lenientDecode (statusMessage status)
    <> bodySuffix body

nonEmpty :: [value] -> Maybe [value]
nonEmpty values = bool (Just values) Nothing (null values)

data ChatChunk = ChatChunk
  { chunkChoices :: [ChatChoice],
    chunkError :: Maybe Value,
    chunkUsage :: Maybe Usage
  }

data ChatChoice = ChatChoice
  { choiceIndex :: Int,
    choiceDelta :: ChatDelta,
    choiceFinishReason :: Maybe Text
  }

data ChatDelta = ChatDelta
  { deltaContent :: Maybe Text,
    deltaReasoning :: Maybe Text,
    deltaToolCalls :: [DeltaToolCall]
  }

data DeltaToolCall = DeltaToolCall
  { deltaToolIndex' :: Int,
    deltaToolId' :: Maybe Text,
    deltaToolFunction :: Maybe DeltaFunction
  }

data DeltaFunction = DeltaFunction
  { deltaFunctionName :: Maybe Text,
    deltaFunctionArguments :: Maybe Text
  }

data ResponsesEvent = ResponsesEvent
  { responsesEventType :: Text,
    responsesEventDelta :: Maybe Text,
    responsesEventOutputIndex :: Int,
    responsesEventItem :: Maybe ResponseItem,
    responsesEventResponse :: Maybe Value,
    responsesEventError :: Maybe Value
  }

data ResponseItem = ResponseItem
  { responseItemType :: Text,
    responseItemId :: Maybe Text,
    responseItemCallId :: Maybe Text,
    responseItemName :: Maybe Text,
    responseItemArguments :: Maybe Text
  }

data ResponseUsage = ResponseUsage
  { responseInputTokens :: Maybe Int,
    responseOutputTokens :: Maybe Int,
    responseCachedTokens :: Maybe Int
  }

instance FromJSON ResponsesEvent where
  parseJSON = withObject "ResponsesEvent" $ \fields ->
    ResponsesEvent
      <$> (firstPresent fields ["type", "event"] >>= maybe (fail "missing response event type") pure)
      <*> fields .:? "delta"
      <*> (fields .:? "output_index" .!= 0)
      <*> fields .:? "item"
      <*> fields .:? "response"
      <*> fields .:? "error"

instance FromJSON ResponseItem where
  parseJSON = withObject "ResponseItem" $ \fields ->
    ResponseItem
      <$> fields .: "type"
      <*> fields .:? "id"
      <*> fields .:? "call_id"
      <*> fields .:? "name"
      <*> fields .:? "arguments"

instance FromJSON ResponseUsage where
  parseJSON = withObject "ResponseUsage" $ \fields ->
    ResponseUsage
      <$> fields .:? "input_tokens"
      <*> fields .:? "output_tokens"
      <*> (fields .:? "input_tokens_details" >>= maybe (pure Nothing) (withObject "InputTokenDetails" (.:? "cached_tokens")))

instance FromJSON ChatChunk where
  parseJSON = withObject "ChatCompletionChunk" $ \fields ->
    ChatChunk <$> (fields .:? "choices" .!= []) <*> fields .:? "error" <*> fields .:? "usage"

instance FromJSON ChatChoice where
  parseJSON = withObject "ChatCompletionChoice" $ \fields ->
    ChatChoice
      <$> (fields .:? "index" .!= 0)
      <*> (fields .:? "delta" .!= emptyDelta)
      <*> fields .:? "finish_reason"

instance FromJSON ChatDelta where
  parseJSON = withObject "ChatCompletionDelta" $ \fields ->
    ChatDelta
      <$> fields .:? "content"
      <*> firstPresent fields ["reasoning_content", "reasoning", "reasoning_text"]
      <*> (fields .:? "tool_calls" .!= [])

instance FromJSON DeltaToolCall where
  parseJSON = withObject "ChatCompletionToolCallDelta" $ \fields ->
    DeltaToolCall
      <$> fields .: "index"
      <*> fields .:? "id"
      <*> fields .:? "function"

instance FromJSON DeltaFunction where
  parseJSON = withObject "ChatCompletionFunctionDelta" $ \fields ->
    DeltaFunction <$> fields .:? "name" <*> fields .:? "arguments"

emptyDelta :: ChatDelta
emptyDelta = ChatDelta Nothing Nothing []

data SseDecoder = SseDecoder
  { sseBuffer :: ByteString,
    sseDataLines :: [ByteString]
  }
  deriving stock (Eq, Show)

emptySseDecoder :: SseDecoder
emptySseDecoder = SseDecoder "" []

feedSse :: SseDecoder -> ByteString -> (SseDecoder, [ByteString])
feedSse decoder chunk
  | ByteString.null combined = (decoder, [])
  | otherwise =
      let (decoder', payloads) = foldLines decoder (init pieces)
       in (decoder' {sseBuffer = last pieces}, payloads)
  where
    combined = sseBuffer decoder <> chunk
    pieces = Char8.split '\n' combined

finishSse :: SseDecoder -> (SseDecoder, [ByteString])
finishSse decoder =
  let (withoutBuffer, buffered) = drainBuffer decoder
      reset = withoutBuffer {sseBuffer = ""}
      (finished, final) = stepLine reset ""
   in (finished, buffered <> final)

drainBuffer :: SseDecoder -> (SseDecoder, [ByteString])
drainBuffer decoder
  | ByteString.null (sseBuffer decoder) = (decoder, [])
  | otherwise = stepLine decoder (sseBuffer decoder)

foldLines :: SseDecoder -> [ByteString] -> (SseDecoder, [ByteString])
foldLines decoder = foldl consume (decoder, [])
  where
    consume (current, payloads) line =
      let (decoder', emitted) = stepLine current line
       in (decoder', payloads <> emitted)

stepLine :: SseDecoder -> ByteString -> (SseDecoder, [ByteString])
stepLine decoder rawLine
  | ByteString.null line = flushEvent decoder
  | "data:" `ByteString.isPrefixOf` line =
      (decoder {sseDataLines = dropSpace (ByteString.drop 5 line) : sseDataLines decoder}, [])
  | otherwise = (decoder, [])
  where
    line = fromMaybe rawLine (ByteString.stripSuffix "\r" rawLine)
    dropSpace value = fromMaybe value (ByteString.stripPrefix " " value)

flushEvent :: SseDecoder -> (SseDecoder, [ByteString])
flushEvent decoder
  | null (sseDataLines decoder) = (decoder, [])
  | otherwise =
      ( decoder {sseDataLines = []},
        [ByteString.intercalate "\n" (reverse (sseDataLines decoder))]
      )

httpError :: HttpException -> Text
httpError = \case
  HttpExceptionRequest _ content -> Text.pack (show content)
  InvalidUrlException _ reason -> Text.pack reason
