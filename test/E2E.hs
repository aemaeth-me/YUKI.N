module E2E
  ( e2eTests,
    Reply (..),
    FakeProvider (..),
    newFakeProvider,
    fakeProvider,
    e2eSettings,
    wiredRuntime,
    agentInput,
    postAgent,
    decodeEvents,
    withSandbox,
    roleChunk,
    textChunk,
    finishChunk,
    toolCallChunk,
    toolCallArgs,
  )
where

import Control.Concurrent.MVar (MVar, readMVar)
import Control.Monad ((>=>))
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither, parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor ((<&>))
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Client (Manager, defaultManagerSettings, newManager)
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types (Message (User), RunAgentInput (..), UserContent (..), UserMessage (..))
import Yuki.N.Agent
import Yuki.N.Artifact (ArtifactStore)
import Yuki.N.Background (newBackgroundRegistry)
import Yuki.N.Config (Settings (..))
import Yuki.N.Model
import Yuki.N.Provider.OpenAI
import Yuki.N.Server (application)
import Yuki.N.ThreadConfig (globalThreadConfig, resolveRuntime)

e2eTests :: TestTree
e2eTests =
  testGroup
    "e2e over a real socket provider"
    [ testCase "streams a plain text answer end to end" plainText,
      testCase "runs a tool round trip and feeds the result back" toolRound,
      testCase "retries 429s and announces provider.retry before succeeding" retryThenSuccess,
      testCase "forwards the usage frame as a usage event" usageFlow,
      testCase "fails the run with PROVIDER_ERROR on a constant 500" providerDown,
      testCase "falls back to a second provider on its own socket" fallbackAcrossProviders,
      testCase "uses DeepSeek Responses events for text and tools" deepSeekResponses,
      testCase "lists models from the fake provider" modelsListing
    ]

-- fake provider: a scripted wai app served by warp on a real socket

data Reply
  = Sse [ByteString]
  | ResponsesSse [ByteString]
  | Failure Status ByteString

data FakeProvider = FakeProvider
  { providerScript :: IORef [Reply],
    providerBodies :: IORef [Value],
    providerGate :: Maybe (MVar ())
  }

newFakeProvider :: [Reply] -> IO FakeProvider
newFakeProvider script = FakeProvider <$> newIORef script <*> newIORef [] <*> pure Nothing

fakeProvider :: FakeProvider -> Application
fakeProvider provider req respond = route (requestMethod req) (pathInfo req)
 where
  route "POST" ["chat", "completions"] = completion >>= respond
  route "POST" ["responses"] = completion >>= respond
  route "GET" ["models"] = respond (responseLBS status200 jsonHeaders modelsPayload)
  route _ _ = respond (responseLBS status404 [] "unknown route")
  completion = (strictRequestBody req >>= traverse_ record . decode) *> hold *> pop
  record body = modifyIORef' (providerBodies provider) (body :)
  hold = traverse_ readMVar (providerGate provider)
  pop = atomicModifyIORef' (providerScript provider) next <&> replyResponse
  next (reply : rest) = (rest, Just reply)
  next [] = ([], Nothing)

replyResponse :: Maybe Reply -> Response
replyResponse (Just (Failure status body)) = responseLBS status jsonHeaders (LazyByteString.fromStrict body)
replyResponse (Just (Sse payloads)) =
  responseStream status200 sseHeaders $ \write flush ->
    traverse_ (frame write flush) payloads *> write "data: [DONE]\n\n" *> flush
 where
  frame write flush payload =
    write (Builder.byteString "data: " <> Builder.byteString prefix)
      *> flush
      *> write (Builder.byteString suffix <> Builder.byteString "\n\n")
      *> flush
   where
    (prefix, suffix) = ByteString.splitAt (ByteString.length payload `div` 2) payload
