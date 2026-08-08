module Yuki.N.Server (runServer) where

import Data.Aeson (FromJSON (..), ToJSON, Value, eitherDecode, encode, object, toJSON, withObject, (.:), (.=))
import Data.ByteString.Builder qualified as Builder
import Data.Functor (($>), (<&>))
import Data.List (find)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Yuki.N.AGUI.Event (Event)
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent (Runtime, runAgent)
import Yuki.N.Config (Settings (..))
import Yuki.N.Sessions (SessionStore (..), validThreadId)
import Yuki.N.Transcript (TranscriptStore (..), renderTranscript, toAguiMessages)

newtype CreateSessionRequest = CreateSessionRequest Text

instance FromJSON CreateSessionRequest where
  parseJSON = withObject "CreateSessionRequest" $ \fields ->
    CreateSessionRequest <$> fields .: "threadId"

application :: Maybe Text -> SessionStore -> TranscriptStore -> (Text -> IO Runtime) -> Application
application cors sessions transcripts runtimeFor request respond =
  route (requestMethod request) (pathInfo request) >>= respond
 where
  route "POST" ["agent"] = handleAgent
  route "OPTIONS" _ = pure (responseLBS status204 (corsHeaders cors <> preflightHeaders) "")
  route "GET" ["threads"] = listSessions sessions <&> ok
  route "POST" ["threads"] = createThread
  route "GET" ["threads", threadId, "transcript"] = threadTranscript threadId
  route _ _ = pure (missing "not found")
  withBody :: (FromJSON body) => Text -> (body -> IO Response) -> IO Response
  withBody label use =
    strictRequestBody request
      >>= either (pure . bad . (label <>) . Text.pack) use . eitherDecode
  createThread =
    withBody "invalid create request: " $ \(CreateSessionRequest threadId) ->
      createSession sessions threadId <&> either sessionError ok
  threadTranscript threadId
    | not (validThreadId threadId) = pure (bad "invalid thread id")
    | otherwise =
        findSession sessions threadId >>= maybe missingSession (const knownSession)
   where
    load = transcriptLoad transcripts threadId
    knownSession = load <&> ok . renderTranscript threadId . fromMaybe []
    missingSession = load >>= maybe (pure (missing "thread not found")) recover
    recover messages =
      ensureSession sessions threadId Nothing
        $> ok (renderTranscript threadId messages)
  sessionError errorText
    | "already exists:" `Text.isInfixOf` errorText = conflict errorText
    | otherwise = bad errorText
  handleAgent = withBody "invalid RunAgentInput: " stream
  stream input
    | not (validThreadId (AGUI.runThreadId input)) = pure (bad "invalid thread id")
    | otherwise =
        ensureSession sessions (AGUI.runThreadId root) (latestUserTitle root)
          *> transcriptInput transcripts root
          >>= streamRun
   where
    root = input {AGUI.runParentId = Nothing}
    streamRun accepted =
      runtimeFor (AGUI.runThreadId accepted)
        <&> responseStream status200 (corsHeaders cors <> streamHeaders) . streamFor accepted
    streamFor accepted runtime write flush =
      runAgent runtime accepted (\event -> write (encodeEvent event) *> flush)
  ok :: (ToJSON a) => a -> Response
  ok = jsonResponse cors status200 . toJSON
  missing = jsonResponse cors status404 . message
  bad = jsonResponse cors status400 . message
  conflict = jsonResponse cors status409 . message

latestUserTitle :: AGUI.RunAgentInput -> Maybe Text
latestUserTitle input =
  listToMaybe
    ( reverse
        [ Text.take 80 title
        | AGUI.User userMessage <- AGUI.runMessages input,
          let raw = AGUI.userContent userMessage,
          let title = Text.unwords (Text.words raw),
          not (Text.null title)
        ]
    )

transcriptInput :: TranscriptStore -> AGUI.RunAgentInput -> IO AGUI.RunAgentInput
transcriptInput transcripts input =
  transcriptLoad transcripts (AGUI.runThreadId input) <&> fromHistory
 where
  fromHistory Nothing = input
  fromHistory (Just []) = input
  fromHistory (Just history) =
    input
      { AGUI.runMessages =
          appendLatestUser (toAguiMessages history) (latestUserMessage input)
      }

appendLatestUser :: [AGUI.Message] -> Maybe AGUI.Message -> [AGUI.Message]
appendLatestUser history Nothing = history
appendLatestUser history (Just nextMessage)
  | sameUser (listToMaybe (reverse history)) nextMessage = history
  | otherwise = history <> [nextMessage]
 where
  sameUser (Just (AGUI.User left)) (AGUI.User right) =
    AGUI.userId left == AGUI.userId right
      || AGUI.userContent left == AGUI.userContent right
  sameUser _ _ = False

latestUserMessage :: AGUI.RunAgentInput -> Maybe AGUI.Message
latestUserMessage = find user . reverse . AGUI.runMessages
 where
  user AGUI.User {} = True
  user _ = False

runServer :: Settings -> SessionStore -> TranscriptStore -> (Text -> IO Runtime) -> IO ()
runServer settings sessions transcripts runtimeFor =
  runSettings
    ( setPort (settingsPort settings)
        . setHost (fromString (settingsHost settings))
        $ defaultSettings
    )
    (application (settingsCorsOrigin settings) sessions transcripts runtimeFor)

encodeEvent :: Event -> Builder.Builder
encodeEvent event =
  Builder.byteString "data: "
    <> Builder.lazyByteString (encode event)
    <> Builder.byteString "\n\n"

jsonResponse :: Maybe Text -> Status -> Value -> Response
jsonResponse cors status value =
  responseLBS
    status
    (corsHeaders cors <> [(hContentType, "application/json; charset=utf-8")])
    (encode value)

message :: Text -> Value
message text = object ["error" .= text]

streamHeaders :: ResponseHeaders
streamHeaders =
  [ (hContentType, "text/event-stream; charset=utf-8"),
    (hCacheControl, "no-cache"),
    ("X-Accel-Buffering", "no")
  ]

preflightHeaders :: ResponseHeaders
preflightHeaders =
  [ ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
    ("Access-Control-Allow-Headers", "Content-Type"),
    ("Access-Control-Max-Age", "86400")
  ]

corsHeaders :: Maybe Text -> ResponseHeaders
corsHeaders = \case
  Nothing -> []
  Just origin ->
    [ ("Access-Control-Allow-Origin", TextEncoding.encodeUtf8 origin),
      (hVary, "Origin")
    ]
