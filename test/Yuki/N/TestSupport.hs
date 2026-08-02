module Yuki.N.TestSupport
  ( afterSpy,
    waitUntil,
    streamInput,
    cancelRequest,
    decodeChunks,
    contextConfig,
    contextConversation,
    isContextSummary,
    echoModel,
    echoTool,
    lastMessage,
    assertLeft,
    bigContent,
    staticTool,
    promptCaptureModel,
    jsonText,
    expectTextRight,
    retrieveWatcher,
    httpGet,
    withWorkDir,
    callTool,
    outcomeValue,
    taskIdOf,
    pollOf,
    withSandbox,
    sessionServiceAt,
    jsonRequest,
    okModel,
    testProvider,
    testSettings,
    testView,
    putConfig,
    agentPost,
    sampleInput,
    tool,
    fakeModel,
    testRuntime,
    collectEvents,
    takeEnd,
    transcriptHistory,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Bool (bool)
import Data.ByteString (ByteString)
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor (($>), (<&>))
import Data.IORef
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Network.HTTP.Types
import Network.Wai (Application, Request, pathInfo, requestHeaders, requestMethod, responseToStream, setRequestBodyChunks)
import Network.Wai.Internal (ResponseReceived (..))
import Network.Wai.Test
import System.Directory (createDirectoryIfMissing, createDirectoryLink, createFileLink, getTemporaryDirectory)
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Background
import Yuki.N.Config
import Yuki.N.Context
import Yuki.N.Model
import Yuki.N.Provider.OpenAI
import Yuki.N.Server
import Yuki.N.Sessions
import Yuki.N.ThreadConfig
import Yuki.N.Transcript

afterSpy :: IORef [[ChatMessage]] -> AgentHooks
afterSpy ref = defaultHooks {afterRun = \_ messages -> modifyIORef' ref (messages :)}
waitUntil :: IO Bool -> IO Bool
waitUntil probe = go (100 :: Int)
 where
  go 0 = pure False
  go n = probe >>= bool (threadDelay 50000 *> go (n - 1)) (pure True)
streamInput :: Application -> RunAgentInput -> IORef [Builder.Builder] -> MVar () -> IO ()
streamInput app input chunks done =
  newIORef (LazyByteString.toStrict (encode input)) >>= \body ->
    app (streamRequest body) respond $> ()
 where
  respond response =
    case responseToStream response of
      (_, _, withBody) ->
        withBody (\body -> body (\builder -> modifyIORef' chunks (builder :)) (pure ()))
          *> putMVar done ()
          $> ResponseReceived
streamRequest :: IORef ByteString -> Request
streamRequest body =
  setRequestBodyChunks (atomicModifyIORef' body (\current -> ("", current))) $
    defaultRequest
      { requestMethod = methodPost,
        pathInfo = ["agent"],
        requestHeaders = [(hContentType, "application/json")]
      }
cancelRequest :: Text -> SRequest
cancelRequest run =
  SRequest
    { simpleRequest =
        defaultRequest
          { requestMethod = methodPost,
            pathInfo = ["agent", "cancel"],
            requestHeaders = [(hContentType, "application/json")]
          },
      simpleRequestBody = encode (object ["runId" .= run])
    }
decodeChunks :: IORef [Builder.Builder] -> IO [Event]
decodeChunks ref =
  readIORef ref >>= decodeAll . foldl feed (emptySseDecoder, []) . fmap bytes . reverse
 where
  bytes = LazyByteString.toStrict . Builder.toLazyByteString
  feed (decoder, acc) chunk =
    let (decoder', decoded) = feedSse decoder chunk in (decoder', acc <> decoded)
  decodeAll (decoder, payloads) =
    let (_, trailing) = finishSse decoder
     in either assertFailure pure (traverse eitherDecodeStrict' (payloads <> trailing))
contextConfig :: ContextConfig
contextConfig = ContextConfig 64 4 96 4096
contextConversation :: [ChatMessage]
contextConversation = ChatSystem "local rules" : concatMap exchange [1 .. 12]
 where
  exchange index =
    [ ChatUser ("user-" <> label <> ": " <> Text.replicate 90 "u"),
      ChatAssistant
        ( AssistantTurn
            ("message-" <> label)
            (Just ("assistant-" <> label <> ": " <> Text.replicate 90 "a"))
            Nothing
            []
        )
    ]
   where
    label = Text.pack (show (index :: Int))
isContextSummary :: ChatMessage -> Bool
isContextSummary (ChatSystem text) = contextSummaryMarker `Text.isPrefixOf` text
isContextSummary _ = False
echoModel :: Model
echoModel = (fakeModel stream) {modelRender = requestValue testProvider}
 where
  stream req emit =
    case lastMessage req of
      Just (ChatToolResult {}) -> emit (ModelTextDelta "done") $> Stop
      _ -> emit (ModelToolCallDelta 0 (Just "call-echo") (Just "echo") "{\"x\":1}") $> ToolUse
echoTool :: BackendTool
echoTool = jsonTool (tool "echo") (\(value :: Value) -> pure (Right value))
lastMessage :: ModelRequest -> Maybe ChatMessage
lastMessage = listToMaybe . reverse . requestMessages
assertLeft :: Either e a -> Assertion
assertLeft = either (const (pure ())) (const (assertFailure "expected Left"))
bigContent :: Text
bigContent = Text.replicate 40 "0123456789abcdefghijklmnopqrstuvwxyz ABCDEF"
staticTool :: Text -> Text -> BackendTool
staticTool name content =
  BackendTool (tool name) (\_ _ -> pure (ToolOutcome content False False))
promptCaptureModel :: IORef [ChatMessage] -> Model
promptCaptureModel captured =
  fakeModel $ \req emit ->
    writeIORef captured (requestMessages req)
      *> emit (ModelTextDelta "# Generated Charter\nA model-generated, auditable charter.")
      $> Stop
jsonText :: (ToJSON value) => value -> Text
jsonText = TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode
expectTextRight :: Either Text value -> IO value
expectTextRight = either (assertFailure . Text.unpack) pure
retrieveWatcher :: Model
retrieveWatcher =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          "{\"summary\":\"s\",\"memorize\":[],\"retrieve\":{\"query\":\"deploy target\",\"reason\":\"need env\"}}"
      )
      $> Stop
httpGet :: [Text] -> Request
httpGet path = defaultRequest {requestMethod = methodGet, pathInfo = path}
withWorkDir :: (FilePath -> Assertion) -> Assertion
withWorkDir action = do
  tmp <- getTemporaryDirectory
  identifier <- newId
  let dir = tmp ++ "/" ++ Text.unpack identifier
  createDirectoryIfMissing True dir
  action dir

callTool :: [BackendTool] -> Text -> Value -> IO ToolOutcome
callTool tools name arguments =
  maybe (assertFailure ("missing tool: " <> Text.unpack name)) pure (find (named . backendToolSpec) tools)
    >>= \backend -> runBackendTool backend (ToolContext "run" "thread" "call" (const (pure ())) Nothing) arguments
 where
  named = (== name) . toolName
outcomeValue :: ToolOutcome -> IO Value
outcomeValue = either assertFailure pure . eitherDecodeStrict' . TextEncoding.encodeUtf8 . toolOutcomeContent
taskIdOf :: ToolOutcome -> IO Text
taskIdOf outcome =
  outcomeValue outcome >>= either assertFailure pure . parseEither (withObject "background" (.: "taskId"))
pollOf :: ToolOutcome -> IO (Bool, Maybe Int, Text, Bool)
pollOf outcome =
  outcomeValue outcome >>= either assertFailure pure . parseEither parse
 where
  parse =
    withObject "poll" $ \fields ->
      (,,,) <$> fields .: "running" <*> fields .:? "exitCode" <*> fields .: "output" <*> fields .: "truncated"
withSandbox :: (FilePath -> Assertion) -> Assertion
withSandbox action = do
  tmp <- getTemporaryDirectory
  identifier <- newId
  let base = tmp ++ "/" ++ Text.unpack identifier
      root = base ++ "/work"
      outside = base ++ "/outside"
  createDirectoryIfMissing True (root ++ "/sub")
  createDirectoryIfMissing True outside
  TextIO.writeFile (outside ++ "/secret.txt") "TOP-SECRET\n"
  TextIO.writeFile (root ++ "/sub/ok.txt") "fine\n"
  createFileLink (outside ++ "/secret.txt") (root ++ "/linkfile.txt")
  createFileLink "linkfile.txt" (root ++ "/chain.txt")
  createDirectoryLink outside (root ++ "/linkdir")
  createDirectoryLink "sub" (root ++ "/inner")
  createDirectoryLink ".." (root ++ "/sub/up")
  action root
sessionServiceAt :: FilePath -> (Text -> IO ()) -> IO SessionService
sessionServiceAt dir cleanup =
  SessionService
    <$> newSessionStore dir
    <*> newTranscriptStore dir
    <*> newThreadConfigStore dir
    <*> pure cleanup
jsonRequest :: (ToJSON body) => Method -> [Text] -> body -> SRequest
jsonRequest method path body =
  SRequest
    { simpleRequest =
        defaultRequest
          { requestMethod = method,
            pathInfo = path,
            requestHeaders = [(hContentType, "application/json")]
          },
      simpleRequestBody = encode body
    }
okModel :: Model
okModel = fakeModel (\_ emit -> emit (ModelTextDelta "ok") $> Stop)
testProvider :: OpenAIConfig
testProvider = OpenAIConfig "fake" "base-model" "http://localhost" "provider-secret" OpenAICompatible ThinkingDisabled Nothing (Just 65536)
testSettings :: Settings
testSettings =
  either (error . Text.unpack) id (resolveSettings (Map.singleton "DEEPSEEK_API_KEY" "super-secret-key-123"))
testView :: ThreadConfigStore -> ConfigView
testView store = ConfigView (renderGlobalConfig testSettings defaults) store defaults (pure (Right [])) (pure [])
 where
  defaults = globalThreadConfig testSettings
putConfig :: Text -> LazyByteString.ByteString -> SRequest
putConfig threadId body =
  SRequest
    { simpleRequest =
        defaultRequest
          { requestMethod = methodPut,
            pathInfo = ["config", "threads", threadId],
            requestHeaders = [(hContentType, "application/json")]
          },
      simpleRequestBody = body
    }
agentPost :: Text -> SRequest
agentPost threadId =
  SRequest
    { simpleRequest =
        defaultRequest
          { requestMethod = methodPost,
            pathInfo = ["agent"],
            requestHeaders = [(hContentType, "application/json")]
          },
      simpleRequestBody = encode ((sampleInput []) {runThreadId = threadId})
    }
sampleInput :: [ToolSpec] -> RunAgentInput
sampleInput tools =
  RunAgentInput
    { runThreadId = "thread",
      runId = "run",
      runParentId = Nothing,
      runState = object [],
      runMessages = [User (UserMessage "user" (UserText "hello") Nothing)],
      runTools = tools,
      runContext = [],
      runForwardedProps = object []
    }
tool :: Text -> ToolSpec
tool name =
  ToolSpec
    { toolName = name,
      toolDescription = name,
      toolParameters = object ["type" .= ("object" :: Text), "properties" .= object []]
    }
fakeModel :: (ModelRequest -> (ModelEvent -> IO ()) -> IO FinishReason) -> Model
fakeModel stream = Model "fake" "fake" Nothing stream (const (object []))
testRuntime :: Model -> [BackendTool] -> ToolExecution -> IO Runtime
testRuntime model tools execution =
  newIORef (0 :: Int) >>= \counter ->
    newBackgroundRegistry <&> \background ->
      Runtime
        { runtimeModel = model,
          runtimeTools = Map.fromList [(toolName (backendToolSpec backend), backend) | backend <- tools],
          runtimeToolExecution = execution,
          runtimeMaxTurns = 8,
          runtimeSystemPrompt = "",
          runtimeHooks = defaultHooks,
          runtimeNewId =
            atomicModifyIORef' counter (\value -> let next = value + 1 in (next, next))
              <&> ("id-" <>) . Text.pack . show,
          runtimeJournal = Nothing,
          runtimeArtifactStore = Nothing,
          runtimeBackground = background,
          runtimeDepth = 1,
          runtimeProviderRetries = 0,
          runtimeFallbacks = [],
          runtimeSplice = Nothing,
          runtimeContext = Nothing,
          runtimeRuns = Nothing,
          runtimeIdentity = defaultIdentity,
          runtimeSteer = const (pure []),
          runtimeFollowUp = const (pure [])
        }
collectEvents :: Runtime -> RunAgentInput -> IO [Event]
collectEvents runtime input = newIORef [] >>= collect
 where
  collect events =
    runAgent runtime input (\event -> modifyIORef' events (event :))
      *> (reverse <$> readIORef events)
takeEnd :: Int -> [value] -> [value]
takeEnd count values = drop (length values - count) values
transcriptHistory :: [ChatMessage]
transcriptHistory =
  [ ChatUser "hi",
    ChatAssistant (AssistantTurn "m-1" (Just "working") (Just "thinking") [ModelToolCall "c-1" "echo" "{\"x\":1}"]),
    ChatToolResult "c-1" "echoed",
    ChatAssistant (AssistantTurn "m-2" (Just "done") Nothing [])
  ]