replyResponse (Just (ResponsesSse payloads)) =
  responseStream status200 sseHeaders $ \write flush -> traverse_ (frame write flush) payloads
 where
  frame write flush payload = write (Builder.byteString "data: " <> Builder.byteString payload <> Builder.byteString "\n\n") *> flush
replyResponse _ = responseLBS status500 [] "fake provider script exhausted"

jsonHeaders :: ResponseHeaders
jsonHeaders = [(hContentType, "application/json")]

sseHeaders :: ResponseHeaders
sseHeaders = [(hContentType, "text/event-stream"), (hCacheControl, "no-cache")]

modelsPayload :: LazyByteString.ByteString
modelsPayload = "{\"object\":\"list\",\"data\":[{\"id\":\"e2e-model\",\"object\":\"model\"}]}"

-- provider stream chunks, serialized by hand (never through production code)

jsonChunk :: Text -> Text -> ByteString
jsonChunk delta finish =
  TextEncoding.encodeUtf8
    ( "{\"id\":\"chatcmpl-e2e\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":"
        <> delta
        <> ",\"finish_reason\":"
        <> finish
        <> "}]}"
    )

escape :: Text -> Text
escape = Text.concatMap escapeChar
 where
  escapeChar '"' = "\\\""
  escapeChar '\\' = "\\\\"
  escapeChar char = Text.singleton char

roleChunk :: ByteString
roleChunk = jsonChunk "{\"role\":\"assistant\"}" "null"

textChunk :: Text -> ByteString
textChunk text = jsonChunk ("{\"content\":\"" <> escape text <> "\"}") "null"

finishChunk :: Text -> ByteString
finishChunk reason = jsonChunk "{}" ("\"" <> reason <> "\"")

emptyChoicesChunk :: ByteString
emptyChoicesChunk = "{\"id\":\"chatcmpl-e2e\",\"object\":\"chat.completion.chunk\",\"choices\":[]}"

usageChunk :: ByteString
usageChunk =
  "{\"id\":\"chatcmpl-e2e\",\"object\":\"chat.completion.chunk\",\"choices\":[],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":7,\"prompt_cache_hit_tokens\":2,\"prompt_cache_miss_tokens\":9}}"

toolCallChunk :: Text -> Text -> ByteString
toolCallChunk callId name =
  jsonChunk
    ( "{\"tool_calls\":[{\"index\":0,\"id\":\""
        <> callId
        <> "\",\"type\":\"function\",\"function\":{\"name\":\""
        <> name
        <> "\",\"arguments\":\"\"}}]}"
    )
    "null"

toolCallHead :: ByteString
toolCallHead = toolCallChunk "call-fs" "fs_list"

toolCallArgs :: Text -> ByteString
toolCallArgs fragment =
  jsonChunk
    ("{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"" <> escape fragment <> "\"}}]}")
    "null"

-- runtime wiring, mirroring Yuki.N: hand-made Settings, production resolution

fakeConfig :: Int -> OpenAIConfig
fakeConfig port =
  OpenAIConfig "e2e" "e2e-model" ("http://127.0.0.1:" <> Text.pack (show port)) "e2e-secret" OpenAICompatible ThinkingDisabled Nothing (Just 65536)

deepSeekConfig :: Int -> OpenAIConfig
deepSeekConfig port =
  OpenAIConfig "deepseek" "deepseek-v4-flash" ("http://127.0.0.1:" <> Text.pack (show port)) "e2e-secret" DeepSeek (ThinkingEnabled High) Nothing (Just 1000000)

