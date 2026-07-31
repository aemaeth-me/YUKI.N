module Main (main) where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (IOException, SomeException, throwIO, try)
import Data.Aeson
import Control.Monad ((>=>))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Parser, parseEither, parseMaybe)
import Data.Bool (bool)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.IORef
import Data.List (find, nub, sort, unfoldr)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as TextIO
import E2E (e2eTests)
import Golden (goldenTests)
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types
import Network.Wai (Application, Request, pathInfo, queryString, requestBody, requestHeaders, requestMethod, responseLBS, responseToStream)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Internal (ResponseReceived (..))
import Network.Wai.Test
import System.Directory
  ( createDirectoryIfMissing,
    createDirectoryLink,
    createFileLink,
    doesFileExist,
    emptyPermissions,
    getPermissions,
    getTemporaryDirectory,
    setPermissions,
  )
import System.FilePath (takeDirectory)
import System.Exit (ExitCode (..))
import System.Process (getProcessExitCode, readProcessWithExitCode)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.AgentsMd
import Yuki.N.Anatomy
import Yuki.N.Artifact
import Yuki.N.Background
import Yuki.N.Blob
import Yuki.N.Config
import Yuki.N.Cognition
import Yuki.N.Context
import Yuki.N.ContextEpoch
import Yuki.N.Diff
import Yuki.N.Experience
import Yuki.N.Facts
import Yuki.N.Inspect
import Yuki.N.Incarnation
import Yuki.N.Journal
import Yuki.N.Memory
import Yuki.N.Memory.Archive
import Yuki.N.Memory.Impression
import Yuki.N.Memory.LongTerm
import Yuki.N.Memory.Working
import Yuki.N.Model
import Yuki.N.Provider.OpenAI
import Yuki.N.Providers
import Yuki.N.Replay
import Yuki.N.Runs
import Yuki.N.Server
import Yuki.N.Sessions
import Yuki.N.SubAgent
import Yuki.N.ThreadConfig
import Yuki.N.Tools
import Yuki.N.Transcript

main :: IO ()
main =
  defaultMain $
    testGroup
      "yuki-n"
      [ protocolTests,
        providerTests,
        providersTests,
        agentTests,
        terminationTests,
        steeringTests,
        retryTests,
        fallbackTests,
        spliceTests,
        contextTests,
        subAgentTests,
        hooksTests,
        machineTests,
        auditTests,
        anatomyTests,
        artifactTests,
        memoryTests,
        cognitionTests,
        factsTests,
        serverTests,
        configTests,
        workToolTests,
        planTests,
        adversarialTests,
        threadConfigTests,
        sessionTests,
        growthTests,
        agentsMdTests,
        transcriptTests,
        e2eTests,
        goldenTests
      ]

protocolTests :: TestTree
protocolTests =
  testGroup
    "AG-UI protocol"
    [ testCase "accepts snake_case aliases at the boundary" aliases,
      testCase "encodes normalized tool-result events" $
        toJSON (ToolCallResult "message" "call" "ok")
          @?= object
            [ "type" .= ("TOOL_CALL_RESULT" :: Text),
              "messageId" .= ("message" :: Text),
              "toolCallId" .= ("call" :: Text),
              "content" .= ("ok" :: Text),
              "role" .= ("tool" :: Text)
            ]
    ]
  where
    aliases =
      either assertFailure verify . eitherDecode $
        "{\"thread_id\":\"thread\",\"run_id\":\"run\",\"messages\":[{\"id\":\"user\",\"role\":\"user\",\"content\":\"hello\"}]}"
    verify input =
      sequence_
        [ runThreadId input @?= "thread",
          runId input @?= "run",
          runMessages input @?= [User (UserMessage "user" (UserText "hello") Nothing)]
        ]

providerTests :: TestTree
providerTests =
  testGroup
    "provider stream"
    [ testCase "decodes fragmented CRLF SSE frames" fragmented,
      testCase "joins multiline SSE data fields" multiline,
      testCase "maps chunk deltas to model events" chunkDeltas,
      testCase "parses finish reasons" chunkFinish,
      testCase "rejects provider error chunks" chunkError,
      testCase "requests usage on the wire" wireOptions,
      testCase "serializes provider-specific thinking controls" thinkingWire,
      testCase "serializes DeepSeek Responses input and tools" responsesWire,
      testCase "attaches usage from the final frame" usageFrame
    ]
  where
    fragmented =
      let (first, firstEvents) = feedSse emptySseDecoder "data: {\"value\":"
          (second, secondEvents) = feedSse first "1}\r\n\r\n"
          (_, finalEvents) = finishSse second
       in sequence_ [firstEvents @?= [], secondEvents <> finalEvents @?= ["{\"value\":1}"]]
    multiline =
      let (decoder, events) = feedSse emptySseDecoder "data: one\ndata: two\n\n"
          (_, finalEvents) = finishSse decoder
       in events <> finalEvents @?= ["one\ntwo"]
    chunkDeltas =
      chunkEvents
        ( ChatChunk
            [ ChatChoice
                0
                ( ChatDelta
                    (Just "text")
                    (Just "reasoning")
                    [DeltaToolCall 1 (Just "call") (Just (DeltaFunction (Just "echo") (Just "a")))]
                )
                Nothing
            ]
            Nothing
            Nothing
        )
        @?= Right
          ( [ ModelReasoningDelta "reasoning",
              ModelTextDelta "text",
              ModelToolCallDelta 1 (Just "call") (Just "echo") "a"
            ],
            Nothing
          )
    chunkFinish =
      chunkEvents (ChatChunk [ChatChoice 0 emptyDelta' (Just "tool_calls")] Nothing Nothing)
        @?= Right ([], Just ToolUse)
    chunkError =
      assertLeft (chunkEvents (ChatChunk [] (Just (object ["message" .= ("boom" :: Text)])) Nothing))
    wireOptions =
      ( parseMaybe (withObject "wire" (.: "stream_options")) rendered
          >>= parseMaybe (withObject "options" (.: "include_usage"))
      )
        @?= Just True
      where
        rendered = requestValue testProvider (ModelRequest [] [])
    thinkingWire =
      let deepseek = testProvider {openAIProvider = "deepseek", openAIDialect = DeepSeek, openAIThinking = ThinkingEnabled Max}
          zai = testProvider {openAIProvider = "zai", openAIThinking = ThinkingEnabled High}
          kimi = testProvider {openAIProvider = "kimi-coding", openAIThinking = ThinkingEnabled Low}
          history = ModelRequest [ChatAssistant (AssistantTurn "assistant" Nothing (Just "kept") [])] []
          field name = parseMaybe (withObject "request" (maybe (fail "missing") pure . KeyMap.lookup name))
          thinkingType = (>>= parseMaybe (withObject "thinking" (.: "type"))) . field "thinking"
          effort = (>>= parseMaybe (withText "effort" pure)) . field "reasoning_effort"
          responseEffort = (>>= parseMaybe (withObject "reasoning" (.: "effort"))) . field "reasoning"
          reasoning =
            field "messages" (requestValue kimi history)
              >>= parseMaybe parseJSON
              >>= listToMaybe
              >>= parseMaybe (withObject "message" (.: "reasoning_content"))
       in sequence_
            [ thinkingType (requestValue deepseek (ModelRequest [] [])) @?= Nothing,
              responseEffort (requestValue deepseek (ModelRequest [] [])) @?= Just ("max" :: Text),
              thinkingType (requestValue zai (ModelRequest [] [])) @?= Just ("enabled" :: Text),
              field "reasoning_effort" (requestValue zai (ModelRequest [] [])) @?= Nothing,
              field "thinking" (requestValue kimi (ModelRequest [] [])) @?= Nothing,
              effort (requestValue kimi (ModelRequest [] [])) @?= Just ("low" :: Text),
              reasoning @?= Just ("kept" :: Text)
            ]
    responsesWire =
      let provider = testProvider {openAIProvider = "deepseek", openAIModelName = "deepseek-v4-flash", openAIDialect = DeepSeek}
          call = ModelToolCall "call-1" "lookup" "{\"query\":\"yuki\"}"
          turn = AssistantTurn "assistant-1" (Just "answer") (Just "thought") [call]
          tool = ToolSpec "lookup" "Find something" (object ["type" .= ("object" :: Text)])
          rendered = requestValue provider (ModelRequest [ChatSystem "system", ChatUser "hello", ChatAssistant turn, ChatToolResult "call-1" "found"] [tool])
          field name = parseMaybe (withObject "request" (maybe (fail "missing") pure . KeyMap.lookup name)) rendered
          input = parseMaybe (withObject "request" (.: "input")) rendered :: Maybe [Value]
          tools = parseMaybe (withObject "request" (.: "tools")) rendered :: Maybe [Value]
          inputTypes :: Maybe [Text]
          inputTypes = input >>= traverse (parseMaybe (withObject "item" (.: "type")))
          toolNames :: Maybe [Text]
          toolNames = tools >>= traverse (parseMaybe (withObject "tool" (.: "name")))
          callIds :: Maybe [Maybe Text]
          callIds = input >>= traverse (parseMaybe (withObject "item" (.:? "call_id")))
       in sequence_
            [ field "messages" @?= Nothing,
              field "stream_options" @?= Nothing,
              field "model" @?= Just (String "deepseek-v4-flash"),
              inputTypes @?= Just ["message", "message", "reasoning", "message", "function_call", "function_call_output"],
              toolNames @?= Just ["lookup"],
              fmap (Just "call-1" `elem`) callIds @?= Just True
            ]
    usageFrame =
      either assertFailure assertEvents (eitherDecodeStrict' frame)
      where
        frame =
          "{\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"prompt_cache_hit_tokens\":3,\"prompt_cache_miss_tokens\":7}}"
        assertEvents chunk =
          chunkEvents chunk @?= Right ([ModelUsage (Usage (Just 10) (Just 5) (Just 3) (Just 7))], Nothing)
    emptyDelta' = ChatDelta Nothing Nothing []

providersTests :: TestTree
providersTests =
  testGroup
    "providers"
    [ testCase "loadProviders returns built-in defaults when no file" defaultsExist,
      testCase "resolveApiKey prefers env over piAuth" keyResolution,
      testCase "providerConfig applies local provider thinking defaults" dialectThinking,
      testCase "resolveRuntime uses provider entry when configProvider matches" providerOverride,
      testCase "resolveRuntime falls back when provider key is missing" missingKeyFallback,
      testCase "listEntry output shape with keyReady" listEntryShape,
      testCase "provider listing never probes the external model endpoint" listingDoesNotProbe,
      testCase "/providers endpoint returns 200 with static listing" providersEndpoint
    ]
  where
    defaultsExist =
      let loaded = defaultProviders
       in sequence_
            [ (providerName <$> Map.lookup "deepseek" loaded) @?= Just "deepseek",
              (providerDefaultModel <$> Map.lookup "deepseek" loaded) @?= Just "deepseek-v4-flash",
              (providerDialect <$> Map.lookup "deepseek" loaded) @?= Just DeepSeek,
              (providerContextTokens <$> Map.lookup "deepseek" loaded) @?= Just 1000000,
              (providerBaseUrl <$> Map.lookup "zai" loaded) @?= Just "https://open.bigmodel.cn/api/paas/v4",
              (providerContextTokens <$> Map.lookup "zai" loaded) @?= Just 1000000,
              (providerPiAuth <$> Map.lookup "zai" loaded) @?= Just (Just "zai"),
              (providerApiKeyEnv <$> Map.lookup "kimi-coding" loaded) @?= Just (Just "KIMI_API_KEY"),
              (providerContextTokens <$> Map.lookup "kimi-coding" loaded) @?= Just 1048576,
              Map.size loaded @?= 3
            ]
    keyResolution =
      let entry = ProviderEntry "test" "https://x" OpenAICompatible "m" (Just "TEST_KEY") (Just "pi-name") 65536
          envKey = Map.singleton "TEST_KEY" "env-secret"
          authValue = object ["pi-name" .= object ["key" .= ("pi-secret" :: Text)]]
       in sequence_
            [ resolveApiKey envKey Nothing entry @?= Just "env-secret",
              resolveApiKey Map.empty (Just authValue) entry @?= Just "pi-secret",
              resolveApiKey envKey (Just authValue) entry @?= Just "env-secret",
              resolveApiKey Map.empty Nothing entry @?= Nothing
            ]
    dialectThinking =
      let ds = providerConfig entry "key" (Just "m1")
          compat = providerConfig entry {providerDialect = OpenAICompatible} "key" (Just "m2")
          fallback = providerConfig entry "key" Nothing
          zai = providerConfig (fromMaybe entry (Map.lookup "zai" defaultProviders)) "key" Nothing
          kimi = providerConfig (fromMaybe entry (Map.lookup "kimi-coding" defaultProviders)) "key" Nothing
          entry = ProviderEntry "ds" "https://x" DeepSeek "m0" Nothing Nothing 65536
       in sequence_
            [ openAIThinking ds @?= ThinkingEnabled High,
              openAIDialect ds @?= DeepSeek,
              openAIModelName ds @?= "m1",
              openAIThinking compat @?= ThinkingDisabled,
              openAIDialect compat @?= OpenAICompatible,
              openAIThinking zai @?= ThinkingEnabled High,
              openAIThinking kimi @?= ThinkingEnabled Max,
              openAIModelName fallback @?= "m0"
            ]
    providerOverride =
      newTlsManager >>= \manager ->
        testRuntime okModel [] Parallel >>= \base ->
          let registry = defaultProviders
              keyMap = Map.singleton "zai" "test-key-zai"
              session = emptyThreadConfig {configProvider = Just "zai"}
              resolved = resolveRuntime manager testProvider Nothing base session registry keyMap
              override = resolveRuntime manager testProvider Nothing base emptyThreadConfig {configModel = Just "override"} registry keyMap
           in (,) <$> resolved <*> override >>= \cfgAndOverride ->
                let cfg = runtimeModel (fst cfgAndOverride)
                 in sequence_
                      [ modelProvider cfg @?= "zai",
                        modelName cfg @?= "glm-5.2",
                        modelName (runtimeModel (snd cfgAndOverride)) @?= "override"
                      ]
    listEntryShape =
      newTlsManager >>= \manager ->
        let entry = fromMaybe (error "missing") (Map.lookup "deepseek" defaultProviders)
            keyMap = Map.empty
         in listEntry manager keyMap ("deepseek", entry) >>= \value ->
              sequence_
                [ parseMaybe (withObject "provider" (.: "name")) value @?= Just ("deepseek" :: Text),
                  parseMaybe (withObject "provider" (.: "baseUrl")) value @?= Just ("https://api.deepseek.com" :: Text),
                  parseMaybe (withObject "provider" (.: "dialect")) value @?= Just ("deepseek" :: Text),
                  parseMaybe (withObject "provider" (.: "defaultModel")) value @?= Just ("deepseek-v4-flash" :: Text),
                  parseMaybe (withObject "provider" (.: "keyReady")) value @?= Just False,
                  parseMaybe (withObject "provider" (.: "models")) value @?= Just (["deepseek-v4-flash"] :: [Text])
                ]
    listingDoesNotProbe =
      newIORef (0 :: Int) >>= \requests ->
        testWithApplication (pure (modelEndpoint requests)) $ \port ->
          newTlsManager >>= \manager ->
            let baseUrl = "http://127.0.0.1:" <> Text.pack (show port)
                entry = ProviderEntry "local" baseUrl OpenAICompatible "configured-model" Nothing Nothing 4096
             in listEntry manager (Map.singleton "local" "key") ("local", entry)
                  *> readIORef requests
                  >>= (@?= 0)
    modelEndpoint requests _ respond =
      modifyIORef' requests (+ 1)
        *> respond
          (responseLBS status200 [(hContentType, "application/json")] "{\"data\":[{\"id\":\"remote-model\"}]}")
    missingKeyFallback =
      newTlsManager >>= \manager ->
        testRuntime okModel [] Parallel >>= \base ->
          let registry = defaultProviders
              session = emptyThreadConfig {configProvider = Just "deepseek"}
           in resolveRuntime manager testProvider Nothing base session registry Map.empty >>= \resolved ->
                modelProvider (runtimeModel resolved) @?= "fake"
    providersEndpoint =
      newMemoryThreadConfigStore >>= \store ->
        testRuntime okModel [] Parallel >>= \base ->
          let staticListing =
                pure
                  [ object
                      [ "name" .= ("deepseek" :: Text),
                        "baseUrl" .= ("https://api.deepseek.com" :: Text),
                        "dialect" .= ("deepseek" :: Text),
                        "defaultModel" .= ("deepseek-v4-flash" :: Text),
                        "keyReady" .= True,
                        "models" .= (["deepseek-v4-flash", "deepseek-v4-pro"] :: [Text])
                      ]
                  ]
              view = ConfigView (renderGlobalConfig testSettings (globalThreadConfig testSettings)) store (globalThreadConfig testSettings) (pure (Right [])) staticListing
              app = application Nothing Nothing (Just view) Nothing (const (pure base))
           in runSession (request (httpGet ["providers"])) app >>= \response ->
                let decoded = eitherDecode (simpleBody response) :: Either String [Value]
                 in case decoded of
                      Left err -> assertFailure ("providers decode: " <> err)
                      Right providers ->
                        let names = mapMaybe (parseMaybe (withObject "provider" (.: "name"))) providers
                            first = listToMaybe providers
                         in sequence_
                              [ simpleStatus response @?= status200,
                                length providers @?= 1,
                                names @?= ["deepseek" :: Text],
                                (first >>= parseMaybe (withObject "provider" (.: "keyReady"))) @?= Just True
                              ]

agentTests :: TestTree
agentTests =
  testGroup
    "agent"
    [ testCase "streams reasoning and text through normalized AG-UI events" reasoningEvents,
      testCase "executes backend tools concurrently and continues the model loop" parallelTools,
      testCase "hands client tools back without another model call" frontendTools,
      testCase "classifies the local model-turn guard distinctly" turnLimitError,
      testCase "surfaces an unexpected synchronous exception with its detail" unexpectedError,
      testCase "emits RUN_ERROR without a following RUN_FINISHED" runError
    ]

reasoningEvents :: Assertion
reasoningEvents =
  testRuntime model [] Parallel >>= collect >>= (@?= expected)
  where
    model =
      fakeModel $ \_ emit ->
        emit (ModelReasoningDelta "brief reasoning") *> emit (ModelTextDelta "hello") $> Stop
    collect runtime = eventType <$$> collectEvents runtime (sampleInput [])
    expected =
      [ "RUN_STARTED",
        "STEP_STARTED",
        "REASONING_START",
        "REASONING_MESSAGE_START",
        "REASONING_MESSAGE_CONTENT",
        "REASONING_MESSAGE_END",
        "REASONING_END",
        "TEXT_MESSAGE_START",
        "TEXT_MESSAGE_CONTENT",
        "TEXT_MESSAGE_END",
        "STEP_FINISHED",
        "RUN_FINISHED"
      ]

parallelTools :: Assertion
parallelTools =
  fixture >>= exercise
  where
    fixture =
      (,,,)
        <$> newIORef (0 :: Int)
        <*> newIORef []
        <*> newEmptyMVar
        <*> newEmptyMVar
    exercise (turns, secondRequest, leftStarted, rightStarted) =
      testRuntime
        (parallelModel turns secondRequest)
        [ barrier "left" leftStarted rightStarted "left-result",
          barrier "right" rightStarted leftStarted "right-result"
        ]
        Parallel
        >>= run secondRequest
    run secondRequest runtime =
      timeout 5000000 (collectEvents runtime (sampleInput []))
        >>= maybe
          (assertFailure "parallel tool execution deadlocked")
          (verifyParallel secondRequest)

parallelModel :: IORef Int -> IORef [ChatMessage] -> Model
parallelModel turns secondRequest =
  fakeModel $ \modelRequest emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next))
      >>= turn modelRequest emit
  where
    turn _ emit 1 =
      emit (ModelToolCallDelta 0 (Just "call-a") (Just "left") "{}")
        *> emit (ModelToolCallDelta 1 (Just "call-b") (Just "right") "{}")
        $> ToolUse
    turn modelRequest emit 2 =
      writeIORef secondRequest (requestMessages modelRequest) *> emit (ModelTextDelta "done") $> Stop
    turn _ _ _ = throwIO (ProviderFailure "unexpected model turn")

barrier :: Text -> MVar () -> MVar () -> Text -> BackendTool
barrier name own other content =
  BackendTool
    (tool name)
    (\_ _ -> (putMVar own () *> readMVar other) $> ToolOutcome content False False)

verifyParallel :: IORef [ChatMessage] -> [Event] -> Assertion
verifyParallel secondRequest events =
  sequence_
    [ length (filter ((== "TOOL_CALL_RESULT") . eventType) events) @?= 2,
      eventType <$> takeEnd 2 events @?= ["STEP_FINISHED", "RUN_FINISHED"]
    ]
    *> (readIORef secondRequest >>= verifyMessages)
  where
    verifyMessages messages =
      [call | ChatToolResult call _ <- messages] @?= ["call-a", "call-b"]

frontendTools :: Assertion
frontendTools = newIORef (0 :: Int) >>= prepare
  where
    prepare calls = testRuntime (frontendModel calls) [] Parallel >>= run calls
    run calls runtime =
      collectEvents runtime (sampleInput [tool "confirm"]) >>= verifyFrontend calls

frontendModel :: IORef Int -> Model
frontendModel calls =
  fakeModel $ \_ emit ->
    modifyIORef' calls (+ 1)
      *> emit (ModelToolCallDelta 0 (Just "frontend-call") (Just "confirm") "{\"ok\":true}")
      $> ToolUse

verifyFrontend :: IORef Int -> [Event] -> Assertion
verifyFrontend calls events =
  readIORef calls
    >>= \count ->
      sequence_
        [ count @?= 1,
          assertBool
            "frontend call must not produce a backend result"
            (all ((/= "TOOL_CALL_RESULT") . eventType) events),
          eventType (last events) @?= "RUN_FINISHED"
        ]

turnLimitError :: Assertion
turnLimitError =
  testRuntime looping [echoTool] Sequential >>= \base ->
    collectEvents base {runtimeMaxTurns = 1} (sampleInput []) >>= \events ->
      case [(message, code) | RunError message code <- events] of
        [(message, code)] ->
          sequence_
            [ code @?= Just "MAX_TURNS_EXCEEDED",
              assertBool "error identifies the configured local limit" ("1 model turns" `Text.isInfixOf` message),
              assertBool "error identifies the configuration key" ("YUKI_MAX_TURNS" `Text.isInfixOf` message)
            ]
        failures -> assertFailure ("expected one turn-limit error, got " <> show failures)
  where
    looping =
      fakeModel $ \_ emit ->
        emit (ModelToolCallDelta 0 (Just "call-echo") (Just "echo") "{}") $> ToolUse

unexpectedError :: Assertion
unexpectedError =
  testRuntime okModel [] Parallel >>= \base ->
    let hooks = defaultHooks {transformContext = \_ _ -> ioError (userError "context transformer exploded")}
     in collectEvents base {runtimeHooks = hooks} (sampleInput []) >>= \events ->
          case [(message, code) | RunError message code <- events] of
            [(message, code)] ->
              sequence_
                [ code @?= Just "UNHANDLED_ERROR",
                  assertBool "error retains the original exception detail" ("context transformer exploded" `Text.isInfixOf` message)
                ]
            failures -> assertFailure ("expected one unhandled error, got " <> show failures)

runError :: Assertion
runError =
  testRuntime
    (fakeModel (\_ _ -> throwIO (ProviderFailure "unavailable")))
    []
    Parallel
    >>= \runtime ->
      eventType <$$> collectEvents runtime (sampleInput [])
        >>= (@?= ["RUN_STARTED", "STEP_STARTED", "RUN_ERROR"])

terminationTests :: TestTree
terminationTests =
  testGroup
    "run termination"
    [ testCase "failure runs afterRun once with the checkpoint history" failureCheckpoint,
      testCase "a thrown emit still accounts the run and rethrows" disconnectAccounts,
      testCase "cancel announces run.cancelled, finishes the stream and accounts" cancelOverHttp,
      testCase "browser control module cancels a real backend stream over loopback" browserControlE2E,
      testCase "afterRun runs exactly once on success, failure and cancel" oncePerTerminal,
      testCase "replays a cancelled journaled run without divergence" cancelReplay
    ]

afterSpy :: IORef [[ChatMessage]] -> AgentHooks
afterSpy ref = defaultHooks {afterRun = \_ messages -> modifyIORef' ref (messages :)}

failAfterTool :: IORef Int -> Model
failAfterTool turns =
  fakeModel $ \_ emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next)) >>= \case
      1 -> emit (ModelToolCallDelta 0 (Just "call-echo") (Just "echo") "{\"x\":1}") $> ToolUse
      _ -> throwIO (ProviderFailure "upstream down")

failureCheckpoint :: Assertion
failureCheckpoint =
  newIORef (0 :: Int) >>= \turns ->
    newIORef [] >>= \histories ->
      testRuntime (failAfterTool turns) [echoTool] Sequential >>= \base ->
        collectEvents base {runtimeHooks = afterSpy histories} (sampleInput []) >>= \events ->
          readIORef histories >>= \captured ->
            sequence_
              [ eventType (last events) @?= "RUN_ERROR",
                assertBool "no RUN_FINISHED on failure" (all ((/= "RUN_FINISHED") . eventType) events),
                case captured of
                  [history] -> [content | ChatToolResult _ content <- history] @?= ["{\"x\":1}"]
                  other -> assertFailure ("afterRun must run exactly once, got " <> show (length other))
              ]

disconnectAccounts :: Assertion
disconnectAccounts =
  newIORef [] >>= \histories ->
    testRuntime okModel [] Parallel >>= \base ->
      (try (runAgent base {runtimeHooks = afterSpy histories} (sampleInput []) throwing) :: IO (Either IOException ()))
        >>= \outcome ->
          readIORef histories >>= \captured ->
            sequence_
              [ assertBool "the failure escapes runAgent" (either (const True) (const False) outcome),
                captured @?= [[ChatUser "hello"]]
              ]
  where
    throwing (TextMessageContent {}) = throwIO (userError "client disconnected")
    throwing _ = pure ()

cancelOverHttp :: Assertion
cancelOverHttp =
  newEmptyMVar >>= \gate ->
    newRunRegistry >>= \runs ->
      newIORef [] >>= \chunks ->
        newIORef [] >>= \histories ->
          newEmptyMVar >>= \streamed ->
            testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel >>= \base ->
              let runtime = base {runtimeRuns = Just runs, runtimeHooks = afterSpy histories}
                  app = application Nothing Nothing Nothing (Just runs) (const (pure runtime))
               in forkIO (streamAgent app chunks streamed)
                    *> (waitUntil (started chunks) >>= bool (assertFailure "run never started") (pure ()))
                    *> runSession (srequest (cancelRequest "ghost")) app
                    >>= \ghost ->
                      runSession (srequest (cancelRequest "run")) app >>= \accepted ->
                        timeout 5000000 (takeMVar streamed) >>= \finished ->
                          runSession (srequest (cancelRequest "run")) app >>= \gone ->
                            decodeChunks chunks >>= \events ->
                              readIORef histories >>= \captured ->
                                sequence_
                                  [ simpleStatus ghost @?= status404,
                                    simpleStatus accepted @?= status202,
                                    simpleStatus gone @?= status404,
                                    assertBool "the stream ends after cancel" (isJust finished),
                                    length [() | Custom "run.cancelled" _ <- events] @?= 1,
                                    eventType (last events) @?= "RUN_FINISHED",
                                    assertBool "no RUN_ERROR on cancel" (all ((/= "RUN_ERROR") . eventType) events),
                                    captured @?= [[ChatUser "hello"]]
                                  ]
  where
    started ref =
      any (ByteString.isInfixOf "RUN_STARTED" . LazyByteString.toStrict . Builder.toLazyByteString) <$> readIORef ref

browserControlE2E :: Assertion
browserControlE2E =
  newEmptyMVar >>= \gate ->
    newRunRegistry >>= \runs ->
      testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel >>= \base ->
        let runId = "browser-control-e2e"
            runtime = base {runtimeRuns = Just runs}
            app = application Nothing Nothing Nothing (Just runs) (const (pure runtime))
         in testWithApplication (pure app) $ \port ->
              timeout
                15000000
                ( readProcessWithExitCode
                    "node"
                    ["frontend/test/backend-control-e2e.mjs", "http://127.0.0.1:" <> show port <> "/"]
                    ""
                )
                >>= \result ->
                  cancelRun runs runId
                    *> maybe
                      (assertFailure "browser control test timed out")
                      verify
                      result
  where
    verify (ExitSuccess, _, _) = pure ()
    verify (code, stdout, stderr) =
      assertFailure
        ( "browser control test failed with "
            <> show code
            <> "\nstdout:\n"
            <> stdout
            <> "\nstderr:\n"
            <> stderr
        )

oncePerTerminal :: Assertion
oncePerTerminal =
  newIORef (0 :: Int) >>= \count ->
    let hooks = defaultHooks {afterRun = \_ _ -> modifyIORef' count (+ 1)}
     in succeed hooks *> failed hooks *> cancelled hooks *> (readIORef count >>= (@?= 3))
  where
    succeed hooks =
      testRuntime okModel [] Parallel
        >>= \base -> collectEvents base {runtimeHooks = hooks} (sampleInput [])
    failed hooks =
      testRuntime (fakeModel (\_ _ -> throwIO (ProviderFailure "down"))) [] Parallel
        >>= \base -> collectEvents base {runtimeHooks = hooks} (sampleInput [])
    cancelled hooks =
      newEmptyMVar >>= \gate ->
        newRunRegistry >>= \runs ->
          newIORef [] >>= \events ->
            newEmptyMVar >>= \done ->
              testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel >>= \base ->
                forkIO
                  ( runAgent base {runtimeRuns = Just runs, runtimeHooks = hooks} (sampleInput [])
                      (\event -> modifyIORef' events (event :))
                      *> putMVar done ()
                  )
                  *> (waitUntil (runStarted <$> readIORef events) >>= bool (assertFailure "run never started") (pure ()))
                  *> cancelRun runs "run"
                  *> (timeout 5000000 (takeMVar done) >>= maybe (assertFailure "cancel did not finish the run") pure)

cancelReplay :: Assertion
cancelReplay =
  newEmptyMVar >>= \gate ->
    newMemoryJournal >>= \(journal, readEntries) ->
      newRunRegistry >>= \runs ->
        newIORef [] >>= \events ->
          newEmptyMVar >>= \done ->
            testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel >>= \base ->
              forkIO
                ( runAgent
                    base {runtimeRuns = Just runs, runtimeJournal = Just journal}
                    (sampleInput [])
                    (\event -> modifyIORef' events (event :))
                    *> putMVar done ()
                )
                *> (waitUntil (runStarted <$> readIORef events) >>= bool (assertFailure "run never started") (pure ()))
                *> cancelRun runs "run"
                *> (timeout 5000000 (takeMVar done) >>= maybe (assertFailure "cancel did not finish the run") pure)
                *> readEntries
                >>= \recorded ->
                  replayEntries defaultHooks Nothing recorded >>= \report ->
                    sequence_
                      [ assertBool "journal records run.cancelled" (any journaled recorded),
                        fmap reportDivergence report @?= Right Nothing,
                        fmap reportEvents report @?= Right 4
                      ]
  where
    journaled (Entry _ _ _ (AgentEventEntry (Custom "run.cancelled" _))) = True
    journaled _ = False

runStarted :: [Event] -> Bool
runStarted = any (\case RunStarted {} -> True; _ -> False)

waitUntil :: IO Bool -> IO Bool
waitUntil probe = go (100 :: Int)
  where
    go 0 = pure False
    go n = probe >>= bool (threadDelay 50000 *> go (n - 1)) (pure True)

streamAgent :: Application -> IORef [Builder.Builder] -> MVar () -> IO ()
streamAgent app = streamInput app (sampleInput [])

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
  defaultRequest
    { requestMethod = methodPost,
      pathInfo = ["agent"],
      requestHeaders = [(hContentType, "application/json")],
      requestBody = atomicModifyIORef' body (\chunk -> ("", chunk))
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
  reverse <$> readIORef ref >>= decode . foldl feed (emptySseDecoder, []) . fmap bytes
  where
    bytes = LazyByteString.toStrict . Builder.toLazyByteString
    feed (decoder, acc) chunk =
      let (decoder', decoded) = feedSse decoder chunk in (decoder', acc <> decoded)
    decode (decoder, payloads) =
      let (_, trailing) = finishSse decoder
       in either assertFailure pure (traverse eitherDecodeStrict' (payloads <> trailing))

streamBegan :: IORef [Builder.Builder] -> IO Bool
streamBegan ref =
  any (ByteString.isInfixOf "RUN_STARTED" . LazyByteString.toStrict . Builder.toLazyByteString) <$> readIORef ref

steeringTests :: TestTree
steeringTests =
  testGroup
    "steering"
    [ testCase "a mid-run steer lands in the next model request and announces the injection" steerMidRun,
      testCase "a steer arriving during the final answer continues the run" lateSteerContinues,
      testCase "a follow-up arriving during the final answer starts the next turn" followUpContinues,
      testCase "an empty queue leaves history and events untouched" emptyDrainSilent,
      testCase "POST /agent/steer answers 202, 404 and 400" steerEndpoint,
      testCase "POST /agent/follow-up queues separately" followUpEndpoint,
      testCase "replays a journaled run with steering without divergence" steerReplay,
      testCase "steering and follow-up entries JSON round-trip" queueEntryJson
    ]

steerModel :: IORef Int -> IORef [ChatMessage] -> Model
steerModel turns captured =
  fakeModel $ \request emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next)) >>= \case
      1 -> emit (ModelToolCallDelta 0 (Just "call-gate") (Just "gate") "{}") $> ToolUse
      _ -> writeIORef captured (requestMessages request) *> emit (ModelTextDelta "done") $> Stop

gateTool :: MVar () -> BackendTool
gateTool gate =
  BackendTool (tool "gate") (\_ _ -> takeMVar gate $> ToolOutcome "tool done" False False)

steerPost :: Text -> Text -> SRequest
steerPost run text =
  SRequest
    { simpleRequest =
        defaultRequest
          { requestMethod = methodPost,
            pathInfo = ["agent", "steer"],
            requestHeaders = [(hContentType, "application/json")]
          },
      simpleRequestBody = encode (object ["runId" .= run, "text" .= text])
    }

followUpPost :: Text -> Text -> SRequest
followUpPost run text = (steerPost run text) {simpleRequest = request}
  where
    request = (simpleRequest (steerPost run text)) {pathInfo = ["agent", "follow-up"]}

steerMidRun :: Assertion
steerMidRun =
  newEmptyMVar >>= \gate ->
    newRunRegistry >>= \runs ->
      newIORef (0 :: Int) >>= \turns ->
        newIORef [] >>= \captured ->
          newIORef [] >>= \chunks ->
            newEmptyMVar >>= \streamed ->
              testRuntime (steerModel turns captured) [gateTool gate] Sequential >>= \base ->
                let runtime = base {runtimeRuns = Just runs}
                    app = application Nothing Nothing Nothing (Just runs) (const (pure runtime))
                 in forkIO (streamAgent app chunks streamed)
                      *> (waitUntil (started chunks) >>= bool (assertFailure "run never started") (pure ()))
                      *> runSession (srequest (steerPost "ghost" "late")) app
                      >>= \ghost ->
                        runSession (srequest (steerPost "run" "hold on")) app
                          >>= \accepted ->
                            putMVar gate ()
                              *> (timeout 5000000 (takeMVar streamed) >>= maybe (assertFailure "steered run did not finish") pure)
                              *> decodeChunks chunks
                              >>= \events ->
                                readIORef captured >>= \messages ->
                                  sequence_
                                    [ simpleStatus ghost @?= status404,
                                      simpleStatus accepted @?= status202,
                                      takeEnd 1 messages @?= [ChatUser "hold on"],
                                      [content | ChatToolResult _ content <- messages] @?= ["tool done"],
                                      eventType (last events) @?= "RUN_FINISHED",
                                      injectValues events
                                    ]
  where
    started ref =
      any (ByteString.isInfixOf "RUN_STARTED" . LazyByteString.toStrict . Builder.toLazyByteString) <$> readIORef ref
    injectValues events =
      case [value | Custom "steering.inject" value <- events] of
        [value] ->
          sequence_
            [ parseMaybe (withObject "steer" (.: "step")) value @?= Just (2 :: Int),
              parseMaybe (withObject "steer" (.: "count")) value @?= Just (1 :: Int)
            ]
        other -> assertFailure ("expected one steering.inject, got " <> show (length other))

lateSteerContinues :: Assertion
lateSteerContinues = queuedAfterAnswer steerPost "steering.inject"

followUpContinues :: Assertion
followUpContinues = queuedAfterAnswer followUpPost "followup.inject"

queuedAfterAnswer :: (Text -> Text -> SRequest) -> Text -> Assertion
queuedAfterAnswer post kind =
  newEmptyMVar >>= \entered ->
    newEmptyMVar >>= \release ->
      newRunRegistry >>= \runs ->
        newIORef (0 :: Int) >>= \turns ->
          newIORef [] >>= \captured ->
            newIORef [] >>= \chunks ->
              newEmptyMVar >>= \streamed ->
                testRuntime (answerGateModel entered release turns captured) [] Sequential >>= \base ->
                  let app = application Nothing Nothing Nothing (Just runs) (const (pure base {runtimeRuns = Just runs}))
                   in forkIO (streamAgent app chunks streamed)
                        *> (timeout 5000000 (takeMVar entered) >>= maybe (assertFailure "model answer never opened") pure)
                        *> runSession (srequest (post "run" "one more thing")) app
                        >>= \accepted ->
                          putMVar release ()
                            *> (timeout 5000000 (takeMVar streamed) >>= maybe (assertFailure "queued run did not finish") pure)
                            *> decodeChunks chunks
                            >>= \events ->
                              readIORef captured >>= \messages ->
                                sequence_
                                  [ simpleStatus accepted @?= status202,
                                    takeEnd 1 messages @?= [ChatUser "one more thing"],
                                    length [() | Custom name _ <- events, name == kind] @?= 1,
                                    eventType (last events) @?= "RUN_FINISHED"
                                  ]

answerGateModel :: MVar () -> MVar () -> IORef Int -> IORef [ChatMessage] -> Model
answerGateModel entered release turns captured =
  fakeModel $ \request emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next)) >>= \case
      1 -> emit (ModelTextDelta "first") *> putMVar entered () *> takeMVar release $> Stop
      _ -> writeIORef captured (requestMessages request) *> emit (ModelTextDelta "second") $> Stop

emptyDrainSilent :: Assertion
emptyDrainSilent =
  newRunRegistry >>= \runs ->
    newIORef (0 :: Int) >>= \turns ->
      newIORef [] >>= \captured ->
        testRuntime (steerModel turns captured) [staticTool "gate" "tool done"] Sequential >>= \base ->
          collectEvents base {runtimeRuns = Just runs} (sampleInput []) >>= \events ->
            readIORef captured >>= \messages ->
              sequence_
                [ assertBool "no steering.inject without a steer" (null [() | Custom "steering.inject" _ <- events]),
                  messages
                    @?= [ ChatUser "hello",
                          ChatAssistant (AssistantTurn "id-1" Nothing Nothing [ModelToolCall "call-gate" "gate" "{}"]),
                          ChatToolResult "call-gate" "tool done"
                        ]
                ]

steerEndpoint :: Assertion
steerEndpoint =
  newRunRegistry >>= \runs ->
    testRuntime okModel [] Parallel >>= \base ->
      let app = application Nothing Nothing Nothing (Just runs) (const (pure base))
       in withRunRegistration runs "run" $
            runSession (srequest (steerPost "run" "hold on")) app >>= \accepted ->
              runSession (srequest (steerPost "ghost" "late")) app >>= \ghost ->
                runSession (srequest badSteer) app >>= \invalid ->
                  drainSteering runs "run" >>= \queued ->
                    sequence_
                      [ simpleStatus accepted @?= status202,
                        simpleStatus ghost @?= status404,
                        simpleStatus invalid @?= status400,
                        queued @?= [ChatUser "hold on"]
                      ]
  where
    badSteer =
      SRequest
        { simpleRequest =
            defaultRequest
              { requestMethod = methodPost,
                pathInfo = ["agent", "steer"],
                requestHeaders = [(hContentType, "application/json")]
              },
          simpleRequestBody = "{\"runId\":1}"
        }

followUpEndpoint :: Assertion
followUpEndpoint =
  newRunRegistry >>= \runs ->
    testRuntime okModel [] Parallel >>= \base ->
      let app = application Nothing Nothing Nothing (Just runs) (const (pure base))
       in withRunRegistration runs "run" $
            runSession (srequest (followUpPost "run" "later")) app >>= \accepted ->
              runSession (srequest (followUpPost "ghost" "late")) app >>= \ghost ->
                drainSteering runs "run" >>= \steering ->
                  drainFollowUps runs "run" >>= \followUps ->
                    sequence_
                      [ simpleStatus accepted @?= status202,
                        simpleStatus ghost @?= status404,
                        steering @?= [],
                        followUps @?= [ChatUser "later"]
                      ]

steerReplay :: Assertion
steerReplay =
  newEmptyMVar >>= \started ->
    newEmptyMVar >>= \gate ->
      newRunRegistry >>= \runs ->
        newMemoryJournal >>= \(journal, readEntries) ->
          newIORef (0 :: Int) >>= \turns ->
            newIORef [] >>= \captured ->
              newIORef [] >>= \events ->
                newEmptyMVar >>= \done ->
                  testRuntime (steerModel turns captured) [blockingTool started gate] Sequential >>= \base ->
                    forkIO
                      ( runAgent base {runtimeRuns = Just runs, runtimeJournal = Just journal} (sampleInput [])
                          (\event -> modifyIORef' events (event :))
                          *> putMVar done ()
                      )
                      *> (timeout 5000000 (takeMVar started) >>= maybe (assertFailure "tool never ran") pure)
                      *> (steerRun runs "run" (ChatUser "hold on") >>= (@?= True))
                      *> putMVar gate ()
                      *> (timeout 5000000 (takeMVar done) >>= maybe (assertFailure "steered run did not finish") pure)
                      *> readEntries
                      >>= \recorded ->
                        reverse <$> readIORef events >>= \live ->
                          replayEntries defaultHooks Nothing recorded >>= \report ->
                            sequence_
                              [ assertBool "journal records the steering entry" (any journaled recorded),
                                assertBool "journal records the injection event" (any announced recorded),
                                fmap reportDivergence report @?= Right Nothing,
                                fmap reportEvents report @?= Right (length live)
                              ]
  where
    blockingTool started gate =
      BackendTool (tool "gate") (\_ _ -> (putMVar started () *> takeMVar gate) $> ToolOutcome "tool done" False False)
    journaled (Entry _ _ _ (SteeringEntry 2 [ChatUser "hold on"])) = True
    journaled _ = False
    announced (Entry _ _ _ (AgentEventEntry (Custom "steering.inject" _))) = True
    announced _ = False

queueEntryJson :: Assertion
queueEntryJson =
  traverse_ (\entry -> eitherDecode (encode entry) @?= Right entry) entries
  where
    entries =
      [ Entry 11 ["run"] (Just 1700000000) (SteeringEntry 2 [ChatUser "hold on"]),
        Entry 12 ["run"] (Just 1700000001) (FollowUpEntry 3 [ChatUser "later"])
      ]

retryTests :: TestTree
retryTests =
  testGroup
    "provider retry"
    [ testCase "retries before the first delta and announces the attempt" retryRecovers,
      testCase "gives up at the attempt cap" retryExhausted,
      testCase "never retries after a delta was consumed" retryAfterDelta,
      testCase "replays a journaled run with provider.retry events without divergence" retryReplay
    ]

flakyModel :: Int -> IORef Int -> Model
flakyModel failures calls =
  fakeModel $ \_ emit ->
    atomicModifyIORef' calls (\count -> (count + 1, count + 1))
      >>= \call ->
        bool
          (emit (ModelTextDelta "recovered") $> Stop)
          (throwIO (ProviderFailure "upstream 429"))
          (call <= failures)

retryEvents :: [Event] -> [Value]
retryEvents events = [value | Custom "provider.retry" value <- events]

retryRecovers :: Assertion
retryRecovers =
  newIORef (0 :: Int) >>= \calls ->
    testRuntime (flakyModel 1 calls) [] Parallel >>= \base ->
      collectEvents base {runtimeProviderRetries = 3} (sampleInput []) >>= \events ->
        readIORef calls >>= \attempts ->
          sequence_
            [ attempts @?= 2,
              [delta | TextMessageContent _ delta <- events] @?= ["recovered"],
              eventType (last events) @?= "RUN_FINISHED",
              case retryEvents events of
                [value] ->
                  sequence_
                    [ parseMaybe (withObject "retry" (.: "attempt")) value @?= Just (1 :: Int),
                      parseMaybe (withObject "retry" (.: "maxAttempts")) value @?= Just (3 :: Int),
                      parseMaybe (withObject "retry" (.: "delayMs")) value @?= Just (1000 :: Int),
                      parseMaybe (withObject "retry" (.: "reason")) value @?= Just ("upstream 429" :: Text)
                    ]
                other -> assertFailure ("expected one provider.retry, got " <> show (length other))
            ]

retryExhausted :: Assertion
retryExhausted =
  newIORef (0 :: Int) >>= \calls ->
    testRuntime (flakyModel 9 calls) [] Parallel >>= \base ->
      collectEvents base {runtimeProviderRetries = 2} (sampleInput []) >>= \events ->
        readIORef calls >>= \attempts ->
          sequence_
            [ attempts @?= 2,
              length (retryEvents events) @?= 1,
              eventType (last events) @?= "RUN_ERROR",
              [code | RunError _ (Just code) <- events] @?= ["PROVIDER_ERROR"]
            ]

retryAfterDelta :: Assertion
retryAfterDelta =
  testRuntime midStreamFailure [] Parallel >>= \base ->
    collectEvents base {runtimeProviderRetries = 3} (sampleInput []) >>= \events ->
      sequence_
        [ [delta | TextMessageContent _ delta <- events] @?= ["partial"],
          retryEvents events @?= [],
          eventType (last events) @?= "RUN_ERROR"
        ]
  where
    midStreamFailure =
      fakeModel $ \_ emit ->
        emit (ModelTextDelta "partial") *> throwIO (ProviderFailure "connection reset")

retryReplay :: Assertion
retryReplay =
  newMemoryJournal >>= \(journal, readEntries) ->
    newIORef (0 :: Int) >>= \calls ->
      testRuntime (flakyModel 1 calls) [] Parallel >>= \base ->
        collectEvents base {runtimeJournal = Just journal, runtimeProviderRetries = 3} (sampleInput [])
          >>= \events ->
            readEntries >>= \recorded ->
              replayEntries defaultHooks Nothing recorded >>= \report ->
                sequence_
                  [ assertBool "journal records provider.retry" (any journaled recorded),
                    fmap reportDivergence report @?= Right Nothing,
                    fmap reportEvents report @?= Right (length (filter (not . isRetry) events))
                  ]
  where
    journaled (Entry _ _ _ (AgentEventEntry (Custom "provider.retry" _))) = True
    journaled _ = False
    isRetry (Custom "provider.retry" _) = True
    isRetry _ = False

fallbackTests :: TestTree
fallbackTests =
  testGroup
    "provider fallback"
    [ testCase "falls back after the primary exhausts its retries" fallbackSucceeds,
      testCase "gives each fallback its own retry budget" fallbackRetries,
      testCase "walks the chain and rethrows the last failure" fallbackChainExhausted,
      testCase "an empty chain keeps the single-provider behavior" fallbackEmptyChain,
      testCase "replays a journaled fallback run without divergence" fallbackReplay,
      testCase "fallback env var defaults, parses a list and rejects empty names" fallbackConfigParse,
      testCase "global config exposes the fallback roster" fallbackConfigRender
    ]

downModel :: IORef Int -> Text -> Text -> Text -> Model
downModel calls provider name reason =
  Model provider name Nothing (\_ _ -> modifyIORef' calls (+ 1) *> throwIO (ProviderFailure reason)) (const (object []))

answeringModel :: IORef Int -> Text -> Text -> Text -> Model
answeringModel calls provider name answer =
  Model provider name Nothing (\_ emit -> modifyIORef' calls (+ 1) *> emit (ModelTextDelta answer) $> Stop) (const (object []))

fallbackField :: Value -> Text -> Maybe Text
fallbackField value key = parseMaybe (withObject "fallback" (.: Key.fromText key)) value

fallbackSucceeds :: Assertion
fallbackSucceeds =
  newIORef (0 :: Int) >>= \primaryCalls ->
    newIORef (0 :: Int) >>= \backupCalls ->
      testRuntime (downModel primaryCalls "alpha" "a1" "alpha down") [] Parallel >>= \base ->
        collectEvents
          base
            { runtimeProviderRetries = 3,
              runtimeFallbacks = [answeringModel backupCalls "beta" "b1" "second wind"]
            }
          (sampleInput [])
          >>= \events ->
            (,) <$> readIORef primaryCalls <*> readIORef backupCalls >>= \calls ->
              sequence_
                [ calls @?= (3, 1),
                  [name | Custom name _ <- events] @?= ["provider.retry", "provider.retry", "provider.fallback"],
                  case [value | Custom "provider.fallback" value <- events] of
                    [value] ->
                      sequence_
                        [ fallbackField value "from" @?= Just "alpha/a1",
                          fallbackField value "to" @?= Just "beta/b1",
                          fallbackField value "reason" @?= Just "alpha down"
                        ]
                    other -> assertFailure ("expected one provider.fallback, got " <> show (length other)),
                  [delta | TextMessageContent _ delta <- events] @?= ["second wind"],
                  eventType (last events) @?= "RUN_FINISHED"
                ]

fallbackRetries :: Assertion
fallbackRetries =
  newIORef (0 :: Int) >>= \primaryCalls ->
    newIORef (0 :: Int) >>= \backupCalls ->
      testRuntime (downModel primaryCalls "alpha" "a1" "alpha down") [] Parallel >>= \base ->
        collectEvents
          base
            { runtimeProviderRetries = 2,
              runtimeFallbacks = [(flakyModel 1 backupCalls) {modelProvider = "beta", modelName = "b1"}]
            }
          (sampleInput [])
          >>= \events ->
            (,) <$> readIORef primaryCalls <*> readIORef backupCalls >>= \calls ->
              sequence_
                [ calls @?= (2, 2),
                  [name | Custom name _ <- events] @?= ["provider.retry", "provider.fallback", "provider.retry"],
                  [delta | TextMessageContent _ delta <- events] @?= ["recovered"],
                  eventType (last events) @?= "RUN_FINISHED"
                ]

fallbackChainExhausted :: Assertion
fallbackChainExhausted =
  newIORef (0 :: Int) >>= \callsA ->
    newIORef (0 :: Int) >>= \callsB ->
      newIORef (0 :: Int) >>= \callsC ->
        testRuntime (downModel callsA "alpha" "a1" "alpha down") [] Parallel >>= \base ->
          collectEvents
            base
              { runtimeProviderRetries = 1,
                runtimeFallbacks =
                  [ downModel callsB "beta" "b1" "beta down",
                    downModel callsC "gamma" "g1" "gamma down"
                  ]
              }
            (sampleInput [])
            >>= \events ->
              (,,) <$> readIORef callsA <*> readIORef callsB <*> readIORef callsC >>= \calls ->
                sequence_
                  [ calls @?= (1, 1, 1),
                    [name | Custom name _ <- events] @?= ["provider.fallback", "provider.fallback"],
                    [to | Custom "provider.fallback" value <- events, Just to <- [fallbackField value "to"]]
                      @?= ["beta/b1", "gamma/g1"],
                    [message | RunError message _ <- events] @?= ["gamma down"],
                    [code | RunError _ (Just code) <- events] @?= ["PROVIDER_ERROR"]
                  ]

fallbackEmptyChain :: Assertion
fallbackEmptyChain =
  newIORef (0 :: Int) >>= \calls ->
    testRuntime (downModel calls "alpha" "a1" "alpha down") [] Parallel >>= \base ->
      collectEvents base {runtimeProviderRetries = 2} (sampleInput []) >>= \events ->
        readIORef calls >>= \attempts ->
          sequence_
            [ attempts @?= 2,
              [() | Custom "provider.fallback" _ <- events] @?= [],
              eventType (last events) @?= "RUN_ERROR",
              [code | RunError _ (Just code) <- events] @?= ["PROVIDER_ERROR"]
            ]

fallbackReplay :: Assertion
fallbackReplay =
  newMemoryJournal >>= \(journal, readEntries) ->
    newIORef (0 :: Int) >>= \calls ->
      testRuntime (downModel calls "alpha" "a1" "alpha down") [] Parallel >>= \base ->
        collectEvents
          base
            { runtimeJournal = Just journal,
              runtimeProviderRetries = 2,
              runtimeFallbacks = [answeringModel calls "beta" "b1" "second wind"]
            }
          (sampleInput [])
          >>= \events ->
            readEntries >>= \recorded ->
              replayEntries defaultHooks Nothing recorded >>= \report ->
                sequence_
                  [ assertBool "journal records provider.fallback" (any journaled recorded),
                    fmap reportDivergence report @?= Right Nothing,
                    fmap reportEvents report @?= Right (length (filter (not . transient) events))
                  ]
  where
    journaled (Entry _ _ _ (AgentEventEntry (Custom "provider.fallback" _))) = True
    journaled _ = False
    transient (Custom "provider.retry" _) = True
    transient (Custom "provider.fallback" _) = True
    transient _ = False

fallbackConfigParse :: Assertion
fallbackConfigParse =
  sequence_
    [ fallbacksOf [] >>= (@?= []),
      fallbacksOf [("YUKI_FALLBACK_PROVIDERS", "zai,kimi-coding")] >>= (@?= ["zai", "kimi-coding"]),
      fallbacksOf [("YUKI_FALLBACK_PROVIDERS", " zai , kimi-coding ")] >>= (@?= ["zai", "kimi-coding"]),
      fallbacksOf [("YUKI_FALLBACK_PROVIDERS", "")] >>= (@?= []),
      rejected "zai,,kimi-coding",
      rejected ",",
      rejected "zai,"
    ]
  where
    fallbacksOf extra =
      either (assertFailure . Text.unpack) (pure . settingsFallbackProviders) (resolveSettings (env extra))
    env extra = Map.fromList (("DEEPSEEK_API_KEY", "secret") : extra)
    rejected value =
      either
        (const (pure ()))
        (const (assertFailure ("YUKI_FALLBACK_PROVIDERS=" <> value <> " should be rejected")))
        (resolveSettings (env [("YUKI_FALLBACK_PROVIDERS", value)]))

fallbackConfigRender :: Assertion
fallbackConfigRender =
  either (assertFailure . Text.unpack) pure (resolveSettings env) >>= \settings ->
    parseMaybe names (renderGlobalConfig settings (globalThreadConfig settings))
      @?= Just (["zai", "kimi-coding"] :: [Text])
  where
    env = Map.fromList [("DEEPSEEK_API_KEY", "secret"), ("YUKI_FALLBACK_PROVIDERS", "zai,kimi-coding")]
    names = withObject "config" $ \fields ->
      fields .: "settings" >>= withObject "settings" (.: "fallbackProviders")

spliceTests :: TestTree
spliceTests =
  testGroup
    "context splice"
    [ testCase "counts characters across message kinds" countsChars,
      testCase "targets only results older than the most recent keep" keepsRecent,
      testCase "skips stubs and small results when targeting" targetGuards,
      testCase "leaves history verbatim without an artifact store" inertWithoutStore,
      testCase "leaves history verbatim below the character threshold" inertBelowThreshold,
      testCase "stubs aged results once each, keeps originals fetchable and reports savings" stubsAgedOnce,
      testCase "replays a journaled run with a splice without divergence" spliceReplay,
      testCase "splice env vars default, accept valid and reject invalid" spliceConfigParse
    ]

bigA, bigB, bigC, bigD :: Text
bigA = Text.replicate 30 "alpha-0123"
bigB = Text.replicate 30 "beta-98765"
bigC = Text.replicate 30 "gamma-0123"
bigD = Text.replicate 30 "delta-9876"

countsChars :: Assertion
countsChars =
  historyChars
    [ ChatSystem (Text.replicate 4 "s"),
      ChatUser (Text.replicate 8 "u"),
      ChatAssistant
        ( AssistantTurn
            "m"
            (Just (Text.replicate 4 "b"))
            (Just (Text.replicate 4 "r"))
            [ModelToolCall "c" "echo" (Text.replicate 8 "a")]
        ),
      ChatToolResult "c" (Text.replicate 16 "t")
    ]
    @?= 4 + 8 + 4 + 4 + 8 + 16

keepsRecent :: Assertion
keepsRecent =
  spliceTargets 2 history @?= [(1, "c-1", bigA), (2, "c-2", bigB)]
  where
    history =
      [ ChatUser "u",
        ChatToolResult "c-1" bigA,
        ChatToolResult "c-2" bigB,
        ChatToolResult "c-3" bigC,
        ChatToolResult "c-4" bigD
      ]

targetGuards :: Assertion
targetGuards =
  spliceTargets 0 history @?= [(2, "c-3", bigA)]
  where
    history =
      [ ChatToolResult "c-1" (artifactStub (artifactIdFor bigB) "big" bigB),
        ChatToolResult "c-2" "tiny",
        ChatToolResult "c-3" bigA
      ]

agedModel :: IORef Int -> IORef [ChatMessage] -> Model
agedModel turns captured =
  fakeModel $ \modelRequest emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next))
      >>= turn modelRequest emit
  where
    turn _ emit 1 = emit (ModelToolCallDelta 0 (Just "call-a") (Just "biga") "{}") $> ToolUse
    turn _ emit 2 = emit (ModelToolCallDelta 0 (Just "call-b") (Just "bigb") "{}") $> ToolUse
    turn _ emit 3 = emit (ModelToolCallDelta 0 (Just "call-c") (Just "bigc") "{}") $> ToolUse
    turn modelRequest emit 4 =
      writeIORef captured (requestMessages modelRequest) *> emit (ModelTextDelta "done") $> Stop
    turn _ _ _ = throwIO (ProviderFailure "unexpected model turn")

agedFixture :: Maybe ArtifactStore -> Maybe SpliceConfig -> (Runtime -> IO Runtime) -> IO ([Event], [ChatMessage])
agedFixture store splice configure =
  newIORef (0 :: Int) >>= \turns ->
    newIORef [] >>= \captured ->
      testRuntime (agedModel turns captured) [staticTool "biga" bigA, staticTool "bigb" bigB, staticTool "bigc" bigC] Sequential
        >>= \base ->
          configure base {runtimeArtifactStore = store, runtimeSplice = splice}
            >>= \runtime ->
              collectEvents runtime (sampleInput [])
                >>= \events -> (,) events <$> readIORef captured

spliceEvents :: [Event] -> [Value]
spliceEvents events = [value | Custom "context.splice" value <- events]

inertWithoutStore :: Assertion
inertWithoutStore =
  agedFixture Nothing (Just (SpliceConfig 400 1)) pure >>= \(events, messages) ->
    sequence_
      [ [content | ChatToolResult _ content <- messages] @?= [bigA, bigB, bigC],
        spliceEvents events @?= []
      ]

inertBelowThreshold :: Assertion
inertBelowThreshold =
  newMemoryArtifactStore >>= \store ->
    agedFixture (Just store) (Just (SpliceConfig 200000 1)) pure >>= \(events, messages) ->
      sequence_
        [ [content | ChatToolResult _ content <- messages] @?= [bigA, bigB, bigC],
          spliceEvents events @?= []
        ]

stubsAgedOnce :: Assertion
stubsAgedOnce =
  newMemoryArtifactStore >>= \store ->
    agedFixture (Just store) (Just (SpliceConfig 400 1)) pure >>= \(events, messages) ->
      case [content | ChatToolResult _ content <- messages] of
        [aged, middle, recent] ->
          sequence_
            [ aged @?= stubA,
              middle @?= stubB,
              recent @?= bigC,
              assertBool "a stub is never re-stubbed" (Text.isInfixOf "tool=biga" aged)
            ]
            *> (artifactFetch store (artifactIdFor bigA) >>= (@?= Just bigA))
            *> (artifactFetch store (artifactIdFor bigB) >>= (@?= Just bigB))
            *> verifyEvents events
        other -> assertFailure ("unexpected tool results: " <> show (length other))
  where
    stubA = artifactStub (artifactIdFor bigA) "biga" bigA
    stubB = artifactStub (artifactIdFor bigB) "bigb" bigB
    verifyEvents events =
      case spliceEvents events of
        [first, second] ->
          sequence_
            [ parseMaybe (withObject "splice" (.: "stubbed")) first @?= Just (1 :: Int),
              parseMaybe (withObject "splice" (.: "savedChars")) first @?= Just (Text.length bigA - Text.length stubA),
              parseMaybe (withObject "splice" (.: "keep")) first @?= Just (1 :: Int),
              parseMaybe (withObject "splice" (.: "stubbed")) second @?= Just (1 :: Int),
              parseMaybe (withObject "splice" (.: "savedChars")) second @?= Just (Text.length bigB - Text.length stubB)
            ]
        other -> assertFailure ("expected two context.splice events, got " <> show (length other))

spliceReplay :: Assertion
spliceReplay =
  newMemoryArtifactStore >>= \store ->
    newMemoryJournal >>= \(journal, readEntries) ->
      agedFixture (Just store) (Just (SpliceConfig 400 1)) (wire journal) >>= \(events, _) ->
        readEntries >>= \recorded ->
          replayEntries defaultHooks Nothing recorded >>= \report ->
            sequence_
              [ fmap reportDivergence report @?= Right Nothing,
                fmap reportEvents report @?= Right (length events),
                assertBool "journaled request carries a stub" (any stubbed recorded),
                assertBool "journaled settings carry the splice config" (any configured recorded)
              ]
  where
    wire journal runtime = pure runtime {runtimeJournal = Just journal}
    stubbed (Entry _ _ _ (ModelRequestEntry recorded)) = any stubbedMessage (requestMessages recorded)
    stubbed _ = False
    stubbedMessage (ChatToolResult _ content) = isArtifactStub content
    stubbedMessage _ = False
    configured (Entry _ _ _ (RunBegin _ settings)) = runSettingsSplice settings == Just (SpliceConfig 400 1)
    configured _ = False

spliceConfigParse :: Assertion
spliceConfigParse =
  sequence_
    [ spliceOf [] >>= (@?= (200000, 4)),
      spliceOf [("YUKI_SPLICE_CHARS", "5000"), ("YUKI_SPLICE_KEEP", "0")] >>= (@?= (5000, 0)),
      spliceOf [("YUKI_SPLICE_CHARS", "100"), ("YUKI_SPLICE_KEEP", "12")] >>= (@?= (100, 12)),
      rejected ("YUKI_SPLICE_CHARS", "0"),
      rejected ("YUKI_SPLICE_CHARS", "many"),
      rejected ("YUKI_SPLICE_KEEP", "-1"),
      rejected ("YUKI_SPLICE_KEEP", "few")
    ]
  where
    spliceOf extra =
      either
        (assertFailure . Text.unpack)
        (pure . ((,) <$> settingsSpliceChars <*> settingsSpliceKeep))
        (resolveSettings (env extra))
    env extra = Map.fromList (("DEEPSEEK_API_KEY", "secret") : extra)
    rejected (key, value) =
      either
        (const (pure ()))
        (const (assertFailure (key ++ "=" ++ value ++ " should be rejected")))
        (resolveSettings (env [(key, value)]))

contextTests :: TestTree
contextTests =
  testGroup
    "context governance"
    [ testCase "estimates ASCII and CJK tokens conservatively" contextTokenEstimate,
      testCase "compacts old dialogue within the model budget" compactsDialogue,
      testCase "anchors an assistant-only suffix with the latest user request" compactionUserAnchor,
      testCase "keeps a tool call and result as one causal unit" keepsToolCausality,
      testCase "keeps the full dropped payload addressable as an artifact" contextArtifact,
      testCase "persists the summary and compaction boundary, then replays cleanly" contextJournalReplay,
      testCase "recognizes overflow and retries once with an emergency compaction" contextOverflowRetry,
      testCase "continues calling tools after compacting an oversized result" toolAfterCompaction
    ]

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

contextTokenEstimate :: Assertion
contextTokenEstimate =
  sequence_
    [ estimateTextTokens "abc" @?= 1,
      estimateTextTokens "abcdef" @?= 2,
      estimateTextTokens "你好a" @?= 3,
      assertBool "overflow code recognized" (isContextOverflow (ProviderFailure "HTTP 400 context_length_exceeded")),
      assertBool "ordinary failure is not overflow" (not (isContextOverflow (ProviderFailure "connection reset")))
    ]

compactsDialogue :: Assertion
compactsDialogue =
  requireCompaction (compactMessages contextConfig (Just 512) [] contextConversation) $ \compaction ->
    let compacted = compactionMessages compaction
     in sequence_
          [ assertBool "old dialogue was dropped" (not (null (compactionDropped compaction))),
            assertBool "users are summarized" (any isUser (compactionDropped compaction)),
            assertBool "assistants are summarized" (any isAssistant (compactionDropped compaction)),
            take 1 compacted @?= [ChatSystem "local rules"],
            assertBool "summary is present" (any isContextSummary compacted),
            assertBool "latest assistant remains" (any latestAssistant compacted),
            assertBool "request fits its model budget" (estimateMessagesTokens compacted <= compactionBudgetTokens compaction)
          ]
  where
    isUser ChatUser {} = True
    isUser _ = False
    isAssistant ChatAssistant {} = True
    isAssistant _ = False
    latestAssistant (ChatAssistant turn) = turnMessageId turn == "message-12"
    latestAssistant _ = False

compactionUserAnchor :: Assertion
compactionUserAnchor =
  requireCompaction (compactToBudget contextConfig {contextKeepUnits = 1} 256 history) $ \compaction ->
    case dropWhile systemMessage (compactionMessages compaction) of
      ChatUser anchor : ChatAssistant {} : _ ->
        sequence_
          [ assertBool "anchor keeps the latest user intent" ("send this request" `Text.isInfixOf` anchor),
            assertBool "anchored request remains within budget" (compactionAfterTokens compaction <= compactionBudgetTokens compaction)
          ]
      suffix -> assertFailure ("expected user/assistant suffix, got " <> show suffix)
  where
    history =
      [ ChatSystem "local rules",
        ChatUser ("send this request " <> Text.replicate 300 "u"),
        ChatAssistant (AssistantTurn "latest" (Just (Text.replicate 600 "a")) Nothing [])
      ]
    systemMessage ChatSystem {} = True
    systemMessage _ = False

keepsToolCausality :: Assertion
keepsToolCausality =
  requireCompaction (compactMessages contextConfig {contextKeepUnits = 1} (Just 512) [] history) $ \compaction ->
    sequence_
      [ assertBool "call/result pair survives together" (causalPair "call-big" "big" (compactionMessages compaction)),
        assertBool "oversized result is clipped to budget" (estimateMessagesTokens (compactionMessages compaction) <= compactionBudgetTokens compaction)
      ]
  where
    history =
      contextConversation
        <> [ ChatAssistant (AssistantTurn "tool-message" Nothing Nothing [ModelToolCall "call-big" "big" "{}"]),
             ChatToolResult "call-big" (Text.replicate 1200 "result")
           ]

contextArtifact :: Assertion
contextArtifact =
  requireCompaction (compactMessages contextConfig (Just 512) [] contextConversation) $ \initial ->
    let attached = attachCompactionArtifact "artifact-123" initial
     in sequence_
          [ assertBool "summary points to full payload" (Text.isInfixOf "artifact artifact-123" (compactionSummary attached)),
            assertBool "artifact attachment stays in budget" (compactionAfterTokens attached <= compactionBudgetTokens attached),
            assertBool "full payload is not reduced to the summary" (Text.length (compactionPayload attached) > Text.length (compactionSummary attached))
          ]

contextJournalReplay :: Assertion
contextJournalReplay =
  newIORef [] >>= \captured ->
    newMemoryJournal >>= \(journal, readEntries) ->
      newMemoryArtifactStore >>= \artifacts ->
        testRuntime (capturingContextModel captured) [] Sequential >>= \base ->
          collectEvents
            base
              { runtimeJournal = Just journal,
                runtimeArtifactStore = Just artifacts,
                runtimeContext = Just contextConfig,
                runtimeSystemPrompt = "local rules"
              }
            (conversationInput (tail contextConversation))
            >>= \events ->
              readEntries >>= \entries ->
                readIORef captured >>= \messages ->
                  artifactList artifacts >>= \stored ->
                    replayEntries defaultHooks Nothing entries >>= \report ->
                      sequence_
                        [ assertBool "model sees persisted summary" (any isContextSummary messages),
                          assertBool "frontend transcript retains summary" (any summaryMessage (toAguiMessages messages)),
                          assertBool "frontend sees the impending compaction" (any statusWillCompact events),
                          assertBool "status explains the exact trigger formula" (any statusExplained events),
                          assertBool "event exposes the compaction boundary" (not (null (contextCompactEvents events))),
                          assertBool "journal stores the normal boundary" (any normalBoundary entries),
                          assertBool "journal stores the effective context window" (any configuredWindow entries),
                          assertBool "full dropped context is stored locally" (any ((== "context_compaction") . artifactMetaToolName) stored),
                          fmap reportDivergence report @?= Right Nothing
                        ]
  where
    summaryMessage (Developer message) = developerName message == Just "context-summary"
    summaryMessage _ = False
    normalBoundary (Entry _ _ _ (ContextCompactEntry _ before after budget dropped False summary)) =
      before > after && after <= budget && dropped > 0 && Text.isPrefixOf contextSummaryMarker summary
    normalBoundary _ = False
    configuredWindow (Entry _ _ _ (RunBegin _ settings)) = runSettingsContextTokens settings == Just 512
    configuredWindow _ = False
    statusWillCompact (Custom "context.status" value) =
      fromMaybe False (parseMaybe (withObject "context.status" (.: "willCompact")) value)
    statusWillCompact _ = False
    statusExplained (Custom "context.status" value) =
      fromMaybe False
        ( (\window reserve tools budget -> budget == max 256 (window - reserve - tools))
            <$> (parseMaybe (withObject "context.status" (.: "windowTokens")) value :: Maybe Int)
            <*> (parseMaybe (withObject "context.status" (.: "reserveTokens")) value :: Maybe Int)
            <*> (parseMaybe (withObject "context.status" (.: "toolTokens")) value :: Maybe Int)
            <*> (parseMaybe (withObject "context.status" (.: "budgetTokens")) value :: Maybe Int)
        )
    statusExplained _ = False

capturingContextModel :: IORef [ChatMessage] -> Model
capturingContextModel captured =
  ( fakeModel
      (\request emit -> writeIORef captured (requestMessages request) *> emit (ModelTextDelta "done") $> Stop)
  )
    { modelContextTokens = Just 512
    }

contextOverflowRetry :: Assertion
contextOverflowRetry =
  newIORef (0 :: Int) >>= \calls ->
    newIORef [] >>= \requests ->
      newMemoryJournal >>= \(journal, readEntries) ->
        testRuntime (overflowContextModel calls requests) [] Sequential >>= \base ->
          collectEvents
            base
              { runtimeJournal = Just journal,
                runtimeContext = Just contextConfig,
                runtimeProviderRetries = 3,
                runtimeSystemPrompt = "local rules"
              }
            (conversationInput (take 10 (tail contextConversation)))
            >>= \events ->
              readIORef requests >>= \seen ->
                readEntries >>= \entries ->
                  replayEntries defaultHooks Nothing entries >>= \report ->
                    verifyOverflow seen events entries report

verifyOverflow :: [ModelRequest] -> [Event] -> [Entry] -> Either Text ReplayReport -> Assertion
verifyOverflow [first, second] events entries report =
  sequence_
    [ assertBool "first request is above emergency budget" (estimateMessagesTokens (requestMessages first) > 256),
      assertBool "retry request is emergency-sized" (estimateMessagesTokens (requestMessages second) <= 256),
      length (contextCompactEvents events) @?= 1,
      assertBool "compaction is marked emergency" (all emergencyEvent (contextCompactEvents events)),
      assertBool "overflow bypasses ordinary backoff" (all (not . providerRetry) events),
      length (filter emergencyBoundary entries) @?= 1,
      fmap reportDivergence report @?= Right Nothing
    ]
verifyOverflow seen _ _ _ = assertFailure ("expected two model requests, got " <> show (length seen))

overflowContextModel :: IORef Int -> IORef [ModelRequest] -> Model
overflowContextModel calls requests =
  Model "fake" "overflow-once" (Just 512) stream (const (object []))
  where
    stream request emit =
      modifyIORef' requests (<> [request])
        *> atomicModifyIORef' calls (\count -> let next = count + 1 in (next, next))
        >>= \case
          1 -> throwIO (ProviderFailure "context_length_exceeded")
          _ -> emit (ModelTextDelta "recovered") $> Stop

toolAfterCompaction :: Assertion
toolAfterCompaction =
  newIORef (0 :: Int) >>= \turns ->
    newIORef [] >>= \second ->
      newIORef [] >>= \third ->
        testRuntime
          (compactingToolModel turns second third)
          [staticTool "big" (Text.replicate 1200 "result"), staticTool "echo" "ok"]
          Sequential
          >>= \base ->
            collectEvents base {runtimeContext = Just contextConfig} (sampleInput [])
              >>= \events ->
                readIORef second >>= \afterBig ->
                  readIORef third >>= \afterEcho ->
                    sequence_
                      [ assertBool "oversized tool pair stays causal" (causalPair "call-big" "big" afterBig),
                        assertBool "first compaction leaves a summary" (any isContextSummary afterBig),
                        assertBool "a later tool call also stays causal" (causalPair "call-echo" "echo" afterEcho),
                        assertBool "tool execution completed after compaction" (any echoResult events),
                        assertBool "oversized result triggered compaction" (not (null (contextCompactEvents events)))
                      ]
  where
    echoResult (ToolCallResult _ "call-echo" "ok") = True
    echoResult _ = False

compactingToolModel :: IORef Int -> IORef [ChatMessage] -> IORef [ChatMessage] -> Model
compactingToolModel turns second third =
  Model "fake" "tool-after-compaction" (Just 512) stream (const (object []))
  where
    stream request emit =
      atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next)) >>= turn request emit
    turn _ emit 1 = emit (ModelToolCallDelta 0 (Just "call-big") (Just "big") "{}") $> ToolUse
    turn request emit 2 =
      writeIORef second (requestMessages request)
        *> emit (ModelToolCallDelta 0 (Just "call-echo") (Just "echo") "{}")
        $> ToolUse
    turn request emit 3 = writeIORef third (requestMessages request) *> emit (ModelTextDelta "done") $> Stop
    turn _ _ _ = throwIO (ProviderFailure "unexpected model turn")

conversationInput :: [ChatMessage] -> RunAgentInput
conversationInput messages = (sampleInput []) {runMessages = toAguiMessages messages}

contextCompactEvents :: [Event] -> [Value]
contextCompactEvents events = [value | Custom "context.compact" value <- events]

emergencyEvent :: Value -> Bool
emergencyEvent = fromMaybe False . parseMaybe (withObject "context.compact" (.: "emergency"))

emergencyBoundary :: Entry -> Bool
emergencyBoundary (Entry _ _ _ (ContextCompactEntry _ _ _ _ _ True _)) = True
emergencyBoundary _ = False

providerRetry :: Event -> Bool
providerRetry (Custom "provider.retry" _) = True
providerRetry _ = False

isContextSummary :: ChatMessage -> Bool
isContextSummary (ChatSystem text) = contextSummaryMarker `Text.isPrefixOf` text
isContextSummary _ = False

causalPair :: Text -> Text -> [ChatMessage] -> Bool
causalPair callId name messages = any paired (zip messages (drop 1 messages))
  where
    paired (ChatAssistant turn, ChatToolResult resultId _) =
      resultId == callId && any (\call -> modelToolCallId call == callId && modelToolName call == name) (turnToolCalls turn)
    paired _ = False

requireCompaction :: Maybe Compaction -> (Compaction -> Assertion) -> Assertion
requireCompaction planned verify = maybe (assertFailure "expected context compaction") verify planned

subAgentTests :: TestTree
subAgentTests =
  testGroup
    "sub-agents"
    [ testCase "delegates to a scoped sub-run and replays cleanly" delegation,
      testCase "refuses delegation at depth zero" depthExhausted,
      testCase "advertises the child's exact inherited tools" capabilityDescription,
      testCase "a resolved cwd lets the child execute a local shell request" inheritedShell,
      testCase "resolveRuntime registers sub_agent only above depth zero" registration
    ]
  where
    capabilityDescription =
      testRuntime okModel [staticTool "shell" "ok", staticTool "fs_read" "ok"] Parallel
        >>= \base ->
          case Map.lookup "sub_agent" (runtimeTools (registerSubAgent base)) of
            Nothing -> assertFailure "missing sub_agent"
            Just backend ->
              let description = toolDescription (backendToolSpec backend)
               in sequence_
                    [ assertBool "description names shell" ("shell" `Text.isInfixOf` description),
                      assertBool "description names fs_read" ("fs_read" `Text.isInfixOf` description),
                      assertBool "description excludes itself" (not ("sub_agent" `Text.isInfixOf` description))
                    ]
    inheritedShell =
      withWorkDir $ \dir ->
        newTlsManager >>= \manager ->
          testRuntime subShellModel [] Sequential >>= \base ->
            resolveRuntime
              manager
              testProvider
              Nothing
              base
              (emptyThreadConfig {configCwd = CwdPath dir})
              Map.empty
              Map.empty
              >>= \runtime ->
                collectEvents runtime (sampleInput [])
                  >>= \events ->
                    sequence_
                      [ assertBool "parent receives the child answer" (any childAnswer events),
                        assertBool "nested event exposes the shell call" (any nestedShell events)
                      ]
    childAnswer (ToolCallResult _ "call-delegate" content) = "child-ok" `Text.isInfixOf` content
    childAnswer _ = False
    nestedShell (Custom "agent.sub" value) =
      parseMaybe
        ( withObject "agent.sub" $ \fields ->
            fields .: "event"
              >>= withObject
                "event"
                (\event -> (,) <$> event .: "type" <*> event .:? "toolCallName")
        )
        value
        == Just ("TOOL_CALL_START" :: Text, Just ("shell" :: Text))
    nestedShell _ = False
    registration =
      newTlsManager >>= \manager ->
        testRuntime okModel [] Parallel >>= \base ->
          let resolved depth = resolveRuntime manager testProvider Nothing base {runtimeDepth = depth} emptyThreadConfig Map.empty Map.empty
           in (,,) <$> resolved 1 <*> resolved 2 <*> resolved 0 >>= \(one, two, zero) ->
                sequence_
                  [ assertBool "depth one registers" (Map.member "sub_agent" (runtimeTools one)),
                    assertBool "deeper still registers" (Map.member "sub_agent" (runtimeTools two)),
                    assertBool "depth zero omits" (Map.notMember "sub_agent" (runtimeTools zero)),
                    runtimeDepth one @?= 1
                  ]
    delegation =
      newMemoryJournal >>= \(journal, readEntries) ->
        delegateRuntime journal 1 >>= \runtime ->
          collectEvents runtime (sampleInput [])
            >>= \events ->
              readEntries
                >>= \recorded ->
                  replayEntries defaultHooks Nothing recorded
                    >>= \report ->
                      sequence_
                        [ [content | ToolCallResult _ "call-delegate" content <- events] @?= ["sub result"],
                          assertBool "sub-run events are scoped" (any isSubEvent events),
                          assertBool "journal nests the sub-run scope" (any ((== 2) . length . entryScope) recorded),
                          fmap reportDivergence report @?= Right Nothing
                        ]
    depthExhausted =
      newMemoryJournal >>= \(journal, _) ->
        delegateRuntime journal 0 >>= \runtime ->
          collectEvents runtime (sampleInput [])
            >>= \events ->
              sequence_
                [ [content | ToolCallResult _ "call-delegate" content <- events] @?= ["delegation depth exhausted"],
                  assertBool "no sub-run events" (all (not . isSubEvent) events)
                ]
    isSubEvent (Custom "agent.sub" _) = True
    isSubEvent _ = False

subShellModel :: Model
subShellModel =
  fakeModel $ \request emit ->
    case lastMessage request of
      Just (ChatToolResult "call-delegate" _) -> emit (ModelTextDelta "parent done") $> Stop
      Just (ChatToolResult "call-shell" content) -> emit (ModelTextDelta content) $> Stop
      Just (ChatUser "run local shell") ->
        emit (ModelToolCallDelta 0 (Just "call-shell") (Just "shell") "{\"command\":\"printf child-ok\"}")
          $> ToolUse
      _ ->
        emit (ModelToolCallDelta 0 (Just "call-delegate") (Just "sub_agent") "{\"prompt\":\"run local shell\"}")
          $> ToolUse

delegateRuntime :: Journal -> Int -> IO Runtime
delegateRuntime journal depth =
  testRuntime subAgentModel [] Parallel >>= \base ->
    let tools = Map.fromList [("delegate", subAgentTool "delegate" "run a sub-agent" runtime)]
        runtime = base {runtimeJournal = Just journal, runtimeTools = tools, runtimeDepth = depth}
     in pure runtime

subAgentModel :: Model
subAgentModel =
  fakeModel $ \request emit ->
    case lastMessage request of
      Just (ChatToolResult {}) -> emit (ModelTextDelta "parent done") $> Stop
      Just (ChatUser "sub task") -> emit (ModelTextDelta "sub result") $> Stop
      _ ->
        emit (ModelToolCallDelta 0 (Just "call-delegate") (Just "delegate") "{\"prompt\":\"sub task\"}")
          $> ToolUse

hooksTests :: TestTree
hooksTests =
  testGroup
    "agent hooks"
    [ testCase "mempty is neutral" identity,
      testCase "steering appends in order" ordering,
      testCase "beforeToolCall stops at the first denial" denial,
      testCase "afterToolCall chains" chaining
    ]
  where
    identity =
      (getSteeringMessages (mempty <> steering "x") (sampleInput []) >>= (@?= [ChatSystem "x"]))
        *> (getSteeringMessages (steering "x" <> mempty) (sampleInput []) >>= (@?= [ChatSystem "x"]))
    ordering =
      getSteeringMessages (steering "a" <> steering "b") (sampleInput [])
        >>= (@?= [ChatSystem "a", ChatSystem "b"])
    denial =
      newIORef False >>= \called ->
        beforeToolCall (deny <> spy called) someCall
          >>= \result ->
            readIORef called >>= \wasCalled ->
              sequence_ [result @?= Left "no", wasCalled @?= False]
    chaining =
      afterToolCall (mark "a" <> mark "b") someCall (ToolOutcome "x" False False)
        >>= (@?= ToolOutcome "xab" False False)
    steering text = defaultHooks {getSteeringMessages = const (pure [ChatSystem text])}
    deny = defaultHooks {beforeToolCall = const (pure (Left "no"))}
    spy ref = defaultHooks {beforeToolCall = const (writeIORef ref True *> pure (Right ()))}
    mark suffix =
      defaultHooks
        { afterToolCall = \_ outcome ->
            pure outcome {toolOutcomeContent = toolOutcomeContent outcome <> suffix}
        }
    someCall = ModelToolCall "call" "echo" "{}"

machineTests :: TestTree
machineTests =
  testGroup
    "response machine"
    [ testCase "emits text lifecycle in order" textLifecycle,
      testCase "closes reasoning before text" reasoningThenText,
      testCase "rejects reasoning after final content" lateReasoning,
      testCase "announces a tool call once and completes it at close" toolLifecycle,
      testCase "rejects an incomplete tool call at close" incompleteTool,
      testCase "emits collected usage at close" usageClose,
      testCase "omits the usage event without usage" noUsage
    ]
  where
    textLifecycle =
      ( steps [ModelTextDelta "hello"] >>= \(state, events) ->
          closeModelTurn "m" "r" state >>= \closed ->
            Right (events, closed)
      )
        @?= Right
          ( [TextMessageStarted "m", TextMessageContent "m" "hello"],
            ([TextMessageEnded "m"], AssistantTurn "m" (Just "hello") Nothing [])
          )
    reasoningThenText =
      fmap snd (steps [ModelReasoningDelta "r1", ModelTextDelta "t"])
        @?= Right
          [ ReasoningStarted "r",
            ReasoningMessageStarted "r",
            ReasoningMessageContent "r" "r1",
            ReasoningMessageEnded "r",
            ReasoningEnded "r",
            TextMessageStarted "m",
            TextMessageContent "m" "t"
          ]
    lateReasoning =
      assertLeft (steps [ModelTextDelta "t", ModelReasoningDelta "x"])
    toolLifecycle =
      ( steps
          [ ModelToolCallDelta 0 (Just "c") (Just "f") "{\"a\":",
            ModelToolCallDelta 0 Nothing Nothing "1}"
          ]
          >>= \(state, events) ->
            closeModelTurn "m" "r" state >>= \closed ->
              Right (events, closed)
      )
        @?= Right
          ( [ ToolCallStarted "c" "f" (Just "m"),
              ToolCallArguments "c" "{\"a\":",
              ToolCallArguments "c" "1}"
            ],
            ([ToolCallEnded "c"], AssistantTurn "m" Nothing Nothing [ModelToolCall "c" "f" "{\"a\":1}"])
          )
    incompleteTool =
      assertLeft (fmap fst (steps [ModelToolCallDelta 0 (Just "c") Nothing "{}"]) >>= closeModelTurn "m" "r")
    usageClose =
      ( steps [ModelTextDelta "hi", ModelUsage (Usage (Just 10) (Just 5) (Just 3) (Just 7))]
          >>= \(state, events) ->
            closeModelTurn "m" "r" state >>= \closed ->
              Right (events, closed)
      )
        @?= Right
          ( [TextMessageStarted "m", TextMessageContent "m" "hi"],
            ( [ TextMessageEnded "m",
                Custom
                  "usage"
                  ( object
                      [ "promptTokens" .= (10 :: Int),
                        "completionTokens" .= (5 :: Int),
                        "cacheHitTokens" .= (3 :: Int),
                        "cacheMissTokens" .= (7 :: Int)
                      ]
                  )
              ],
              AssistantTurn "m" (Just "hi") Nothing []
            )
          )
    noUsage =
      (steps [ModelTextDelta "hi"] >>= \(state, _) -> fst <$> closeModelTurn "m" "r" state)
        @?= Right [TextMessageEnded "m"]

steps :: [ModelEvent] -> Either ProviderFailure (ResponseState, [Event])
steps = foldl apply (Right (emptyResponse, []))
  where
    apply acc event =
      acc >>= \(state, events) ->
        (\(state', new) -> (state', events <> new)) <$> stepModelEvent "m" "r" state event

auditTests :: TestTree
auditTests =
  testGroup
    "audit journal"
    [ testCase "replays a journaled run without divergence" cleanReplay,
      testCase "detects a tampered event" tampered,
      testCase "records the wire-level api.request entry" wireRequest,
      testCase "entry JSON round-trips with and without a timestamp" entryTimeJson,
      testCase "file journal resumes its global sequence across restarts" journalRestartSequence,
      testCase "recovers and reports an incomplete final journal line" journalTailRecovery,
      testCase "rejects corruption in the middle of a journal" journalMiddleCorruption,
      testCase "atomic stores survive orphaned crash-temporary files" atomicStoreRecovery,
      testCase "aggregates a mixed journal into a run summary" summaryAggregates,
      testCase "reduces noisy journal events into one causal run trace" traceAggregates
    ]
  where
    cleanReplay =
      journaledRun >>= \(events, recorded) ->
        replayEntries defaultHooks Nothing recorded >>= \report ->
          sequence_
            [ fmap reportDivergence report @?= Right Nothing,
              fmap reportEvents report @?= Right (length events)
            ]
    tampered =
      journaledRun >>= \(_, recorded) ->
        replayEntries defaultHooks Nothing (forge recorded) >>= \report ->
          assertBool "tampering is detected" (either (const False) (\r -> reportDivergence r /= Nothing) report)
    forge =
      fmap
        ( \entry -> case entryKind entry of
            AgentEventEntry (TextMessageContent messageId _) ->
              entry {entryKind = AgentEventEntry (TextMessageContent messageId "forged")}
            _ -> entry
        )
    wireRequest =
      journaledRun >>= \(_, recorded) ->
        case [value | Entry _ _ _ (ApiRequestEntry value) <- recorded] of
          [] -> assertFailure "missing api.request entry"
          (value : _) ->
            sequence_
              [ parseMaybe (withObject "api.request" (.: "model")) value @?= Just ("base-model" :: Text),
                parseMaybe (withObject "api.request" (.: "messages")) value
                  @?= Just [object ["role" .= ("user" :: Text), "content" .= ("hello" :: Text)]]
              ]

entryTimeJson :: Assertion
entryTimeJson =
  sequence_
    [ eitherDecode (encode stamped) @?= Right stamped,
      eitherDecode (encode unstamped) @?= Right unstamped,
      eitherDecode legacy @?= Right legacyEntry
    ]
  where
    stamped = Entry 7 ["run"] (Just 1700000000) (IdEntry "id-1")
    unstamped = Entry 8 ["run"] Nothing (IdEntry "id-2")
    legacyEntry = Entry 9 ["run"] Nothing (IdEntry "id-3")
    legacy =
      encode
        ( object
            [ "seq" .= (9 :: Int),
              "scope" .= (["run"] :: [Text]),
              "kind" .= ("id" :: Text),
              "value" .= ("id-3" :: Text)
            ]
        )

journalRestartSequence :: Assertion
journalRestartSequence =
  withWorkDir $ \dir ->
    newFileJournal dir >>= \first ->
      recordMaybe (Just first) (IdEntry "before")
        *> newFileJournal dir >>= \second ->
          recordMaybe (Just second) (IdEntry "after")
            *> readJournal (journalFilePath dir)
            >>= either (assertFailure . Text.unpack) (\entries -> fmap entrySeq entries @?= [0, 1])

journalTailRecovery :: Assertion
journalTailRecovery =
  withWorkDir $ \dir ->
    let path = journalFilePath dir
        intact =
          [ Entry 4 ["run-a"] (Just 1) (IdEntry "a"),
            Entry 9 ["run-b"] (Just 2) (IdEntry "b")
          ]
     in LazyByteString.writeFile path (renderJournal intact <> "{\"seq\":10")
          *> readJournalFile path >>= \case
            Left failure -> assertFailure (Text.unpack failure)
            Right snapshot ->
              sequence_
                [ journalReadEntries snapshot @?= intact,
                  assertBool "truncated tail is reported" (maybe False (Text.isInfixOf "incomplete final line") (journalReadWarning snapshot))
                ]
                *> newFileJournal dir >>= \journal ->
                  recordMaybe (Just journal) (IdEntry "continued")
                    *> readJournal path
                    >>= either
                      (assertFailure . Text.unpack)
                      (\entries -> sequence_ [fmap entrySeq entries @?= [4, 9, 10], fmap entryKind entries @?= fmap entryKind intact <> [IdEntry "continued"]])
  where
    renderJournal = LazyByteString.concat . fmap ((<> "\n") . encode)

journalMiddleCorruption :: Assertion
journalMiddleCorruption =
  withWorkDir $ \dir ->
    let path = journalFilePath dir
        entry = Entry 0 [] Nothing (IdEntry "ok")
     in LazyByteString.writeFile path (encode entry <> "\n{broken}\n" <> encode entry <> "\n")
          *> readJournalFile path
          >>= either
            (\failure -> assertBool "failure names the corrupt middle line" ("journal line 2" `Text.isInfixOf` failure))
            (const (assertFailure "middle corruption was silently accepted"))

atomicStoreRecovery :: Assertion
atomicStoreRecovery =
  withWorkDir $ \dir ->
    newTranscriptStore dir >>= \transcripts ->
      newThreadConfigStore dir >>= \configs ->
        newThreadStore dir >>= \threads ->
          newFileJournal dir >>= \journal ->
            let config = emptyThreadConfig {configSystemPrompt = Just "kept"}
                history = [ChatUser "hello", ChatAssistant (AssistantTurn "answer" (Just "world") Nothing [])]
             in transcriptSave transcripts "thread" history
                  *> threadConfigWrite configs "thread" config
                  *> threadSaveEpisode threads "thread" (Episode "run-1" "memory" 1700000000)
                  *> recordMaybe (Just journal) (IdEntry "before-crash")
                  *> traverse_
                    (\path -> TextIO.writeFile path "{partial")
                    [ dir ++ "/transcripts/thread.json.tmp-killed",
                      dir ++ "/threads-config/thread.json.tmp-killed",
                      dir ++ "/threads/thread.json.tmp-killed"
                    ]
                  *> LazyByteString.appendFile (journalFilePath dir) "{\"seq\":"
                  *> newTranscriptStore dir >>= \reopenedTranscripts ->
                    newThreadConfigStore dir >>= \reopenedConfigs ->
                      newThreadStore dir >>= \reopenedThreads ->
                        newFileJournal dir >>= \reopenedJournal ->
                          recordMaybe (Just reopenedJournal) (IdEntry "after-crash")
                            *> transcriptLoad reopenedTranscripts "thread" >>= \savedHistory ->
                              threadConfigRead reopenedConfigs "thread" >>= \savedConfig ->
                                threadBrief reopenedThreads "thread" >>= \savedBrief ->
                                  readJournal (journalFilePath dir)
                                    >>= either
                                      (assertFailure . Text.unpack)
                                      ( \entries ->
                                          sequence_
                                            [ savedHistory @?= Just history,
                                              savedConfig @?= config,
                                              fmap briefRollingSummary savedBrief @?= Just "memory",
                                              fmap entrySeq entries @?= [0, 1],
                                              fmap entryKind entries @?= [IdEntry "before-crash", IdEntry "after-crash"]
                                            ]
                                      )

summaryAggregates :: Assertion
summaryAggregates =
  sequence_
    [ runSummary "run-a" mixed @?= Just expectedA,
      fmap summaryStatus (runSummary "run-b" mixed) @?= Just "open",
      runSummary "run-c" mixed @?= Nothing
    ]
  where
    inputA = (sampleInput []) {runId = "run-a"}
    inputB = (sampleInput []) {runId = "run-b"}
    settings = RunSettings 8 Parallel "" 1 Nothing Nothing Nothing
    usageEvent' prompt completion hit =
      Custom
        "usage"
        ( object
            [ "promptTokens" .= prompt,
              "completionTokens" .= completion,
              "cacheHitTokens" .= hit
            ]
        )
    mixed =
      [ Entry 1 ["run-a"] (Just 100) (RunBegin inputA settings),
        Entry 2 ["run-a"] (Just 110) (ModelRequestEntry (ModelRequest [] [])),
        Entry 3 ["run-a"] (Just 120) (ApiRequestEntry (object ["model" .= ("m" :: Text)])),
        Entry 4 ["run-a"] (Just 130) (AgentEventEntry (usageEvent' (10 :: Int) (5 :: Int) (3 :: Int))),
        Entry 5 ["run-a"] (Just 140) (ToolCallEntry "c1" "echo" "{}" (ToolOutcome "ok" False False)),
        Entry 6 ["run-a", "memory"] (Just 150) (ModelRequestEntry (ModelRequest [] [])),
        Entry 7 ["run-a"] (Just 160) (AgentEventEntry (Custom "usage" (object ["promptTokens" .= (2 :: Int)]))),
        Entry 8 ["run-a"] (Just 170) (AgentEventEntry (RunFinished "thread" "run-a" Nothing)),
        Entry 9 ["run-b"] Nothing (RunBegin inputB settings)
      ]
    expectedA =
      RunSummary
        "run-a"
        "thread"
        8
        2
        1
        3
        1
        (UsageSum 12 5 3)
        1
        "finished"
        1
        8
        (Just 100)
        (Just 170)

traceAggregates :: Assertion
traceAggregates =
  case runTrace "run-trace" entries of
    Nothing -> assertFailure "trace was not built"
    Just trace ->
      let traceRows = traceSteps trace
       in sequence_
            [ traceStatus trace @?= "finished",
              length (filter ((== "assistant") . traceStepKind) traceRows) @?= 1,
              length (filter ((== "tool") . traceStepKind) traceRows) @?= 1,
              length (filter ((== "terminal") . traceStepKind) traceRows) @?= 1,
              fmap traceStepArtifactIds (listToMaybe (filter ((== "tool") . traceStepKind) traceRows))
                @?= Just ["art-abc123"]
            ]
  where
    input = (sampleInput []) {runId = "run-trace"}
    settings = RunSettings 8 Parallel "" 1 Nothing Nothing Nothing
    entries =
      [ Entry 1 ["run-trace"] (Just 100) (RunBegin input settings),
        Entry 2 ["run-trace"] (Just 101) (ModelRequestEntry (ModelRequest [] [])),
        Entry 3 ["run-trace"] (Just 102) (AgentEventEntry (ReasoningStarted "reason-1")),
        Entry 4 ["run-trace"] (Just 103) (AgentEventEntry (ReasoningEnded "reason-1")),
        Entry 5 ["run-trace"] (Just 104) (AgentEventEntry (TextMessageContent "message-1" "answer")),
        Entry 6 ["run-trace"] (Just 105) (AgentEventEntry (TextMessageContent "message-1" "answer")),
        Entry 7 ["run-trace"] (Just 106) (ToolCallEntry "call-1" "inspect" "{\"path\":\"x\"}" (ToolOutcome "[artifact art-abc123]" False False)),
        Entry 8 ["run-trace"] (Just 107) (AgentEventEntry (RunFinished "thread" "run-trace" Nothing)),
        Entry 9 ["run-trace"] (Just 108) (AgentEventEntry (RunFinished "thread" "run-trace" Nothing))
      ]

journaledRun :: IO ([Event], [Entry])
journaledRun =
  newMemoryJournal >>= \(journal, readEntries) ->
    testRuntime echoModel [echoTool] Parallel >>= \base ->
      collectEvents base {runtimeJournal = Just journal} (sampleInput [])
        >>= \events -> readEntries >>= \recorded -> pure (events, recorded)

echoModel :: Model
echoModel = (fakeModel stream) {modelRender = requestValue testProvider}
  where
    stream request emit =
      case lastMessage request of
        Just (ChatToolResult {}) -> emit (ModelTextDelta "done") $> Stop
        _ -> emit (ModelToolCallDelta 0 (Just "call-echo") (Just "echo") "{\"x\":1}") $> ToolUse

echoTool :: BackendTool
echoTool = jsonTool (tool "echo") (\(value :: Value) -> pure (Right value))

lastMessage :: ModelRequest -> Maybe ChatMessage
lastMessage = listToMaybe . reverse . requestMessages

assertLeft :: Either e a -> Assertion
assertLeft = either (const (pure ())) (const (assertFailure "expected Left"))

artifactTests :: TestTree
artifactTests =
  testGroup
    "artifacts"
    [ testCase "elides a duplicate large tool result as a reference stub" elidesDuplicate,
      testCase "keeps small duplicate results inline" keepsSmall,
      testCase "lists a human preview and accepts legacy metadata" artifactPreview,
      testCase "does not store a tool-produced artifact guidance twice" guidedArtifactOnce,
      testCase "reads back a stored artifact in full" readsBack,
      testCase "replays a journaled run with duplicates without divergence" replaysClean
    ]

bigContent :: Text
bigContent = Text.replicate 40 "0123456789abcdefghijklmnopqrstuvwxyz ABCDEF"

withArtifactStore :: (ArtifactStore -> Assertion) -> Assertion
withArtifactStore action =
  getTemporaryDirectory >>= \tmp ->
    newId >>= \identifier ->
      let dir = tmp ++ "/" ++ Text.unpack identifier
       in createDirectoryIfMissing True dir *> newArtifactStore dir >>= action

dupCalls :: Text -> IORef Int -> IORef [ChatMessage] -> Model
dupCalls name turns captured =
  fakeModel $ \modelRequest emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next))
      >>= turn modelRequest emit
  where
    turn _ emit 1 =
      emit (ModelToolCallDelta 0 (Just "call-a") (Just name) "{}")
        *> emit (ModelToolCallDelta 1 (Just "call-b") (Just name) "{}")
        $> ToolUse
    turn modelRequest emit 2 =
      writeIORef captured (requestMessages modelRequest) *> emit (ModelTextDelta "done") $> Stop
    turn _ _ _ = throwIO (ProviderFailure "unexpected model turn")

staticTool :: Text -> Text -> BackendTool
staticTool name content =
  BackendTool (tool name) (\_ _ -> pure (ToolOutcome content False False))

elidesDuplicate :: Assertion
elidesDuplicate =
  withArtifactStore $ \store ->
    newIORef (0 :: Int) >>= \turns ->
      newIORef [] >>= \captured ->
        testRuntime (dupCalls "big" turns captured) [staticTool "big" bigContent] Sequential >>= \base ->
          collectEvents base {runtimeArtifactStore = Just store} (sampleInput []) >>= \events ->
            readIORef captured >>= verify events
  where
    verify events messages =
      case [content | ChatToolResult _ content <- messages] of
        [first, second] ->
          sequence_
            [ first @?= bigContent,
              assertBool "second result is a reference stub" (isArtifactStub second),
              assertBool "stub names the artifact" (Text.isInfixOf (artifactIdFor bigContent) second),
              assertBool "stub keeps an excerpt" (Text.isInfixOf (Text.take 200 bigContent) second),
              [content | ToolCallResult _ _ content <- events] @?= [bigContent, bigContent]
            ]
        other -> assertFailure ("unexpected tool results: " <> show (length other))

keepsSmall :: Assertion
keepsSmall =
  withArtifactStore $ \store ->
    newIORef (0 :: Int) >>= \turns ->
      newIORef [] >>= \captured ->
        testRuntime (dupCalls "small" turns captured) [staticTool "small" "tiny result"] Sequential >>= \base ->
          collectEvents base {runtimeArtifactStore = Just store} (sampleInput [])
            *> readIORef captured
            >>= \messages ->
              [content | ChatToolResult _ content <- messages] @?= ["tiny result", "tiny result"]

artifactPreview :: Assertion
artifactPreview =
  newMemoryArtifactStore >>= \store ->
    artifactSave store "shell" "alpha\n\n beta\tgamma"
      *> artifactList store
      >>= \case
        [meta] ->
          sequence_
            [ artifactMetaPreview meta @?= "alpha beta gamma",
              eitherDecode
                "{\"id\":\"art-legacy\",\"toolName\":\"shell\",\"chars\":3,\"time\":1}"
                @?= Right (ArtifactMeta "art-legacy" "shell" "" 3 1)
            ]
        metas -> assertFailure ("expected one artifact, got " <> show (length metas))

guidedArtifactOnce :: Assertion
guidedArtifactOnce =
  newMemoryArtifactStore >>= \store ->
    artifactSave store "shell" bigContent >>= \identifier ->
      newIORef (0 :: Int) >>= \turns ->
        newIORef [] >>= \captured ->
          let guided =
                Text.take 220 bigContent
                  <> "\n[artifact "
                  <> identifier
                  <> ": full shell output; call artifact_read]"
           in testRuntime (dupCalls "shell" turns captured) [staticTool "shell" guided] Sequential
                >>= \base ->
                  collectEvents base {runtimeArtifactStore = Just store} (sampleInput [])
                    *> artifactList store
                    >>= \metas ->
                      sequence_
                        [ length metas @?= 1,
                          fmap artifactMetaId metas @?= [identifier]
                        ]

readsBack :: Assertion
readsBack =
  withArtifactStore $ \store ->
    artifactSave store "big" bigContent >>= \identifier ->
      newIORef [] >>= \captured ->
        testRuntime (readBackModel identifier captured) [artifactReadTool store] Sequential >>= \base ->
          collectEvents base {runtimeArtifactStore = Just store} (sampleInput [])
            *> readIORef captured
            >>= \messages ->
              [content | ChatToolResult _ content <- messages] @?= [bigContent]

readBackModel :: Text -> IORef [ChatMessage] -> Model
readBackModel identifier captured =
  fakeModel $ \modelRequest emit ->
    case lastMessage modelRequest of
      Just (ChatToolResult {}) ->
        writeIORef captured (requestMessages modelRequest) *> emit (ModelTextDelta "done") $> Stop
      _ ->
        emit (ModelToolCallDelta 0 (Just "call-read") (Just artifactReadToolName) ("{\"id\":\"" <> identifier <> "\"}"))
          $> ToolUse

replaysClean :: Assertion
replaysClean =
  withArtifactStore $ \store ->
    newMemoryJournal >>= \(journal, readEntries) ->
      newIORef (0 :: Int) >>= \turns ->
        newIORef [] >>= \captured ->
          testRuntime (dupCalls "big" turns captured) [staticTool "big" bigContent] Sequential >>= \base ->
            collectEvents base {runtimeJournal = Just journal, runtimeArtifactStore = Just store} (sampleInput [])
              >>= \events ->
                readEntries >>= \recorded ->
                  replayEntries defaultHooks Nothing recorded >>= \report ->
                    sequence_
                      [ fmap reportDivergence report @?= Right Nothing,
                        fmap reportEvents report @?= Right (length events)
                      ]

anatomyTests :: TestTree
anatomyTests =
  testGroup
    "token anatomy"
    [ testCase "aggregates categories across model requests" aggregates,
      testCase "treats an empty journal as zero" emptyJournal
    ]
  where
    aggregates =
      anatomyEntries specimen
        @?= AnatomyReport
          2
          (Anatomy 8 (2 * specimenSize) 20 36 8 32)
          (Just (Anatomy 4 specimenSize 12 24 4 16))
    emptyJournal = anatomyEntries [] @?= AnatomyReport 0 mempty Nothing

specimen :: [Entry]
specimen =
  [ Entry 1 ["run"] Nothing (ModelRequestEntry firstRequest),
    Entry 2 ["run"] Nothing (ModelEventEntry (ModelTextDelta "noise")),
    Entry 3 ["run"] Nothing (ModelRequestEntry secondRequest)
  ]

specimenSize :: Int
specimenSize = fromIntegral (LazyByteString.length (encode [specimenSpec]))

specimenSpec :: ToolSpec
specimenSpec = ToolSpec "echo" "echo" (object ["type" .= ("object" :: Text)])

firstRequest :: ModelRequest
firstRequest =
  ModelRequest
    [ ChatSystem (Text.replicate 4 "s"),
      ChatUser (Text.replicate 8 "u"),
      ChatAssistant
        ( AssistantTurn
            "m1"
            (Just (Text.replicate 4 "b"))
            (Just (Text.replicate 4 "r"))
            [ModelToolCall "c1" "echo" (Text.replicate 8 "a")]
        ),
      ChatToolResult "c1" (Text.replicate 16 "t")
    ]
    [specimenSpec]

secondRequest :: ModelRequest
secondRequest =
  ModelRequest
    ( requestMessages firstRequest
        <> [ ChatAssistant (AssistantTurn "m2" (Just (Text.replicate 12 "b")) Nothing []),
             ChatUser (Text.replicate 4 "u")
           ]
    )
    [specimenSpec]

memoryTests :: TestTree
memoryTests =
  testGroup
    "memory"
    [ testCase "watches only the increment of a thread" increments,
      testCase "persists an episode when the run finishes" episodeOnDisk,
      testCase "watcher failure never breaks the run" failureIsolation,
      testCase "composes with business afterRun hooks" composition,
      testCase "injects the brief once when transformed twice" briefingIdempotent,
      testCase "renders the briefing at the head with marker, summary, episodes and as-of time" briefingStructure,
      testCase "caps the rolling summary at 2000 characters" briefingCap,
      testCase "carries the brief into the next run exactly once" briefingAcrossRuns,
      testCase "announces context injections as custom events" injectionEvents,
      testCase "replays a journaled run with briefing without divergence" briefingReplay,
      testCase "replays a memory-enabled journal via replayWithStores without divergence" briefingReplayWithStores,
      testCase "multi-run memory replay resumes after the prior run boundary" multiRunMemoryReplay,
      testCase "replayWithStores leaves the live ThreadStore unchanged" storesUnchangedAfterReplay,
      testCase "replayFile gates journals with memory-injected requests" replayFileGateForMemory
    ]

injectionEvents :: Assertion
injectionEvents =
  newMemoryThreadStore >>= \store ->
    newMemoryFactStore >>= \facts ->
      newMemoryState >>= \state ->
        testRuntime (fakeModel (\_ emit -> emit (ModelTextDelta "ok") $> Stop)) [] Sequential >>= \base ->
          threadSaveEpisode store "thread" (Episode "run-0" "did things" 1700000000)
            *> collectEvents base {runtimeHooks = memoryHooks rollingWatcher store facts Nothing state} (sampleInput [])
            >>= \events ->
              case [text | Custom "context.inject" value <- events, Just text <- [injectedText value]] of
                [text] -> assertBool "injection carries the brief" (Text.isInfixOf "did things" text)
                other -> assertFailure ("expected one context.inject, got " <> show (length other))
  where
    injectedText = parseMaybe (withObject "inject" (.: "content"))

rollingWatcher :: Model
rollingWatcher = fakeModel (\_ emit -> emit (ModelTextDelta "rolling memo") $> Stop)

markedMessage :: ChatMessage -> Bool
markedMessage (ChatSystem text) = briefingMarker `Text.isInfixOf` text
markedMessage _ = False

briefingCount :: [ChatMessage] -> Int
briefingCount = length . filter markedMessage

briefingIdempotent :: Assertion
briefingIdempotent =
  newMemoryThreadStore >>= \store ->
    threadSaveEpisode store "thread" (Episode "run-0" "did things" 1700000000)
      *> newMemoryFactStore
      >>= \facts -> newMemoryState >>= exercise store facts
  where
    exercise store facts state =
      transformContext hooks input [ChatUser "hi"]
        >>= \once ->
          transformContext hooks input once >>= \twice ->
            sequence_ [briefingCount twice @?= 1, twice @?= once]
      where
        hooks = memoryHooks rollingWatcher store facts Nothing state
        input = sampleInput []

briefingStructure :: Assertion
briefingStructure =
  newMemoryThreadStore >>= \store ->
    threadSaveEpisode store "thread" (Episode "run-0" "did things" 1700000000)
      *> threadSaveEpisode store "thread" (Episode "run-1" "shipped" 1700000100)
      *> newMemoryFactStore
      >>= \facts ->
        newMemoryState
        >>= \state ->
          ( transformContext (memoryHooks rollingWatcher store facts Nothing state) (sampleInput []) [ChatUser "hi"]
              >>= verify
          )
            *> (newMemoryThreadStore >>= empty facts)
  where
    verify (ChatSystem text : rest) =
      sequence_
        [ rest @?= [ChatUser "hi"],
          init (Text.lines text)
            @?= [ briefingMarker,
                  "summary: shipped",
                  "episode 2023-11-14T22:13:20Z: did things",
                  "episode 2023-11-14T22:15:00Z: shipped"
                ],
          assertBool "an as-of line closes the briefing" ("as of 2023-11-14T22:15:00Z" == last (Text.lines text))
        ]
    verify other = assertFailure ("briefing missing at head: " <> show (length other) <> " messages")
    empty facts store =
      newMemoryState >>= \state ->
        transformContext (memoryHooks rollingWatcher store facts Nothing state) (sampleInput []) [ChatUser "hi"]
          >>= (@?= [ChatUser "hi"])

briefingCap :: Assertion
briefingCap =
  newMemoryThreadStore >>= \store ->
    threadSaveEpisode store "thread" (Episode "run-0" (Text.replicate 3000 "x") 1700000000)
      *> newMemoryFactStore
      >>= \facts ->
        newMemoryState
        >>= \state ->
          transformContext (memoryHooks rollingWatcher store facts Nothing state) (sampleInput []) [ChatUser "hi"]
          >>= \case
            (ChatSystem text : _) -> Text.lines text !! 1 @?= "summary: " <> Text.replicate 2000 "x"
            _ -> assertFailure "briefing missing at head"

briefingAcrossRuns :: Assertion
briefingAcrossRuns =
  newMemoryThreadStore >>= \store ->
    newMemoryFactStore >>= \facts ->
      newMemoryState >>= \state ->
        newIORef [] >>= \captured ->
          testRuntime (captureModel captured) [echoTool] Sequential >>= \base ->
            collectEvents base {runtimeHooks = hooks state store facts} (input "run-1")
              *> collectEvents base {runtimeHooks = hooks state store facts} (input "run-2")
              *> (reverse <$> readIORef captured)
              >>= verify
  where
    hooks state store facts = memoryHooks rollingWatcher store facts Nothing state
    input runId = (sampleInput [tool "echo"]) {runId = runId}
    verify [first, second, third, fourth] =
      sequence_
        [ briefingCount first @?= 0,
          briefingCount second @?= 0,
          briefingCount third @?= 1,
          briefingCount fourth @?= 1,
          case third of
            (ChatSystem text : _) ->
              assertBool "briefing carries the rolling summary" (Text.isInfixOf "rolling memo" text)
            _ -> assertFailure "briefing is not at the head"
        ]
    verify other = assertFailure ("unexpected request count: " <> show (length other))

captureModel :: IORef [[ChatMessage]] -> Model
captureModel captured =
  fakeModel $ \request emit ->
    modifyIORef' captured (requestMessages request :)
      *> case lastMessage request of
        Just (ChatToolResult {}) -> emit (ModelTextDelta "done") $> Stop
        _ -> emit (ModelToolCallDelta 0 (Just "call-echo") (Just "echo") "{\"x\":1}") $> ToolUse

briefingReplay :: Assertion
briefingReplay =
  newMemoryThreadStore >>= \store ->
    threadSaveEpisode store "thread" (Episode "run-0" "earlier" 1700000000)
      *> newMemoryFactStore
      >>= \facts ->
        newMemoryJournal
        >>= \(journal, readEntries) ->
          newMemoryState >>= \state ->
            testRuntime mainModel [] Parallel >>= \base ->
              collectEvents base {runtimeHooks = hooks state store facts, runtimeJournal = Just journal} (sampleInput [])
                >>= \events ->
                  readEntries >>= \recorded ->
                    newMemoryThreadStore >>= \replayStore ->
                      threadSaveEpisode replayStore "thread" (Episode "run-0" "earlier" 1700000000)
                        *> newMemoryState
                        >>= \replayState ->
                          replayEntries (hooks replayState replayStore facts) Nothing recorded >>= \report ->
                            sequence_
                              [ fmap reportDivergence report @?= Right Nothing,
                                fmap reportEvents report @?= Right (length events),
                                assertBool "journaled request carries the briefing" (any briefed recorded)
                              ]
  where
    hooks state store facts = memoryHooks rollingWatcher store facts Nothing state
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)
    briefed (Entry _ _ _ (ModelRequestEntry request)) = any markedMessage (requestMessages request)
    briefed _ = False

briefingReplayWithStores :: Assertion
briefingReplayWithStores =
  newMemoryThreadStore >>= \store ->
    threadSaveEpisode store "thread" (Episode "run-0" "earlier" 1700000000)
      *> newMemoryThreadStore
      >>= \replayStore ->
        threadSaveEpisode replayStore "thread" (Episode "run-0" "earlier" 1700000000)
          *> newMemoryFactStore
          >>= \facts ->
            newMemoryJournal
            >>= \(journal, readEntries) ->
              newMemoryState >>= \state ->
                testRuntime mainModel [] Parallel >>= \base ->
                  collectEvents base {runtimeHooks = hooks journal state store facts, runtimeJournal = Just journal} (sampleInput [])
                    >>= \events ->
                      readEntries >>= \recorded ->
                        replayWithStores replayStore facts Nothing recorded >>= \report ->
                        sequence_
                          [ fmap reportDivergence report @?= Right Nothing,
                            fmap reportEvents report @?= Right (length events)
                          ]
  where
    hooks journal state store facts = memoryHooks rollingWatcher store facts (Just journal) state
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)

multiRunMemoryReplay :: Assertion
multiRunMemoryReplay =
  newMemoryThreadStore >>= \store ->
    newMemoryFactStore >>= \facts ->
      newMemoryJournal >>= \(journal, readEntries) ->
        newMemoryState >>= \state ->
          testRuntime mainModel [] Parallel >>= \base ->
            let hooks = memoryHooks rollingWatcher store facts (Just journal) state
                runtime = base {runtimeHooks = hooks, runtimeJournal = Just journal}
             in collectEvents runtime firstInput
                  *> collectEvents runtime secondInput
                  *> readEntries
                  >>= \recorded ->
                    replayWithStores store facts (Just "memory-run-2") recorded >>= \report ->
                      sequence_
                        [ fmap reportDivergence report @?= Right Nothing,
                          assertBool "second watcher skips the prior user message" (any correctDelta recorded)
                        ]
  where
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "answer") $> Stop)
    firstInput =
      (sampleInput [])
        { runId = "memory-run-1",
          runMessages = [User (UserMessage "user-1" (UserText "one") Nothing)]
        }
    secondInput =
      (sampleInput [])
        { runId = "memory-run-2",
          runMessages =
            toAguiMessages
              [ ChatUser "one",
                ChatAssistant (AssistantTurn "answer-1" (Just "answer") Nothing []),
                ChatUser "two"
              ]
        }
    correctDelta (Entry _ ["memory-run-2", "memory"] _ (ModelRequestEntry request)) =
      case [text | ChatUser text <- requestMessages request] of
        [prompt] -> Text.isInfixOf "user: two" prompt && not (Text.isInfixOf "user: one" prompt)
        _ -> False
    correctDelta _ = False

storesUnchangedAfterReplay :: Assertion
storesUnchangedAfterReplay =
  newMemoryThreadStore >>= \store ->
    threadSaveEpisode store "thread" (Episode "run-0" "earlier" 1700000000)
      *> newMemoryThreadStore
      >>= \replayStore ->
        threadSaveEpisode replayStore "thread" (Episode "run-0" "earlier" 1700000000)
          *> newMemoryFactStore
          >>= \facts ->
            newMemoryJournal
            >>= \(journal, readEntries) ->
              newMemoryState >>= \state ->
                testRuntime mainModel [] Parallel >>= \base ->
                  collectEvents base {runtimeHooks = hooks journal state store facts, runtimeJournal = Just journal} (sampleInput [])
                    *> readEntries
                    >>= \recorded ->
                      threadBrief replayStore "thread" >>= \briefBefore ->
                        factList facts >>= \factsBefore ->
                          replayWithStores replayStore facts Nothing recorded >>= \report ->
                            threadBrief replayStore "thread" >>= \briefAfter ->
                              factList facts >>= \factsAfter ->
                                sequence_
                                  [ fmap reportDivergence report @?= Right Nothing,
                                    briefAfter @?= briefBefore,
                                    factsAfter @?= factsBefore
                                  ]
  where
    hooks journal state store facts = memoryHooks rollingWatcher store facts (Just journal) state
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)

replayFileGateForMemory :: Assertion
replayFileGateForMemory =
  newMemoryThreadStore >>= \store ->
    threadSaveEpisode store "thread" (Episode "run-0" "earlier" 1700000000)
      *> newMemoryFactStore
      >>= \facts ->
        newMemoryJournal >>= \(journal, readEntries) ->
          newMemoryState >>= \state ->
            testRuntime mainModel [] Parallel >>= \base ->
              collectEvents base {runtimeHooks = hooks state store facts, runtimeJournal = Just journal} (sampleInput [])
                *> readEntries
                >>= \recorded ->
                  getTemporaryDirectory >>= \tmp ->
                    newId >>= \identifier ->
                      let dir = tmp ++ "/" ++ Text.unpack identifier
                       in createDirectoryIfMissing True dir
                            *> LazyByteString.writeFile (journalFilePath dir) (LazyByteString.concat (fmap ((<> "\n") . encode) recorded))
                            *> ( replayFile defaultHooks (journalFilePath dir) Nothing >>= \case
                                  Left msg ->
                                    assertBool "gate message mentions memory" ("memory-injected" `Text.isInfixOf` msg)
                                  Right _ -> assertFailure "expected gate rejection, got success"
                               )
  where
    hooks state store facts = memoryHooks rollingWatcher store facts Nothing state
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)

increments :: Assertion
increments =
  newIORef [] >>= \requests ->
    newIORef (0 :: Int) >>= \calls ->
      newMemoryThreadStore >>= \store ->
        newMemoryFactStore >>= \facts ->
          newMemoryState >>= \states ->
            exercise (memoryHooks (spy requests calls) store facts Nothing states)
              *> (readIORef requests >>= verify)
  where
    input = sampleInput []
    first = [ChatUser "first"]
    second = first <> [ChatAssistant (AssistantTurn "m1" (Just "answer") Nothing []), ChatUser "second"]
    exercise hooks =
      (transformContext hooks input first >>= (@?= first))
        *> (transformContext hooks input second >>= (@?= second))
    spy requests calls =
      fakeModel $ \request emit ->
        modifyIORef' requests (bodies request :)
          *> atomicModifyIORef' calls (\count -> (count + 1, count + 1))
          >>= \count -> emit (ModelTextDelta ("memo-" <> Text.pack (show count))) $> Stop
    bodies = Text.intercalate "\n" . fmap userTextOf . requestMessages
    userTextOf (ChatUser text) = text
    userTextOf _ = ""
    verify captured =
      case reverse captured of
        [one, two] ->
          sequence_
            [ assertBool "first watch sees the first message" (Text.isInfixOf "first" one),
              assertBool "second watch sees only the increment" (Text.isInfixOf "second" two),
              assertBool "second watch skips seen messages" (not (Text.isInfixOf "first" two)),
              assertBool "second watch carries the previous summary" (Text.isInfixOf "memo-1" two)
            ]
        other -> assertFailure ("unexpected watcher calls: " <> show (length other))

episodeOnDisk :: Assertion
episodeOnDisk =
  getTemporaryDirectory >>= \tmp ->
    newId >>= \identifier ->
      newThreadStore (tmp ++ "/" ++ Text.unpack identifier) >>= exercise
  where
    exercise store =
      newMemoryFactStore >>= \facts ->
        newMemoryState >>= \states ->
          testRuntime mainModel [] Parallel >>= \base ->
            collectEvents base {runtimeHooks = memoryHooks watcher store facts Nothing states} (sampleInput [])
            >>= \events ->
              threadBrief store "thread"
                >>= \case
                  Just (ThreadBrief "rolling: greeted" [Episode "run" "rolling: greeted" _]) ->
                    eventType (last events) @?= "RUN_FINISHED"
                  other -> assertFailure ("unexpected thread brief: " <> show other)
    watcher = fakeModel (\_ emit -> emit (ModelTextDelta "rolling: greeted") $> Stop)
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi there") $> Stop)

failureIsolation :: Assertion
failureIsolation =
  newMemoryThreadStore >>= \store ->
    newMemoryFactStore >>= \facts ->
      newMemoryState >>= \states ->
        newIORef [] >>= \seen ->
          testRuntime (capture seen) [] Parallel >>= \base ->
            collectEvents base {runtimeHooks = memoryHooks broken store facts Nothing states} (sampleInput [])
            >>= \events ->
              (,) <$> readIORef seen <*> threadBrief store "thread"
                >>= \(requests, stored) ->
                  sequence_
                    [ eventType (last events) @?= "RUN_FINISHED",
                      requests @?= [[ChatUser "hello"]],
                      stored @?= Nothing
                    ]
  where
    broken = fakeModel (\_ _ -> throwIO (ProviderFailure "watcher down"))
    capture seen =
      fakeModel $ \request emit ->
        modifyIORef' seen (requestMessages request :) *> emit (ModelTextDelta "fine") $> Stop

composition :: Assertion
composition =
  newMemoryThreadStore >>= \store ->
    newMemoryFactStore >>= \facts ->
      newMemoryState >>= \states ->
        newIORef False >>= \called ->
          testRuntime mainModel [] Parallel >>= \base ->
            collectEvents
              base {runtimeHooks = memoryHooks watcher store facts Nothing states <> business called}
            (sampleInput [])
            *> ((,) <$> readIORef called <*> threadBrief store "thread")
            >>= \(wasCalled, stored) ->
              sequence_
                [ wasCalled @?= True,
                  assertBool "memory afterRun stored an episode" (maybe False (not . null . briefEpisodes) stored)
                ]
  where
    watcher = fakeModel (\_ emit -> emit (ModelTextDelta "memo") $> Stop)
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)
    business called = defaultHooks {afterRun = \_ _ -> writeIORef called True}

cognitionTests :: TestTree
cognitionTests =
  testGroup
    "incarnation cognition"
    [ testCase "uses real SHA-256 content identities" cognitionSha,
      testCase "persists a monotonic per-incarnation experience stream" cognitionExperience,
      testCase "isolates same-task context heads and histories by incarnation" cognitionContextIsolation,
      testCase "persists immutable structured Task archives across restart" cognitionTaskArchivePersistence,
      testCase "greps Task archives and reads causal windows" cognitionTaskArchiveRetrieval,
      testCase "captures accepted input and full tool results before projection" cognitionTaskArchiveHooks,
      testCase "migrates a legacy task idempotently without promoting long-term memory" cognitionLegacyTaskMigration,
      testCase "records failed and cancelled run termination payloads" cognitionTerminalOutcomes,
      testCase "keeps long-term memory explicit, scoped and receipt-audited" cognitionLongTermTest,
      testCase "activates non-factual impressions without injecting memory content" cognitionImpression,
      testCase "activates and audits impressions across tasks" cognitionImpressionAcrossTasks,
      testCase "records impression activation failures with task scope" cognitionImpressionFailure,
      testCase "consolidates impressions from the actual experience payload closure" cognitionImpressionClosure,
      testCase "rejects ungrounded impression memory proposals" cognitionImpressionProposalGuard,
      testCase "requires current evidence for new impressions" cognitionImpressionEvidenceGuard,
      testCase "keeps tool diagnostics out of impressions" cognitionImpressionDiagnosticGuard,
      testCase "migrates the known false grep impression with provenance" cognitionImpressionFalseMigration,
      testCase "archives and restores non-default incarnations safely" cognitionIncarnationLifecycle,
      testCase "deletes an archived incarnation and every derived store" cognitionDeleteIncarnation,
      testCase "seeds and activates auditable prompt revisions" cognitionPrompts,
      testCase "upgrades an automatic legacy Root to the Task Archive protocol" cognitionRootMigration,
      testCase "generates charters from the active audited Root revision" cognitionPromptRoot,
      testCase "sleeps, forgets, wakes and continues with a Wake Packet" cognitionSleep,
      testCase "preserves one parallel tool turn through sleep and wake" cognitionSleepParallelTools,
      testCase "sleeps over the live run context rather than its initial request" cognitionLiveSleep,
      testCase "fails explicitly rather than silently compacting when sleep fails" cognitionSleepFailure,
      testCase "recovers a prepared sleep into one coherent wake epoch" cognitionPreparedRecovery,
      testCase "uses ContextEpoch when no transcript projection exists" cognitionAuthoritativeContext,
      testCase "repairs legacy parallel tool turns before provider replay" cognitionLegacyParallelTools,
      testCase "serves incarnation-first inspection endpoints" cognitionHttp,
      testCase "serves Task archive catalog, grep and anchored read endpoints" cognitionTaskArchiveHttp,
      testCase "binds, archives and restores incarnation tasks over HTTP" cognitionLifecycleHttp,
      testCase "keeps task ownership immutable and lists by session metadata" cognitionTaskOwnerHttp,
      testCase "refuses to archive an incarnation with a live task run" cognitionArchiveActiveRun
    ]

cognitionSha :: Assertion
cognitionSha =
  sequence_
    [ sha256 "" @?= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      sha256 "abc" @?= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    ]

cognitionExperience :: Assertion
cognitionExperience =
  withWorkDir $ \dir ->
    newExperienceStore dir >>= withTextRight (\store ->
      experienceHead store "yuki" >>= \zero ->
        experienceAppend store (Just zero) (experienceDraft "first") >>= withTextRight (\first ->
          experienceAppend store (Just zero) (experienceDraft "stale") >>= \stale ->
            newExperienceStore dir >>= withTextRight (\reopened ->
              experienceEvents reopened "yuki" >>= \events ->
                sequence_
                  [ experienceSeq first @?= 1,
                    assertLeft stale,
                    fmap experienceSeq events @?= [1]
                  ])))
  where
    experienceDraft kind =
      ExperienceDraft "yuki" "operation" "yuki" Nothing (Just "task") (Just "run") Nothing Nothing kind "sha256-payload" "sha256-payload"

cognitionContextIsolation :: Assertion
cognitionContextIsolation =
  newMemoryBlobStore >>= \blobs ->
    newMemoryContextEpochStore blobs >>= \store ->
      contextEpochCommit store "north" task Nothing [segment "north/1" "north first"] Nothing
        >>= withTextRight
          ( \northFirst ->
              contextEpochCommit store "south" task Nothing [segment "south/1" "south only"] Nothing
                >>= withTextRight
                  ( \southOnly ->
                      contextEpochCommit store "north" task (Just (contextEpochId northFirst)) [segment "north/2" "north second"] Nothing
                        >>= withTextRight
                          ( \northSecond ->
                              (,,,)
                                <$> contextEpochHead store "north" task
                                <*> contextEpochHead store "south" task
                                <*> contextEpochList store "north" task
                                <*> contextEpochList store "south" task
                                >>= \(northHead, southHead, northHistory, southHistory) ->
                                  sequence_
                                    [ fmap contextEpochId northHead @?= Just (contextEpochId northSecond),
                                      fmap contextEpochId southHead @?= Just (contextEpochId southOnly),
                                      fmap contextEpochId northHistory @?= fmap contextEpochId [northFirst, northSecond],
                                      fmap contextEpochId southHistory @?= [contextEpochId southOnly],
                                      fmap contextEpochIncarnationId northHistory @?= ["north", "north"],
                                      fmap contextEpochIncarnationId southHistory @?= ["south"]
                                    ]
                          )
                  )
          )
  where
    task = "same-task"
    segment source content =
      ContextSegmentInput source SegmentUser AuthorityUser content Nothing Nothing

cognitionTaskArchivePersistence :: Assertion
cognitionTaskArchivePersistence =
  withWorkDir $ \dir ->
    newBlobStore dir >>= withTextRight (newTaskArchiveStore dir >=> withTextRight (exercise dir))
  where
    task = "archived-task"
    user = entry "user-1" ArchiveUser "Keep the complete tool evidence." Nothing Nothing Nothing
    result = entry "call-1/result" ArchiveToolResult fullResult (Just "call-1") (Just "call-1") (Just "inspect")
    reasoning = entry "turn-1/reasoning" ArchiveReasoning "I should inspect the source first." (Just "turn-1") Nothing Nothing
    answer = entry "turn-1/assistant" ArchiveAssistant "The source confirms the result." (Just "turn-1") Nothing Nothing
    call = entry "call-1/call" ArchiveToolCall (jsonText (ModelToolCall "call-1" "inspect" "{\"path\":\"source\"}")) (Just "turn-1") (Just "call-1") (Just "inspect")
    fullResult = "complete-tool-result-sentinel\n" <> Text.replicate 900 "e"
    running =
      ArchiveRunDraft "art" task "run-1" (Just "intent-1") "running" Nothing [user, result]
    completed =
      ArchiveRunDraft "art" task "run-1" (Just "intent-1") "completed" Nothing [user, reasoning, answer, call, result]
    rewritten = completed {archiveRunDraftStatus = "failed", archiveRunDraftFailure = Just "late rewrite"}
    exercise dir store =
      taskArchiveAppend store running >>= withTextRight (\_ ->
        taskArchiveAppend store completed >>= withTextRight (\sealed ->
          taskArchiveAppend store completed >>= withTextRight (\repeated ->
            taskArchiveAppend store rewritten >>= \rewrite ->
              newBlobStore dir >>= withTextRight (newTaskArchiveStore dir >=> withTextRight (verify sealed repeated rewrite)))))
    verify sealed repeated rewrite reopened =
      taskArchiveRuns reopened "art" (Just task) >>= \runs ->
        taskArchiveTasks reopened "art" 20 >>= \catalog ->
          case archiveRunEntryIds sealed of
            _ : resultId : _ ->
              taskArchiveRead reopened (ArchiveReadRequest "art" resultId 0 0 0 20000)
                >>= withTextRight
                  ( \window ->
                      sequence_
                        [ repeated @?= sealed,
                          assertLeft rewrite,
                          fmap archiveRunStatus runs @?= ["completed"],
                          fmap archiveTaskId catalog @?= [task],
                          fmap archiveTaskRunCount catalog @?= [1],
                          fmap archiveTaskEntryCount catalog @?= [5],
                          fmap archiveSliceSeq (archiveReadResultEntries window) @?= [2 .. 5],
                          fmap archiveSliceContent
                            (filter ((== ArchiveToolResult) . archiveSliceKind) (archiveReadResultEntries window))
                            @?= [fullResult]
                        ]
                  )
            _ -> assertFailure "persisted Task archive did not retain its entry identities"
    entry source kind content parent callId toolName =
      ArchiveEntryDraft source kind content parent callId toolName

cognitionTaskArchiveRetrieval :: Assertion
cognitionTaskArchiveRetrieval =
  newMemoryBlobStore >>= \blobs ->
    newMemoryTaskArchiveStore blobs >>= \store ->
      taskArchiveAppend store primary >>= withTextRight (\_ ->
        taskArchiveAppend store secondary >>= withTextRight (\_ ->
          taskArchiveAppend store otherRun >>= withTextRight (\_ ->
            verify store)))
  where
    task = "task-a"
    turn = "turn-a"
    callA = "call-a"
    callB = "call-b"
    primary =
      ArchiveRunDraft
        "art"
        task
        "run-a"
        Nothing
        "completed"
        Nothing
        [ entry "user-a" ArchiveUser "第一行\nAlpha NEEDLE beta\nrepeat repeat repeat\n第三行" Nothing Nothing Nothing,
          entry "reasoning-a" ArchiveReasoning (padded "secret-reasoning") (Just turn) Nothing Nothing,
          entry "assistant-a" ArchiveAssistant (padded "answer-without-query") (Just turn) Nothing Nothing,
          entry "call-a/call" ArchiveToolCall (padded "call-a-input") (Just turn) (Just callA) (Just "shell"),
          entry "call-b/call" ArchiveToolCall (padded "call-b-input") (Just turn) (Just callB) (Just "second"),
          entry "call-memory/call" ArchiveToolCall "{\"query\":\"recursive-noise\"}" (Just turn) (Just "call-memory") (Just "memory_grep"),
          entry "call-a/result" ArchiveToolResult (padded "tool-A-evidence" <> "\n[artifact art-source-a: full shell output]") (Just callA) (Just callA) (Just "shell"),
          entry "call-b/result" ArchiveToolResult (padded "tool-B-evidence") (Just callB) (Just callB) (Just "second"),
          entry "call-memory/result" ArchiveToolResult "{\"hits\":[{\"excerpt\":\"recursive-noise\"}],\"scannedEntries\":8}" (Just "call-memory") (Just "call-memory") (Just "memory_grep")
        ]
    secondary =
      ArchiveRunDraft "art" "task-b" "run-b" Nothing "completed" Nothing
        [entry "user-b" ArchiveUser "Needle in another archived Task." Nothing Nothing Nothing]
    otherRun =
      ArchiveRunDraft "other" "task-c" "run-c" Nothing "completed" Nothing
        [entry "user-c" ArchiveUser "NEEDLE must remain isolated." Nothing Nothing Nothing]
    verify store =
      search store (ArchiveGrepRequest "art" "needle" (Just task) [] False 20 0 False Nothing) >>= \insensitive ->
        search store (ArchiveGrepRequest "art" "needle" (Just task) [] True 20 0 False Nothing) >>= \sensitive ->
          search store (ArchiveGrepRequest "art" "secret-reasoning" Nothing [] False 20 0 False Nothing) >>= \defaultReasoning ->
            search store (ArchiveGrepRequest "art" "secret-reasoning" Nothing [ArchiveReasoning] False 20 0 False Nothing) >>= \explicitReasoning ->
              search store (ArchiveGrepRequest "art" "needle" Nothing [] False 20 0 False Nothing) >>= \allOwn ->
                search store (ArchiveGrepRequest "art" "needle" Nothing [] False 20 0 False (Just task)) >>= \excluded ->
                  search store (ArchiveGrepRequest "art" "tool-A-evidence" (Just task) [] False 20 0 False Nothing) >>= \anchorSearch ->
                  search store (ArchiveGrepRequest "art" "repeat" (Just task) [] True 20 0 False Nothing) >>= \repeated ->
                    search store (ArchiveGrepRequest "art" "needle" Nothing [] False 1 0 False Nothing) >>= \firstPage ->
                      search store (ArchiveGrepRequest "art" "needle" Nothing [] False 1 1 False Nothing) >>= \secondPage ->
                        search store (ArchiveGrepRequest "art" "recursive-noise" (Just task) [] True 20 0 False Nothing) >>= \processHidden ->
                          search store (ArchiveGrepRequest "art" "recursive-noise" (Just task) [] True 20 0 True Nothing) >>= \processShown ->
                            taskArchiveTasks store "art" 20 >>= \catalog ->
                              case archiveGrepResultHits anchorSearch of
                                [anchor] ->
                                  taskArchiveRead store (ArchiveReadRequest "art" (archiveHitEntryId anchor) 0 0 (archiveHitMatchOffset anchor) 256)
                                    >>= withTextRight (verifyWindow store insensitive sensitive defaultReasoning explicitReasoning allOwn excluded repeated firstPage secondPage processHidden processShown catalog anchor)
                                hits -> assertFailure ("unexpected Task archive anchor hits: " <> show (length hits))
    verifyWindow store insensitive sensitive defaultReasoning explicitReasoning allOwn excluded repeated firstPage secondPage processHidden processShown catalog anchor window =
      taskArchiveRead store (ArchiveReadRequest "art" (archiveHitEntryId anchor) 0 0 (archiveHitMatchOffset anchor) 1)
        >>= withTextRight
          ( \tiny ->
              taskArchiveRead store (ArchiveReadRequest "other" (archiveHitEntryId anchor) 0 0 0 256) >>= \foreignRead ->
                let entries = archiveReadResultEntries window
                    tinyEntries = archiveReadResultEntries tiny
                 in sequence_
                      [ fmap archiveHitLineNumber (archiveGrepResultHits insensitive) @?= [2],
                        fmap archiveHitMatchOffset (archiveGrepResultHits insensitive) @?= [10],
                        archiveGrepResultHits sensitive @?= [],
                        archiveGrepResultHits defaultReasoning @?= [],
                        fmap archiveHitKind (archiveGrepResultHits explicitReasoning) @?= [ArchiveReasoning],
                        sort (fmap archiveHitTaskId (archiveGrepResultHits allOwn)) @?= [task, "task-b"],
                        sort (fmap archiveHitTaskId (archiveGrepResultHits excluded)) @?= ["task-b"],
                        fmap archiveHitEntryMatchIndex (archiveGrepResultHits repeated) @?= [1, 2, 3],
                        fmap archiveHitEntryMatchCount (archiveGrepResultHits repeated) @?= [3, 3, 3],
                        archiveGrepResultTotalHits firstPage @?= 2,
                        archiveGrepResultReturnedHits firstPage @?= 1,
                        archiveGrepResultNextOffset firstPage @?= Just 1,
                        archiveGrepResultHasMore firstPage @?= True,
                        archiveGrepResultNextOffset secondPage @?= Nothing,
                        archiveGrepResultHasMore secondPage @?= False,
                        archiveGrepResultHits processHidden @?= [],
                        fmap archiveHitEvidenceClass (archiveGrepResultHits processShown) @?= ["process", "process"],
                        archiveHitSourceCompleteness anchor @?= "artifact-backed",
                        archiveHitArtifactIds anchor @?= ["art-source-a"],
                        sort (fmap archiveTaskId catalog) @?= [task, "task-b"],
                        fmap archiveSliceKind entries
                          @?= [ ArchiveReasoning,
                                ArchiveAssistant,
                                ArchiveToolCall,
                                ArchiveToolCall,
                                ArchiveToolCall,
                                ArchiveToolResult,
                                ArchiveToolResult,
                                ArchiveToolResult
                              ],
                        assertBool "causal read exceeded its global character budget" (sum (fmap (Text.length . archiveSliceContent) entries) <= 256),
                        assertBool "anchor text was not centered into the bounded read" ("tool-A-evidence" `Text.isInfixOf` archiveSliceContent (entries !! 5)),
                        sum (fmap (Text.length . archiveSliceContent) tinyEntries) @?= 1,
                        Text.length (archiveSliceContent (tinyEntries !! 5)) @?= 1,
                        assertLeft foreignRead
                      ]
          )
    search store grepRequest =
      taskArchiveGrep store grepRequest >>= either (throwIO . userError . Text.unpack) pure
    padded label = label <> ":" <> Text.replicate 500 "x"
    entry source kind content parent callId toolName =
      ArchiveEntryDraft source kind content parent callId toolName

cognitionTaskArchiveHooks :: Assertion
cognitionTaskArchiveHooks =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \incarnation ->
        let hooks = cognitionHooks cognition incarnation
            input =
              (sampleInput [])
                { runThreadId = "raw-hook-task",
                  runId = "raw-hook-run",
                  runMessages = [User (UserMessage "intent-raw" (UserText accepted) Nothing)]
                }
            call = ModelToolCall "raw-call" "inspect" "{\"path\":\"large\"}"
            finalMessages =
              [ ChatUser accepted,
                ChatAssistant (AssistantTurn "raw-turn" (Just "I inspected it.") Nothing [call]),
                ChatToolResult "raw-call" projected
              ]
         in observeEvent hooks input (RunStarted "raw-hook-task" "raw-hook-run" Nothing)
              *> observeEvent hooks input (ToolCallResult "raw-tool-message" "raw-call" completeResult)
              *> afterRunOutcome hooks input RunSucceeded finalMessages
              *> taskArchiveGrep
                (cognitionArchive cognition)
                (ArchiveGrepRequest "yuki" "complete-result-sentinel" (Just "raw-hook-task") [] True 20 0 False Nothing)
              >>= withTextRight
                ( \full ->
                    taskArchiveGrep
                      (cognitionArchive cognition)
                      (ArchiveGrepRequest "yuki" "projected-result-stub" (Just "raw-hook-task") [] True 20 0 False Nothing)
                      >>= withTextRight
                        ( \stub ->
                            taskArchiveGrep
                              (cognitionArchive cognition)
                              (ArchiveGrepRequest "yuki" accepted (Just "raw-hook-task") [] True 20 0 False Nothing)
                              >>= withTextRight
                                ( \user ->
                                    taskArchiveRuns (cognitionArchive cognition) "yuki" (Just "raw-hook-task") >>= \runs ->
                                      sequence_
                                        [ fmap archiveHitKind (archiveGrepResultHits full) @?= [ArchiveToolResult],
                                          archiveGrepResultHits stub @?= [],
                                          fmap archiveHitKind (archiveGrepResultHits user) @?= [ArchiveUser],
                                          fmap archiveRunStatus runs @?= ["completed"]
                                        ]
                                )
                        )
                ))
  where
    accepted = "accepted-input-sentinel"
    completeResult = "complete-result-sentinel\n" <> Text.replicate 2000 "原"
    projected = "projected-result-stub"

cognitionLegacyTaskMigration :: Assertion
cognitionLegacyTaskMigration =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition identity >>= \incarnation ->
        cognitionMigrateLegacyTask cognition incarnation task messages (Just candidate)
          >>= withTextRight
            ( \() ->
                migrationSnapshot cognition >>= \before ->
                  cognitionMigrateLegacyTask cognition incarnation task messages (Just candidate)
                    >>= withTextRight
                      ( \() ->
                          migrationSnapshot cognition >>= \repeated ->
                            verify cognition before repeated
                      )
            ))
  where
    identity = "yuki"
    task = "legacy.task"
    messages =
      [ ChatUser "Restore the amber workspace.",
        ChatAssistant (AssistantTurn "legacy-answer" (Just "The workspace was restored.") Nothing [])
      ]
    candidate =
      object
        [ "rollingSummary" .= ("legacy summary candidate" :: Text),
          "episodes" .= ([] :: [Value])
        ]
    migrationSnapshot cognition =
      (,,,,,)
        <$> experienceEvents (cognitionExperiences cognition) identity
        <*> contextEpochList (cognitionContexts cognition) identity task
        <*> workingRead (cognitionWorking cognition) identity
        <*> workingReadFocus (cognitionWorking cognition) identity task
        <*> longTermCatalog (cognitionLongTerm cognition) identity 100
        <*> taskArchiveRuns (cognitionArchive cognition) identity (Just task)
    verify cognition before@(events, epochs, head', focus, catalog, archived) repeated =
      sequence_
        [ repeated @?= before,
          fmap experienceKind events
            @?= [ "LegacyTranscriptImported",
                  "LegacyWorkingMemoryCandidate",
                  "LegacyTaskMigrationCompleted"
                ],
          fmap experienceSeq events @?= [1, 2, 3],
          fmap (cursorSeq . workingMemoryCursor) head' @?= Just 3,
          fmap focusFrameObjective focus @?= Just "Restore the amber workspace.",
          fmap focusFrameRecentOutcomeRefs focus @?= Just (fmap experienceEventId events),
          catalog @?= [],
          fmap archiveRunStatus archived @?= ["legacy"],
          fmap (length . archiveRunEntryIds) archived @?= [2]
        ]
        *> verifyContext cognition epochs
        *> verifyCandidate cognition events focus
    verifyContext cognition epochs =
      case epochs of
        [epoch] ->
          contextEpochProject (cognitionContexts cognition) (contextEpochId epoch)
            >>= withTextRight
              ( \projected ->
                  sequence_
                    [ fmap (contextSegmentKind . fst) projected @?= [SegmentUser, SegmentAssistant],
                      fmap snd projected @?= ["Restore the amber workspace.", "The workspace was restored."]
                    ]
              )
        _ -> assertFailure ("unexpected migrated epoch count: " <> show (length epochs))
    verifyCandidate cognition events focus =
      case find ((== "LegacyWorkingMemoryCandidate") . experienceKind) events of
        Nothing -> assertFailure "legacy working-memory candidate event is missing"
        Just event ->
          blobFetch (cognitionBlobs cognition) (experiencePayloadRef event) >>= \case
            Left failure -> assertFailure (Text.unpack failure)
            Right payload ->
              sequence_
                [ either assertFailure (@?= candidate) (eitherDecode payload >>= parseEither (withObject "legacy candidate" (.: "candidate"))),
                  assertBool
                    "working focus does not reference the legacy candidate"
                    (maybe False (experienceEventId event `elem`) (focusFrameRecentOutcomeRefs <$> focus))
                ]

cognitionTerminalOutcomes :: Assertion
cognitionTerminalOutcomes =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \incarnation ->
        let hooks = cognitionHooks cognition incarnation
            failed = (sampleInput []) {runThreadId = "failed-task", runId = "failed-run"}
            cancelled = (sampleInput []) {runThreadId = "cancelled-task", runId = "cancelled-run"}
         in afterRunOutcome hooks failed (RunFailed "PROVIDER_ERROR" "provider down") [ChatUser "failed input"]
              *> afterRunOutcome hooks cancelled RunWasCancelled [ChatUser "cancelled input"]
              *> experienceEvents (cognitionExperiences cognition) "yuki"
              >>= traverse (terminalStatus cognition)
                . filter ((== "RunTerminated") . experienceKind)
              >>= \statuses ->
                Map.fromList statuses
                  @?= Map.fromList
                    [ ("failed-run", "failed"),
                      ("cancelled-run", "cancelled")
                    ])
  where
    terminalStatus :: Cognition -> ExperienceEvent -> IO (Text, Text)
    terminalStatus cognition event =
      blobFetch (cognitionBlobs cognition) (experiencePayloadRef event) >>= \case
        Left failure -> assertFailure (Text.unpack failure) $> ("", "")
        Right payload ->
          case eitherDecode payload >>= parseEither (withObject "RunTerminated" (.: "status")) of
            Left failure -> assertFailure failure $> ("", "")
            Right status -> pure (fromMaybe "" (experienceRunId event), status)

cognitionLongTermTest :: Assertion
cognitionLongTermTest =
  withWorkDir $ \dir ->
    newLongTermStore dir >>= withTextRight (\store ->
      longTermRemember
        store
        (RememberRequest "yuki" MemoryPrivate "preference" "琥珀色是这个分身的参考色" ["琥珀", "color"] ["experience/1"])
        >>= withTextRight (\memory ->
          longTermCatalog store "yuki" 10 >>= \own ->
            longTermCatalog store "other" 10 >>= \other ->
              longTermGrep store (GrepRequest "yuki" "琥珀" Nothing 8) >>= withTextRight (\_ ->
                longTermRead store (ReadRequest "yuki" (longMemoryId memory) Nothing) >>= withTextRight (\_ ->
                  newLongTermStore dir >>= withTextRight (\reopened ->
                    longTermReceipts reopened "yuki" >>= \receipts ->
                      sequence_
                        [ fmap memoryCatalogId own @?= [longMemoryId memory],
                          other @?= [],
                          length receipts @?= 2,
                          sort (fmap memoryReadReceiptAction receipts) @?= ["grep", "read"]
                        ])))))

cognitionImpression :: Assertion
cognitionImpression =
  newMemoryLongTermStore >>= \longTerm ->
    longTermRemember
      longTerm
      (RememberRequest "yuki" MemoryPrivate "preference" "secret amber memory content" ["amber"] ["source"])
      >>= withTextRight (\memory ->
        newMemoryImpressionStore >>= \impressions ->
          longTermCatalog longTerm "yuki" 8 >>= \catalog ->
            activateImpression
              [impressionCueModel (longMemoryId memory)]
              Nothing
              impressions
              "yuki"
              (ImpressionScope "task" "run" "intent")
              "pick a color"
              [longMemoryId memory]
              (jsonText catalog)
              >>= withTextRight (\activation ->
                let injected = impressionActivationInjectedText activation
                 in sequence_
                      [ assertBool "cue is explicitly non-factual" ("non-factual" `Text.isInfixOf` injected),
                        assertBool "cue tells the agent to grep" ("memory_grep" `Text.isInfixOf` injected),
                        assertBool "long-term content is not injected" (not ("secret amber memory content" `Text.isInfixOf` injected))
                      ]))

cognitionImpressionAcrossTasks :: Assertion
cognitionImpressionAcrossTasks =
  withWorkDir $ \dir ->
    newCognition dir [impressionCueWithoutMemoryModel] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \incarnation ->
        let hooks = cognitionHooks cognition incarnation
            first = impressionInput "task-a" "run-a" "intent-a" "first direction"
            second = impressionInput "task-b" "run-b" "intent-b" "second direction"
            activate input = transformContext hooks input [ChatUser (latestUser input)]
         in activate first >>= \firstContext ->
              activate second >>= \secondContext ->
                activate second
                  *> impressionActivations (cognitionImpressions cognition) "yuki"
                  >>= \activations ->
                    sequence_
                      [ fmap impressionActivationTaskId activations @?= ["task-a", "task-b"],
                        fmap impressionActivationRunId activations @?= ["run-a", "run-b"],
                        fmap impressionActivationIntentId activations @?= ["intent-a", "intent-b"],
                        fmap impressionActivationError activations @?= [Nothing, Nothing],
                        assertBool "first task received an impression cue" (any impressionCue firstContext),
                        assertBool "second task received an impression cue" (any impressionCue secondContext)
                      ])
  where
    latestUser input =
      fromMaybe "" . listToMaybe . reverse $
        [text | User message <- runMessages input, Right text <- [userText (userContent message)]]
    impressionCue (ChatSystem content) = "non-factual" `Text.isInfixOf` content
    impressionCue _ = False

cognitionImpressionFailure :: Assertion
cognitionImpressionFailure =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \incarnation ->
        let input = impressionInput "task-failed" "run-failed" "intent-failed" "unavailable profile"
         in transformContext (cognitionHooks cognition incarnation) input [ChatUser "unavailable profile"]
              *> impressionActivations (cognitionImpressions cognition) "yuki"
              >>= \activations ->
                case activations of
                  [activation] ->
                    sequence_
                      [ impressionActivationTaskId activation @?= "task-failed",
                        impressionActivationRunId activation @?= "run-failed",
                        impressionActivationIntentId activation @?= "intent-failed",
                        impressionActivationError activation @?= Just "model chain exhausted"
                      ]
                  _ -> assertFailure ("unexpected activation failure count: " <> show (length activations)))

impressionInput :: Text -> Text -> Text -> Text -> RunAgentInput
impressionInput task run intent content =
  (sampleInput [])
    { runThreadId = task,
      runId = run,
      runMessages = [User (UserMessage intent (UserText content) Nothing)]
    }

cognitionImpressionClosure :: Assertion
cognitionImpressionClosure =
  withWorkDir $ \dir ->
    newIORef [] >>= \captured ->
      newCognition dir [impressionConsolidationModel captured] Nothing >>= withTextRight (\cognition ->
        ensureIncarnation cognition "yuki" >>= \incarnation ->
          let input =
                (sampleInput [])
                  { runThreadId = "closure-task",
                    runId = "closure-run",
                    runMessages =
                      [ User
                          ( UserMessage
                              "closure-user"
                              (UserText "actual-user-payload-sentinel")
                              Nothing
                          )
                      ]
                  }
              messages =
                [ ChatUser "actual-user-payload-sentinel",
                  ChatAssistant
                    (AssistantTurn "closure-answer" (Just "actual-assistant-payload-sentinel") Nothing [])
                ]
           in afterRunOutcome (cognitionHooks cognition incarnation) input RunSucceeded messages
                *> waitUntil
                  ( any ((== "ImpressionConsolidationSucceeded") . experienceKind)
                      <$> experienceEvents (cognitionExperiences cognition) "yuki"
                  )
                >>= \finished ->
                  readIORef captured >>= \requestMessages' ->
                    impressionRead (cognitionImpressions cognition) "yuki" >>= \state ->
                      impressionRevisions (cognitionImpressions cognition) "yuki" >>= \revisions ->
                        let rendered =
                              Text.intercalate
                                "\n"
                                [text | ChatUser text <- requestMessages']
                            source =
                              impressionRevisionExperienceRef
                                <$> listToMaybe (reverse revisions)
                         in sequence_
                              [ assertBool "consolidation completed" finished,
                                assertBool "closure contains the real user payload" ("actual-user-payload-sentinel" `Text.isInfixOf` rendered),
                                assertBool "closure contains the real assistant payload" ("actual-assistant-payload-sentinel" `Text.isInfixOf` rendered),
                                assertBool "revision carries its source experience" (maybe False (not . Text.null) source),
                                impressionRevision state @?= 1
                              ])

cognitionImpressionProposalGuard :: Assertion
cognitionImpressionProposalGuard =
  newMemoryImpressionStore >>= \impressions ->
    consolidateImpression
      [ungroundedProposalModel]
      Nothing
      impressions
      "yuki"
      "experience-1"
      []
      ["experience-1"]
      "{}"
      >>= assertLeft

cognitionImpressionEvidenceGuard :: Assertion
cognitionImpressionEvidenceGuard =
  newMemoryImpressionStore >>= \impressions ->
    consolidateImpression
      [impressionDecisionModel "continuity" "This direction may continue." []]
      Nothing
      impressions
      "yuki"
      "experience-1"
      []
      ["experience-1"]
      "{}"
      >>= assertLeft

cognitionImpressionDiagnosticGuard :: Assertion
cognitionImpressionDiagnosticGuard =
  newMemoryImpressionStore >>= \impressions ->
    consolidateImpression
      [impressionDecisionModel "grep lesson" "A truncated memory_grep result requires memory_read." ["experience-1"]]
      Nothing
      impressions
      "yuki"
      "experience-1"
      []
      ["experience-1"]
      "{}"
      >>= assertLeft

cognitionImpressionFalseMigration :: Assertion
cognitionImpressionFalseMigration =
  withWorkDir $ \dir ->
    encodeFile (dir ++ "/impressions.json") legacy
      *> newImpressionStore dir
      >>= withTextRight
        ( \store ->
            impressionRead store "yuki-8nckh0" >>= \state ->
              impressionRevisions store "yuki-8nckh0" >>= \revisions ->
                newImpressionStore dir >>= withTextRight
                  ( \reopened ->
                      impressionRead reopened "yuki-8nckh0" >>= \again ->
                        sequence_
                          [ impressionRevision state @?= 4,
                            impressionItems state @?= [],
                            impressionRevision again @?= 4,
                            assertBool
                              "migration records the voided impression"
                              ( any
                                  (elem "impression-q1r2s3" . impressionRevisionVoidProposals)
                                  revisions
                              )
                          ]
                  )
        )
  where
    legacy =
      object
        [ "states"
            .= ( Map.fromList
                   [ ( "yuki-8nckh0" :: Text,
                       object
                         [ "incarnationId" .= ("yuki-8nckh0" :: Text),
                           "revision" .= (3 :: Int),
                           "items"
                             .= [ object
                                    [ "id" .= ("impression-q1r2s3" :: Text),
                                      "label" .= ("GrepTruncationAwareness" :: Text),
                                      "intuition" .= ("memory_grep scannedEntries hid 改天孙观为婺女观." :: Text),
                                      "strength" .= (0.9 :: Double),
                                      "sourceMemoryIds" .= ([] :: [Text]),
                                      "sourceExperienceRefs" .= ["event-1" :: Text],
                                      "updated" .= (1 :: Int)
                                    ]
                                ],
                           "generatorRevision" .= ("impression-consolidation/v2" :: Text),
                           "effectiveHash" .= ("old" :: Text),
                           "updated" .= (1 :: Int)
                         ]
                     )
                   ]
               )
        , "activations" .= ([] :: [Value])
        , "revisions" .= ([] :: [Value])
        ]

cognitionIncarnationLifecycle :: Assertion
cognitionIncarnationLifecycle =
  newMemoryIncarnationStore >>= \store ->
    incarnationCreate store "art" "Art" "Make careful visual judgments." Nothing
      >>= withTextRight
        ( \created ->
            promptAppend
              store
              (Just "art")
              IncarnationCharter
              "test charter"
              "charter"
              "test/v1"
              Nothing
              Nothing
              PromptDraft
              >>= \prompt ->
                incarnationArchive store "yuki" 1 >>= \defaultArchive ->
                  incarnationArchive store "art" (incarnationRevision created)
                    >>= withTextRight
                      ( \archived ->
                          incarnationUpdate
                            store
                            "art"
                            (incarnationRevision archived)
                            "Changed"
                            "Must remain blocked."
                            Nothing
                            >>= \blockedUpdate ->
                              promptActivate
                                store
                                "art"
                                (incarnationRevision archived)
                                (promptRevisionId prompt)
                                >>= \blockedPrompt ->
                                  incarnationRestore store "art" 1 >>= \staleRestore ->
                                    incarnationRestore store "art" (incarnationRevision archived)
                                      >>= withTextRight
                                        ( \restored ->
                                            incarnationRestore store "art" (incarnationRevision restored)
                                              >>= \repeatedRestore ->
                                                sequence_
                                                  [ assertLeft defaultArchive,
                                                    incarnationStatus archived @?= IncarnationArchived,
                                                    assertLeft blockedUpdate,
                                                    assertLeft blockedPrompt,
                                                    assertLeft staleRestore,
                                                    incarnationStatus restored @?= IncarnationActive,
                                                    incarnationRevision restored @?= incarnationRevision archived + 1,
                                                    assertLeft repeatedRestore
                                                  ]
                                        )
                      )
        )

ungroundedProposalModel :: Model
ungroundedProposalModel =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "impressions" .= ([] :: [Value]),
                    "memoryProposals"
                      .= [ object
                             [ "content" .= ("remember this without evidence" :: Text),
                               "kind" .= ("preference" :: Text),
                               "visibility" .= ("private" :: Text),
                               "sourceRefs" .= ([] :: [Text]),
                               "reason" .= ("model suggestion" :: Text)
                             ]
                         ],
                    "voidProposals" .= ([] :: [Text]),
                    "reason" .= ("proposal audit" :: Text)
                  ]
              )
          )
      )
      $> Stop

impressionDecisionModel :: Text -> Text -> [Text] -> Model
impressionDecisionModel label intuition sources =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "impressions"
                      .= [ object
                             [ "id" .= ("" :: Text),
                               "label" .= label,
                               "intuition" .= intuition,
                               "strength" .= (0.7 :: Double),
                               "sourceMemoryIds" .= ([] :: [Text]),
                               "sourceExperienceRefs" .= sources
                             ]
                         ],
                    "memoryProposals" .= ([] :: [Value]),
                    "voidProposals" .= ([] :: [Text]),
                    "reason" .= ("test" :: Text)
                  ]
              )
          )
      )
      $> Stop

impressionConsolidationModel :: IORef [ChatMessage] -> Model
impressionConsolidationModel captured =
  fakeModel $ \request emit ->
    writeIORef captured (requestMessages request)
      *> emit
        ( ModelTextDelta
            ( jsonText
                ( object
                    [ "impressions" .= ([] :: [Value]),
                      "memoryProposals" .= ([] :: [Value]),
                      "voidProposals" .= ([] :: [Text]),
                      "reason" .= ("integrated the completed experience" :: Text)
                    ]
                )
            )
        )
      $> Stop

impressionCueModel :: Text -> Model
impressionCueModel memoryId =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "cues"
                      .= [ object
                             [ "hint" .= ("A color preference may be relevant." :: Text),
                               "suggestedQuery" .= ("amber" :: Text),
                               "memoryIds" .= [memoryId],
                               "confidence" .= (0.8 :: Double),
                               "reason" .= ("intent resembles a prior preference" :: Text)
                             ]
                         ]
                  ]
              )
          )
      )
      $> Stop

impressionCueWithoutMemoryModel :: Model
impressionCueWithoutMemoryModel =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "cues"
                      .= [ object
                             [ "hint" .= ("A prior direction may be relevant." :: Text),
                               "suggestedQuery" .= Null,
                               "memoryIds" .= ([] :: [Text]),
                               "confidence" .= (0.7 :: Double),
                               "reason" .= ("the intent resembles an established working direction" :: Text)
                             ]
                         ]
                  ]
              )
          )
      )
      $> Stop

cognitionDeleteIncarnation :: Assertion
cognitionDeleteIncarnation =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\cognition ->
      let identity = "yuki-del"
          incarnationStore = cognitionIncarnations cognition
       in incarnationCreate incarnationStore identity "Del" "To be deleted." Nothing
            >>= withTextRight (\created ->
              let expected = incarnationRevision created
               in seedStores cognition identity
                    *> incarnationArchive incarnationStore identity expected
                    >>= withTextRight (\archived ->
                      deleteIncarnation cognition identity (incarnationRevision archived)
                        >>= withTextRight (\_ -> verifyGone cognition identity))))
  where
    seedStores cognition identity = do
      taskArchiveAppend
        (cognitionArchive cognition)
        (ArchiveRunDraft identity "del-task" "del-run" (Just "del-intent") "completed" Nothing
          [ArchiveEntryDraft "user" ArchiveUser "delete me from the archive" Nothing Nothing Nothing])
        >>= either (ioError . userError . Text.unpack) (const (pure ()))
      longTermRemember
        (cognitionLongTerm cognition)
        (RememberRequest identity MemoryPrivate "preference" "delete me from long-term memory" [] ["src"])
        >>= either (ioError . userError . Text.unpack) (const (pure ()))
      let cursor = ExperienceCursor ("experience/" <> identity) 0
      experienceAppend
        (cognitionExperiences cognition)
        Nothing
        (ExperienceDraft identity "del-op" identity Nothing Nothing Nothing Nothing Nothing "UserInputAccepted" "payload-ref" "payload-hash")
        >>= either (ioError . userError . Text.unpack) (const (pure ()))
      workingCreate (cognitionWorking cognition) identity cursor
        >>= either (ioError . userError . Text.unpack) (const (pure ()))
      impressionCommit
        (cognitionImpressions cognition)
        identity
        0
        (emptyImpressionState identity)
        (ImpressionRevision "del-impression-revision" identity "del-experience" 0 1 "test seed" [] [] "del-invocation" "test/model" 0)
        >>= either (ioError . userError . Text.unpack) (const (pure ()))
    verifyGone cognition identity =
      incarnationList (cognitionIncarnations cognition) >>= \incarnations ->
        promptList (cognitionIncarnations cognition) (Just identity) >>= \prompts ->
          taskArchiveTasks (cognitionArchive cognition) identity 20 >>= \archives ->
            experienceEvents (cognitionExperiences cognition) identity >>= \events ->
              workingRead (cognitionWorking cognition) identity >>= \working ->
                longTermCatalog (cognitionLongTerm cognition) identity 20 >>= \catalog ->
                  impressionRead (cognitionImpressions cognition) identity >>= \impression ->
                    sequence_
                      [ assertBool "incarnation record removed" (all ((/= identity) . incarnationId) incarnations),
                        assertBool "charter prompts removed" (null prompts),
                        assertBool "task archive removed" (null archives),
                        assertBool "experience events removed" (null events),
                        assertBool "working memory removed" (working == Nothing),
                        assertBool "long-term catalog removed" (null catalog),
                        assertBool "impression state emptied" (null (impressionItems impression))
                      ]

cognitionPrompts :: Assertion
cognitionPrompts =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \initial ->
        ( incarnationUpdate
            (cognitionIncarnations cognition)
            "yuki"
            (incarnationRevision initial)
            ""
            (incarnationDirection initial)
            (incarnationImpressionModel initial)
            >>= assertLeft
        )
          *> promptAppend
              (cognitionIncarnations cognition)
              (Just "yuki")
              IncarnationCharter
              "audit edit"
              "A deliberately revised working style."
              "test/v1"
              Nothing
              (incarnationPromptRevision initial)
              PromptDraft
            >>= \revision ->
              promptActivate
                (cognitionIncarnations cognition)
                "yuki"
                (incarnationRevision initial)
                (promptRevisionId revision)
                >>= withTextRight (\activated ->
                  compileIncarnationPrompt cognition activated >>= \compiled ->
                    promptList (cognitionIncarnations cognition) (Just "yuki") >>= \revisions ->
                      promptList (cognitionIncarnations cognition) Nothing >>= \roots ->
                        sequence_
                          [ assertBool "default prompt is active at bootstrap" (isJust (incarnationPromptRevision initial)),
                            assertBool "compiled prompt includes root constitution" ("Root Constitution" `Text.isInfixOf` compiled),
                            assertBool "compiled prompt includes activated charter" ("deliberately revised" `Text.isInfixOf` compiled),
                            assertBool "prompt lineage remains auditable" (length revisions >= 2),
                            assertBool
                              "active Root does not contain the v2 Task Archive protocol"
                              ( any
                                  ( \root ->
                                      promptStatus root == PromptActive
                                        && promptGeneratorRevision root == rootPromptRevision
                                        && "immutable Task archive" `Text.isInfixOf` promptContent root
                                  )
                                  roots
                              )
                          ]))

cognitionRootMigration :: Assertion
cognitionRootMigration =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\cognition ->
      promptList (cognitionIncarnations cognition) Nothing >>= \roots ->
        case listToMaybe (reverse (filter ((== PromptActive) . promptStatus) roots)) of
          Nothing -> assertFailure "fresh cognition has no active Root"
          Just active ->
            promptAppend
              (cognitionIncarnations cognition)
              Nothing
              RootConstitution
              "kernel bootstrap"
              "# Yuki Root Constitution · v1\nLegacy automatic root."
              "root-constitution/v1"
              Nothing
              (Just (promptRevisionId active))
              PromptDraft
              >>= \legacy ->
                promptActivateRoot
                  (cognitionIncarnations cognition)
                  (promptOrdinal active)
                  (promptRevisionId legacy)
                  >>= withTextRight
                    ( const
                        ( newCognition dir [] Nothing >>= withTextRight (\reopened ->
                            promptList (cognitionIncarnations reopened) Nothing >>= \migrated ->
                              let activeRoots = filter ((== PromptActive) . promptStatus) migrated
                               in sequence_
                                    [ length activeRoots @?= 1,
                                      fmap promptGeneratorRevision activeRoots @?= [rootPromptRevision],
                                      assertBool
                                        "automatic Root migration lost the Task Archive protocol"
                                        (any (Text.isInfixOf "immutable Task archive" . promptContent) activeRoots)
                                    ])
                        )
                    ))

cognitionPromptRoot :: Assertion
cognitionPromptRoot =
  withWorkDir $ \dir ->
    newIORef [] >>= \captured ->
      newCognition dir [promptCaptureModel captured] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \incarnation ->
        promptList (cognitionIncarnations cognition) Nothing >>= \roots ->
          let expected =
                maybe
                  0
                  promptOrdinal
                  (listToMaybe (reverse (filter ((== PromptActive) . promptStatus) roots)))
           in promptAppend
              (cognitionIncarnations cognition)
              Nothing
              RootConstitution
              "root audit test"
              "# CUSTOM ROOT SENTINEL\nUse the audited root."
              "manual-root-test/v1"
              Nothing
              (promptRevisionId <$> listToMaybe roots)
              PromptDraft
              >>= \root ->
                promptActivateRoot (cognitionIncarnations cognition) expected (promptRevisionId root)
                  >>= withTextRight
                    ( \activated ->
                        cognitionGeneratePrompt cognition incarnation "regenerate beneath edited root"
                          >>= withTextRight
                            ( \generated ->
                                readIORef captured >>= \messages ->
                                  promptList (cognitionIncarnations cognition) Nothing >>= \revisions ->
                                    sequence_
                                      [ promptStatus activated @?= PromptActive,
                                        length (filter ((== PromptActive) . promptStatus) revisions) @?= 1,
                                        assertBool
                                          "generator request contains the active edited Root"
                                          (any rootMarked messages),
                                        assertBool
                                          "generated charter records its Root generator lineage"
                                          (promptRevisionId root `Text.isInfixOf` promptGeneratorRevision generated)
                                      ]
                            )
                    ))
  where
    rootMarked (ChatSystem text) = "CUSTOM ROOT SENTINEL" `Text.isInfixOf` text
    rootMarked _ = False

promptCaptureModel :: IORef [ChatMessage] -> Model
promptCaptureModel captured =
  fakeModel $ \request emit ->
    writeIORef captured (requestMessages request)
      *> emit (ModelTextDelta "# Generated Charter\nA model-generated, auditable charter.")
      $> Stop

cognitionSleep :: Assertion
cognitionSleep =
  withWorkDir $ \dir ->
    newCognition dir [sleepDecisionModel] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \incarnation ->
        testRuntime sleepDecisionModel [] Sequential >>= \base ->
          let runtime =
                base
                  { runtimeContext = Just (ContextConfig 128 2 96 8000),
                    runtimeModel = sleepDecisionModel
                  }
              messages =
                concat
                  [ [ChatUser ("turn " <> Text.pack (show index)), ChatAssistant (AssistantTurn ("a-" <> Text.pack (show index)) (Just "working") Nothing [])]
                    | index <- [1 :: Int .. 12]
                  ]
           in cognitionSleepMessages cognition incarnation "task" (Just "sleep-run") SleepManual runtime messages
                >>= withTextRight (\result ->
                  workingSleepCycles (cognitionWorking cognition) "yuki" >>= \cycles ->
                    contextEpochProject
                      (cognitionContexts cognition)
                      (contextEpochId (sleepResultEpoch result))
                      >>= withTextRight
                        ( \projected ->
                            workingReadFocus (cognitionWorking cognition) "yuki" "task" >>= \focus ->
                              contextEpochHead (cognitionContexts cognition) "yuki" "task" >>= \headEpoch ->
                                sequence_
                                  [ workingMemoryStatus (sleepResultHead result) @?= WorkingAwake,
                                    sleepCycleStatus (sleepResultCycle result) @?= CycleAwake,
                                    wakePacketContinuation (sleepResultPacket result) @?= "Continue from the verified open work.",
                                    assertBool "sleep audits forgetting" (not (null (wakePacketForgotten (sleepResultPacket result)))),
                                    assertBool "active context is a Wake Packet" ("[wake packet" `Text.isPrefixOf` compactionSummary (sleepResultCompaction result)),
                                    fmap (contextSegmentKind . fst) projected @?= [SegmentWakePacket],
                                    assertBool
                                      "forgotten turns are absent from the wake epoch"
                                      (all (not . Text.isInfixOf "turn " . snd) projected),
                                    fmap contextEpochId headEpoch @?= Just (contextEpochId (sleepResultEpoch result)),
                                    fmap focusFrameEpochId focus @?= Just (contextEpochId (sleepResultEpoch result)),
                                    fmap focusFrameObjective focus @?= Just "Continue from the verified open work.",
                                    fmap focusFrameActiveItems focus @?= Just ["current implementation is in progress"],
                                    fmap focusFrameOpenLoops focus @?= Just ["run verification"],
                                    length cycles @?= 1
                                  ]
                        )))

cognitionSleepParallelTools :: Assertion
cognitionSleepParallelTools =
  withWorkDir $ \dir ->
    newCognition dir [retainEverySegmentModel] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \incarnation ->
        testRuntime okModel [] Sequential >>= \base ->
          let runtime = base {runtimeContext = Just (ContextConfig 128 2 96 8000)}
              user = ChatUser ("parallel work " <> Text.replicate 1600 "x")
              messages =
                [ user,
                  ChatAssistant (AssistantTurn "parallel-turn" (Just "checking both") Nothing calls),
                  ChatToolResult "parallel-a" "first result",
                  ChatToolResult "parallel-b" "second result"
                ]
           in cognitionSleepMessages cognition incarnation "parallel-sleep-task" (Just "parallel-sleep-run") SleepManual runtime messages
                >>= withTextRight
                  ( \result ->
                      contextEpochProject
                        (cognitionContexts cognition)
                        (contextEpochId (sleepResultEpoch result))
                        >>= withTextRight
                          ( \projected ->
                              let compacted = dropWhile (/= user) (compactionMessages (sleepResultCompaction result))
                                  replayed = projectedAguiMessages projected >>= toChatMessages
                               in sequence_
                                    [ compacted @?= messages,
                                      fmap (contextSegmentKind . fst) projected
                                        @?= [ SegmentWakePacket,
                                              SegmentUser,
                                              SegmentAssistant,
                                              SegmentToolCall,
                                              SegmentToolCall,
                                              SegmentToolResult,
                                              SegmentToolResult
                                            ],
                                      fmap (contextSegmentTurnGroup . fst) projected
                                        @?= [Nothing, Nothing, Just "parallel-turn", Just "parallel-turn", Just "parallel-turn", Nothing, Nothing],
                                      either (assertFailure . Text.unpack) verifyWake replayed
                                    ]
                          )
                  ))
  where
    calls =
      [ ModelToolCall "parallel-a" "first" "{\"value\":1}",
        ModelToolCall "parallel-b" "second" "{\"value\":2}"
      ]
    verifyWake (ChatSystem packet : retained) =
      sequence_
        [ assertBool "wake projection starts with its packet" (wakePacketMarker `Text.isPrefixOf` packet),
          retained
            @?= [ ChatUser ("parallel work " <> Text.replicate 1600 "x"),
                  ChatAssistant (AssistantTurn "parallel-turn" (Just "checking both") Nothing calls),
                  ChatToolResult "parallel-a" "first result",
                  ChatToolResult "parallel-b" "second result"
                ]
        ]
    verifyWake messages = assertFailure ("unexpected wake projection: " <> show messages)

cognitionLiveSleep :: Assertion
cognitionLiveSleep =
  withWorkDir $ \dir ->
    newCognition dir [sleepDecisionModel] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \incarnation ->
        newIORef (0 :: Int) >>= \turns ->
          newIORef [] >>= \captured ->
            testRuntime (liveSleepAgentModel turns captured) [] Sequential >>= \base ->
              attachCognition
                cognition
                incarnation
                base {runtimeContext = Just (ContextConfig 128 2 96 8000)}
                >>= \runtime ->
                  let input =
                        (sampleInput [])
                          { runThreadId = "live-sleep-task",
                            runId = "live-sleep-run",
                            runMessages =
                              [ User
                                  ( UserMessage
                                      "live-user"
                                      (UserText "live-run-user-sentinel")
                                      Nothing
                                  )
                              ]
                          }
                   in collectEvents runtime input >>= \events ->
                        readIORef captured >>= \secondRequest ->
                          contextEpochHead (cognitionContexts cognition) "yuki" "live-sleep-task" >>= \epoch ->
                            traverse
                              (contextEpochProject (cognitionContexts cognition) . contextEpochId)
                              epoch
                              >>= \projected ->
                                sequence_
                                  [ assertBool "run completed after sleeping" (any (\case RunFinished {} -> True; _ -> False) events),
                                    assertBool "next turn receives a Wake Packet" (any wakeMessage secondRequest),
                                    assertBool "forgotten live user input is absent" (ChatUser "live-run-user-sentinel" `notElem` secondRequest),
                                    assertBool "forgotten sleep call is absent" (not (any sleepCall secondRequest)),
                                    assertBool "forgotten sleep result is absent" (not (any toolResult secondRequest)),
                                    fmap (fmap (fmap (contextSegmentKind . fst))) projected
                                      @?= Just (Right [SegmentWakePacket, SegmentAssistant]),
                                    assertBool
                                      "closed context does not resurrect the forgotten live input"
                                      ( maybe
                                          False
                                          (either (const False) (all (not . Text.isInfixOf "live-run-user-sentinel" . snd)))
                                          projected
                                      )
                                  ])
  where
    wakeMessage (ChatSystem text) = wakePacketMarker `Text.isPrefixOf` text
    wakeMessage _ = False
    sleepCall (ChatAssistant turn) = any ((== "sleep") . modelToolName) (turnToolCalls turn)
    sleepCall _ = False
    toolResult ChatToolResult {} = True
    toolResult _ = False

liveSleepAgentModel :: IORef Int -> IORef [ChatMessage] -> Model
liveSleepAgentModel turns captured =
  fakeModel $ \request emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next))
      >>= \case
        1 ->
          emit
            ( ModelToolCallDelta
                0
                (Just "sleep-call")
                (Just "sleep")
                "{\"reason\":\"clear the live working context\"}"
            )
            $> ToolUse
        2 ->
          writeIORef captured (requestMessages request)
            *> emit (ModelTextDelta "continued after waking")
            $> Stop
        _ -> throwIO (ProviderFailure "unexpected model turn after live sleep")

cognitionPreparedRecovery :: Assertion
cognitionPreparedRecovery =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\before ->
      ensureIncarnation before "yuki" >>= \_ ->
        contextEpochCommit
          (cognitionContexts before)
          "yuki"
          "recovery-task"
          Nothing
          [ContextSegmentInput "recovery-user" SegmentUser AuthorityUser "recover this task" Nothing Nothing]
          Nothing
          >>= withTextRight
            ( \baseEpoch ->
                experienceHead (cognitionExperiences before) "yuki" >>= \cursor ->
                  workingCreate (cognitionWorking before) "yuki" cursor >>= withTextRight (\created ->
                    let frame =
                          FocusFrame
                            "focus/yuki/recovery-task"
                            "yuki"
                            "recovery-task"
                            1
                            FocusActive
                            (contextEpochId baseEpoch)
                            "pre-sleep objective"
                            ["old active"]
                            ["old loop"]
                            ["discard this provisional claim"]
                            []
                            []
                            cursor
                            1
                     in workingPutFocus
                          (cognitionWorking before)
                          "yuki"
                          (workingMemoryRevision created)
                          frame
                          >>= withTextRight
                            ( \focused ->
                                workingRequestSleep
                                  (cognitionWorking before)
                                  "yuki"
                                  (workingMemoryRevision focused)
                                  "prepared-cycle"
                                  "recovery-task"
                                  (Just "recovery-run")
                                  (contextEpochId baseEpoch)
                                  SleepManual
                                  >>= withTextRight
                                    ( \(quiescing, _) ->
                                        let packet =
                                              WakePacket
                                                "prepared-packet"
                                                "yuki"
                                                "recovery-task"
                                                (Just "recovery-run")
                                                (contextEpochId baseEpoch)
                                                SleepManual
                                                "wake objective"
                                                ["wake active"]
                                                ["wake loop"]
                                                [ForgetDecision "noise" "not needed" []]
                                                []
                                                "packet-payload"
                                                sleepDreamRevision
                                                "sleep-invocation"
                                                2
                                            checkpoint =
                                              WorkingMemoryCheckpoint
                                                "prepared-checkpoint"
                                                "yuki"
                                                (workingMemoryRevision quiescing)
                                                cursor
                                                (workingMemoryFocusFrames quiescing)
                                                (workingMemoryActiveTaskId quiescing)
                                                "checkpoint-payload"
                                                "checkpoint-closure"
                                                "prepared-packet"
                                                sleepDreamRevision
                                                2
                                         in workingPrepareCheckpoint
                                              (cognitionWorking before)
                                              "yuki"
                                              (workingMemoryRevision quiescing)
                                              "prepared-cycle"
                                              checkpoint
                                              packet
                                              >>= withTextRight
                                                ( const
                                                    ( newCognition dir [] Nothing >>= withTextRight verifyRecovered
                                                    )
                                                )
                                    )
                            )
                  )
            ))
  where
    verifyRecovered recovered =
      workingRead (cognitionWorking recovered) "yuki" >>= \head' ->
        workingReadFocus (cognitionWorking recovered) "yuki" "recovery-task" >>= \focus ->
          workingReadSleepCycle (cognitionWorking recovered) "prepared-cycle" >>= \cycle' ->
            contextEpochHead (cognitionContexts recovered) "yuki" "recovery-task" >>= \epoch ->
              sequence_
                [ fmap workingMemoryStatus head' @?= Just WorkingAwake,
                  fmap sleepCycleStatus cycle' @?= Just CycleAwake,
                  fmap contextEpochWakePacketId epoch @?= Just (Just "prepared-packet"),
                  fmap focusFrameEpochId focus @?= (contextEpochId <$> epoch),
                  fmap focusFrameObjective focus @?= Just "wake objective",
                  fmap focusFrameActiveItems focus @?= Just ["wake active"],
                  fmap focusFrameOpenLoops focus @?= Just ["wake loop"],
                  fmap focusFrameProvisionalClaims focus @?= Just []
                ]

cognitionSleepFailure :: Assertion
cognitionSleepFailure =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \incarnation ->
        testRuntime okModel [] Sequential >>= \base ->
          let runtime = base {runtimeContext = Just contextConfig}
              input = (sampleInput []) {runThreadId = "failed-sleep-task", runId = "failed-sleep-run"}
              messages = [ChatUser "work that must not disappear"]
           in case forcedCompaction runtime [] messages of
                Nothing -> assertFailure "missing forced compaction fixture"
                Just compaction ->
                  ( try
                      (afterCompaction (cognitionHooks cognition incarnation) input 1 False True messages compaction) ::
                      IO (Either SomeException Compaction)
                  )
                    >>= \attempt ->
                      workingSleepCycles (cognitionWorking cognition) "yuki" >>= \cycles ->
                        contextEpochHead (cognitionContexts cognition) "yuki" "failed-sleep-task" >>= \epoch ->
                          sequence_
                            [ either (const (pure ())) (const (assertFailure "sleep failure was silently accepted")) attempt,
                              cycles @?= [],
                              fmap contextEpochWakePacketId epoch @?= Just Nothing
                            ])

cognitionAuthoritativeContext :: Assertion
cognitionAuthoritativeContext =
  withWorkDir $ \dir ->
    newCognition (dir ++ "/cognition") [] Nothing >>= withTextRight (\cognition ->
      sessionServiceAt (dir ++ "/sessions") (const (pure ())) >>= \service ->
        contextEpochCommit
          (cognitionContexts cognition)
          "yuki"
          "authority-task"
          Nothing
          [ ContextSegmentInput "old-user" SegmentUser AuthorityUser "epoch-user-sentinel" Nothing Nothing,
            ContextSegmentInput "old-answer" SegmentAssistant AuthorityAgent "epoch-assistant-sentinel" Nothing Nothing
          ]
          Nothing
          >>= withTextRight
            ( \_ ->
                newIORef [] >>= \captured ->
                  testRuntime (promptCaptureModel captured) [] Sequential >>= \runtime ->
                    let inspection =
                          withCognition cognition
                            (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
                        app = application Nothing (Just inspection) Nothing Nothing (const (pure runtime))
                     in transcriptLoad (serviceTranscripts service) "authority-task" >>= \stored ->
                          (stored @?= Nothing)
                            *> runSession (srequest (agentPost "authority-task")) app
                            >>= \response ->
                              readIORef captured >>= \messages ->
                                sequence_
                                  [ simpleStatus response @?= status200,
                                    assertBool "epoch user survives without transcript" (ChatUser "epoch-user-sentinel" `elem` messages),
                                    assertBool
                                      "epoch assistant survives without transcript"
                                      ( any
                                          ( \case
                                              ChatAssistant turn -> turnText turn == Just "epoch-assistant-sentinel"
                                              _ -> False
                                          )
                                          messages
                                      ),
                                    assertBool "latest submitted user is appended" (ChatUser "hello" `elem` messages)
                                  ]
            ))

-- Context epochs written before turn grouping split one assistant tool turn into
-- adjacent segments. Reprojection must repair that shape before any provider sees it.
cognitionLegacyParallelTools :: Assertion
cognitionLegacyParallelTools =
  withWorkDir $ \dir ->
    newCognition (dir ++ "/cognition") [] Nothing >>= withTextRight (\cognition ->
      sessionServiceAt (dir ++ "/sessions") (const (pure ())) >>= \service ->
        contextEpochCommit
          (cognitionContexts cognition)
          "yuki"
          task
          Nothing
          legacySegments
          Nothing
          >>= withTextRight
            ( \epoch ->
                contextEpochProject (cognitionContexts cognition) (contextEpochId epoch)
                  >>= withTextRight
                    ( \projected ->
                        newIORef [] >>= \captured ->
                          testRuntime (promptCaptureModel captured) [] Sequential >>= \runtime ->
                            let inspection =
                                  withCognition cognition
                                    (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
                                app = application Nothing (Just inspection) Nothing Nothing (const (pure runtime))
                             in runSession (srequest (agentPost task)) app >>= \response ->
                                  readIORef captured >>= \messages ->
                                    verifyIncomplete (cognitionContexts cognition)
                                      *> sequence_
                                        [ (projectedAguiMessages projected >>= toChatMessages) @?= Right history,
                                          dropWhile (/= ChatUser "legacy parallel user") messages
                                            @?= history <> [ChatUser "hello"],
                                          simpleStatus response @?= status200
                                        ]
                    )
            ))
  where
    task = "legacy-parallel-task"
    firstCall = ModelToolCall "legacy-call-a" "first" "{\"value\":1}"
    secondCall = ModelToolCall "legacy-call-b" "second" "{\"value\":2}"
    calls = [firstCall, secondCall]
    history =
      [ ChatUser "legacy parallel user",
        ChatAssistant (AssistantTurn "legacy-turn" (Just "checking both") Nothing calls),
        ChatToolResult "legacy-call-a" "first result",
        ChatToolResult "legacy-call-b" "second result"
      ]
    legacySegments =
      [ ContextSegmentInput "legacy-user" SegmentUser AuthorityUser "legacy parallel user" Nothing Nothing,
        ContextSegmentInput "legacy-turn" SegmentAssistant AuthorityAgent "checking both" Nothing Nothing,
        ContextSegmentInput "legacy-call-a" SegmentToolCall AuthorityAgent (jsonText firstCall) (Just "legacy-call-a") Nothing,
        ContextSegmentInput "legacy-call-b" SegmentToolCall AuthorityAgent (jsonText (FunctionCall "second" "{\"value\":2}")) (Just "legacy-call-b") Nothing,
        ContextSegmentInput "legacy-result-a" SegmentToolResult AuthorityTool "first result" (Just "legacy-call-a") Nothing,
        ContextSegmentInput "legacy-result-b" SegmentToolResult AuthorityTool "second result" (Just "legacy-call-b") Nothing
      ]
    verifyIncomplete store =
      contextEpochCommit
        store
        "yuki"
        "incomplete-tool-task"
        Nothing
        [ ContextSegmentInput "incomplete-turn" SegmentAssistant AuthorityAgent "working" Nothing Nothing,
          ContextSegmentInput "incomplete-call" SegmentToolCall AuthorityAgent (jsonText (ModelToolCall "incomplete-call" "work" "{}")) (Just "incomplete-call") Nothing
        ]
        Nothing
        >>= withTextRight
          ( contextEpochProject store . contextEpochId
              >=> withTextRight (assertLeft . projectedAguiMessages)
          )

sleepDecisionModel :: Model
sleepDecisionModel =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "continuation" .= ("Continue from the verified open work." :: Text),
                    "activeItems" .= [("current implementation is in progress" :: Text)],
                    "openLoops" .= [("run verification" :: Text)],
                    "forgotten"
                      .= [ object
                             [ "subject" .= ("superseded conversational detail" :: Text),
                               "reason" .= ("not needed for the next action" :: Text),
                               "sourceSegmentIds" .= ([] :: [Text])
                             ]
                         ],
                    "retainedSegmentIds" .= ([] :: [Text])
                  ]
              )
          )
      )
      $> Stop

retainEverySegmentModel :: Model
retainEverySegmentModel =
  fakeModel $ \request emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( DreamDecision
                  "Continue the parallel tool work."
                  ["parallel tool work is active"]
                  ["finish the response"]
                  []
                  (take 12 (nub (concatMap segmentIds [text | ChatUser text <- requestMessages request])))
              )
          )
      )
      $> Stop
  where
    segmentIds text
      | Text.null suffix = []
      | otherwise = Text.take 40 suffix : segmentIds (Text.drop 40 suffix)
      where
        (_, suffix) = Text.breakOn "segment-" text

cognitionHttp :: Assertion
cognitionHttp =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\cognition ->
      testRuntime okModel [] Parallel >>= \runtime ->
        let inspection = withCognition cognition emptyInspection
            app = application Nothing (Just inspection) Nothing Nothing (const (pure runtime))
         in promptList (cognitionIncarnations cognition) Nothing >>= \roots ->
              case listToMaybe roots of
                Nothing -> assertFailure "missing Root prompt revision"
                Just root ->
                  runSession (request (httpGet ["incarnations"])) app >>= \incarnations ->
                    runSession (request (httpGet ["incarnations", "yuki", "impression"])) app >>= \impression ->
                      runSession
                        ( srequest
                            ( jsonRequest
                                methodPost
                                ["prompts", "root"]
                                ( object
                                    [ "sourceIntent" .= (" " :: Text),
                                      "content" .= ("must not be accepted" :: Text)
                                    ]
                                )
                            )
                        )
                        app
                        >>= \emptyDraft ->
                          runSession
                            ( srequest
                                ( jsonRequest
                                    methodPost
                                    ["incarnations", "yuki", "prompts"]
                                    ( object
                                        [ "sourceIntent" .= ("invalid lineage" :: Text),
                                          "content" .= ("must remain a draft" :: Text),
                                          "parentRevision" .= promptRevisionId root
                                        ]
                                    )
                                )
                            )
                            app
                            >>= \wrongParent ->
                              sequence_
                                [ simpleStatus incarnations @?= status200,
                                  simpleStatus impression @?= status200,
                                  simpleStatus emptyDraft @?= status400,
                                  simpleStatus wrongParent @?= status400,
                                  assertBool
                                    "default incarnation is present"
                                    ("\"id\":\"yuki\"" `ByteString.isInfixOf` LazyByteString.toStrict (simpleBody incarnations))
                                ])

cognitionTaskArchiveHttp :: Assertion
cognitionTaskArchiveHttp =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\cognition ->
      testRuntime okModel [] Parallel >>= \runtime ->
        taskArchiveAppend
          (cognitionArchive cognition)
          ( ArchiveRunDraft
              "yuki"
              "route-task"
              "route-run"
              Nothing
              "completed"
              Nothing
              [ArchiveEntryDraft "route-user" ArchiveUser "route-memory-sentinel" Nothing Nothing Nothing]
          )
          >>= withTextRight
            ( \stored ->
                case archiveRunEntryIds stored of
                  [entryId] ->
                    let app = application Nothing (Just (withCognition cognition emptyInspection)) Nothing Nothing (const (pure runtime))
                     in runSession (request (httpGet ["incarnations", "yuki", "task-records"])) app >>= \catalog ->
                          runSession
                            ( srequest
                                ( jsonRequest
                                    methodPost
                                    ["incarnations", "yuki", "task-records", "search"]
                                    ( object
                                        [ "query" .= ("route-memory-sentinel" :: Text),
                                          "caseSensitive" .= True,
                                          "limit" .= (20 :: Int)
                                        ]
                                    )
                                )
                            )
                            app
                            >>= \searched ->
                              runSession (request (httpGet ["incarnations", "yuki", "task-records", entryId])) app >>= \readBack ->
                                runSession (request (httpGet ["incarnations", "yuki", "task-records", "missing-entry"])) app >>= \missingEntry ->
                                  sequence_
                                    [ simpleStatus catalog @?= status200,
                                      simpleStatus searched @?= status200,
                                      simpleStatus readBack @?= status200,
                                      simpleStatus missingEntry @?= status404,
                                      responseContains "route-task" catalog,
                                      responseContains "\"mode\":\"fixed\"" searched,
                                      responseContains "route-memory-sentinel" searched,
                                      responseContains "route-memory-sentinel" readBack
                                    ]
                  identifiers -> assertFailure ("unexpected Task archive entry count: " <> show (length identifiers))
            ))
  where
    responseContains needle =
      assertBool
        ("response body does not contain " <> needle)
        . ByteString.isInfixOf (TextEncoding.encodeUtf8 (Text.pack needle))
        . LazyByteString.toStrict
        . simpleBody

cognitionLifecycleHttp :: Assertion
cognitionLifecycleHttp =
  withWorkDir $ \dir ->
    newCognition (dir ++ "/cognition") [] Nothing >>= withTextRight (\cognition ->
      sessionServiceAt (dir ++ "/sessions") (const (pure ())) >>= \service ->
        testRuntime okModel [] Parallel >>= \runtime ->
          incarnationCreate
            (cognitionIncarnations cognition)
            "art"
            "Art"
            "Make careful visual judgments."
            Nothing
            >>= withTextRight
              ( \created ->
                  let view = testView (serviceConfigs service)
                      inspection =
                        withCognition cognition
                          (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
                      app = application Nothing (Just inspection) (Just view) Nothing (const (pure runtime))
                      post path body = runSession (srequest (jsonRequest methodPost path body)) app
                   in post
                        ["threads"]
                        ( object
                            [ "threadId" .= ("art-task" :: Text),
                              "title" .= ("Art task" :: Text),
                              "incarnationId" .= ("art" :: Text)
                            ]
                        )
                        >>= \taskCreated ->
                          threadConfigRead (serviceConfigs service) "art-task" >>= \bound ->
                            post
                              ["incarnations", "art", "archive"]
                              (object ["expectedRevision" .= incarnationRevision created])
                              >>= \archived ->
                                runSession (request (httpGet ["incarnations"])) app >>= \activeList ->
                                  runSession
                                    (request ((httpGet ["incarnations"]) {queryString = [("archived", Just "true")]}))
                                    app
                                    >>= \allList ->
                                      runSession (request (httpGet ["incarnations", "art"])) app >>= \hidden ->
                                        findSession (serviceSessions service) "art-task" >>= \archivedTask ->
                                          post
                                            ["threads"]
                                            ( object
                                                [ "threadId" .= ("rejected-task" :: Text),
                                                  "incarnationId" .= ("art" :: Text)
                                                ]
                                            )
                                            >>= \rejectedCreate ->
                                              post ["threads", "art-task", "restore"] (object [])
                                                >>= \blockedTaskRestore ->
                                                  post ["incarnations", "art", "restore"] (object ["expectedRevision" .= (2 :: Int)])
                                                    >>= \restored ->
                                                      findSession (serviceSessions service) "art-task" >>= \stillArchived ->
                                                        post ["threads", "art-task", "restore"] (object [])
                                                          >>= \taskRestored ->
                                                            sequence_
                                                              [ simpleStatus taskCreated @?= status200,
                                                                configIncarnationId bound @?= Just "art",
                                                                simpleStatus archived @?= status200,
                                                                assertBool
                                                                  "archived incarnation is hidden from the default list"
                                                                  (not (containsArt activeList)),
                                                                assertBool
                                                                  "archived incarnation remains auditable"
                                                                  (containsArt allList),
                                                                simpleStatus hidden @?= status404,
                                                                fmap sessionArchived archivedTask @?= Just True,
                                                                fmap sessionIncarnationId archivedTask @?= Just "art",
                                                                simpleStatus rejectedCreate @?= status409,
                                                                simpleStatus blockedTaskRestore @?= status409,
                                                                simpleStatus restored @?= status200,
                                                                fmap sessionArchived stillArchived @?= Just True,
                                                                fmap sessionIncarnationId stillArchived @?= Just "art",
                                                                simpleStatus taskRestored @?= status200
                                                              ]
              ))
  where
    containsArt =
      ByteString.isInfixOf "\"id\":\"art\""
        . LazyByteString.toStrict
        . simpleBody

cognitionTaskOwnerHttp :: Assertion
cognitionTaskOwnerHttp =
  withWorkDir $ \dir ->
    newCognition (dir ++ "/cognition") [] Nothing >>= withTextRight (\cognition ->
      sessionServiceAt (dir ++ "/sessions") (const (pure ())) >>= \service ->
        testRuntime okModel [] Parallel >>= \runtime ->
          incarnationCreate
            (cognitionIncarnations cognition)
            "art"
            "Art"
            "Make careful visual judgments."
            Nothing
            >>= withTextRight
              ( \_ ->
                  let view = testView (serviceConfigs service)
                      inspection =
                        withCognition cognition
                          (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
                      app = application Nothing (Just inspection) (Just view) Nothing (const (pure runtime))
                      create =
                        jsonRequest
                          methodPost
                          ["threads"]
                          (object ["threadId" .= ("owned-task" :: Text), "incarnationId" .= ("art" :: Text)])
                   in runSession (srequest create) app >>= \created ->
                        runSession
                          ( srequest
                              ( putConfig
                                  "owned-task"
                                  (encode (emptyThreadConfig {configIncarnationId = Just "yuki"}))
                              )
                          )
                          app
                          >>= \reassigned ->
                            runSession
                              ( srequest
                                  ( putConfig
                                      "owned-task"
                                      (encode (emptyThreadConfig {configSystemPrompt = Just "kept"}))
                                  )
                              )
                              app
                              >>= \updated ->
                                threadConfigRead (serviceConfigs service) "owned-task" >>= \canonical ->
                                  threadConfigWrite
                                    (serviceConfigs service)
                                    "owned-task"
                                    canonical {configIncarnationId = Just "yuki"}
                                    *> runSession (request (httpGet ["incarnations", "art", "tasks"])) app
                                    >>= \artTasks ->
                                      runSession (request (httpGet ["incarnations", "yuki", "tasks"])) app
                                        >>= \yukiTasks ->
                                          findSession (serviceSessions service) "owned-task" >>= \meta ->
                                            sequence_
                                              [ simpleStatus created @?= status200,
                                                simpleStatus reassigned @?= status409,
                                                simpleStatus updated @?= status204,
                                                configIncarnationId canonical @?= Just "art",
                                                configSystemPrompt canonical @?= Just "kept",
                                                fmap sessionIncarnationId meta @?= Just "art",
                                                decodeTaskIds artTasks @?= Right ["owned-task"],
                                                decodeTaskIds yukiTasks @?= Right []
                                              ]
              ))
  where
    decodeTaskIds response =
      fmap (fmap sessionId) (eitherDecode (simpleBody response) :: Either String [SessionMeta])

cognitionArchiveActiveRun :: Assertion
cognitionArchiveActiveRun =
  withWorkDir $ \dir ->
    newCognition (dir ++ "/cognition") [] Nothing >>= withTextRight (\cognition ->
      sessionServiceAt (dir ++ "/sessions") (const (pure ())) >>= \service ->
        newRunRegistry >>= \runs ->
          newEmptyMVar >>= \release ->
            testRuntime okModel [] Parallel >>= \runtime ->
              incarnationCreate
                (cognitionIncarnations cognition)
                "art"
                "Art"
                "Make careful visual judgments."
                Nothing
                >>= withTextRight
                  ( \created ->
                      createSession (serviceSessions service) "art-live-task" Nothing "art" Nothing Nothing
                        >>= withTextRight
                          ( \_ ->
                              threadConfigWrite
                                (serviceConfigs service)
                                "art-live-task"
                                emptyThreadConfig {configIncarnationId = Just "art"}
                                *> forkIO
                                  (withRunRegistrationFor runs "art-live-run" "art-live-task" (takeMVar release))
                                *> waitUntil (elem "art-live-task" <$> activeThreads runs)
                                >>= \registered ->
                                  let view = testView (serviceConfigs service)
                                      inspection =
                                        withCognition cognition
                                          (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
                                      app = application Nothing (Just inspection) (Just view) (Just runs) (const (pure runtime))
                                   in runSession
                                        ( srequest
                                            ( jsonRequest
                                                methodPost
                                                ["incarnations", "art", "archive"]
                                                (object ["expectedRevision" .= incarnationRevision created])
                                            )
                                        )
                                        app
                                        >>= \blocked ->
                                          putMVar release ()
                                            *> waitUntil (null <$> activeThreads runs)
                                            >>= \stopped ->
                                              incarnationRead (cognitionIncarnations cognition) "art" >>= \current ->
                                                findSession (serviceSessions service) "art-live-task" >>= \task ->
                                                  sequence_
                                                    [ assertBool "live run registered" registered,
                                                      simpleStatus blocked @?= status409,
                                                      assertBool "run registration released" stopped,
                                                      fmap incarnationStatus current @?= Just IncarnationActive,
                                                      fmap sessionArchived task @?= Just False
                                                    ]
                          )
                  ))

jsonText :: ToJSON value => value -> Text
jsonText = TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

withTextRight :: (value -> Assertion) -> Either Text value -> Assertion
withTextRight use = either (assertFailure . Text.unpack) use

factsTests :: TestTree
factsTests =
  testGroup
    "facts"
    [ testCase "memorizes watcher facts, drops malformed entries and dedupes by content" memorizeDedup,
      testCase "materializes a retrieval slot after the briefing and touches hits" retrievalSlot,
      testCase "stays inert on an unparseable watcher decision" badJsonSilent,
      testCase "caps retrievals at three per run" budgetCapped,
      testCase "cools a repeated query down for five watcher rounds" cooldownThrottles,
      testCase "persists facts as jsonl across restarts" fileRoundTrip,
      testCase "replays a journaled run with a retrieval slot without divergence" retrievalReplay,
      testCase "archives old untouched facts, hiding them from search but not the list" archiveStale,
      testCase "invalidates a fact by content and reports a miss" invalidateByContent,
      testCase "voids a fact named by a watcher invalidate decision" watcherInvalidates,
      testCase "parses fact lines written before archived and void existed" legacyLine,
      testCase "replays a journaled run with an invalidate decision without divergence" invalidateReplay
    ]

retrieveWatcher :: Model
retrieveWatcher =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          "{\"summary\":\"s\",\"memorize\":[],\"retrieve\":{\"query\":\"deploy target\",\"reason\":\"need env\"}}"
      )
      $> Stop

slotMarked :: ChatMessage -> Bool
slotMarked (ChatSystem text) = candidatesMarker `Text.isInfixOf` text
slotMarked _ = False

invalidateWatcher :: Model
invalidateWatcher =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          "{\"summary\":\"s\",\"memorize\":[],\"retrieve\":null,\"invalidate\":[\
          \{\"content\":\"the deploy target is fly.io\",\"reason\":\"moved to railway\"},\
          \{\"content\":42}]}"
      )
      $> Stop

memorizeDedup :: Assertion
memorizeDedup =
  newMemoryFactStore >>= \facts ->
    newMemoryThreadStore >>= \threads ->
      newMemoryState >>= \state ->
        transformContext (memoryHooks memorizeWatcher threads facts Nothing state) (sampleInput []) [ChatUser "hi"]
          *> factList facts
          >>= \case
            [fact] ->
              sequence_
                [ factContent fact @?= "uses ghcup for the toolchain",
                  factKind fact @?= FactProject,
                  factSource fact @?= "run",
                  factId fact @?= factIdFor "uses ghcup for the toolchain"
                ]
            other -> assertFailure ("unexpected facts: " <> show (length other))
  where
    memorizeWatcher =
      fakeModel $ \_ emit ->
        emit
          ( ModelTextDelta
              "{\"summary\":\"s\",\"memorize\":[\
              \{\"content\":\"uses ghcup for the toolchain\",\"kind\":\"project\",\"reason\":\"setup\"},\
              \{\"content\":\"uses ghcup for the toolchain\",\"kind\":\"project\",\"reason\":\"setup\"},\
              \{\"content\":\"bogus entry\",\"kind\":\"nonsense\",\"reason\":\"bad\"}],\
              \\"retrieve\":null}"
          )
          $> Stop

retrievalSlot :: Assertion
retrievalSlot =
  newMemoryFactStore >>= \facts ->
    factAdd facts "the deploy target is fly.io" FactProject "run-0"
      *> newMemoryThreadStore
      >>= \threads ->
        threadSaveEpisode threads "thread" (Episode "run-0" "earlier" 1700000000)
          *> newMemoryState
          >>= \state ->
            transformContext (memoryHooks retrieveWatcher threads facts Nothing state) (sampleInput []) [ChatUser "hi"]
              >>= \once ->
                transformContext (memoryHooks retrieveWatcher threads facts Nothing state) (sampleInput []) once
                  >>= \twice -> verify facts once twice
  where
    verify facts once twice =
      case once of
        [ChatSystem brief, ChatSystem slot, ChatUser "hi"] ->
          sequence_
            [ assertBool "briefing stays at the head" (briefingMarker `Text.isInfixOf` brief),
              assertBool "slot follows the briefing" (candidatesMarker `Text.isInfixOf` slot),
              assertBool "slot carries kind and content" (Text.isInfixOf "- project: the deploy target is fly.io" slot),
              twice @?= once
            ]
            *> touched facts
        other -> assertFailure ("unexpected context: " <> show (length other) <> " messages")
    touched facts =
      factList facts >>= \case
        [fact] ->
          sequence_
            [ factUseCount fact @?= 1,
              assertBool "lastUsed updated" (factLastUsed fact > 0)
            ]
        other -> assertFailure ("unexpected facts: " <> show (length other))

badJsonSilent :: Assertion
badJsonSilent =
  newMemoryFactStore >>= \facts ->
    newMemoryThreadStore >>= \threads ->
      newMemoryState >>= \state ->
        transformContext (memoryHooks broken threads facts Nothing state) (sampleInput []) [ChatUser "hi"]
          >>= \messages ->
            factList facts
              >>= \stored ->
                sequence_
                  [ messages @?= [ChatUser "hi"],
                    stored @?= []
                  ]
  where
    broken = fakeModel (\_ emit -> emit (ModelTextDelta "{\"summary\": broken") $> Stop)

budgetCapped :: Assertion
budgetCapped =
  newMemoryFactStore >>= \facts ->
    newIORef (0 :: Int) >>= \searches ->
      newIORef (0 :: Int) >>= \calls ->
        newMemoryThreadStore >>= \threads ->
          newMemoryState >>= \state ->
            let hooks = memoryHooks (rotatingWatcher calls) threads (spySearch searches facts) Nothing state
             in traverse_ (transformContext hooks (sampleInput [])) (stagesFor 4)
                  *> (readIORef searches >>= (@?= 3))

cooldownThrottles :: Assertion
cooldownThrottles =
  newMemoryFactStore >>= \facts ->
    newIORef (0 :: Int) >>= \searches ->
      newMemoryThreadStore >>= \threads ->
        newMemoryState >>= \state ->
          let hooks = memoryHooks retrieveWatcher threads (spySearch searches facts) Nothing state
           in traverse_ (transformContext hooks (sampleInput [])) (stagesFor 7)
                *> (readIORef searches >>= (@?= 2))

rotatingWatcher :: IORef Int -> Model
rotatingWatcher counter =
  fakeModel $ \_ emit ->
    atomicModifyIORef' counter (\count -> (count + 1, count + 1))
      >>= \count ->
        emit
          ( ModelTextDelta
              ( "{\"summary\":\"s\",\"memorize\":[],\"retrieve\":{\"query\":\"q-"
                  <> Text.pack (show count)
                  <> "\",\"reason\":\"r\"}}"
              )
          )
          $> Stop

spySearch :: IORef Int -> FactStore -> FactStore
spySearch counter store =
  store {factSearch = \query -> modifyIORef' counter (+ 1) *> factSearch store query}

stagesFor :: Int -> [[ChatMessage]]
stagesFor rounds = [take amount dialog | amount <- take rounds [1, 3 ..]]
  where
    dialog =
      concatMap
        (\index -> [ChatUser ("u-" <> Text.pack (show index)), assistantReply])
        [(1 :: Int) ..]

assistantReply :: ChatMessage
assistantReply = ChatAssistant (AssistantTurn "m" (Just "ok") Nothing [])

fileRoundTrip :: Assertion
fileRoundTrip =
  getTemporaryDirectory >>= \tmp ->
    newId >>= \identifier ->
      let dir = tmp ++ "/" ++ Text.unpack identifier
       in newFactStore dir
            >>= \store ->
              factAdd store "prefers point-free style" FactPreference "run-1"
                >>= \fact ->
                  factAdd store "prefers point-free style" FactPreference "run-1"
                    *> factTouch store [fact]
                    *> newFactStore dir
                    >>= verify
  where
    verify reloaded =
      factList reloaded >>= \case
        [fact] ->
          sequence_
            [ factId fact @?= factIdFor "prefers point-free style",
              factUseCount fact @?= 1,
              assertBool "lastUsed persisted" (factLastUsed fact > 0)
            ]
        other -> assertFailure ("unexpected facts: " <> show (length other))

retrievalReplay :: Assertion
retrievalReplay =
  newMemoryFactStore >>= \facts ->
    factAdd facts "the deploy target is fly.io" FactProject "run-0"
      *> newMemoryThreadStore
      >>= \threads ->
        newMemoryJournal
        >>= \(journal, readEntries) ->
          newMemoryState >>= \state ->
            testRuntime mainModel [] Parallel >>= \base ->
              collectEvents base {runtimeHooks = hooks facts threads journal state, runtimeJournal = Just journal} (sampleInput [])
                >>= \events ->
                  readEntries >>= \recorded ->
                  replayWithStores threads facts Nothing recorded >>= \report ->
                      sequence_
                        [ fmap reportDivergence report @?= Right Nothing,
                          fmap reportEvents report @?= Right (length events),
                          assertBool "journaled request carries the retrieval slot" (any slotted recorded)
                        ]
  where
    hooks facts threads journal state = memoryHooks retrieveWatcher threads facts (Just journal) state
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)
    slotted (Entry _ _ _ (ModelRequestEntry request)) = any slotMarked (requestMessages request)
    slotted _ = False

archiveStale :: Assertion
archiveStale =
  getTemporaryDirectory >>= \tmp ->
    newId >>= \identifier ->
      let dir = tmp ++ "/" ++ Text.unpack identifier
       in createDirectoryIfMissing True dir
            *> LazyByteString.writeFile (dir ++ "/facts.jsonl") seed
            *> newFactStore dir
            >>= exercise dir
  where
    seed = LazyByteString.intercalate "\n" (fmap encode specimens) <> "\n"
    specimens =
      [ Fact (factIdFor "legacy deploy target") "legacy deploy target" FactProject "run-0" 1000 0 0 False False,
        Fact (factIdFor "touched old detail") "touched old detail" FactProject "run-0" 1000 100 3 False False,
        Fact (factIdFor "fresh detail") "fresh detail" FactProject "run-0" 2000 0 0 False False
      ]
    exercise dir store =
      factArchiveOlderThan store 1500 >>= \count ->
        factSearch store "legacy deploy" >>= \hits ->
          factSearch store "fresh" >>= \survivors ->
            factList store >>= \listed ->
              newFactStore dir >>= \reloaded ->
                factList reloaded >>= \persisted ->
                  sequence_
                    [ count @?= 1,
                      hits @?= [],
                      length survivors @?= 1,
                      fmap factArchived listed @?= [False, True, False],
                      fmap factArchived persisted @?= [False, True, False]
                    ]

invalidateByContent :: Assertion
invalidateByContent =
  newMemoryFactStore >>= \facts ->
    factAdd facts "the deploy target is fly.io" FactProject "run-0"
      *> factInvalidate facts "the deploy target is fly.io"
      >>= \hit ->
        factInvalidate facts "no such fact" >>= \miss ->
          factSearch facts "deploy target" >>= \hits ->
            factList facts >>= \listed ->
              sequence_
                [ hit @?= True,
                  miss @?= False,
                  hits @?= [],
                  fmap factVoid listed @?= [True]
                ]

watcherInvalidates :: Assertion
watcherInvalidates =
  newMemoryFactStore >>= \facts ->
    factAdd facts "the deploy target is fly.io" FactProject "run-0"
      *> newMemoryThreadStore
      >>= \threads ->
        newMemoryState >>= \state ->
          transformContext (memoryHooks invalidateWatcher threads facts Nothing state) (sampleInput []) [ChatUser "hi"]
            *> factList facts
            >>= \listed ->
              factSearch facts "deploy target" >>= \hits ->
                sequence_
                  [ fmap factVoid listed @?= [True],
                    hits @?= []
                  ]

legacyLine :: Assertion
legacyLine =
  either assertFailure verify $
    eitherDecode
      "{\"id\":\"fact-x\",\"content\":\"old line\",\"kind\":\"user\",\"source\":\"run\",\"created\":1,\"lastUsed\":2,\"useCount\":3}"
  where
    verify fact =
      sequence_
        [ factArchived fact @?= False,
          factVoid fact @?= False,
          factUseCount fact @?= 3
        ]

invalidateReplay :: Assertion
invalidateReplay =
  newMemoryFactStore >>= \facts ->
    factAdd facts "the deploy target is fly.io" FactProject "run-0"
      *> newMemoryThreadStore
      >>= \threads ->
        newMemoryJournal >>= \(journal, readEntries) ->
          newMemoryState >>= \state ->
            testRuntime mainModel [] Parallel >>= \base ->
              collectEvents base {runtimeHooks = hooks facts threads journal state, runtimeJournal = Just journal} (sampleInput [])
                >>= \events ->
                  readEntries >>= \recorded ->
                    replayWithStores threads facts Nothing recorded >>= \report ->
                      sequence_
                        [ fmap reportDivergence report @?= Right Nothing,
                          fmap reportEvents report @?= Right (length events)
                        ]
  where
    hooks facts threads journal state = memoryHooks invalidateWatcher threads facts (Just journal) state
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)

serverTests :: TestTree
serverTests =
  testGroup
    "HTTP server"
    [ testCase "serves AG-UI events as SSE" serverEvents,
      testCase "serves the thread brief, 404 when the thread is unknown" briefOverHttp,
      testCase "lists facts" factsOverHttp,
      testCase "lists artifacts and serves raw content" artifactsOverHttp,
      testCase "lists journal runs and filters entries by run" journalOverHttp,
      testCase "serves a run summary and 404s unknown runs" summaryOverHttp,
      testCase "serves an aggregated run trace" traceOverHttp,
      testCase "replays a journaled run over HTTP" replayOverHttp,
      testCase "degrades per capability" capabilityDegradation,
      testCase "inspection routes 404 without an Inspection" inspectionMissing
    ]

inspectionFixture :: IO (Application, Text, Int)
inspectionFixture =
  newMemoryThreadStore >>= \threads ->
    newMemoryFactStore >>= \facts ->
      newMemoryArtifactStore >>= \artifacts ->
        getTemporaryDirectory >>= \tmp ->
          newId >>= \identifier ->
            let dir = tmp ++ "/" ++ Text.unpack identifier
             in createDirectoryIfMissing True dir *> newMemoryJournal >>= seed threads facts artifacts dir
  where
    seed threads facts artifacts dir (journal, readEntries) =
      threadSaveEpisode threads "thread" (Episode "run-0" "earlier" 1700000000)
        *> factAdd facts "the deploy target is fly.io" FactProject "run-0"
        *> artifactSave artifacts "big" bigContent
        *> testRuntime echoModel [echoTool] Parallel
        >>= \base ->
          collectEvents base {runtimeJournal = Just journal} (journaledInput "run-1")
            >>= \events ->
              collectEvents base {runtimeJournal = Just journal} (journaledInput "run-2")
                *> (readEntries >>= LazyByteString.writeFile (journalFilePath dir) . renderJournal)
                *> pure
                  ( application Nothing (Just (inspection threads facts artifacts dir)) Nothing Nothing (const (pure base)),
                    artifactIdFor bigContent,
                    length events
                  )
    renderJournal = LazyByteString.concat . fmap ((<> "\n") . encode)
    inspection threads facts artifacts dir =
      newInspection (Just (threads, facts)) (Just artifacts) (Just (journalFilePath dir)) Nothing

journaledInput :: Text -> RunAgentInput
journaledInput run = (sampleInput [tool "echo"]) {runId = run}

httpGet :: [Text] -> Request
httpGet path = defaultRequest {requestMethod = methodGet, pathInfo = path}

replayRequest :: LazyByteString.ByteString -> SRequest
replayRequest body =
  SRequest
    { simpleRequest =
        defaultRequest
          { requestMethod = methodPost,
            pathInfo = ["replay"],
            requestHeaders = [(hContentType, "application/json")]
          },
      simpleRequestBody = body
    }

briefOverHttp :: Assertion
briefOverHttp =
  inspectionFixture >>= \(app, _, _) ->
    runSession (request (httpGet ["memory", "threads", "thread"])) app >>= \found ->
      runSession (request (httpGet ["memory", "threads", "unknown"])) app >>= \unknown ->
        sequence_
          [ simpleStatus found @?= status200,
            simpleStatus unknown @?= status404,
            either assertFailure ((@?= "earlier") . briefRollingSummary) (eitherDecode (simpleBody found))
          ]

factsOverHttp :: Assertion
factsOverHttp =
  inspectionFixture >>= \(app, _, _) ->
    runSession (request (httpGet ["memory", "facts"])) app >>= \response ->
      sequence_
        [ simpleStatus response @?= status200,
          either
            assertFailure
            ((@?= ["the deploy target is fly.io"]) . fmap factContent)
            (eitherDecode (simpleBody response))
        ]

artifactsOverHttp :: Assertion
artifactsOverHttp =
  inspectionFixture >>= \(app, identifier, _) ->
    runSession (request (httpGet ["artifacts"])) app >>= \listed ->
      runSession (request (httpGet ["artifacts", identifier])) app >>= \fetched ->
        runSession (request (httpGet ["artifacts", "art-missing"])) app >>= \missing ->
          sequence_
            [ simpleStatus listed @?= status200,
              either assertFailure (metasMatch identifier) (eitherDecode (simpleBody listed)),
              simpleStatus fetched @?= status200,
              lookup hContentType (simpleHeaders fetched) @?= Just "text/plain; charset=utf-8",
              simpleBody fetched @?= LazyByteString.fromStrict (TextEncoding.encodeUtf8 bigContent),
              simpleStatus missing @?= status404
            ]
  where
    metasMatch identifier metas =
      fmap (\meta -> (artifactMetaId meta, artifactMetaToolName meta, artifactMetaChars meta)) metas
        @?= [(identifier, "big", Text.length bigContent)]

journalOverHttp :: Assertion
journalOverHttp =
  inspectionFixture >>= \(app, _, _) ->
    runSession (request (httpGet ["journal", "runs"])) app >>= \runs ->
      runSession (request (httpGet ["journal"])) app >>= \everything ->
        runSession (request filtered) app >>= \matching ->
          sequence_
            [ simpleStatus runs @?= status200,
              either assertFailure (@?= ["run-1", "run-2"]) (eitherDecode (simpleBody runs) :: Either String [Text]),
              simpleStatus everything @?= status200,
              simpleStatus matching @?= status200,
              verify
                (eitherDecode (simpleBody everything) :: Either String [Entry])
                (eitherDecode (simpleBody matching) :: Either String [Entry])
            ]
  where
    filtered = (httpGet ["journal"]) {queryString = [("run", Just "run-1")]}
    verify allDecoded matchingDecoded = case (allDecoded, matchingDecoded) of
      (Right allEntries, Right matchingEntries) ->
        sequence_
          [ assertBool "filter is not empty" (not (null matchingEntries)),
            assertBool
              "filter keeps only the wanted run"
              (all ((== Just "run-1") . listToMaybe . entryScope) matchingEntries),
            assertBool "journal holds more than one run" (length allEntries > length matchingEntries)
          ]
      _ -> assertFailure "journal responses must decode"

summaryOverHttp :: Assertion
summaryOverHttp =
  inspectionFixture >>= \(app, _, _) ->
    runSession (request (httpGet ["journal", "runs", "run-1", "summary"])) app >>= \found ->
      runSession (request (httpGet ["journal", "runs", "missing", "summary"])) app >>= \unknown ->
        sequence_
          [ simpleStatus found @?= status200,
            simpleStatus unknown @?= status404,
            either assertFailure (@?= ("run-1", "finished", 2, 1)) (decodeSummary (simpleBody found))
          ]
  where
    decodeSummary :: LazyByteString.ByteString -> Either String (Text, Text, Int, Int)
    decodeSummary body =
      eitherDecode body
        >>= parseEither
          ( withObject "summary" $ \fields ->
              (,,,)
                <$> fields .: "runId"
                <*> fields .: "status"
                <*> fields .: "turns"
                <*> fields .: "toolCalls"
          )

traceOverHttp :: Assertion
traceOverHttp =
  inspectionFixture >>= \(app, _, _) ->
    runSession (request (httpGet ["journal", "runs", "run-1", "trace"])) app >>= \found ->
      runSession (request (httpGet ["journal", "runs", "missing", "trace"])) app >>= \unknown ->
        sequence_
          [ simpleStatus found @?= status200,
            simpleStatus unknown @?= status404,
            either assertFailure (assertBool "trace includes causal steps" . (> 2)) (decodeSteps (simpleBody found))
          ]
  where
    decodeSteps :: LazyByteString.ByteString -> Either String Int
    decodeSteps body =
      eitherDecode body
        >>= parseEither
          (withObject "trace" (\fields -> length <$> (fields .: "steps" :: Parser [Value])))

replayOverHttp :: Assertion
replayOverHttp =
  inspectionFixture >>= \(app, _, eventCount) ->
    runSession (srequest (replayRequest (encode (object ["runId" .= ("run-1" :: Text)])))) app >>= \explicit ->
      runSession (srequest (replayRequest "")) app >>= \latest ->
        sequence_
          [ simpleStatus explicit @?= status200,
            either assertFailure (verifyReport eventCount "run-1") (decodeReport (simpleBody explicit)),
            simpleStatus latest @?= status200,
            either assertFailure (verifyReport eventCount "run-2") (decodeReport (simpleBody latest))
          ]
  where
    verifyReport expected run (reportRun, events, divergence) =
      sequence_ [reportRun @?= run, events @?= expected, divergence @?= Nothing]

decodeReport :: LazyByteString.ByteString -> Either String (Text, Int, Maybe Value)
decodeReport body =
  eitherDecode body
    >>= parseEither (withObject "report" (\fields -> (,,) <$> fields .: "runId" <*> fields .: "events" <*> fields .:? "divergence"))

capabilityDegradation :: Assertion
capabilityDegradation =
  newMemoryArtifactStore >>= \artifacts ->
    let partial = newInspection Nothing (Just artifacts) Nothing Nothing
     in testRuntime echoModel [echoTool] Parallel >>= \base ->
          runSession (request (httpGet ["artifacts"])) (application Nothing (Just partial) Nothing Nothing (const (pure base))) >>= \listed ->
            runSession (request (httpGet ["memory", "facts"])) (application Nothing (Just partial) Nothing Nothing (const (pure base))) >>= \facts ->
              sequence_ [simpleStatus listed @?= status200, simpleStatus facts @?= status404]

inspectionMissing :: Assertion
inspectionMissing =
  testRuntime echoModel [echoTool] Parallel >>= \base ->
    runSession (request (httpGet ["memory", "facts"])) (application Nothing Nothing Nothing Nothing (const (pure base))) >>= \facts ->
      runSession (srequest (replayRequest "")) (application Nothing Nothing Nothing Nothing (const (pure base))) >>= \replay ->
        sequence_ [simpleStatus facts @?= status404, simpleStatus replay @?= status404]

serverEvents :: Assertion
serverEvents =
  testRuntime
    (fakeModel (\_ emit -> emit (ModelTextDelta "hello") $> Stop))
    []
    Parallel
    >>= run
  where
    run runtime = runSession agentRequest (application Nothing Nothing Nothing Nothing (const (pure runtime))) >>= verify
    agentRequest =
      srequest
        SRequest
          { simpleRequest =
              defaultRequest
                { requestMethod = methodPost,
                  pathInfo = ["agent"],
                  requestHeaders = [(hContentType, "application/json")]
                },
            simpleRequestBody = encode (sampleInput [])
          }
    verify response =
      let (decoder, payloads) = feedSse emptySseDecoder . LazyByteString.toStrict $ simpleBody response
          (_, trailing) = finishSse decoder
       in sequence_
            [ simpleStatus response @?= status200,
              lookup hContentType (simpleHeaders response) @?= Just "text/event-stream; charset=utf-8"
            ]
            *> (traverse decodeEventType (payloads <> trailing) >>= (@?= expected))
    expected =
      [ "RUN_STARTED",
        "STEP_STARTED",
        "TEXT_MESSAGE_START",
        "TEXT_MESSAGE_CONTENT",
        "TEXT_MESSAGE_END",
        "STEP_FINISHED",
        "RUN_FINISHED"
      ]

configTests :: TestTree
configTests =
  testGroup
    "configuration"
    [ testCase "defaults to a proxy-safe local port and DeepSeek V4 Flash" deepSeekDefaults,
      testCase "requires model and URL for unknown providers" customRequiresConfiguration,
      testCase "sub-agent depth defaults to one, accepts zero, rejects bad values" subAgentDepthConfig,
      testCase "provider retries default to three, accept zero, reject bad values" providerRetriesConfig,
      testCase "context summary config enforces the real algorithmic floor" contextSummaryConfig
    ]

deepSeekDefaults :: Assertion
deepSeekDefaults =
  either
    (assertFailure . Text.unpack)
    verify
    (resolveSettings (Map.singleton "DEEPSEEK_API_KEY" "secret"))
  where
    verify settings =
      let provider = settingsProvider settings
       in sequence_
            [ openAIProvider provider @?= "deepseek",
              settingsPort settings @?= 18080,
              openAIModelName provider @?= "deepseek-v4-flash",
              openAIBaseUrl provider @?= "https://api.deepseek.com",
              openAIDialect provider @?= DeepSeek,
              openAIThinking provider @?= ThinkingEnabled High,
              openAIContextTokens provider @?= Just 1000000,
              settingsContextReserveTokens settings @?= 16384
            ]

customRequiresConfiguration :: Assertion
customRequiresConfiguration =
  either
    (const (pure ()))
    (const (assertFailure "custom provider should need explicit configuration"))
    (resolveSettings (Map.fromList [("YUKI_PROVIDER", "custom"), ("YUKI_API_KEY", "secret")]))

subAgentDepthConfig :: Assertion
subAgentDepthConfig =
  sequence_
    [ depthOf [] >>= (@?= 1),
      depthOf [("YUKI_SUBAGENT_DEPTH", "0")] >>= (@?= 0),
      depthOf [("YUKI_SUBAGENT_DEPTH", "3")] >>= (@?= 3),
      rejected "-1",
      rejected "two"
    ]
  where
    depthOf extra =
      either (assertFailure . Text.unpack) (pure . settingsSubAgentDepth) (resolveSettings (env extra))
    env extra = Map.fromList (("DEEPSEEK_API_KEY", "secret") : extra)
    rejected value =
      either
        (const (pure ()))
        (const (assertFailure ("YUKI_SUBAGENT_DEPTH=" <> value <> " should be rejected")))
        (resolveSettings (env [("YUKI_SUBAGENT_DEPTH", value)]))

providerRetriesConfig :: Assertion
providerRetriesConfig =
  sequence_
    [ retriesOf [] >>= (@?= 3),
      retriesOf [("YUKI_PROVIDER_RETRIES", "0")] >>= (@?= 0),
      retriesOf [("YUKI_PROVIDER_RETRIES", "7")] >>= (@?= 7),
      rejected "-1",
      rejected "two"
    ]
  where
    retriesOf extra =
      either (assertFailure . Text.unpack) (pure . settingsProviderRetries) (resolveSettings (env extra))
    env extra = Map.fromList (("DEEPSEEK_API_KEY", "secret") : extra)
    rejected value =
      either
        (const (pure ()))
        (const (assertFailure ("YUKI_PROVIDER_RETRIES=" <> value <> " should be rejected")))
        (resolveSettings (env [("YUKI_PROVIDER_RETRIES", value)]))

contextSummaryConfig :: Assertion
contextSummaryConfig =
  sequence_
    [ summaryOf "96" >>= (@?= 96),
      summaryOf "2048" >>= (@?= 2048),
      rejected "95",
      rejected "0"
    ]
  where
    env value = Map.fromList [("DEEPSEEK_API_KEY", "secret"), ("YUKI_CONTEXT_SUMMARY_TOKENS", value)]
    summaryOf value =
      either (assertFailure . Text.unpack) (pure . settingsContextSummaryTokens) (resolveSettings (env value))
    rejected value =
      either
        (const (pure ()))
        (const (assertFailure ("YUKI_CONTEXT_SUMMARY_TOKENS=" <> value <> " should be rejected")))
        (resolveSettings (env value))

workToolTests :: TestTree
workToolTests =
  testGroup
    "work tools"
    [ testCase "diff rewrites the middle with three lines of context" diffMiddle,
      testCase "diff splits far-apart changes into two hunks" diffEnds,
      testCase "diff replaces everything" diffAll,
      testCase "diff of identical files is empty" diffSame,
      testCase "sandbox rejects dotdot and absolute escapes" sandboxEscape,
      testCase "write then edit then read with diff outcomes" writeEditRead,
      testCase "fs_read pages a window, clamps and rejects out-of-bounds offsets" paginatedRead,
      testCase "fs_edit fails on missing and ambiguous old text" editFailures,
      testCase "fs_edit demands a fresh read and fs_write records the stamp" staleEdit,
      testCase "fs_list sorts, marks directories and caps depth at two" listEntries,
      testCase "fs_list and config tree render symlinks without following them" listSymlinks,
      testCase "local path completion stays inside cwd and omits symlinks" pathCompletion,
      testCase "fs_glob matches **, ?, caps at 200 and skips noise directories" globSearch,
      testCase "fs_grep hits literal text with line numbers and include filter" grepSearch,
      testCase "fs_grep treats regex metacharacters literally" grepLiteral,
      testCase "fs_glob and fs_grep reject sandbox escapes" searchSandbox,
      testCase "shell captures exit code and merged output" shellCaptures,
      testCase "shell stops at the timeout" shellStops,
      testCase "shell timeout hints at shell_bg" shellTimeoutHint,
      testCase "large shell output lands in an artifact with guidance" shellArtifact,
      testCase "shell streams stdout and stderr chunks while running" shellStreams,
      testCase "background task starts, runs, and is polled to completion" backgroundLifecycle,
      testCase "background stdin feeds cat and closes on eof" backgroundStdinFeed,
      testCase "shell_kill terminates the process group and reaps the task" backgroundKill,
      testCase "concurrent background spawns all register and reap" backgroundSpawnRace,
      testCase "background tasks are visible only to their owning thread" backgroundThreadIsolation,
      testCase "completed retention is bounded without evicting running tasks" backgroundRetention,
      testCase "thread archive and service shutdown reap their owned processes" backgroundShutdown,
      testCase "fresh runtimes manage one task across three later user turns" backgroundAcrossRuntimeFor
    ]

diffMiddle :: Assertion
diffMiddle =
  unified "f.txt" (numbered "l5") (numbered "X") @?= Text.unlines expected
  where
    numbered replacement = Text.unlines (["l1", "l2", "l3", "l4", replacement, "l6", "l7", "l8", "l9", "l10"] :: [Text])
    expected =
      [ "--- a/f.txt",
        "+++ b/f.txt",
        "@@ -2,7 +2,7 @@",
        " l2",
        " l3",
        " l4",
        "-l5",
        "+X",
        " l6",
        " l7",
        " l8"
      ]

diffEnds :: Assertion
diffEnds =
  unified "f.txt" (numbered "l1" "l10") (numbered "X" "Y") @?= Text.unlines expected
  where
    numbered head' last' = Text.unlines ([head', "l2", "l3", "l4", "l5", "l6", "l7", "l8", "l9", last'] :: [Text])
    expected =
      [ "--- a/f.txt",
        "+++ b/f.txt",
        "@@ -1,4 +1,4 @@",
        "-l1",
        "+X",
        " l2",
        " l3",
        " l4",
        "@@ -7,4 +7,4 @@",
        " l7",
        " l8",
        " l9",
        "-l10",
        "+Y"
      ]

diffAll :: Assertion
diffAll =
  unified "f.txt" "a\nb\n" "x\ny\nz\n"
    @?= Text.unlines ["--- a/f.txt", "+++ b/f.txt", "@@ -1,2 +1,3 @@", "-a", "-b", "+x", "+y", "+z"]

diffSame :: Assertion
diffSame = unified "f.txt" "same\nfile\n" "same\nfile\n" @?= ""

withWorkDir :: (FilePath -> Assertion) -> Assertion
withWorkDir action =
  getTemporaryDirectory >>= \tmp ->
    newId >>= \identifier ->
      let dir = tmp ++ "/" ++ Text.unpack identifier
       in createDirectoryIfMissing True dir *> action dir

callTool :: [BackendTool] -> Text -> Value -> IO ToolOutcome
callTool = callToolContext (ToolContext "run" "thread" "call" (const (pure ())) Nothing)

callToolContext :: ToolContext -> [BackendTool] -> Text -> Value -> IO ToolOutcome
callToolContext context tools name arguments =
  maybe (assertFailure ("missing tool: " <> Text.unpack name)) pure (find (named . backendToolSpec) tools)
    >>= \backend -> runBackendTool backend context arguments
  where
    named = (== name) . toolName

sandboxEscape :: Assertion
sandboxEscape = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        callTool tools "fs_read" (object ["path" .= ("../../../../etc/passwd" :: Text)]) >>= \relative ->
          callTool tools "fs_read" (object ["path" .= ("/etc/passwd" :: Text)]) >>= \absolute ->
            callTool tools "fs_write" (object ["path" .= ("../escape.txt" :: Text), "content" .= ("x" :: Text)]) >>= \written ->
              sequence_
                [ toolOutcomeError relative @?= True,
                  toolOutcomeError absolute @?= True,
                  toolOutcomeError written @?= True,
                  toolOutcomeContent relative @?= "path escapes the work directory",
                  toolOutcomeContent absolute @?= "path escapes the work directory",
                  toolOutcomeContent written @?= "path escapes the work directory"
                ]

writeEditRead :: Assertion
writeEditRead = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        callTool tools "fs_write" (object ["path" .= ("sub/notes.txt" :: Text), "content" .= ("alpha\nbeta\n" :: Text)]) >>= \written ->
          callTool tools "fs_edit" (object ["path" .= ("sub/notes.txt" :: Text), "old" .= ("beta" :: Text), "new" .= ("gamma" :: Text)]) >>= \edited ->
            callTool tools "fs_read" (object ["path" .= ("sub/notes.txt" :: Text)]) >>= \readBack ->
              sequence_
                [ toolOutcomeError written @?= False,
                  toolOutcomeContent written
                    @?= Text.unlines ["--- a/sub/notes.txt", "+++ b/sub/notes.txt", "@@ -1,0 +1,2 @@", "+alpha", "+beta"],
                  toolOutcomeContent edited
                    @?= Text.unlines ["--- a/sub/notes.txt", "+++ b/sub/notes.txt", "@@ -1,2 +1,2 @@", " alpha", "-beta", "+gamma"],
                  toolOutcomeError readBack @?= False,
                  toolOutcomeContent readBack @?= "alpha\ngamma\n"
                ]

paginatedRead :: Assertion
paginatedRead = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        TextIO.writeFile (dir ++ "/f.txt") "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"
          *> callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "offset" .= (3 :: Int), "limit" .= (4 :: Int)]) >>= \window ->
            callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "limit" .= (2 :: Int)]) >>= \headOnly ->
              callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "offset" .= (8 :: Int)]) >>= \tailOnly ->
                callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "offset" .= (0 :: Int), "limit" .= (2 :: Int)]) >>= \clamped ->
                  callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "offset" .= (11 :: Int)]) >>= \outOfBounds ->
                    sequence_
                      [ toolOutcomeError window @?= False,
                        toolOutcomeContent window @?= "l3\nl4\nl5\nl6\n(lines 3-6 of 10)",
                        toolOutcomeContent headOnly @?= "l1\nl2\n(lines 1-2 of 10)",
                        toolOutcomeContent tailOnly @?= "l8\nl9\nl10\n(lines 8-10 of 10)",
                        toolOutcomeContent clamped @?= "l1\nl2\n(lines 1-2 of 10)",
                        toolOutcomeError outOfBounds @?= True,
                        toolOutcomeContent outOfBounds @?= "offset 11 exceeds f.txt line count 10"
                      ]

editFailures :: Assertion
editFailures = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        TextIO.writeFile (dir ++ "/dup.txt") "dup dup here"
          *> callTool tools "fs_read" (object ["path" .= ("dup.txt" :: Text)])
          *> callTool tools "fs_edit" (object ["path" .= ("dup.txt" :: Text), "old" .= ("absent" :: Text), "new" .= ("x" :: Text)]) >>= \missing ->
            callTool tools "fs_edit" (object ["path" .= ("dup.txt" :: Text), "old" .= ("dup" :: Text), "new" .= ("x" :: Text)]) >>= \ambiguous ->
              sequence_
                [ toolOutcomeError missing @?= True,
                  assertBool "missing explains" (Text.isInfixOf "old text not found in dup.txt" (toolOutcomeContent missing)),
                  toolOutcomeError ambiguous @?= True,
                  assertBool "ambiguous explains" (Text.isInfixOf "old text occurs 2 times in dup.txt" (toolOutcomeContent ambiguous))
                ]

staleEdit :: Assertion
staleEdit = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        TextIO.writeFile (dir ++ "/s.txt") "aaa\n"
          *> editAt tools "s.txt" "aaa" "bbb" >>= \unread ->
            readAt tools "s.txt"
              *> editAt tools "s.txt" "aaa" "bbb" >>= \fresh ->
                TextIO.writeFile (dir ++ "/s.txt") "cccc\n"
                  *> editAt tools "s.txt" "bbb" "x" >>= \stale ->
                    readAt tools "s.txt"
                      *> editAt tools "s.txt" "cccc" "dddd" >>= \reread ->
                        writeAt tools "w.txt" "fresh\n"
                          *> editAt tools "w.txt" "fresh" "done" >>= \afterWrite ->
                            TextIO.readFile (dir ++ "/s.txt") >>= \finalContent ->
                              sequence_
                                [ toolOutcomeError unread @?= True,
                                  toolOutcomeContent unread @?= "read the file before editing",
                                  toolOutcomeError fresh @?= False,
                                  toolOutcomeError stale @?= True,
                                  toolOutcomeContent stale @?= "file changed since last read; re-read it",
                                  toolOutcomeError reread @?= False,
                                  toolOutcomeError afterWrite @?= False,
                                  finalContent @?= "dddd\n"
                                ]
    readAt tools path = callTool tools "fs_read" (object ["path" .= (path :: Text)])
    writeAt tools path content = callTool tools "fs_write" (object ["path" .= (path :: Text), "content" .= (content :: Text)])
    editAt tools path old new = callTool tools "fs_edit" (object ["path" .= (path :: Text), "old" .= (old :: Text), "new" .= (new :: Text)])

listEntries :: Assertion
listEntries = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        createDirectoryIfMissing True (dir ++ "/src/deep")
          *> TextIO.writeFile (dir ++ "/b.txt") "b"
          *> TextIO.writeFile (dir ++ "/src/a.txt") "a"
          *> TextIO.writeFile (dir ++ "/src/deep/x.txt") "x"
          *> callTool tools "fs_list" (object []) >>= \outcome ->
            sequence_
              [ toolOutcomeError outcome @?= False,
                toolOutcomeContent outcome @?= Text.intercalate "\n" ["b.txt", "src/", "  a.txt", "  deep/"]
              ]

listSymlinks :: Assertion
listSymlinks =
  withSandbox $ \root ->
    workTools Nothing root >>= \tools ->
      callTool tools "fs_list" (object []) >>= \listed ->
        callTool tools "fs_list" (object ["path" .= ("inner" :: Text)]) >>= \explicit ->
          listTree root 8 >>= \tree ->
            let renderedTree = Text.intercalate "\n" tree
             in sequence_
                  [ toolOutcomeError listed @?= False,
                    assertBool "external directory symlink is a leaf" ("linkdir@" `Text.isInfixOf` toolOutcomeContent listed),
                    assertBool "internal directory symlink is a leaf" ("inner@" `Text.isInfixOf` toolOutcomeContent listed),
                    assertBool "cycle symlink is a leaf" ("up@" `Text.isInfixOf` toolOutcomeContent listed),
                    assertBool "external content never appears" (not ("TOP-SECRET" `Text.isInfixOf` toolOutcomeContent listed)),
                    toolOutcomeError explicit @?= True,
                    toolOutcomeContent explicit @?= "refusing to list through a symbolic link",
                    assertBool "config tree marks external symlink" ("linkdir@" `Text.isInfixOf` renderedTree),
                    assertBool "config tree marks internal symlink" ("inner@" `Text.isInfixOf` renderedTree),
                    assertBool "config tree does not expand the cycle" (length (filter (Text.isInfixOf "up@") tree) == 1)
                  ]

pathCompletion :: Assertion
pathCompletion =
  withSandbox $ \root ->
    completePaths root "" >>= \top ->
      completePaths root "sub/" >>= \nested ->
        completePaths root "../" >>= \escaped ->
          sequence_
            [ assertBool "offers real directories" ("sub/" `elem` top),
              assertBool "omits external symlinks" (not ("linkdir/" `elem` top)),
              assertBool "omits file symlinks" (not ("linkfile.txt" `elem` top)),
              nested @?= ["sub/ok.txt"],
              escaped @?= []
            ]

globSearch :: Assertion
globSearch = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        createDirectoryIfMissing True (dir ++ "/src/N")
          *> createDirectoryIfMissing True (dir ++ "/node_modules/pkg")
          *> createDirectoryIfMissing True (dir ++ "/.hidden")
          *> createDirectoryIfMissing True (dir ++ "/caps")
          *> TextIO.writeFile (dir ++ "/x.hs") "top"
          *> TextIO.writeFile (dir ++ "/src/N/x.hs") "nested"
          *> TextIO.writeFile (dir ++ "/node_modules/pkg/x.hs") "dep"
          *> TextIO.writeFile (dir ++ "/.hidden/x.hs") "hidden"
          *> traverse_ (\name -> TextIO.writeFile (dir ++ "/caps/" ++ name) "cap") capNames
          *> callTool tools "fs_glob" (object ["pattern" .= ("**/x.hs" :: Text)]) >>= \nested ->
            callTool tools "fs_glob" (object ["pattern" .= ("src/?/x.hs" :: Text)]) >>= \single ->
              callTool tools "fs_glob" (object ["pattern" .= ("caps/*.txt" :: Text)]) >>= \capped ->
                sequence_
                  [ toolOutcomeError nested @?= False,
                    toolOutcomeContent nested @?= "src/N/x.hs\nx.hs",
                    toolOutcomeContent single @?= "src/N/x.hs",
                    toolOutcomeContent capped @?= expectedCaps
                  ]
    capNames = ["cap-" <> replicate (3 - length s) '0' <> s <> ".txt" | i <- [0 .. 204 :: Int], let s = show i]
    expectedCaps = Text.intercalate "\n" (fmap (Text.pack . ("caps/" ++)) (take 200 capNames)) <> "\n... 5 more"

grepSearch :: Assertion
grepSearch = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        TextIO.writeFile (dir ++ "/a.txt") "one\ntwo needle\nthree needle\n"
          *> TextIO.writeFile (dir ++ "/b.hs") "needle in hs\n"
          *> TextIO.writeFile (dir ++ "/b.txt") "needle in txt\n"
          *> callTool tools "fs_grep" (object ["pattern" .= ("needle" :: Text)]) >>= \plain ->
            callTool tools "fs_grep" (object ["pattern" .= ("needle" :: Text), "include" .= ("*.hs" :: Text)]) >>= \hsOnly ->
              sequence_
                [ toolOutcomeError plain @?= False,
                  toolOutcomeContent plain
                    @?= Text.intercalate "\n" ["a.txt:2:two needle", "a.txt:3:three needle", "b.hs:1:needle in hs", "b.txt:1:needle in txt"],
                  toolOutcomeContent hsOnly @?= "b.hs:1:needle in hs"
                ]

grepLiteral :: Assertion
grepLiteral = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        TextIO.writeFile (dir ++ "/c.txt") "axb\nliteral .* here\n"
          *> callTool tools "fs_grep" (object ["pattern" .= (".*" :: Text)]) >>= \outcome ->
            sequence_
              [ toolOutcomeError outcome @?= False,
                toolOutcomeContent outcome @?= "c.txt:2:literal .* here"
              ]

searchSandbox :: Assertion
searchSandbox = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        callTool tools "fs_glob" (object ["pattern" .= ("*" :: Text), "path" .= ("../" :: Text)]) >>= \globbed ->
          callTool tools "fs_grep" (object ["pattern" .= ("x" :: Text), "path" .= ("../" :: Text)]) >>= \grepped ->
            sequence_
              [ toolOutcomeError globbed @?= True,
                toolOutcomeError grepped @?= True,
                toolOutcomeContent globbed @?= "path escapes the work directory",
                toolOutcomeContent grepped @?= "path escapes the work directory"
              ]

shellCaptures :: Assertion
shellCaptures = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        callTool tools "shell" (object ["command" .= ("echo out; echo err >&2; exit 3" :: Text)]) >>= \outcome ->
          sequence_
            [ toolOutcomeError outcome @?= False,
              toolOutcomeContent outcome @?= "exit 3\nout\nerr\n"
            ]

shellStops :: Assertion
shellStops = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        callTool tools "shell" (object ["command" .= ("echo before; sleep 30; echo after" :: Text), "timeoutSeconds" .= (1 :: Int)]) >>= \outcome ->
          sequence_
            [ assertBool "timeout reported" ("exit timeout" `Text.isPrefixOf` toolOutcomeContent outcome),
              assertBool "partial output kept" (Text.isInfixOf "before" (toolOutcomeContent outcome)),
              assertBool "killed before completion" (not (Text.isInfixOf "after" (toolOutcomeContent outcome)))
            ]

shellTimeoutHint :: Assertion
shellTimeoutHint = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        callTool tools "shell" (object ["command" .= ("printf before; sleep 30" :: Text), "timeoutSeconds" .= (1 :: Int)]) >>= \outcome ->
          toolOutcomeContent outcome
            @?= "exit timeout\nbefore\nhint: use shell_bg for long-running tasks, then shell_output to poll\n"

shellArtifact :: Assertion
shellArtifact = withWorkDir exercise
  where
    exercise dir =
      newMemoryArtifactStore >>= \store ->
        workTools (Just store) dir >>= \tools ->
          callTool tools "shell" (object ["command" .= bigCommand]) >>= \outcome ->
            artifactList store >>= \metas ->
              sequence_
                [ toolOutcomeError outcome @?= False,
                  assertBool "head kept" ("exit 0\nline-0" `Text.isPrefixOf` toolOutcomeContent outcome),
                  assertBool "tail kept" (Text.isInfixOf "line-39" (toolOutcomeContent outcome)),
                  assertBool "guidance names the artifact" (Text.isInfixOf "[artifact art-" (toolOutcomeContent outcome)),
                  assertBool "guidance points at artifact_read" (Text.isInfixOf "artifact_read" (toolOutcomeContent outcome)),
                  fmap artifactMetaToolName metas @?= ["shell"]
                ]
    bigCommand =
      "i=0; while [ $i -lt 40 ]; do echo line-$i-xxxxxxxxxxxx; i=$((i+1)); done" :: Text

shellStreams :: Assertion
shellStreams = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        newIORef [] >>= \events ->
          callToolContext (streaming events) tools "shell" (object ["command" .= ("echo one; sleep 0.5; echo two; sleep 0.5; echo err >&2" :: Text)]) >>= \outcome ->
            reverse <$> readIORef events >>= \emitted ->
              let chunks = mapMaybe (parseMaybe parseChunk) [value | Custom "shell.output" value <- emitted]
                  stdout = Text.concat [delta | ("call-1", "stdout", delta) <- chunks]
                  stderr = Text.concat [delta | ("call-1", "stderr", delta) <- chunks]
               in sequence_
                    [ assertBool "streams at least two chunks" (length chunks >= 2),
                      stdout @?= "one\ntwo\n",
                      stderr @?= "err\n",
                      toolOutcomeContent outcome @?= "exit 0\none\ntwo\nerr\n"
                    ]
      where
        streaming events = ToolContext "run" "thread" "call-1" (\event -> modifyIORef' events (event :)) Nothing
    parseChunk :: Value -> Parser (Text, Text, Text)
    parseChunk =
      withObject "shell.output" $ \fields ->
        (,,) <$> fields .: "callId" <*> fields .: "stream" <*> fields .: "delta"

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

backgroundLifecycle :: Assertion
backgroundLifecycle = withWorkDir exercise
  where
    exercise dir =
      newBackgroundRegistry >>= \registry ->
        let tools = backgroundTools registry dir
         in callTool tools "shell_bg" (object ["command" .= ("sleep 1; echo done" :: Text)]) >>= \started ->
              taskIdOf started >>= \taskId ->
                callTool tools "shell_output" (object ["taskId" .= taskId]) >>= \early ->
                  callTool tools "shell_output" (object ["taskId" .= taskId, "waitSeconds" .= (5 :: Int)]) >>= \late ->
                    pollOf early >>= \(earlyRunning, _, _, _) ->
                      pollOf late >>= \(running, exitCode, output, truncated) ->
                        sequence_
                          [ toolOutcomeError started @?= False,
                            earlyRunning @?= True,
                            running @?= False,
                            exitCode @?= Just 0,
                            assertBool "buffered output kept" ("done" `Text.isInfixOf` output),
                            truncated @?= False
                          ]

backgroundStdinFeed :: Assertion
backgroundStdinFeed = withWorkDir exercise
  where
    exercise dir =
      newBackgroundRegistry >>= \registry ->
        let tools = backgroundTools registry dir
         in callTool tools "shell_bg" (object ["command" .= ("cat" :: Text)]) >>= \started ->
              taskIdOf started >>= \taskId ->
                callTool tools "shell_stdin" (object ["taskId" .= taskId, "text" .= ("hello\n" :: Text)]) >>= \fed ->
                  callTool tools "shell_stdin" (object ["taskId" .= taskId, "text" .= ("" :: Text), "eof" .= True]) >>= \closed ->
                    callTool tools "shell_stdin" (object ["taskId" .= taskId, "text" .= ("late\n" :: Text)]) >>= \late ->
                      callTool tools "shell_output" (object ["taskId" .= taskId, "waitSeconds" .= (5 :: Int)]) >>= \polled ->
                        pollOf polled >>= \(running, exitCode, output, _) ->
                          sequence_
                            [ toolOutcomeError fed @?= False,
                              toolOutcomeError closed @?= False,
                              toolOutcomeError late @?= True,
                              running @?= False,
                              exitCode @?= Just 0,
                              output @?= "hello\n"
                            ]

backgroundKill :: Assertion
backgroundKill = withWorkDir exercise
  where
    exercise dir =
      newBackgroundRegistry >>= \registry ->
        let tools = backgroundTools registry dir
         in callTool tools "shell_bg" (object ["command" .= ("sleep 30" :: Text)]) >>= \started ->
              taskIdOf started >>= \taskId ->
                callTool tools "shell_output" (object ["taskId" .= taskId]) >>= \early ->
                  callTool tools "shell_kill" (object ["taskId" .= taskId]) >>= \killed ->
                    callTool tools "shell_output" (object ["taskId" .= taskId]) >>= \late ->
                      pollOf early >>= \(running, _, _, _) ->
                        outcomeValue killed >>= \result ->
                          sequence_
                            [ running @?= True,
                              parseMaybe (withObject "kill" (.: "killed")) result @?= Just True,
                              toolOutcomeError late @?= True,
                              assertBool "reaped task is unknown" ("unknown background task" `Text.isInfixOf` toolOutcomeContent late)
                            ]

backgroundSpawnRace :: Assertion
backgroundSpawnRace = withWorkDir exercise
  where
    exercise dir =
      newBackgroundRegistry >>= \registry ->
        sequence (replicate 8 newEmptyMVar) >>= \slots ->
          let tools = backgroundTools registry dir
           in traverse_ (forkIO . spawn tools) slots
                *> (timeout 10000000 (traverse takeMVar slots) >>= maybe (assertFailure "concurrent spawns did not finish") pure)
                >>= traverse (kill tools)
                >>= \killed ->
                  ((== 0) <$> backgroundTaskCount registry) >>= \empty ->
                    sequence_
                      [ killed @?= replicate 8 True,
                        assertBool "every spawned task is reaped, none leaks" empty
                      ]
    spawn tools slot =
      callTool tools "shell_bg" (object ["command" .= ("cat" :: Text)]) >>= taskIdOf >>= putMVar slot
    kill tools taskId =
      callTool tools "shell_kill" (object ["taskId" .= taskId])
        >>= fmap ((Just True ==) . parseMaybe (withObject "kill" (.: "killed"))) . outcomeValue

backgroundThreadIsolation :: Assertion
backgroundThreadIsolation = withWorkDir exercise
  where
    exercise dir =
      newBackgroundRegistry >>= \registry ->
        let tools = backgroundTools registry dir
         in callAs "thread-a" tools "shell_bg" (object ["command" .= ("cat" :: Text)]) >>= \started ->
              taskIdOf started >>= \taskId ->
                callAs "thread-b" tools "shell_output" (object ["taskId" .= taskId]) >>= \alien ->
                  callAs "thread-a" tools "shell_output" (object ["taskId" .= taskId]) >>= \owned ->
                    callAs "thread-a" tools "shell_kill" (object ["taskId" .= taskId]) >>= \killed ->
                      sequence_
                        [ toolOutcomeError alien @?= True,
                          assertBool "foreign thread learns no task details" ("unknown background task" `Text.isInfixOf` toolOutcomeContent alien),
                          toolOutcomeError owned @?= False,
                          toolOutcomeError killed @?= False
                        ]

backgroundRetention :: Assertion
backgroundRetention = withWorkDir exercise
  where
    exercise dir =
      newBackgroundRegistryWithLimit 2 >>= \registry ->
        let tools = backgroundTools registry dir
         in callTool tools "shell_bg" (object ["command" .= ("cat" :: Text)]) >>= \running ->
              taskIdOf running >>= \runningId ->
                traverse (complete tools) [1 .. 4 :: Int] >>= \completed ->
                  waitUntil ((<= 3) <$> backgroundTaskCount registry) >>= \bounded ->
                    lookupBackground registry runningId >>= \live ->
                      lookupBackground registry (head completed) >>= \oldest ->
                        lookupBackground registry (last completed) >>= \newest ->
                          callTool tools "shell_kill" (object ["taskId" .= runningId]) >>= \killed ->
                            sequence_
                              [ assertBool "registry converges to running plus retention limit" bounded,
                                assertBool "running task is never pruned" (isJust live),
                                assertBool "oldest completed task is pruned" (isNothing oldest),
                                assertBool "newest completed task remains inspectable" (isJust newest),
                                toolOutcomeError killed @?= False
                              ]
    complete tools index =
      callTool tools "shell_bg" (object ["command" .= ("printf done-" <> Text.pack (show index) :: Text)]) >>= \started ->
        taskIdOf started >>= \taskId ->
          callTool tools "shell_output" (object ["taskId" .= taskId, "waitSeconds" .= (5 :: Int)]) $> taskId

backgroundShutdown :: Assertion
backgroundShutdown = withWorkDir exercise
  where
    exercise dir =
      newBackgroundRegistry >>= \registry ->
        let tools = backgroundTools registry dir
         in callAs "thread-a" tools "shell_bg" (object ["command" .= ("cat" :: Text)]) >>= \first ->
              callAs "thread-b" tools "shell_bg" (object ["command" .= ("cat" :: Text)]) >>= \second ->
                (,) <$> taskIdOf first <*> taskIdOf second >>= \(firstId, secondId) ->
                  (,) <$> lookupBackground registry firstId <*> lookupBackground registry secondId >>= \case
                    (Just firstProc, Just secondProc) ->
                      shutdownBackgroundThread registry "thread-a"
                        *> callAs "thread-a" tools "shell_output" (object ["taskId" .= firstId]) >>= \archived ->
                          callAs "thread-b" tools "shell_output" (object ["taskId" .= secondId]) >>= \surviving ->
                            shutdownBackground registry
                              *> waitUntil (bothReaped firstProc secondProc) >>= \reaped ->
                                backgroundTaskCount registry >>= \remaining ->
                                  sequence_
                                    [ toolOutcomeError archived @?= True,
                                      toolOutcomeError surviving @?= False,
                                      assertBool "both process handles are reaped" reaped,
                                      remaining @?= 0
                                    ]
                    _ -> assertFailure "spawned tasks missing from registry"
    bothReaped first second =
      (&&)
        <$> (isJust <$> getProcessExitCode (backgroundProcess first))
        <*> (isJust <$> getProcessExitCode (backgroundProcess second))

backgroundAcrossRuntimeFor :: Assertion
backgroundAcrossRuntimeFor = withWorkDir exercise
  where
    exercise dir =
      newTlsManager >>= \manager ->
        newBackgroundRegistry >>= \registry ->
          newIORef Nothing >>= \task ->
            newIORef Map.empty >>= \observed ->
              newIORef (0 :: Int) >>= \resolved ->
                testRuntime (backgroundRoundModel task observed) [] Sequential >>= \base ->
                  let runtimeFor _ =
                        modifyIORef' resolved (+ 1)
                          *> resolveRuntime
                            manager
                            testProvider
                            Nothing
                            base {runtimeBackground = registry}
                            (emptyThreadConfig {configCwd = CwdPath dir})
                            Map.empty
                            Map.empty
                      app = application Nothing Nothing Nothing Nothing runtimeFor
                   in traverse (runBackgroundRound app) (zip [1 ..] ["start", "output", "stdin", "kill"])
                        >>= \responses ->
                          readIORef observed >>= \results ->
                            readIORef resolved >>= \resolutions ->
                              backgroundTaskCount registry >>= \remaining ->
                                sequence_
                                  [ assertBool "each run returns an SSE success" (all ((== status200) . simpleStatus) responses),
                                    resolutions @?= 4,
                                    assertBool "a later run can poll" (resultField "output" "running" results == Just True),
                                    assertBool "a third run can write stdin" (resultField "stdin" "stdinOpen" results == Just True),
                                    assertBool "a fourth run terminates" (resultField "kill" "killed" results == Just True),
                                    remaining @?= 0
                                  ]

backgroundRoundModel :: IORef (Maybe Text) -> IORef (Map.Map Text Value) -> Model
backgroundRoundModel task observed =
  fakeModel $ \request emit ->
    case lastMessage request of
      Just (ChatToolResult _ content) ->
        remember (roundName request) content
          *> emit (ModelTextDelta "done")
          $> Stop
      _ -> dispatch (roundName request) emit
  where
    dispatch "start" emit =
      emit (ModelToolCallDelta 0 (Just "call-start") (Just "shell_bg") "{\"command\":\"cat\"}") $> ToolUse
    dispatch name emit =
      readIORef task >>= maybe (throwIO (ProviderFailure "task id not captured")) (call name emit)
    call :: Text -> (ModelEvent -> IO ()) -> Text -> IO FinishReason
    call "output" emit taskId =
      emit (ModelToolCallDelta 0 (Just "call-output") (Just "shell_output") (jsonArgs taskId [])) $> ToolUse
    call "stdin" emit taskId =
      emit (ModelToolCallDelta 0 (Just "call-stdin") (Just "shell_stdin") (jsonArgs taskId [("text", "hello\n")])) $> ToolUse
    call "kill" emit taskId =
      emit (ModelToolCallDelta 0 (Just "call-kill") (Just "shell_kill") (jsonArgs taskId [])) $> ToolUse
    call name _ _ = throwIO (ProviderFailure ("unknown background round: " <> name))
    remember name content =
      either (throwIO . ProviderFailure . Text.pack) pure (eitherDecodeStrict' (TextEncoding.encodeUtf8 content)) >>= \value ->
        modifyIORef' observed (Map.insert name value)
          *> case name of
            "start" ->
              maybe
                (throwIO (ProviderFailure "shell_bg omitted taskId"))
                (writeIORef task . Just)
                (parseMaybe (withObject "background" (.: "taskId")) value)
            _ -> pure ()
    jsonArgs :: Text -> [(Text, Text)] -> Text
    jsonArgs taskId fields =
      TextEncoding.decodeUtf8
        . LazyByteString.toStrict
        . encode
        $ object (["taskId" .= taskId] <> [Key.fromText key .= value | (key, value) <- fields])

roundName :: ModelRequest -> Text
roundName request = fromMaybe "" (listToMaybe [text | ChatUser text <- reverse (requestMessages request)])

runBackgroundRound :: Application -> (Int, Text) -> IO SResponse
runBackgroundRound app (index, action) =
  runSession (srequest request) app
  where
    request =
      SRequest
        { simpleRequest =
            defaultRequest
              { requestMethod = methodPost,
                pathInfo = ["agent"],
                requestHeaders = [(hContentType, "application/json")]
              },
          simpleRequestBody =
            encode
              ( (sampleInput [])
                  { runThreadId = "daily-thread",
                    runId = "background-run-" <> Text.pack (show index),
                    runMessages = [User (UserMessage ("user-" <> Text.pack (show index)) (UserText action) Nothing)]
                  }
              )
        }

resultField :: FromJSON value => Text -> Text -> Map.Map Text Value -> Maybe value
resultField roundKey field results =
  Map.lookup roundKey results >>= parseMaybe (withObject "background result" (.: Key.fromText field))

callAs :: Text -> [BackendTool] -> Text -> Value -> IO ToolOutcome
callAs threadId =
  callToolContext (ToolContext "run" threadId "call" (const (pure ())) Nothing)

planTests :: TestTree
planTests =
  testGroup
    "plan tool"
    [ testCase "set replaces the plan, renders it and announces the full state" planSet,
      testCase "update flips items one by one and rejects unknown ids" planUpdate,
      testCase "clear empties the plan and renders the empty state" planClear,
      testCase "journaled plan events replay without divergence" planReplay,
      testCase "every tool spec is structurally valid JSON Schema" schemaSanity
    ]

schemaSanity :: Assertion
schemaSanity =
  withSandbox (workTools Nothing >=> traverse_ check . fmap (toolParameters . backendToolSpec))
  where
    check parameters =
      assertBool ("invalid schema node in: " ++ show parameters) (valid parameters)
    valid (Object fields) =
      hasType && consistent "properties" "object" && consistent "items" "array" && recurse
      where
        hasType = case KeyMap.lookup "type" fields of
          Just (String _) -> True
          _ -> False
        consistent key want =
          maybe True (const (KeyMap.lookup "type" fields == Just (String want))) (KeyMap.lookup key fields)
        recurse =
          maybe True (all valid . fmap snd . KeyMap.toList) (objectOf "properties")
            && maybe True valid (KeyMap.lookup "items" fields)
        objectOf key = case KeyMap.lookup key fields of
          Just (Object inner) -> Just inner
          _ -> Nothing
    valid _ = True

callPlan :: [BackendTool] -> IORef [Event] -> Value -> IO ToolOutcome
callPlan tools events arguments =
  callToolContext (streaming events) tools "plan" arguments
  where
    streaming ref = ToolContext "run" "thread" "call" (\event -> modifyIORef' ref (event :)) Nothing

planEvent :: [(Text, Text, Text)] -> Event
planEvent items = Custom "plan" (object ["items" .= fmap item items])
  where
    item (identifier, title, status) =
      object ["id" .= identifier, "title" .= title, "status" .= status]

planSetArgs :: Value
planSetArgs =
  object
    [ "action" .= ("set" :: Text),
      "items"
        .= [ object ["id" .= ("1" :: Text), "title" .= ("scan" :: Text)],
             object ["id" .= ("2" :: Text), "title" .= ("fix" :: Text)]
           ]
    ]

planUpdateArgs :: Text -> Text -> Value
planUpdateArgs identifier status =
  object ["action" .= ("update" :: Text), "id" .= identifier, "status" .= status]

planSet :: Assertion
planSet = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        newIORef [] >>= \events ->
          callPlan tools events planSetArgs >>= \outcome ->
            reverse <$> readIORef events >>= \emitted ->
              sequence_
                [ toolOutcomeError outcome @?= False,
                  toolOutcomeContent outcome @?= "1. [ ] scan\n2. [ ] fix",
                  emitted @?= [planEvent [("1", "scan", "pending"), ("2", "fix", "pending")]]
                ]

planUpdate :: Assertion
planUpdate = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        newIORef [] >>= \events ->
          callPlan tools events planSetArgs
            *> callPlan tools events (planUpdateArgs "1" "doing") >>= \doing ->
              callPlan tools events (planUpdateArgs "1" "done") >>= \done ->
                callPlan tools events (planUpdateArgs "2" "doing") >>= \second ->
                  callPlan tools events (planUpdateArgs "9" "done") >>= \unknown ->
                    reverse <$> readIORef events >>= \emitted ->
                      sequence_
                        [ toolOutcomeContent doing @?= "1. [doing] scan\n2. [ ] fix",
                          toolOutcomeContent done @?= "1. [done] scan\n2. [ ] fix",
                          toolOutcomeContent second @?= "1. [done] scan\n2. [doing] fix",
                          toolOutcomeError unknown @?= True,
                          toolOutcomeContent unknown @?= "unknown plan item: 9",
                          length emitted @?= 4,
                          last emitted @?= planEvent [("1", "scan", "done"), ("2", "fix", "doing")]
                        ]

planClear :: Assertion
planClear = withWorkDir exercise
  where
    exercise dir =
      workTools Nothing dir >>= \tools ->
        newIORef [] >>= \events ->
          callPlan tools events planSetArgs
            *> callPlan tools events (object ["action" .= ("clear" :: Text)]) >>= \cleared ->
              callPlan tools events (object ["action" .= ("clear" :: Text)]) >>= \again ->
                reverse <$> readIORef events >>= \emitted ->
                  sequence_
                    [ toolOutcomeError cleared @?= False,
                      toolOutcomeContent cleared @?= "(empty plan)",
                      toolOutcomeContent again @?= "(empty plan)",
                      last emitted @?= planEvent []
                    ]

planReplay :: Assertion
planReplay = withWorkDir exercise
  where
    exercise dir =
      newMemoryJournal >>= \(journal, readEntries) ->
        newIORef (0 :: Int) >>= \turns ->
          workTools Nothing dir >>= \tools ->
            testRuntime (planModel turns) tools Sequential >>= \base ->
              collectEvents base {runtimeJournal = Just journal} (sampleInput []) >>= \events ->
                readEntries >>= \recorded ->
                  replayEntries defaultHooks Nothing recorded >>= \report ->
                    sequence_
                      [ assertBool "journal records the plan event" (any journaled recorded),
                        [content | ToolCallResult _ "call-plan" content <- events] @?= ["1. [ ] scan\n2. [ ] fix"],
                        fmap reportDivergence report @?= Right Nothing,
                        fmap reportEvents report @?= Right (length (filter (not . isPlan) events))
                      ]
    journaled (Entry _ _ _ (AgentEventEntry (Custom "plan" _))) = True
    journaled _ = False
    isPlan (Custom "plan" _) = True
    isPlan _ = False

planModel :: IORef Int -> Model
planModel turns =
  fakeModel $ \_ emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next)) >>= \case
      1 -> emit (ModelToolCallDelta 0 (Just "call-plan") (Just "plan") planArgs) $> ToolUse
      _ -> emit (ModelTextDelta "planned") $> Stop
  where
    planArgs = "{\"action\":\"set\",\"items\":[{\"id\":\"1\",\"title\":\"scan\"},{\"id\":\"2\",\"title\":\"fix\"}]}"

adversarialTests :: TestTree
adversarialTests =
  testGroup
    "adversarial"
    [ testGroup
        "sandbox escapes"
        [ testCase "dotdot, nested-dotdot and absolute escapes are rejected by every fs tool" escapeFamily,
          testCase "the work directory itself stays reachable" rootReachable,
          testCase "symlinks to outside files, chains and directories are rejected" symlinkEscape,
          testCase "symlinks inside the sandbox resolve and work" symlinkInternal,
          testCase "glob and grep never cross symlinks and survive cycles" walkerSymlinks
        ],
      testGroup
        "concurrent runs on one thread"
        [ testCase "two runs coexist, streams stay separate and the transcript lands untorn" concurrentRuns,
          testCase "duplicate runId cancel race ends both streams then 404s" duplicateRunIdRace
        ],
      testGroup
        "background leaks"
        [ testCase "shell_kill reaps the process and drops the registry entry" killReaps,
          testCase "an externally killed task reports exit and leaves no zombie" externalKill,
          testCase "a dead registry entry never jams new background tasks" deadEntryNeverJams
        ],
      testGroup
        "SSE chunking"
        [ testCase "every binary split reproduces the one-shot decode" binarySplits,
          testCase "200 pseudo-random n-ary splits reproduce the one-shot decode" randomSplits,
          testCase "empty chunks and an unterminated tail" emptyChunks
        ]
    ]

withSandbox :: (FilePath -> Assertion) -> Assertion
withSandbox action =
  getTemporaryDirectory >>= \tmp ->
    newId >>= \identifier ->
      let base = tmp ++ "/" ++ Text.unpack identifier
          root = base ++ "/work"
          outside = base ++ "/outside"
       in createDirectoryIfMissing True (root ++ "/sub")
            *> createDirectoryIfMissing True outside
            *> TextIO.writeFile (outside ++ "/secret.txt") "TOP-SECRET\n"
            *> TextIO.writeFile (root ++ "/sub/ok.txt") "fine\n"
            *> createFileLink (outside ++ "/secret.txt") (root ++ "/linkfile.txt")
            *> createFileLink "linkfile.txt" (root ++ "/chain.txt")
            *> createDirectoryLink outside (root ++ "/linkdir")
            *> createDirectoryLink "sub" (root ++ "/inner")
            *> createDirectoryLink ".." (root ++ "/sub/up")
            *> action root

assertEscape :: ToolOutcome -> Assertion
assertEscape outcome =
  sequence_
    [ toolOutcomeError outcome @?= True,
      toolOutcomeContent outcome @?= "path escapes the work directory"
    ]

escapeFamily :: Assertion
escapeFamily = withSandbox exercise
  where
    exercise root =
      workTools Nothing root >>= \tools ->
        traverse_ (fmap assertEscape . readAt tools) fileEscapes
          *> traverse_ (fmap assertEscape . writeAt tools) fileEscapes
          *> traverse_ (fmap assertEscape . editAt tools) fileEscapes
          *> traverse_ (fmap assertEscape . globAt tools) dirEscapes
          *> traverse_ (fmap assertEscape . grepAt tools) dirEscapes
      where
        absolute = Text.pack (takeDirectory root ++ "/outside")
        fileEscapes =
          [ "../outside/secret.txt",
            "sub/../../outside/secret.txt",
            "ghost/../../outside/secret.txt",
            absolute <> "/secret.txt"
          ]
        dirEscapes = ["../outside", "ghost/../../outside", absolute]
        readAt tools path = callTool tools "fs_read" (object ["path" .= path])
        writeAt tools path = callTool tools "fs_write" (object ["path" .= path, "content" .= ("x" :: Text)])
        editAt tools path = callTool tools "fs_edit" (object ["path" .= path, "old" .= ("o" :: Text), "new" .= ("n" :: Text)])
        globAt tools path = callTool tools "fs_glob" (object ["pattern" .= ("*" :: Text), "path" .= path])
        grepAt tools path = callTool tools "fs_grep" (object ["pattern" .= ("x" :: Text), "path" .= path])

rootReachable :: Assertion
rootReachable = withSandbox exercise
  where
    exercise root =
      workTools Nothing root >>= \tools ->
        callTool tools "fs_read" (object ["path" .= ("." :: Text)]) >>= \readRoot ->
          callTool tools "fs_list" (object ["path" .= ("." :: Text)]) >>= \listRoot ->
            callTool tools "fs_glob" (object ["pattern" .= ("**/*.txt" :: Text), "path" .= ("." :: Text)]) >>= \globRoot ->
              callTool tools "fs_grep" (object ["pattern" .= ("fine" :: Text), "path" .= ("." :: Text)]) >>= \grepRoot ->
                sequence_
                  [ toolOutcomeError readRoot @?= True,
                    assertBool "reading a directory is not an escape" (toolOutcomeContent readRoot /= "path escapes the work directory"),
                    toolOutcomeError listRoot @?= False,
                    assertBool "lists the sandbox" (Text.isInfixOf "sub/" (toolOutcomeContent listRoot)),
                    toolOutcomeError globRoot @?= False,
                    toolOutcomeContent globRoot @?= "sub/ok.txt",
                    toolOutcomeError grepRoot @?= False,
                    toolOutcomeContent grepRoot @?= "sub/ok.txt:1:fine"
                  ]

symlinkEscape :: Assertion
symlinkEscape = withSandbox exercise
  where
    exercise root =
      workTools Nothing root >>= \tools ->
        traverse_ (fmap assertEscape . readAt tools) ["linkfile.txt", "chain.txt", "linkdir/secret.txt"]
          *> traverse_ (fmap assertEscape . writeAt tools) ["linkfile.txt", "linkdir/evil.txt"]
          *> traverse_ (fmap assertEscape . editAt tools) ["linkfile.txt", "chain.txt"]
          *> (TextIO.readFile (outside "secret.txt") >>= (@?= "TOP-SECRET\n"))
          *> (doesFileExist (outside "evil.txt") >>= assertBool "nothing is written outside" . not)
      where
        outside name = takeDirectory root ++ "/outside/" ++ name
        readAt tools path = callTool tools "fs_read" (object ["path" .= (path :: Text)])
        writeAt tools path = callTool tools "fs_write" (object ["path" .= (path :: Text), "content" .= ("x" :: Text)])
        editAt tools path = callTool tools "fs_edit" (object ["path" .= (path :: Text), "old" .= ("o" :: Text), "new" .= ("n" :: Text)])

symlinkInternal :: Assertion
symlinkInternal = withSandbox exercise
  where
    exercise root =
      workTools Nothing root >>= \tools ->
        readAt tools "inner/ok.txt" >>= \readInner ->
          writeAt tools "inner/new.txt" >>= \writeInner ->
            editInner tools >>= \edited ->
              (,) <$> TextIO.readFile (root ++ "/sub/ok.txt") <*> doesFileExist (root ++ "/sub/new.txt") >>= \(after, landed) ->
                sequence_
                  [ toolOutcomeError readInner @?= False,
                    toolOutcomeContent readInner @?= "fine\n",
                    toolOutcomeError writeInner @?= False,
                    landed @?= True,
                    toolOutcomeError edited @?= False,
                    after @?= "great\n"
                  ]
      where
        readAt tools path = callTool tools "fs_read" (object ["path" .= (path :: Text)])
        writeAt tools path = callTool tools "fs_write" (object ["path" .= (path :: Text), "content" .= ("brand new\n" :: Text)])
        editInner tools = callTool tools "fs_edit" (object ["path" .= ("inner/ok.txt" :: Text), "old" .= ("fine" :: Text), "new" .= ("great" :: Text)])

walkerSymlinks :: Assertion
walkerSymlinks = withSandbox exercise
  where
    exercise root =
      workTools Nothing root >>= \tools ->
        timeout 5000000 (probe tools) >>= maybe (assertFailure "the walker hung on a symlink cycle") verify
      where
        probe tools =
          (,,)
            <$> callTool tools "fs_glob" (object ["pattern" .= ("**/*.txt" :: Text)])
            <*> callTool tools "fs_grep" (object ["pattern" .= ("TOP-SECRET" :: Text)])
            <*> callTool tools "fs_grep" (object ["pattern" .= ("fine" :: Text)])
        verify (names, leak, hits) =
          sequence_
            [ toolOutcomeContent names @?= "sub/ok.txt",
              toolOutcomeContent leak @?= "",
              toolOutcomeContent hits @?= "sub/ok.txt:1:fine"
            ]

gatedModel :: MVar () -> Model
gatedModel release =
  fakeModel $ \_ emit -> readMVar release *> emit (ModelTextDelta "ok") $> Stop

concurrentRuns :: Assertion
concurrentRuns =
  withWorkDir $ \dir ->
    newTranscriptStore dir >>= \store ->
      newRunRegistry >>= \runs ->
        newEmptyMVar >>= \release ->
          newIORef [] >>= \histories ->
            newIORef [] >>= \chunksA ->
              newIORef [] >>= \chunksB ->
                newEmptyMVar >>= \doneA ->
                  newEmptyMVar >>= \doneB ->
                    testRuntime (gatedModel release) [] Parallel >>= \base ->
                      let runtime = base {runtimeRuns = Just runs, runtimeHooks = transcriptHooks store <> afterSpy histories}
                          app = application Nothing Nothing Nothing (Just runs) (const (pure runtime))
                       in forkIO (streamInput app inputA chunksA doneA)
                            *> forkIO (streamInput app inputB chunksB doneB)
                            *> (waitUntil ((&&) <$> streamBegan chunksA <*> streamBegan chunksB) >>= bool (assertFailure "both runs never started") (pure ()))
                            *> (steerRun runs "run-a" (ChatUser "probe") >>= (@?= True))
                            *> (cancelRun runs "run-a" >>= (@?= True))
                            *> (timeout 5000000 (takeMVar doneA) >>= maybe (assertFailure "cancelled run did not finish") pure)
                            *> putMVar release ()
                            *> (timeout 5000000 (takeMVar doneB) >>= maybe (assertFailure "surviving run did not finish") pure)
                            *> runSession (srequest (cancelRequest "run-b")) app >>= \lateCancel ->
                              decodeChunks chunksA >>= \eventsA ->
                                decodeChunks chunksB >>= \eventsB ->
                                  transcriptLoad store "thread" >>= \saved ->
                                    reverse <$> readIORef histories >>= \captured ->
                                      sequence_
                                        [ simpleStatus lateCancel @?= status404,
                                          length [() | Custom "run.cancelled" _ <- eventsA] @?= 1,
                                          [() | Custom "run.cancelled" _ <- eventsB] @?= [],
                                          [run | RunStarted _ run _ <- eventsA] @?= ["run-a"],
                                          [run | RunStarted _ run _ <- eventsB] @?= ["run-b"],
                                          [run | RunFinished _ run _ <- eventsA] @?= ["run-a"],
                                          [run | RunFinished _ run _ <- eventsB] @?= ["run-b"],
                                          [delta | TextMessageContent _ delta <- eventsB] @?= ["ok"],
                                          eventType (last eventsA) @?= "RUN_FINISHED",
                                          eventType (last eventsB) @?= "RUN_FINISHED",
                                          length captured @?= 2,
                                          assertBool "transcript is one whole history, not torn" (saved `elem` fmap Just captured)
                                        ]
  where
    inputA = (sampleInput []) {runId = "run-a", runMessages = [User (UserMessage "user-a" (UserText "hello-a") Nothing)]}
    inputB = (sampleInput []) {runId = "run-b", runMessages = [User (UserMessage "user-b" (UserText "hello-b") Nothing)]}

duplicateRunIdRace :: Assertion
duplicateRunIdRace =
  newRunRegistry >>= \runs ->
    newEmptyMVar >>= \gate ->
      newIORef [] >>= \chunksA ->
        newIORef [] >>= \chunksB ->
          newEmptyMVar >>= \doneA ->
            newEmptyMVar >>= \doneB ->
              testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel >>= \base ->
                let runtime = base {runtimeRuns = Just runs}
                    app = application Nothing Nothing Nothing (Just runs) (const (pure runtime))
                 in forkIO (streamInput app same chunksA doneA)
                      *> (waitUntil (streamBegan chunksA) >>= bool (assertFailure "first run never started") (pure ()))
                      *> forkIO (streamInput app same chunksB doneB)
                      *> (waitUntil (streamBegan chunksB) >>= bool (assertFailure "duplicate run never started") (pure ()))
                      *> (cancelRun runs "run" >>= (@?= True))
                      *> (timeout 5000000 (takeMVar doneB) >>= maybe (assertFailure "cancelled duplicate did not finish") pure)
                      *> putMVar gate ()
                      *> (timeout 5000000 (takeMVar doneA) >>= maybe (assertFailure "first run did not finish") pure)
                      *> runSession (srequest (cancelRequest "run")) app >>= \lateCancel ->
                        decodeChunks chunksA >>= \eventsA ->
                          decodeChunks chunksB >>= \eventsB ->
                            sequence_
                              [ simpleStatus lateCancel @?= status404,
                                [() | Custom "run.cancelled" _ <- eventsA] @?= [],
                                length [() | Custom "run.cancelled" _ <- eventsB] @?= 1,
                                eventType (last eventsA) @?= "RUN_FINISHED",
                                eventType (last eventsB) @?= "RUN_FINISHED"
                              ]
  where
    same = sampleInput []

pidOf :: ToolOutcome -> IO Int
pidOf outcome =
  outcomeValue outcome >>= either assertFailure pure . parseEither (withObject "background" (.: "pid"))

killReaps :: Assertion
killReaps = withWorkDir exercise
  where
    exercise dir =
      newBackgroundRegistry >>= \registry ->
        let tools = backgroundTools registry dir
         in callTool tools "shell_bg" (object ["command" .= ("sleep 500" :: Text)]) >>= \started ->
              taskIdOf started >>= \taskId ->
                lookupBackground registry taskId >>= \found ->
                  case found of
                    Nothing -> assertFailure "task missing from the registry"
                    Just task ->
                      callTool tools "shell_kill" (object ["taskId" .= taskId]) >>= \killed ->
                        outcomeValue killed >>= \result ->
                          waitUntil (isJust <$> getProcessExitCode (backgroundProcess task)) >>= \reaped ->
                            isJust <$> lookupBackground registry taskId >>= \registered ->
                              sequence_
                                [ parseMaybe (withObject "kill" (.: "killed")) result @?= Just True,
                                  assertBool "the process is reaped, no zombie" reaped,
                                  assertBool "the registry drops the task" (not registered)
                                ]

externalKill :: Assertion
externalKill = withWorkDir exercise
  where
    exercise dir =
      newBackgroundRegistry >>= \registry ->
        let tools = backgroundTools registry dir
         in callTool tools "shell_bg" (object ["command" .= ("sleep 500" :: Text)]) >>= \started ->
              (,) <$> taskIdOf started <*> pidOf started >>= \(taskId, pid) ->
                lookupBackground registry taskId >>= \found ->
                  case found of
                    Nothing -> assertFailure "task missing from the registry"
                    Just task ->
                      workTools Nothing dir >>= \shellTools ->
                        callTool shellTools "shell" (object ["command" .= ("kill -9 " <> Text.pack (show pid) :: Text)]) >>= \sigkill ->
                        callTool tools "shell_output" (object ["taskId" .= taskId, "waitSeconds" .= (5 :: Int)]) >>= \polled ->
                          pollOf polled >>= \(running, exitCode, _, _) ->
                            waitUntil (isJust <$> getProcessExitCode (backgroundProcess task)) >>= \reaped ->
                              isJust <$> lookupBackground registry taskId >>= \registered ->
                                callTool tools "shell_kill" (object ["taskId" .= taskId]) >>= \cleanup ->
                                  outcomeValue cleanup >>= \result ->
                                    sequence_
                                      [ assertBool "sigkill lands" (Text.isPrefixOf "exit 0" (toolOutcomeContent sigkill)),
                                        running @?= False,
                                        assertBool "the exit is reported, never a hang" (isJust exitCode),
                                        assertBool "the watcher reaps the corpse" reaped,
                                        assertBool "a dead task lingers until shell_kill reaps it" registered,
                                        parseMaybe (withObject "kill" (.: "killed")) result @?= Just True
                                      ]

deadEntryNeverJams :: Assertion
deadEntryNeverJams = withWorkDir exercise
  where
    exercise dir =
      newBackgroundRegistry >>= \registry ->
        exerciseWith registry (backgroundTools registry dir)
    exerciseWith registry tools =
      callTool tools "shell_bg" (object ["command" .= ("true" :: Text)]) >>= \first ->
              taskIdOf first >>= \firstId ->
                callTool tools "shell_output" (object ["taskId" .= firstId, "waitSeconds" .= (5 :: Int)]) >>= \polledFirst ->
                  callTool tools "shell_bg" (object ["command" .= ("echo second" :: Text)]) >>= \second ->
                    taskIdOf second >>= \secondId ->
                      callTool tools "shell_output" (object ["taskId" .= secondId, "waitSeconds" .= (5 :: Int)]) >>= \polledSecond ->
                        pollOf polledFirst >>= \(_, firstExit, _, _) ->
                          pollOf polledSecond >>= \(running, exitCode, output, _) ->
                            (,) <$> reap tools firstId <*> reap tools secondId >>= \(firstKilled, secondKilled) ->
                              sequence_
                                [ assertBool "the first task died on its own" (isJust firstExit),
                                  assertBool "task ids are distinct" (firstId /= secondId),
                                  running @?= False,
                                  exitCode @?= Just 0,
                                  output @?= "second\n",
                                  firstKilled @?= Just True,
                                  secondKilled @?= Just True
                                ]
    reap tools taskId =
      callTool tools "shell_kill" (object ["taskId" .= taskId])
        >>= fmap (parseMaybe (withObject "kill" (.: "killed"))) . outcomeValue

sseSpecimen :: ByteString
sseSpecimen =
  ByteString.concat
    [ ": comment line\r\n",
      "data: {\"a\":1}\r\n",
      "\r\n",
      "data: one\n",
      "data: two\n",
      "\n",
      ": mid comment\n",
      "event: ping\n",
      "data: [DONE]\n",
      "\n",
      "\n",
      "data: tail"
    ]

sseExpected :: [ByteString]
sseExpected = ["{\"a\":1}", "one\ntwo", "[DONE]", "tail"]

sseCollect :: [ByteString] -> [ByteString]
sseCollect chunks = payloads <> trailing
  where
    (decoder, payloads) = foldl feed (emptySseDecoder, []) chunks
    feed (current, acc) chunk = (next, acc <> emitted)
      where
        (next, emitted) = feedSse current chunk
    (_, trailing) = finishSse decoder

binarySplits :: Assertion
binarySplits =
  (sseCollect [sseSpecimen] @?= sseExpected)
    *> traverse_ splitAtEvery [0 .. ByteString.length sseSpecimen]
  where
    splitAtEvery point =
      sseCollect [ByteString.take point sseSpecimen, ByteString.drop point sseSpecimen] @?= sseExpected

randomSplits :: Assertion
randomSplits = traverse_ check [1 .. 200]
  where
    check seed = sseCollect (chopAt (splitPoints seed) sseSpecimen) @?= sseExpected

splitPoints :: Int -> [Int]
splitPoints seed = sort (nub (take (1 + seed `mod` 7) (fmap (`mod` (size + 1)) (lcg seed))))
  where
    size = ByteString.length sseSpecimen

lcg :: Int -> [Int]
lcg seed = unfoldr step (seed * 2654435761 + 1)
  where
    step x = Just (x, (x * 1103515245 + 12345) `mod` 2147483648)

chopAt :: [Int] -> ByteString -> [ByteString]
chopAt points bytes = go 0 points bytes
  where
    go _ [] rest = [rest]
    go offset (point : rest) chunk =
      piece : go point rest remainder
      where
        (piece, remainder) = ByteString.splitAt (point - offset) chunk

emptyChunks :: Assertion
emptyChunks =
  sequence_
    [ sseCollect [] @?= [],
      sseCollect ["", "", ""] @?= [],
      sseCollect (replicate 5 "" <> [sseSpecimen]) @?= sseExpected,
      sseCollect ["data: tail"] @?= ["tail"],
      sseCollect ["data: cr-tail\r"] @?= ["cr-tail"]
    ]
threadConfigTests :: TestTree
threadConfigTests =
  testGroup
    "thread config"
    [ testCase "resolve merges session over global per field" resolveFields,
      testCase "cwd JSON distinguishes inherit, none and a concrete path" cwdStateJson,
      testCase "reasoning effort JSON accepts only supported values" reasoningEffortJson,
      testCase "a session can inherit, clear or replace a global cwd" cwdOverridesGlobal,
      testCase "file store round-trips under a sanitized name and reloads" fileStoreRoundTrip,
      testCase "resolveRuntime roots tools at the configured cwd and gates fs and shell" toolResolution,
      testCase "resolveRuntime overrides the prompt and rebuilds the model by name" promptAndModel,
      testCase "resolveRuntime applies per-thread reasoning effort" reasoningEffortResolution,
      testCase "resolveRuntime applies per-thread context policy" contextPolicyResolution,
      testCase "resolveRuntime strips the hooks when memory is off" memoryStripped,
      testCase "PUT then GET returns the saved config, unknown threads are all null" configEndpoints,
      testCase "capabilities endpoint reports the resolved backend tools" configCapabilities,
      testCase "context endpoint explains the exact compaction threshold" configContextPolicy,
      testCase "PUT rejects a missing cwd without saving" configRejectsBadCwd,
      testCase "PUT rejects invalid context policy values" configRejectsBadContext,
      testCase "PUT rejects an unknown reasoning effort" configRejectsBadEffort,
      testCase "config tree endpoint never descends through symlinks" configTreeSymlinks,
      testCase "path completion endpoint uses the resolved session cwd" configPathCompletion,
      testCase "GET /config masks the API key" configMasksKey,
      testCase "handleAgent resolves the system prompt per thread" perThreadPrompts
    ]

agentsMdTests :: TestTree
agentsMdTests =
  testGroup
    "AGENTS.md"
    [ testCase "collects nested files root-first with path headers" nestedAgentsMd,
      testCase "yields empty without any AGENTS.md" absentAgentsMd,
      testCase "skips unreadable files without failing" unreadableAgentsMd,
      testCase "caps the total at 32KB with a truncation note" cappedAgentsMd,
      testCase "appendAgentsMd joins with two blank lines only when both sides exist" appendShape,
      testCase "resolve appends the section when a cwd resolves, never without" resolveAgentsMd
    ]

sessionTests :: TestTree
sessionTests =
  testGroup
    "local sessions"
    [ testCase "metadata index survives reopen, rename, archive and restore" sessionIndexPersists,
      testCase "migrates legacy owners from config and makes them immutable" sessionOwnerMigration,
      testCase "forks at a stable history node without changing the source" sessionForks,
      testCase "exports and imports a complete bundle without overwriting duplicates" sessionTransfers,
      testCase "archive invokes thread cleanup" sessionArchiveCleanup,
      testCase "HTTP routes list, create, rename, archive, restore and serve empty transcripts" sessionRoutes,
      testCase "manual compaction persists a bounded transcript and local snapshot" sessionManualCompact,
      testCase "agent requests auto-index valid sessions and reject archived ones" sessionAgentIndex
    ]

sessionServiceAt :: FilePath -> (Text -> IO ()) -> IO SessionService
sessionServiceAt dir cleanup =
  SessionService
    <$> newSessionStore dir
    <*> newTranscriptStore dir
    <*> newThreadConfigStore dir
    <*> pure cleanup

sessionIndexPersists :: Assertion
sessionIndexPersists =
  withWorkDir $ \dir ->
    newSessionStore dir >>= \store ->
      ( createSession store "alpha" (Just "Alpha") "yuki" Nothing Nothing
          >>= \created -> fmap withoutTimes created @?= Right (meta "alpha" "Alpha" "yuki" False Nothing Nothing)
      )
        *> ( renameSession store "alpha" "Renamed"
               >>= either (assertFailure . Text.unpack) (\renamed -> sessionTitle renamed @?= "Renamed")
           )
        *> ( setSessionArchived store "alpha" True
               >>= either (assertFailure . Text.unpack) (\archived -> assertBool "archived" (sessionArchived archived))
           )
        *> ( newSessionStore dir >>= \reopened ->
               (listSessions reopened False >>= (@?= []))
                 *> ( listSessions reopened True
                        >>= \allSessions -> fmap withoutTimes allSessions @?= [meta "alpha" "Renamed" "yuki" True Nothing Nothing]
                    )
                 *> ( setSessionArchived reopened "alpha" False
                        >>= either
                          (assertFailure . Text.unpack)
                          ( \restored ->
                              sequence_
                                [ sessionArchived restored @?= False,
                                  sessionIncarnationId restored @?= "yuki"
                                ]
                          )
                    )
           )
  where
    withoutTimes value = value {sessionCreated = 0, sessionUpdated = 0}
    meta identifier title owner archived parent node = SessionMeta identifier title owner 0 0 archived parent node

sessionOwnerMigration :: Assertion
sessionOwnerMigration =
  withWorkDir $ \dir ->
    let path = dir ++ "/sessions/index.json"
        legacy identifier =
          object
            [ "id" .= (identifier :: Text),
              "title" .= identifier,
              "created" .= (1 :: Int),
              "updated" .= (1 :: Int),
              "archived" .= False
            ]
     in createDirectoryIfMissing True (dir ++ "/sessions")
          *> LazyByteString.writeFile path (encode [legacy "legacy-art", legacy "legacy-yuki"])
          *> newSessionStore dir
          >>= \sessions ->
            newThreadConfigStore dir >>= \configs ->
              threadConfigWrite configs "legacy-art" emptyThreadConfig {configIncarnationId = Just "art"}
                *> migrateSessionOwners sessions configs
                >>= withTextRight
                  ( \() ->
                      (,,,)
                        <$> findSession sessions "legacy-art"
                        <*> findSession sessions "legacy-yuki"
                        <*> threadConfigRead configs "legacy-art"
                        <*> threadConfigRead configs "legacy-yuki"
                        >>= \(art, yuki, artConfig, yukiConfig) ->
                          claimSessionOwner sessions "legacy-art" "yuki" >>= \reassigned ->
                            newSessionStore dir >>= \reopened ->
                              findSession reopened "legacy-art" >>= \stored ->
                                sequence_
                                  [ fmap sessionIncarnationId art @?= Just "art",
                                    fmap sessionIncarnationId yuki @?= Just "yuki",
                                    configIncarnationId artConfig @?= Just "art",
                                    configIncarnationId yukiConfig @?= Just "yuki",
                                    assertLeft reassigned,
                                    fmap sessionIncarnationId stored @?= Just "art"
                                  ]
                  )

sessionForks :: Assertion
sessionForks =
  withWorkDir $ \dir ->
    sessionServiceAt dir (const (pure ())) >>= \service ->
      let sessions = serviceSessions service
          transcripts = serviceTranscripts service
          configs = serviceConfigs service
          config = emptyThreadConfig {configIncarnationId = Just "art", configSystemPrompt = Just "forked"}
       in createSession sessions "source" (Just "Source") "art" Nothing Nothing
            *> transcriptSave transcripts "source" transcriptHistory
            *> threadConfigWrite configs "source" config
            *> ( forkSession service "source" "branch" (Just "m-1") (Just "Branch")
                   >>= either (assertFailure . Text.unpack) verifyMeta
               )
            *> (transcriptLoad transcripts "source" >>= (@?= Just transcriptHistory))
            *> (transcriptLoad transcripts "branch" >>= (@?= Just (take 2 transcriptHistory)))
            *> (threadConfigRead configs "branch" >>= (@?= config))
            *> (forkSession service "source" "missing-node" (Just "absent") Nothing >>= assertLeft)
            *> (transcriptLoad transcripts "missing-node" >>= (@?= Nothing))
  where
    verifyMeta result =
      sequence_
        [ sessionId result @?= "branch",
          sessionIncarnationId result @?= "art",
          sessionParent result @?= Just "source",
          sessionForkNode result @?= Just "m-1"
        ]

sessionTransfers :: Assertion
sessionTransfers =
  withWorkDir $ \dir ->
    sessionServiceAt dir (const (pure ())) >>= \service ->
      let sessions = serviceSessions service
          transcripts = serviceTranscripts service
          configs = serviceConfigs service
          config = emptyThreadConfig {configCwd = CwdNone, configIncarnationId = Just "art", configMemory = Just False}
       in createSession sessions "source" (Just "Portable") "art" Nothing Nothing
            *> transcriptSave transcripts "source" transcriptHistory
            *> threadConfigWrite configs "source" config
            *> exportSession service "source"
            >>= maybe (assertFailure "missing export") (transfer service config)
  where
    transfer service config bundle =
      (eitherDecode (encode bundle) @?= Right bundle)
        *> ( importSession service (ImportRequest bundle (Just "imported") (Just "Imported"))
               >>= either
                 (assertFailure . Text.unpack)
                 ( \result ->
                     sequence_
                       [ sessionTitle result @?= "Imported",
                         sessionIncarnationId result @?= "art"
                       ]
                 )
           )
        *> (transcriptLoad (serviceTranscripts service) "imported" >>= (@?= Just transcriptHistory))
        *> (threadConfigRead (serviceConfigs service) "imported" >>= (@?= config))
        *> ( importSession
               service
               ( ImportRequest
                   bundle
                     { bundleMeta =
                         (bundleMeta bundle) {sessionIncarnationId = ""}
                     }
                   (Just "legacy-imported")
                   Nothing
               )
               >>= either
                 (assertFailure . Text.unpack)
                 (\result -> sessionIncarnationId result @?= "art")
           )
        *> (threadConfigRead (serviceConfigs service) "legacy-imported" >>= \stored -> configIncarnationId stored @?= Just "art")
        *> transcriptSave (serviceTranscripts service) "imported" [ChatUser "keep"]
        *> (importSession service (ImportRequest bundle (Just "imported") Nothing) >>= assertLeft)
        *> (transcriptLoad (serviceTranscripts service) "imported" >>= (@?= Just [ChatUser "keep"]))

sessionArchiveCleanup :: Assertion
sessionArchiveCleanup =
  withWorkDir $ \dir ->
    newIORef [] >>= \cleaned ->
      sessionServiceAt dir (\threadId -> modifyIORef' cleaned (threadId :)) >>= \service ->
        createSession (serviceSessions service) "thread" Nothing "yuki" Nothing Nothing
          *> (archiveSession service "thread" >>= either (assertFailure . Text.unpack) (const (pure ())))
          *> (restoreSession service "thread" >>= either (assertFailure . Text.unpack) (const (pure ())))
          *> (readIORef cleaned >>= (@?= ["thread"]))

sessionRoutes :: Assertion
sessionRoutes =
  withWorkDir $ \dir ->
    sessionServiceAt dir (const (pure ())) >>= \service ->
      testRuntime okModel [] Parallel >>= \base ->
        let inspection = withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service)))
            app = application Nothing (Just inspection) Nothing Nothing (const (pure base))
         in runSession (srequest (jsonRequest methodPost ["threads"] (object ["threadId" .= ("route" :: Text), "title" .= ("Route" :: Text)]))) app >>= \created ->
              runSession (srequest (jsonRequest methodPatch ["threads", "route"] (object ["title" .= ("Named" :: Text)]))) app >>= \renamed ->
                runSession (srequest (jsonRequest methodPost ["threads", "route", "archive"] (object []))) app >>= \archived ->
                  runSession (request (httpGet ["threads"])) app >>= \active ->
                    runSession (request ((httpGet ["threads"]) {queryString = [("archived", Just "true")]})) app >>= \allSessions ->
                      runSession (request (httpGet ["threads", "route", "transcript"])) app >>= \emptyTranscript ->
                        runSession (srequest (jsonRequest methodPost ["threads", "route", "restore"] (object []))) app >>= \restored ->
                          sequence_
                            [ simpleStatus created @?= status200,
                              simpleStatus renamed @?= status200,
                              simpleStatus archived @?= status200,
                              either assertFailure (@?= ([] :: [SessionMeta])) (eitherDecode (simpleBody active)),
                              either assertFailure (\sessions -> fmap sessionTitle sessions @?= ["Named"]) (eitherDecode (simpleBody allSessions)),
                              simpleStatus emptyTranscript @?= status200,
                              simpleStatus restored @?= status200
                            ]

sessionManualCompact :: Assertion
sessionManualCompact =
  withWorkDir $ \dir ->
    sessionServiceAt dir (const (pure ())) >>= \service ->
      newMemoryArtifactStore >>= \artifacts ->
        testRuntime (okModel {modelContextTokens = Just 512}) [] Parallel >>= \base ->
          let inspection =
                withSessionService service
                  (newInspection Nothing (Just artifacts) Nothing (Just (serviceTranscripts service)))
              runtime = base {runtimeArtifactStore = Just artifacts, runtimeContext = Just contextConfig}
              app = application Nothing (Just inspection) Nothing Nothing (const (pure runtime))
           in createSession (serviceSessions service) "compact-me" Nothing "yuki" Nothing Nothing
                *> transcriptSave (serviceTranscripts service) "compact-me" contextConversation
                *> runSession
                  (request defaultRequest {requestMethod = methodPost, pathInfo = ["threads", "compact-me", "compact"]})
                  app
                >>= \response ->
                  transcriptLoad (serviceTranscripts service) "compact-me" >>= \stored ->
                    artifactList artifacts >>= \metas ->
                      case eitherDecode (simpleBody response) :: Either String Value of
                        Left message -> assertFailure message
                        Right body ->
                          sequence_
                            [ simpleStatus response @?= status200,
                              parseMaybe (withObject "compact" (.: "changed")) body @?= Just True,
                              assertBool
                                "persisted transcript is bounded"
                                (maybe False ((<= 256) . estimateMessagesTokens) stored),
                              assertBool
                                "persisted transcript keeps a summary"
                                (maybe False (any isContextSummary) stored),
                              fmap artifactMetaToolName metas @?= ["context_compaction"]
                            ]

sessionAgentIndex :: Assertion
sessionAgentIndex =
  withWorkDir $ \dir ->
    sessionServiceAt dir (const (pure ())) >>= \service ->
      testRuntime okModel [] Parallel >>= \base ->
        let inspection = withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service)))
            app = application Nothing (Just inspection) Nothing Nothing (const (pure base))
            input = (sampleInput []) {runThreadId = "auto", runId = "auto-run"}
         in runSession (srequest (jsonRequest methodPost ["agent"] input)) app >>= \first ->
              findSession (serviceSessions service) "auto" >>= \created ->
                ensureSession (serviceSessions service) "auto" (Just "second title") "yuki" >>= \unchanged ->
                  archiveSession service "auto"
                    *> runSession (srequest (jsonRequest methodPost ["agent"] input {runId = "archived-run"})) app
                    >>= \rejected ->
                      sequence_
                        [ simpleStatus first @?= status200,
                          fmap sessionTitle created @?= Just "hello",
                          sessionTitle unchanged @?= "hello",
                          simpleStatus rejected @?= status409
                        ]

jsonRequest :: ToJSON body => Method -> [Text] -> body -> SRequest
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

growthTests :: TestTree
growthTests =
  testGroup
    "bounded local state"
    [ testCase "run completion clears transient memory and caps thread episodes" memoryStateBounded,
      testCase "journal keeps complete recent runs and preserves sequence across compaction" journalRetention,
      testCase "live journal inspection uses the in-memory index" journalInspectionCache,
      testCase "artifact retention removes old objects and compacts the index" artifactRetention,
      testCase "fact retention caps resident state and compacts the file" factRetention
    ]

memoryStateBounded :: Assertion
memoryStateBounded =
  newMemoryFactStore >>= \facts ->
    factAdd facts "the deploy target is fly.io" FactProject "seed"
      *> newMemoryThreadStore
      >>= \threads ->
        newMemoryState >>= \state ->
          testRuntime okModel [] Parallel >>= \base ->
            let runtime = base {runtimeHooks = memoryHooks retrieveWatcher threads facts Nothing state}
                run index =
                  collectEvents
                    runtime
                    ((sampleInput []) {runId = "bounded-" <> Text.pack (show index)})
             in traverse_ run [(1 :: Int) .. 80]
                  *> ( memoryTransientCounts state
                         >>= \(briefings, candidates, budgets, cooldowns) ->
                           threadBrief threads "thread" >>= \brief ->
                             sequence_
                               [ briefings @?= 0,
                                 candidates @?= 0,
                                 budgets @?= 0,
                                 assertBool "cooldowns remain bounded by recent queries" (cooldowns <= 1),
                                 fmap (length . briefEpisodes) brief @?= Just 64
                               ]
                     )

journalRetention :: Assertion
journalRetention =
  withWorkDir $ \dir ->
    newFileJournalWithLimit 2 dir >>= \journal ->
      traverse_ (recordRun journal) ["run-1", "run-2", "run-3"]
        *> (journalSnapshot journal >>= verify [2, 3, 4, 5] ["run-2", "run-3"])
        *> ( newFileJournalWithLimit 2 dir >>= \reopened ->
               recordRun reopened "run-4"
                 *> (journalSnapshot reopened >>= verify [4, 5, 6, 7] ["run-3", "run-4"])
           )
  where
    settings = RunSettings 8 Parallel "" 1 Nothing Nothing Nothing
    recordRun journal run =
      let input = (sampleInput []) {runId = run}
          scoped = subJournal run journal
       in recordMaybe (Just scoped) (RunBegin input settings)
            *> recordMaybe (Just scoped) (IdEntry ("id-" <> run))
    verify seqs runs entries =
      sequence_
        [ fmap entrySeq entries @?= seqs,
          [runId input | Entry _ scope _ (RunBegin input _) <- entries, length scope == 1] @?= runs
        ]

journalInspectionCache :: Assertion
journalInspectionCache =
  withWorkDir $ \dir ->
    newFileJournal dir >>= \journal ->
      recordMaybe (Just journal) (IdEntry "cached")
        *> ( testRuntime okModel [] Parallel >>= \base ->
               let path = journalFilePath dir
                   inspection = withLiveJournal journal (newInspection Nothing Nothing (Just path) Nothing)
                   app = application Nothing (Just inspection) Nothing Nothing (const (pure base))
                in LazyByteString.writeFile path "{broken"
                     *> ( runSession (request (httpGet ["journal"])) app
                            >>= \response ->
                              sequence_
                                [ simpleStatus response @?= status200,
                                  either assertFailure (\entries -> fmap entryKind entries @?= [IdEntry "cached"]) (eitherDecode (simpleBody response))
                                ]
                        )
           )

artifactRetention :: Assertion
artifactRetention =
  withWorkDir $ \dir ->
    newArtifactStoreWithLimit 2 dir >>= \store ->
      traverse (artifactSave store "tool") ["first", "second", "third"] >>= \identifiers ->
        artifactList store >>= \listed ->
          artifactFetch store (fromMaybe "" (listToMaybe identifiers)) >>= \oldest ->
            newArtifactStoreWithLimit 2 dir >>= \reopened ->
              artifactList reopened >>= \afterRestart ->
                sequence_
                  [ length listed @?= 2,
                    oldest @?= Nothing,
                    length afterRestart @?= 2,
                    LazyByteString.readFile (dir ++ "/index.jsonl")
                      >>= \bytes -> length (filter (not . LazyByteString.null) (LazyByteString.split 10 bytes)) @?= 2
                  ]

factRetention :: Assertion
factRetention =
  withWorkDir $ \dir ->
    newFactStoreWithLimit 2 dir >>= \store ->
      traverse_ (\content -> factAdd store content FactProject "run") ["first fact", "second fact", "third fact"]
        *> ( factList store >>= \listed ->
               newFactStoreWithLimit 2 dir >>= \reopened ->
                 factList reopened >>= \afterRestart ->
                   LazyByteString.readFile (dir ++ "/facts.jsonl") >>= \bytes ->
                     sequence_
                       [ length listed @?= 2,
                         assertBool "newest fact is retained" (any ((== "third fact") . factContent) listed),
                         length afterRestart @?= 2,
                         length (filter (not . LazyByteString.null) (LazyByteString.split 10 bytes)) @?= 2
                       ]
           )

nestedAgentsMd :: Assertion
nestedAgentsMd =
  withWorkDir $ \root ->
    let leaf = root ++ "/leaf"
        expected = Text.intercalate "\n\n" [sectionOf root "root rules", sectionOf leaf "leaf rules"]
     in createDirectoryIfMissing True leaf
          *> writeFile (root ++ "/AGENTS.md") "root rules"
          *> writeFile (leaf ++ "/AGENTS.md") "leaf rules"
          *> (agentsMdSection (Just leaf) >>= assertBool "root-first with path headers" . Text.isInfixOf expected)
  where
    sectionOf dir body = "# " <> Text.pack (dir ++ "/AGENTS.md") <> "\n\n" <> body

absentAgentsMd :: Assertion
absentAgentsMd =
  (agentsMdSection Nothing >>= (@?= ""))
    *> withWorkDir (\dir -> agentsMdSection (Just dir) >>= (@?= ""))

unreadableAgentsMd :: Assertion
unreadableAgentsMd =
  withWorkDir $ \root ->
    let leaf = root ++ "/leaf"
        blocked = leaf ++ "/AGENTS.md"
     in createDirectoryIfMissing True leaf
          *> writeFile (root ++ "/AGENTS.md") "root rules"
          *> writeFile blocked "hidden"
          *> getPermissions blocked
          >>= \original ->
            setPermissions blocked emptyPermissions
              *> (agentsMdSection (Just leaf) >>= verify)
              *> setPermissions blocked original
  where
    verify section =
      sequence_
        [ assertBool "keeps the readable file" (Text.isInfixOf "root rules" section),
          assertBool "skips the unreadable file" (not (Text.isInfixOf "hidden" section))
        ]

cappedAgentsMd :: Assertion
cappedAgentsMd =
  withWorkDir $ \root ->
    writeFile (root ++ "/AGENTS.md") (replicate 40000 'x')
      *> (agentsMdSection (Just root) >>= (@?= expected root))
  where
    expected root = Text.take 32768 full <> "\n# AGENTS.md sections truncated at 32768 characters"
      where
        full = "# " <> Text.pack (root ++ "/AGENTS.md") <> "\n\n" <> Text.replicate 40000 "x"

appendShape :: Assertion
appendShape =
  sequence_
    [ appendAgentsMd "" "prompt" @?= "prompt",
      appendAgentsMd "section" "" @?= "section",
      appendAgentsMd "section" "prompt" @?= "prompt\n\n\nsection"
    ]

resolveAgentsMd :: Assertion
resolveAgentsMd =
  withWorkDir $ \root ->
    newTlsManager >>= \manager ->
      testRuntime okModel [] Parallel >>= \base ->
        writeFile (root ++ "/AGENTS.md") "project rules"
          *> ( (,,) <$> inject manager base (emptyThreadConfig {configCwd = CwdPath root})
                <*> inject manager base (emptyThreadConfig {configCwd = CwdPath root, configSystemPrompt = Just "session"})
                <*> inject manager base emptyThreadConfig
             )
          >>= \(withCwd, withSession, withoutCwd) ->
            sequence_
              [ runtimeSystemPrompt withCwd @?= "base prompt\n\n\n# " <> Text.pack (root ++ "/AGENTS.md") <> "\n\nproject rules",
                runtimeSystemPrompt withSession @?= "session\n\n\n# " <> Text.pack (root ++ "/AGENTS.md") <> "\n\nproject rules",
                runtimeSystemPrompt withoutCwd @?= "base prompt"
              ]
  where
    inject manager base config =
      resolveRuntime manager testProvider Nothing base {runtimeSystemPrompt = "base prompt"} config Map.empty Map.empty >>= \resolved ->
        agentsMdSection (cwdPath (configCwd config)) <&> \section ->
          resolved {runtimeSystemPrompt = appendAgentsMd section (runtimeSystemPrompt resolved)}

okModel :: Model
okModel = fakeModel (\_ emit -> emit (ModelTextDelta "ok") $> Stop)

testProvider :: OpenAIConfig
testProvider = OpenAIConfig "fake" "base-model" "http://localhost" "provider-secret" OpenAICompatible ThinkingDisabled Nothing (Just 65536)

testSettings :: Settings
testSettings =
  either (error . Text.unpack) id (resolveSettings (Map.singleton "DEEPSEEK_API_KEY" "super-secret-key-123"))

resolveFields :: Assertion
resolveFields =
  sequence_
    [ resolveThreadConfig emptyThreadConfig global @?= global,
      resolveThreadConfig session emptyThreadConfig @?= session,
      resolveThreadConfig session global
        @?= emptyThreadConfig
          { configCwd = CwdPath "/global",
            configSystemPrompt = Just "session",
            configModel = Just "global-model",
            configReasoningEffort = Just Max,
            configFs = Just False,
            configMemory = Just True
          }
    ]
  where
    session = emptyThreadConfig {configSystemPrompt = Just "session", configFs = Just False}
    global =
      emptyThreadConfig
        { configCwd = CwdPath "/global",
          configSystemPrompt = Just "global",
          configModel = Just "global-model",
          configReasoningEffort = Just Max,
          configMemory = Just True
        }

cwdStateJson :: Assertion
cwdStateJson =
  sequence_
    [ decodeConfig "{}" @?= Right CwdInherit,
      decodeConfig "{\"cwd\":null}" @?= Right CwdNone,
      decodeConfig "{\"cwd\":\"/work\"}" @?= Right (CwdPath "/work"),
      decodeConfig "{\"cwdMode\":\"inherit\",\"cwd\":null}" @?= Right CwdInherit,
      decodeConfig "{\"cwdMode\":\"none\",\"cwd\":\"/ignored\"}" @?= Right CwdNone,
      decodeConfig "{\"cwdMode\":\"path\",\"cwd\":\"/chosen\"}" @?= Right (CwdPath "/chosen"),
      eitherDecode (encode (emptyThreadConfig {configCwd = CwdNone})) @?= Right (emptyThreadConfig {configCwd = CwdNone}),
      eitherDecode (encode (emptyThreadConfig {configCwd = CwdPath "/chosen"})) @?= Right (emptyThreadConfig {configCwd = CwdPath "/chosen"})
    ]
  where
    decodeConfig bytes = configCwd <$> (eitherDecode bytes :: Either String ThreadConfig)

reasoningEffortJson :: Assertion
reasoningEffortJson =
  sequence_
    [ eitherDecode "{\"reasoningEffort\":\"low\"}" @?= Right (emptyThreadConfig {configReasoningEffort = Just Low}),
      eitherDecode (encode (emptyThreadConfig {configReasoningEffort = Just Max})) @?= Right (emptyThreadConfig {configReasoningEffort = Just Max}),
      case eitherDecode "{\"reasoningEffort\":\"medium\"}" :: Either String ThreadConfig of
        Left _ -> pure ()
        Right _ -> assertFailure "medium should be rejected"
    ]

cwdOverridesGlobal :: Assertion
cwdOverridesGlobal =
  withWorkDir $ \globalDir ->
    let localDir = globalDir ++ "/local"
        global = emptyThreadConfig {configCwd = CwdPath globalDir}
        effective session = resolveThreadConfig session global
     in createDirectoryIfMissing True localDir
          *> TextIO.writeFile (globalDir ++ "/global.txt") "global"
          *> TextIO.writeFile (localDir ++ "/local.txt") "local"
          *> newTlsManager >>= \manager ->
            testRuntime okModel [] Parallel >>= \base ->
              (,,)
                <$> resolveRuntime manager testProvider Nothing base (effective emptyThreadConfig) Map.empty Map.empty
                <*> resolveRuntime manager testProvider Nothing base (effective (emptyThreadConfig {configCwd = CwdNone})) Map.empty Map.empty
                <*> resolveRuntime manager testProvider Nothing base (effective (emptyThreadConfig {configCwd = CwdPath localDir})) Map.empty Map.empty
                >>= \(inherited, cleared, replaced) ->
                  callRuntimeList inherited >>= \globalList ->
                    callRuntimeList replaced >>= \localList ->
                      sequence_
                        [ configCwd (effective emptyThreadConfig) @?= CwdPath globalDir,
                          configCwd (effective (emptyThreadConfig {configCwd = CwdNone})) @?= CwdNone,
                          Map.member "fs_list" (runtimeTools inherited) @?= True,
                          Map.member "fs_list" (runtimeTools cleared) @?= False,
                          assertBool "inherited runtime is rooted globally" ("global.txt" `Text.isInfixOf` globalList),
                          assertBool "replacement runtime is rooted locally" ("local.txt" `Text.isInfixOf` localList && not ("global.txt" `Text.isInfixOf` localList))
                        ]
  where
    callRuntimeList runtime =
      maybe (assertFailure "missing fs_list") pure (Map.lookup "fs_list" (runtimeTools runtime))
        >>= \backend ->
          runBackendTool backend (ToolContext "run" "thread" "call" (const (pure ())) Nothing) (object [])
            <&> toolOutcomeContent

fileStoreRoundTrip :: Assertion
fileStoreRoundTrip =
  withWorkDir $ \dir ->
    newThreadConfigStore dir >>= \store ->
      threadConfigWrite store "th/read:me" saved
        *> (threadConfigRead store "th/read:me" >>= (@?= saved))
        *> (doesFileExist (dir ++ "/threads-config/th-read-me.json") >>= assertBool "config file uses the sanitized name")
        *> (newThreadConfigStore dir >>= \reopened -> threadConfigRead reopened "th/read:me" >>= (@?= saved))
        *> (threadConfigRead store "absent" >>= (@?= emptyThreadConfig))
  where
    saved =
      emptyThreadConfig
        { configCwd = CwdPath "/work",
          configSystemPrompt = Just "prompt",
          configModel = Just "model-x",
          configReasoningEffort = Just Low,
          configFs = Just False,
          configShell = Just True,
          configMemory = Just False,
          configContextReserveTokens = Just 4096,
          configContextKeepUnits = Just 8,
          configContextSummaryTokens = Just 1024
        }

toolResolution :: Assertion
toolResolution =
  withWorkDir $ \dir ->
    newTlsManager >>= \manager ->
      newMemoryArtifactStore >>= \artifacts ->
        testRuntime okModel [] Parallel >>= \base ->
          let resolved config = Map.keys . runtimeTools <$> resolveRuntime manager testProvider (Just artifacts) base config Map.empty Map.empty
           in traverse resolved (configs dir) >>= (@?= expected)
  where
    configs dir =
      [ emptyThreadConfig {configCwd = CwdPath dir},
        emptyThreadConfig,
        emptyThreadConfig {configCwd = CwdPath dir, configFs = Just False},
        emptyThreadConfig {configCwd = CwdPath dir, configShell = Just False}
      ]
    expected =
      [ [artifactReadToolName, "fs_edit", "fs_glob", "fs_grep", "fs_list", "fs_read", "fs_write", "plan", "shell", "shell_bg", "shell_kill", "shell_output", "shell_stdin", "sub_agent"],
        [artifactReadToolName, "sub_agent"],
        [artifactReadToolName, "plan", "shell", "shell_bg", "shell_kill", "shell_output", "shell_stdin", "sub_agent"],
        [artifactReadToolName, "fs_edit", "fs_glob", "fs_grep", "fs_list", "fs_read", "fs_write", "plan", "sub_agent"]
      ]

promptAndModel :: Assertion
promptAndModel =
  newTlsManager >>= \manager ->
    testRuntime okModel [] Parallel >>= \base ->
      let resolved config = resolveRuntime manager testProvider Nothing base {runtimeSystemPrompt = "global prompt"} config Map.empty Map.empty
       in (,,) <$> resolved emptyThreadConfig
            <*> resolved emptyThreadConfig {configSystemPrompt = Just "local"}
            <*> resolved emptyThreadConfig {configModel = Just "deepseek-v4-pro"}
            >>= \(global, local, override) ->
              sequence_
                [ runtimeSystemPrompt global @?= "global prompt",
                  runtimeSystemPrompt local @?= "local",
                  modelName (runtimeModel global) @?= "fake",
                  modelName (runtimeModel override) @?= "deepseek-v4-pro"
                ]

reasoningEffortResolution :: Assertion
reasoningEffortResolution =
  newTlsManager >>= \manager ->
    testRuntime okModel [] Parallel >>= \base ->
      let selected =
            emptyThreadConfig
              { configProvider = Just "kimi-coding",
                configReasoningEffort = Just Low
              }
          inherited = emptyThreadConfig {configReasoningEffort = Just Max}
          keys = Map.singleton "kimi-coding" "key"
          effort runtime =
            parseMaybe
              ( withObject "request" $ \request ->
                  (request .: "reasoning_effort")
                    <|> (request .: "reasoning" >>= \reasoning -> reasoning .: "effort")
              )
              (modelRender (runtimeModel runtime) (ModelRequest [] []))
       in (,)
            <$> resolveRuntime manager testProvider Nothing base selected defaultProviders keys
            <*> resolveRuntime manager (settingsProvider testSettings) Nothing base inherited Map.empty Map.empty
            >>= \(kimi, deepseek) ->
              sequence_
                [ modelProvider (runtimeModel kimi) @?= "kimi-coding",
                  effort kimi @?= Just ("low" :: Text),
                  effort deepseek @?= Just ("max" :: Text)
                ]

contextPolicyResolution :: Assertion
contextPolicyResolution =
  newTlsManager >>= \manager ->
    testRuntime okModel [] Parallel >>= \base ->
      let initial = ContextConfig 8192 12 2048 200000
          config =
            emptyThreadConfig
              { configContextReserveTokens = Just 4096,
                configContextKeepUnits = Just 6,
                configContextSummaryTokens = Just 768
              }
       in resolveRuntime manager testProvider Nothing base {runtimeContext = Just initial} config Map.empty Map.empty
            >>= maybe
              (assertFailure "context policy disappeared")
              ( \resolved ->
                  sequence_
                    [ contextReserveTokens resolved @?= 4096,
                      contextKeepUnits resolved @?= 6,
                      contextSummaryTokens resolved @?= 768,
                      contextFallbackChars resolved @?= 200000
                    ]
              )
              . runtimeContext

memoryStripped :: Assertion
memoryStripped =
  newIORef False >>= \called ->
    newTlsManager >>= \manager ->
      testRuntime okModel [] Parallel >>= \base ->
        let hooks config = runtimeHooks <$> resolveRuntime manager testProvider Nothing base {runtimeHooks = business} config Map.empty Map.empty
            business =
              defaultHooks
                { afterRun = \_ _ -> writeIORef called True,
                  getSteeringMessages = const (pure [ChatSystem "steer"])
                }
         in (,) <$> hooks emptyThreadConfig {configMemory = Just False} <*> hooks emptyThreadConfig >>= \(stripped, kept) ->
              afterRun stripped (sampleInput []) []
                *> (readIORef called >>= (@?= False))
                *> (getSteeringMessages stripped (sampleInput []) >>= (@?= []))
                *> afterRun kept (sampleInput []) []
                *> (readIORef called >>= (@?= True))

configApp :: IO (Application, ThreadConfigStore)
configApp =
  newMemoryThreadConfigStore >>= \store ->
    newTlsManager >>= \manager ->
      testRuntime okModel [] Parallel >>= \base ->
        let context =
              ContextConfig
                (settingsContextReserveTokens testSettings)
                (settingsContextKeepUnits testSettings)
                (settingsContextSummaryTokens testSettings)
                (settingsSpliceChars testSettings)
         in pure
              ( application Nothing Nothing (Just (testView store)) Nothing (configResolver store manager base {runtimeContext = Just context}),
                store
              )

testView :: ThreadConfigStore -> ConfigView
testView store = ConfigView (renderGlobalConfig testSettings defaults) store defaults (pure (Right [])) (pure [])
  where
    defaults = globalThreadConfig testSettings

configResolver :: ThreadConfigStore -> Manager -> Runtime -> Text -> IO Runtime
configResolver store manager base threadId =
  threadConfigRead store threadId
    >>= \session ->
      resolveRuntime manager (settingsProvider testSettings) Nothing base (resolveThreadConfig session (globalThreadConfig testSettings)) Map.empty Map.empty

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

configEndpoints :: Assertion
configEndpoints =
  configApp >>= \(app, _) ->
    runSession (srequest (putConfig "t-a" (encode (emptyThreadConfig {configSystemPrompt = Just "prompt-a"})))) app >>= \saved ->
      runSession (request (httpGet ["config", "threads", "t-a"])) app >>= \fetched ->
        runSession (request (httpGet ["config", "threads", "t-unknown"])) app >>= \unknown ->
          sequence_
            [ simpleStatus saved @?= status204,
              either assertFailure (@?= emptyThreadConfig {configSystemPrompt = Just "prompt-a"}) (eitherDecode (simpleBody fetched)),
              either assertFailure (@?= emptyThreadConfig) (eitherDecode (simpleBody unknown))
            ]

configCapabilities :: Assertion
configCapabilities =
  withWorkDir $ \dir ->
    configApp >>= \(app, store) ->
      threadConfigWrite store "capable" (emptyThreadConfig {configCwd = CwdPath dir, configShell = Just False})
        *> runSession (request (httpGet ["config", "threads", "capable", "capabilities"])) app
        >>= \response ->
          sequence_
            [ simpleStatus response @?= status200,
              either
                assertFailure
                ( @?=
                    [ "fs_edit",
                      "fs_glob",
                      "fs_grep",
                      "fs_list",
                      "fs_read",
                      "fs_write",
                      "plan",
                      "sub_agent"
                    ]
                )
                (eitherDecode (simpleBody response) :: Either String [Text])
            ]

configContextPolicy :: Assertion
configContextPolicy =
  configApp >>= \(app, store) ->
    threadConfigWrite
      store
      "contextual"
      ( emptyThreadConfig
          { configContextReserveTokens = Just 4096,
            configContextKeepUnits = Just 6,
            configContextSummaryTokens = Just 768
          }
      )
      *> runSession (request (httpGet ["config", "threads", "contextual", "context"])) app
      >>= \response ->
        case eitherDecode (simpleBody response) of
          Left failure -> assertFailure failure
          Right value ->
            sequence_
              [ simpleStatus response @?= status200,
                parseMaybe (withObject "policy" (.: "enabled")) value @?= Just True,
                parseMaybe (withObject "policy" (.: "reserveTokens")) value @?= Just (4096 :: Int),
                parseMaybe (withObject "policy" (.: "keepUnits")) value @?= Just (6 :: Int),
                parseMaybe (withObject "policy" (.: "summaryTokens")) value @?= Just (768 :: Int),
                ( (\window reserve tools budget -> budget == max 256 (window - reserve - tools))
                    <$> (parseMaybe (withObject "policy" (.: "windowTokens")) value :: Maybe Int)
                    <*> (parseMaybe (withObject "policy" (.: "reserveTokens")) value :: Maybe Int)
                    <*> (parseMaybe (withObject "policy" (.: "toolTokens")) value :: Maybe Int)
                    <*> (parseMaybe (withObject "policy" (.: "budgetTokens")) value :: Maybe Int)
                )
                  @?= Just True
              ]

configRejectsBadCwd :: Assertion
configRejectsBadCwd =
  configApp >>= \(app, store) ->
    runSession (srequest (putConfig "t-b" (encode (emptyThreadConfig {configCwd = CwdPath "/no/such/yuki-dir"})))) app >>= \rejected ->
      threadConfigRead store "t-b" >>= \stored ->
        sequence_ [simpleStatus rejected @?= status400, stored @?= emptyThreadConfig]

configRejectsBadContext :: Assertion
configRejectsBadContext =
  configApp >>= \(app, store) ->
    traverse_
      (reject app store)
      [ ("bad-reserve", emptyThreadConfig {configContextReserveTokens = Just 0}),
        ("bad-keep", emptyThreadConfig {configContextKeepUnits = Just 0}),
        ("bad-summary", emptyThreadConfig {configContextSummaryTokens = Just 95})
      ]
  where
    reject app store (threadId, config) =
      runSession (srequest (putConfig threadId (encode config))) app >>= \rejected ->
        threadConfigRead store threadId >>= \stored ->
          sequence_ [simpleStatus rejected @?= status400, stored @?= emptyThreadConfig]

configRejectsBadEffort :: Assertion
configRejectsBadEffort =
  configApp >>= \(app, store) ->
    runSession (srequest (putConfig "bad-effort" "{\"reasoningEffort\":\"medium\"}")) app >>= \rejected ->
      threadConfigRead store "bad-effort" >>= \stored ->
        sequence_ [simpleStatus rejected @?= status400, stored @?= emptyThreadConfig]

configTreeSymlinks :: Assertion
configTreeSymlinks =
  withSandbox $ \root ->
    configApp >>= \(app, store) ->
      threadConfigWrite store "tree-thread" (emptyThreadConfig {configCwd = CwdPath root})
        *> runSession (request treeRequest) app >>= \response ->
          case eitherDecode (simpleBody response) of
            Left failure -> assertFailure failure
            Right entries ->
              let rendered = Text.intercalate "\n" (entries :: [Text])
               in sequence_
                    [ simpleStatus response @?= status200,
                      assertBool "external symlink remains a leaf" ("linkdir@" `Text.isInfixOf` rendered),
                      assertBool "internal symlink remains a leaf" ("inner@" `Text.isInfixOf` rendered),
                      assertBool "cycle remains a leaf" ("up@" `Text.isInfixOf` rendered),
                      assertBool "outside content is absent" (not ("secret.txt" `Text.isInfixOf` rendered))
                    ]
  where
    treeRequest =
      defaultRequest
        { requestMethod = methodGet,
          pathInfo = ["config", "threads", "tree-thread", "tree"],
          queryString = [("depth", Just "8")]
        }

configPathCompletion :: Assertion
configPathCompletion =
  withWorkDir $ \root ->
    createDirectoryIfMissing True (root ++ "/src")
      *> TextIO.writeFile (root ++ "/src/Main.hs") "main = pure ()"
      *> configApp
      >>= \(app, store) ->
        threadConfigWrite store "paths-thread" (emptyThreadConfig {configCwd = CwdPath root})
          *> runSession
            (srequest (jsonRequest methodPost ["config", "threads", "paths-thread", "paths"] (object ["prefix" .= ("src/M" :: Text)])))
            app
          >>= \response ->
            sequence_
              [ simpleStatus response @?= status200,
                either
                  assertFailure
                  (\paths -> paths @?= ["src/Main.hs"])
                  ( ( eitherDecode (simpleBody response)
                        >>= parseEither (withObject "paths" (.: "paths"))
                    ) ::
                      Either String [Text]
                  )
              ]

configMasksKey :: Assertion
configMasksKey =
  configApp >>= \(app, _) ->
    runSession (request (httpGet ["config"])) app >>= \response ->
      let body = TextEncoding.decodeUtf8 (LazyByteString.toStrict (simpleBody response))
       in sequence_
            [ simpleStatus response @?= status200,
              assertBool "masks the API key" (Text.isInfixOf "＊＊＊" body),
              assertBool "never leaks the API key" (not (Text.isInfixOf "super-secret-key-123" body)),
              assertBool "summarizes the provider" (Text.isInfixOf "deepseek-v4-flash" body)
            ]

perThreadPrompts :: Assertion
perThreadPrompts =
  newMemoryThreadConfigStore >>= \store ->
    newIORef [] >>= \captured ->
      newTlsManager >>= \manager ->
        testRuntime (capturePrompts captured) [] Parallel >>= \base ->
          let app = application Nothing Nothing (Just (testView store)) Nothing (configResolver store manager base)
           in runSession (srequest (putConfig "thread-a" (encode (emptyThreadConfig {configSystemPrompt = Just "prompt-a"})))) app
                *> runSession (srequest (putConfig "thread-b" (encode (emptyThreadConfig {configSystemPrompt = Just "prompt-b"})))) app
                *> runSession (srequest (agentPost "thread-a")) app
                *> runSession (srequest (agentPost "thread-b")) app
                *> (readIORef captured >>= verify)
  where
    verify [forB, forA] =
      sequence_ [systemHead forA @?= Just "prompt-a", systemHead forB @?= Just "prompt-b"]
    verify other = assertFailure ("unexpected request count: " <> show (length other))
    systemHead messages = case messages of
      (ChatSystem text : _) -> Just text
      _ -> Nothing

capturePrompts :: IORef [[ChatMessage]] -> Model
capturePrompts captured =
  fakeModel $ \request emit ->
    modifyIORef' captured (requestMessages request :) *> emit (ModelTextDelta "ok") $> Stop

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
        runtimeSteer = const (pure []),
        runtimeFollowUp = const (pure [])
      }

collectEvents :: Runtime -> RunAgentInput -> IO [Event]
collectEvents runtime input = newIORef [] >>= collect
  where
    collect events =
      runAgent runtime input (\event -> modifyIORef' events (event :))
        *> (reverse <$> readIORef events)

decodeEventType :: ByteString -> IO Text
decodeEventType payload =
  either
    (\message -> assertFailure message $> "")
    pure
    (eitherDecodeStrict' payload >>= parseEither (withObject "event" (.: "type")))

takeEnd :: Int -> [value] -> [value]
takeEnd count values = drop (length values - count) values

infixl 4 <$$>

(<$$>) :: (Functor outer, Functor inner) => (a -> b) -> outer (inner a) -> outer (inner b)
(<$$>) = fmap . fmap

transcriptTests :: TestTree
transcriptTests =
  testGroup
    "transcripts"
    [ testCase "maps chat messages to AG-UI messages and back" aguiRoundTrip,
      testCase "file store filters system, persists under a sanitized name and reloads" storeRoundTrip,
      testCase "file store preserves a Wake Packet across reload" wakePacketRoundTrip,
      testCase "a.b and a-b remain physically isolated across thread stores" threadIdPhysicalIsolation,
      testCase "serves the transcript as AG-UI messages, 404 when unknown" transcriptOverHttp,
      testCase "root runs persist the transcript, sub runs do not overwrite it" rootOnlyWrites
    ]

transcriptHistory :: [ChatMessage]
transcriptHistory =
  [ ChatUser "hi",
    ChatAssistant (AssistantTurn "m-1" (Just "working") (Just "thinking") [ModelToolCall "c-1" "echo" "{\"x\":1}"]),
    ChatToolResult "c-1" "echoed",
    ChatAssistant (AssistantTurn "m-2" (Just "done") Nothing [])
  ]

aguiRoundTrip :: Assertion
aguiRoundTrip =
  sequence_
    [ toAguiMessages transcriptHistory @?= agui,
      toChatMessages (toAguiMessages transcriptHistory) @?= Right transcriptHistory,
      toAguiMessages (ChatSystem "injected" : transcriptHistory) @?= agui
    ]
  where
    agui =
      [ User (UserMessage "tr-0" (UserText "hi") Nothing),
        Reasoning (ReasoningMessage "tr-1-reasoning" "thinking" Nothing),
        Assistant (AssistantMessage "m-1" (Just "working") Nothing [ToolCall "c-1" (FunctionCall "echo" "{\"x\":1}") Nothing]),
        Tool (ToolMessage "tr-2" "echoed" "c-1" Nothing Nothing),
        Assistant (AssistantMessage "m-2" (Just "done") Nothing [])
      ]

storeRoundTrip :: Assertion
storeRoundTrip =
  withWorkDir $ \dir ->
    newTranscriptStore dir >>= \store ->
      transcriptSave store "th/read:me" (ChatSystem "injected briefing" : transcriptHistory)
        *> (transcriptLoad store "th/read:me" >>= (@?= Just transcriptHistory))
        *> (doesFileExist (dir ++ "/transcripts/th-read-me.json") >>= assertBool "transcript file uses the sanitized name")
        *> (newTranscriptStore dir >>= \reopened -> transcriptLoad reopened "th/read:me" >>= (@?= Just transcriptHistory))
        *> (transcriptLoad store "absent" >>= (@?= Nothing))

wakePacketRoundTrip :: Assertion
wakePacketRoundTrip =
  withWorkDir $ \dir ->
    let packet = ChatSystem (wakePacketMarker <> "\nContinue from the retained open loop.")
        retained = [ChatUser "before sleep", packet, ChatAssistant (AssistantTurn "awake" (Just "continued") Nothing [])]
     in newTranscriptStore dir >>= \store ->
          transcriptSave store "sleeping-task" (ChatSystem "ephemeral instruction" : retained)
            *> newTranscriptStore dir
            >>= \reopened ->
              transcriptLoad reopened "sleeping-task" >>= \saved ->
                sequence_
                  [ saved @?= Just retained,
                    fmap toAguiMessages saved
                      @?= Just
                        [ User (UserMessage "tr-0" (UserText "before sleep") Nothing),
                          Developer (DeveloperMessage "tr-1" (wakePacketMarker <> "\nContinue from the retained open loop.") (Just "wake-packet")),
                          Assistant (AssistantMessage "awake" (Just "continued") Nothing [])
                        ]
                  ]

threadIdPhysicalIsolation :: Assertion
threadIdPhysicalIsolation =
  withWorkDir $ \dir ->
    newTranscriptStore dir >>= \transcripts ->
      newThreadConfigStore dir >>= \configs ->
        newThreadStore dir >>= \briefs ->
          let dotHistory = [ChatUser "dot transcript"]
              dashHistory = [ChatUser "dash transcript"]
              dotConfig = emptyThreadConfig {configSystemPrompt = Just "dot config"}
              dashConfig = emptyThreadConfig {configSystemPrompt = Just "dash config"}
              dotBrief = Episode "dot-run" "dot brief" 1
              dashBrief = Episode "dash-run" "dash brief" 2
           in transcriptSave transcripts "a.b" dotHistory
                *> transcriptSave transcripts "a-b" dashHistory
                *> threadConfigWrite configs "a.b" dotConfig
                *> threadConfigWrite configs "a-b" dashConfig
                *> threadSaveEpisode briefs "a.b" dotBrief
                *> threadSaveEpisode briefs "a-b" dashBrief
                *> traverse doesFileExist
                  [ dir ++ "/transcripts/a.b.json",
                    dir ++ "/transcripts/a-b.json",
                    dir ++ "/threads-config/a.b.json",
                    dir ++ "/threads-config/a-b.json",
                    dir ++ "/threads/a.b.json",
                    dir ++ "/threads/a-b.json"
                  ]
                >>= \physical ->
                  newTranscriptStore dir >>= \reopenedTranscripts ->
                    newThreadConfigStore dir >>= \reopenedConfigs ->
                      newThreadStore dir >>= \reopenedBriefs ->
                        (,,,,,)
                          <$> transcriptLoad reopenedTranscripts "a.b"
                          <*> transcriptLoad reopenedTranscripts "a-b"
                          <*> threadConfigRead reopenedConfigs "a.b"
                          <*> threadConfigRead reopenedConfigs "a-b"
                          <*> threadBrief reopenedBriefs "a.b"
                          <*> threadBrief reopenedBriefs "a-b"
                          >>= \(dotTranscript, dashTranscript, storedDotConfig, storedDashConfig, storedDotBrief, storedDashBrief) ->
                            sequence_
                              [ assertBool "thread stores did not create six distinct physical files" (and physical),
                                dotTranscript @?= Just dotHistory,
                                dashTranscript @?= Just dashHistory,
                                storedDotConfig @?= dotConfig,
                                storedDashConfig @?= dashConfig,
                                fmap briefRollingSummary storedDotBrief @?= Just "dot brief",
                                fmap briefRollingSummary storedDashBrief @?= Just "dash brief"
                              ]

transcriptOverHttp :: Assertion
transcriptOverHttp =
  newMemoryTranscriptStore >>= \store ->
    transcriptSave store "thread" (ChatSystem "injected" : transcriptHistory)
      *> testRuntime okModel [] Parallel
      >>= \base ->
        let app = application Nothing (Just (newInspection Nothing Nothing Nothing (Just store))) Nothing Nothing (const (pure base))
         in runSession (request (httpGet ["threads", "thread", "transcript"])) app >>= \found ->
              runSession (request (httpGet ["threads", "unknown", "transcript"])) app >>= \unknown ->
                sequence_
                  [ simpleStatus found @?= status200,
                    simpleStatus unknown @?= status404,
                    either assertFailure (@?= ("thread", toAguiMessages transcriptHistory)) (decodeDocument (simpleBody found))
                  ]
  where
    decodeDocument :: LazyByteString.ByteString -> Either String (Text, [Message])
    decodeDocument body =
      eitherDecode body
        >>= parseEither (withObject "transcript" (\fields -> (,) <$> fields .: "threadId" <*> fields .: "messages"))

rootOnlyWrites :: Assertion
rootOnlyWrites =
  withWorkDir $ \dir ->
    newTranscriptStore dir >>= \store ->
      testRuntime okModel [] Parallel >>= \base ->
        let wired = base {runtimeHooks = transcriptHooks store}
         in collectEvents wired (sampleInput [])
              *> collectEvents wired ((sampleInput []) {runId = "run-sub", runParentId = Just "run"})
              *> (transcriptLoad store "thread" >>= (@?= Just root))
  where
    root = [ChatUser "hello", ChatAssistant (AssistantTurn "id-1" (Just "ok") Nothing [])]