e2eSettings :: Int -> FilePath -> Int -> Settings
e2eSettings port workDir retries =
  Settings
    { settingsHost = "127.0.0.1",
      settingsPort = 0,
      settingsDataDir = workDir ++ "/.yuki-n",
      settingsCorsOrigin = Nothing,
      settingsMaxTurns = 8,
      settingsToolExecution = Parallel,
      settingsSystemPrompt = "",
      settingsJournalDir = Nothing,
      settingsArtifactDir = Nothing,
      settingsTranscriptDir = Nothing,
      settingsWorkDir = Just workDir,
      settingsMemoryDir = Nothing,
      settingsMemoryModel = Nothing,
      settingsSubAgentDepth = 1,
      settingsSubAgentMaxParallel = 4,
      settingsProviderRetries = retries,
      settingsSpliceChars = 200000,
      settingsSpliceKeep = 4,
      settingsContextReserveTokens = 8192,
      settingsContextKeepUnits = 12,
      settingsContextSummaryTokens = 2048,
      settingsDispatchGenerateTimeout = 20,
      settingsTelemetryGit = True,
      settingsTelemetryGitTimeout = 3,
      settingsTelemetryDiffBytes = 8192,
      settingsProvider = fakeConfig port,
      settingsFallbackProviders = []
    }

wiredRuntime :: Manager -> Maybe ArtifactStore -> Settings -> IO Runtime
wiredRuntime manager artifacts settings = do
  counter <- newIORef (0 :: Int)
  background <- newBackgroundRegistry
  resolveRuntime manager provider artifacts (base counter background) (globalThreadConfig settings) Map.empty Map.empty
 where
  provider = settingsProvider settings
  base counter background =
    Runtime
      { runtimeModel = openAIModel manager provider,
        runtimeTools = Map.empty,
        runtimeToolExecution = settingsToolExecution settings,
        runtimeMaxTurns = settingsMaxTurns settings,
        runtimeSystemPrompt = settingsSystemPrompt settings,
        runtimeHooks = defaultHooks,
        runtimeNewId =
          atomicModifyIORef' counter (\value -> (value + 1, value + 1))
            <&> \next -> "msg-" <> Text.pack (show next),
        runtimeJournal = Nothing,
        runtimeArtifactStore = Nothing,
        runtimeBackground = background,
        runtimeDepth = settingsSubAgentDepth settings,
        runtimeSubAgentMaxParallel = settingsSubAgentMaxParallel settings,
        runtimeProviderRetries = settingsProviderRetries settings,
        runtimeFallbacks = [],
        runtimeSplice = Nothing,
        runtimeContext = Nothing,
        runtimeRuns = Nothing,
        runtimeTelemetry = Nothing,
        runtimeIdentity = defaultIdentity,
        runtimeSteer = const (pure []),
        runtimeFollowUp = const (pure [])
      }

-- AG-UI client side: POST /agent through the real server, decode the SSE stream

agentInput :: RunAgentInput
agentInput =
  RunAgentInput "e2e-thread" "e2e-run" Nothing (object []) [User (UserMessage "user-1" (UserText "hello") Nothing)] [] [] (object [])

postAgent :: Session SResponse
postAgent =
  srequest
    SRequest
      { simpleRequest =
          defaultRequest
            { requestMethod = methodPost,
              pathInfo = ["agent"],
              requestHeaders = [(hContentType, "application/json")]
            },
        simpleRequestBody = encode agentInput
      }

decodeEvents :: SResponse -> IO [Event]
decodeEvents response =
  (simpleStatus response @?= status200)
    *> (lookup hContentType (simpleHeaders response) @?= Just "text/event-stream; charset=utf-8")
    *> traverse decodeOne (payloadsOf (simpleBody response))
 where
  decodeOne = either (assertFailure . ("invalid AG-UI event: " <>)) pure . eitherDecodeStrict'

payloadsOf :: LazyByteString.ByteString -> [ByteString]
payloadsOf = mapMaybe (ByteString.stripPrefix "data: ") . Char8.lines . LazyByteString.toStrict

drive :: FilePath -> Int -> [Reply] -> ([Event] -> [Value] -> Assertion) -> Assertion
drive workDir retries script assertions = do
  provider <- newFakeProvider script
  testWithApplication (pure (fakeProvider provider)) (run provider)
 where
  run provider port = do
    manager <- newManager defaultManagerSettings
    runtime <- wiredRuntime manager Nothing (e2eSettings port workDir retries)
    events <- runSession postAgent (application Nothing Nothing Nothing Nothing Nothing Nothing (const (pure runtime))) >>= decodeEvents
    recorded <- reverse <$> readIORef (providerBodies provider)
    assertions events recorded

withSandbox :: (FilePath -> IO a) -> IO a
withSandbox action = do
  tmp <- getTemporaryDirectory
  ident <- newId
  let dir = tmp ++ "/" ++ Text.unpack ident
  createDirectoryIfMissing True dir
  writeFile (dir ++ "/marker.txt") "marker payload"
  action dir

-- assertions on the request bodies the provider recorded

data WireMessage = WireMessage Text (Maybe Text) (Maybe Text) [Value]

wireMessagesOf :: Value -> Either String [WireMessage]
wireMessagesOf = parseEither (withObject "request" ((.: "messages") >=> traverse message))
 where
  message =
    withObject "message" $ \fields ->
      WireMessage
        <$> fields .: "role"
        <*> fields .:? "content"
        <*> fields .:? "tool_call_id"
        <*> fields .:? "tool_calls" .!= []

wireContents :: Value -> Maybe [Text]
wireContents = parseMaybe (withObject "request" ((.: "messages") >=> traverse (withObject "message" (.: "content"))))

wireToolNames :: Value -> Maybe [Text]
wireToolNames = parseMaybe (withObject "request" ((.: "tools") >=> traverse toolNameOf))

toolNameOf :: Value -> Parser Text
toolNameOf = withObject "tool" (\fields -> fields .: "function" >>= withObject "function" (.: "name"))

-- small event predicates and shaped expectations

isTextStart :: Event -> Bool
isTextStart TextMessageStarted {} = True
isTextStart _ = False

isRunFinished :: Event -> Bool
isRunFinished RunFinished {} = True
isRunFinished _ = False

isRunError :: Event -> Bool
isRunError RunError {} = True
isRunError _ = False

expectOne :: [value] -> IO value
expectOne [value] = pure value
expectOne other = assertFailure ("expected exactly one item, got " <> show (length other))

expectTwo :: [value] -> IO (value, value)
expectTwo [first, second] = pure (first, second)
expectTwo other = assertFailure ("expected exactly two items, got " <> show (length other))

expectSubstring :: String -> Text -> [Text] -> Assertion
expectSubstring label needle [content] =
  assertBool (label <> ": missing " <> Text.unpack needle) (needle `Text.isInfixOf` content)
expectSubstring label _ other =
  assertFailure (label <> ": expected exactly one payload, got " <> show (length other))

-- scenarios

deepSeekResponses :: Assertion
deepSeekResponses = do
  provider <- newFakeProvider script
  testWithApplication (pure (fakeProvider provider)) $ \port -> do
    manager <- newManager defaultManagerSettings
    textEvents <- newIORef []
    toolEvents <- newIORef []
    let model = openAIModel manager (deepSeekConfig port)
        run events req = streamModel model req (\event -> modifyIORef' events (<> [event]))
    textFinish <- run textEvents (ModelRequest [ChatUser "hello"] [])
    toolFinish <- run toolEvents (ModelRequest [ChatUser "use a tool"] [])
    textSeen <- readIORef textEvents
    toolSeen <- readIORef toolEvents
    requests <- reverse <$> readIORef (providerBodies provider)
    textFinish @?= Stop
    textSeen @?= [ModelReasoningDelta "thinking", ModelTextDelta "flash", ModelUsage (Usage (Just 11) (Just 7) (Just 2) (Just 9))]
    toolFinish @?= ToolUse
    toolSeen @?= [ModelToolCallDelta 0 (Just "call-1") (Just "lookup") "", ModelToolCallDelta 0 Nothing Nothing "{\"query\":\"yuki\"}", ModelUsage (Usage (Just 8) (Just 4) (Just 0) (Just 8))]
    traverse responseShape requests @?= Just [True, True]
 where
  script =
    [ ResponsesSse
        [ "{\"event\":\"response.reasoning_text.delta\",\"sequence_number\":1,\"output_index\":0,\"delta\":\"thinking\"}",
          "{\"event\":\"response.output_text.delta\",\"sequence_number\":2,\"output_index\":0,\"delta\":\"flash\"}",
          "{\"event\":\"response.completed\",\"sequence_number\":3,\"response\":{\"usage\":{\"input_tokens\":11,\"output_tokens\":7,\"input_tokens_details\":{\"cached_tokens\":2}}}}"
        ],
      ResponsesSse
        [ "{\"event\":\"response.output_item.added\",\"sequence_number\":1,\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc-1\",\"call_id\":\"call-1\",\"name\":\"lookup\",\"arguments\":\"\"}}",
          "{\"event\":\"response.function_call_arguments.delta\",\"sequence_number\":2,\"output_index\":0,\"delta\":\"{\\\"query\\\":\\\"yuki\\\"}\"}",
          "{\"event\":\"response.completed\",\"sequence_number\":3,\"response\":{\"usage\":{\"input_tokens\":8,\"output_tokens\":4,\"input_tokens_details\":{\"cached_tokens\":0}}}}"
        ]
    ]
  responseShape =
    parseMaybe
      ( withObject "response request" $ \fields ->
          (\model -> model == ("deepseek-v4-flash" :: Text) && KeyMap.member "input" fields && not (KeyMap.member "messages" fields)) <$> fields .: "model"
      )

plainText :: Assertion
plainText =
  withSandbox $ \workDir ->
    drive workDir 1 script $ \events requests ->
      expectOne requests >>= \body ->
        sequence_
          [ [delta | TextMessageContent _ delta <- events] @?= ["你好，", "world"],
            [messageId | TextMessageStarted messageId <- events] @?= ["msg-1"],
            isRunFinished (last events) @?= True,
            length [() | RunError {} <- events] @?= 0,
            wireStream body @?= Just True,
            wireContents body @?= Just ["hello"],
            fmap ("fs_list" `elem`) (wireToolNames body) @?= Just True
          ]
 where
  script = [Sse [roleChunk, textChunk "你好，", emptyChoicesChunk, textChunk "world", finishChunk "stop"]]
  wireStream = parseMaybe (withObject "request" (.: "stream"))

toolRound :: Assertion
toolRound = withSandbox $ \workDir ->
  drive workDir 1 script $ \events requests -> do
    (first, second) <- expectTwo requests
    fedBack <- either assertFailure pure (wireMessagesOf second)
    [name | ToolCallStarted _ name _ <- events] @?= ["fs_list"]
    Text.concat [fragment | ToolCallArguments _ fragment <- events] @?= "{\"path\":\".\"}"
    length [() | ToolCallEnded "call-fs" <- events] @?= 1
    expectSubstring "tool result lists the sandbox" "marker.txt" [content | ToolCallResult _ "call-fs" content <- events]
    [delta | TextMessageContent _ delta <- events] @?= ["listed"]
    isRunFinished (last events) @?= True
    wireContents first @?= Just ["hello"]
    [name | WireMessage "assistant" _ _ calls <- fedBack, name <- mapMaybe (parseMaybe toolNameOf) calls] @?= ["fs_list"]
    expectSubstring "tool result reaches the provider" "marker.txt" [content | WireMessage "tool" (Just content) (Just "call-fs") _ <- fedBack]
 where
  script =
    [ Sse [roleChunk, toolCallHead, toolCallArgs "{\"path\":", toolCallArgs "\".\"}", finishChunk "tool_calls"],
      Sse [roleChunk, textChunk "listed", finishChunk "stop"]
    ]

retryThenSuccess :: Assertion
retryThenSuccess =
  withSandbox $ \workDir ->
    drive workDir 3 script $ \events requests ->
      sequence_
        [ [attempt | Custom "provider.retry" value <- events, Just attempt <- [retryAttempt value]] @?= [1, 2],
          retriesBeforeText events @?= 2,
          [delta | TextMessageContent _ delta <- events] @?= ["recovered"],
          isRunFinished (last events) @?= True,
          length requests @?= 3
        ]
 where
  script =
    [ Failure status429 "{\"error\":{\"message\":\"slow down\"}}",
      Failure status429 "{\"error\":{\"message\":\"slow down\"}}",
      Sse [roleChunk, textChunk "recovered", finishChunk "stop"]
    ]
  retryAttempt :: Value -> Maybe Int
  retryAttempt = parseMaybe (withObject "retry" (.: "attempt"))
  retriesBeforeText = length . filter isRetry . takeWhile (not . isTextStart)
  isRetry (Custom "provider.retry" _) = True
  isRetry _ = False

usageFlow :: Assertion
usageFlow =
  withSandbox $ \workDir ->
    drive workDir 1 script $ \events _ ->
      expectOne [value | Custom "usage" value <- events] >>= \value ->
        sequence_
          [ usageNumber "promptTokens" value @?= Just 11,
            usageNumber "completionTokens" value @?= Just 7,
            usageNumber "cacheHitTokens" value @?= Just 2,
            usageNumber "cacheMissTokens" value @?= Just 9,
            isRunFinished (last events) @?= True
          ]
 where
  script = [Sse [roleChunk, textChunk "metered", finishChunk "stop", usageChunk]]
  usageNumber :: Text -> Value -> Maybe Int
  usageNumber key = parseMaybe (withObject "usage" (.: Key.fromText key))

providerDown :: Assertion
providerDown =
  withSandbox $ \workDir ->
    drive workDir 1 script $ \events requests ->
      expectOne [message | RunError message _ <- events] >>= \message ->
        sequence_
          [ [code | RunError _ (Just code) <- events] @?= ["PROVIDER_ERROR"],
            assertBool "error mentions the status" (Text.isInfixOf "500" message),
            assertBool "error mentions the provider body" (Text.isInfixOf "boom" message),
            isRunError (last events) @?= True,
            length [() | RunFinished {} <- events] @?= 0,
            length requests @?= 1
          ]
 where
  script = [Failure status500 "{\"error\":{\"message\":\"boom\"}}"]

fallbackAcrossProviders :: Assertion
fallbackAcrossProviders = withSandbox $ \workDir -> do
  primary <- newFakeProvider [Failure status500 "{\"error\":{\"message\":\"boom\"}}"]
  backup <- newFakeProvider [Sse [roleChunk, textChunk "backup answer", finishChunk "stop"]]
  manager <- newManager defaultManagerSettings
  testWithApplication (pure (fakeProvider primary)) $ \primaryPort ->
    testWithApplication (pure (fakeProvider backup)) $ \backupPort -> do
      runtime <- wiredRuntime manager Nothing (e2eSettings primaryPort workDir 1)
      events <- runSession postAgent (serving runtime backupPort manager) >>= decodeEvents
      primaryRequests <- readIORef (providerBodies primary)
      backupRequests <- readIORef (providerBodies backup)
      [() | Custom "provider.fallback" _ <- events] @?= [()]
      [delta | TextMessageContent _ delta <- events] @?= ["backup answer"]
      isRunFinished (last events) @?= True
      length primaryRequests @?= 1
      length backupRequests @?= 1
 where
  serving runtime backupPort manager =
    application
      Nothing
      Nothing
      Nothing
      Nothing
      Nothing
      Nothing
      (const (pure runtime {runtimeFallbacks = [openAIModel manager (fakeConfig backupPort)]}))

modelsListing :: Assertion
modelsListing = do
  provider <- newFakeProvider []
  manager <- newManager defaultManagerSettings
  testWithApplication (pure (fakeProvider provider)) $ \port -> do
    models <- fetchModelIds manager (fakeConfig port)
    models @?= Right ["e2e-model"]
