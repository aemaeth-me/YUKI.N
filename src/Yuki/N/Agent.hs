module Yuki.N.Agent
  ( AgentHooks (..),
    BackendTool (..),
    RunOutcome (..),
    artifactReadTool,
    ResponseState,
    Runtime (..),
    ToolContext (..),
    ToolExecution (..),
    ToolOutcome (..),
    closeModelTurn,
    compactHistory,
    defaultHooks,
    emptyResponse,
    failAgent,
    forcedCompaction,
    historyChars,
    jsonTool,
    newId,
    runAgent,
    runtimeContextWindow,
    spliceTargets,
    stepModelEvent,
    toChatMessages,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently)
import Control.Exception
import Control.Monad (void, (>=>))
import Data.Aeson
  ( FromJSON (..),
    Result (..),
    ToJSON,
    Value,
    eitherDecodeStrict',
    encode,
    fromJSON,
    object,
    withObject,
    (.:),
    (.=),
  )
import Data.Bifunctor (first)
import Data.Bool (bool)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.IORef
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (catMaybes, fromMaybe, isJust, maybeToList)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Unique (hashUnique, newUnique)
import Yuki.N.AGUI.Event (Event (..))
import qualified Yuki.N.AGUI.Types as AGUI
import Yuki.N.Artifact
  ( ArtifactStore (..),
    SpliceConfig (..),
    artifactIdFor,
    artifactReadToolName,
    artifactStub,
    isArtifactStub,
    stubThreshold,
  )
import Yuki.N.Background (BackgroundRegistry)
import Yuki.N.Context
import Yuki.N.Journal
import Yuki.N.Model
import Yuki.N.Runs (RunCancelled (..), RunRegistry, drainFollowUps, drainSteering, withRunRegistrationFor)

data Runtime = Runtime
  { runtimeModel :: Model,
    runtimeTools :: Map Text BackendTool,
    runtimeToolExecution :: ToolExecution,
    runtimeMaxTurns :: Int,
    runtimeSystemPrompt :: Text,
    runtimeHooks :: AgentHooks,
    runtimeNewId :: IO Text,
    runtimeJournal :: Maybe Journal,
    runtimeArtifactStore :: Maybe ArtifactStore,
    runtimeBackground :: BackgroundRegistry,
    runtimeDepth :: Int,
    runtimeProviderRetries :: Int,
    runtimeFallbacks :: [Model],
    runtimeSplice :: Maybe SpliceConfig,
    runtimeContext :: Maybe ContextConfig,
    runtimeRuns :: Maybe RunRegistry,
    runtimeSteer :: Int -> IO [ChatMessage],
    runtimeFollowUp :: Int -> IO [ChatMessage]
  }

data BackendTool = BackendTool
  { backendToolSpec :: AGUI.ToolSpec,
    runBackendTool :: ToolContext -> Value -> IO ToolOutcome
  }

data ToolContext = ToolContext
  { toolContextRunId :: Text,
    toolContextThreadId :: Text,
    toolContextCallId :: Text,
    toolContextEmit :: Event -> IO (),
    toolContextJournal :: Maybe Journal
  }

data AgentHooks = AgentHooks
  { transformContext :: AGUI.RunAgentInput -> [ChatMessage] -> IO [ChatMessage],
    observeEvent :: AGUI.RunAgentInput -> Event -> IO (),
    shouldSleep :: AGUI.RunAgentInput -> IO Bool,
    afterCompaction :: AGUI.RunAgentInput -> Int -> Bool -> Bool -> [ChatMessage] -> Compaction -> IO Compaction,
    getSteeringMessages :: AGUI.RunAgentInput -> IO [ChatMessage],
    getFollowUpMessages :: AGUI.RunAgentInput -> IO [ChatMessage],
    beforeToolCall :: ModelToolCall -> IO (Either Text ()),
    afterToolCall :: ModelToolCall -> ToolOutcome -> IO ToolOutcome,
    afterRunOutcome :: AGUI.RunAgentInput -> RunOutcome -> [ChatMessage] -> IO (),
    afterRun :: AGUI.RunAgentInput -> [ChatMessage] -> IO ()
  }

data RunOutcome
  = RunSucceeded
  | RunFailed Text Text
  | RunWasCancelled
  deriving stock (Eq, Show)

defaultHooks :: AgentHooks
defaultHooks =
  AgentHooks
    { transformContext = const pure,
      observeEvent = \_ _ -> pure (),
      shouldSleep = const (pure False),
      afterCompaction = \_ _ _ _ _ -> pure,
      getSteeringMessages = const (pure []),
      getFollowUpMessages = const (pure []),
      beforeToolCall = const (pure (Right ())),
      afterToolCall = const pure,
      afterRunOutcome = \_ _ _ -> pure (),
      afterRun = \_ _ -> pure ()
    }

instance Semigroup AgentHooks where
  left <> right =
    AgentHooks
      { transformContext = \input -> transformContext left input >=> transformContext right input,
        observeEvent = \input event -> observeEvent left input event *> observeEvent right input event,
        shouldSleep = \input -> liftA2 (||) (shouldSleep left input) (shouldSleep right input),
        afterCompaction = \input step emergency forced messages ->
          afterCompaction left input step emergency forced messages
            >=> afterCompaction right input step emergency forced messages,
        getSteeringMessages = \input -> liftA2 (<>) (getSteeringMessages left input) (getSteeringMessages right input),
        getFollowUpMessages = \input -> liftA2 (<>) (getFollowUpMessages left input) (getFollowUpMessages right input),
        beforeToolCall = \call ->
          beforeToolCall left call >>= either (pure . Left) (const (beforeToolCall right call)),
        afterToolCall = \call -> afterToolCall left call >=> afterToolCall right call,
        afterRunOutcome = \input outcome messages ->
          afterRunOutcome left input outcome messages *> afterRunOutcome right input outcome messages,
        afterRun = \input messages -> afterRun left input messages *> afterRun right input messages
      }

instance Monoid AgentHooks where
  mempty = defaultHooks

jsonTool :: (FromJSON input, ToJSON output) => AGUI.ToolSpec -> (input -> IO (Either Text output)) -> BackendTool
jsonTool spec execute = BackendTool spec (const (decode . fromJSON))
  where
    decode = \case
      Error message -> pure (failure ("invalid tool arguments: " <> Text.pack message))
      Success input ->
        execute input
          <&> either failure (success . TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode)

artifactReadTool :: ArtifactStore -> BackendTool
artifactReadTool store = BackendTool spec (const readBack)
  where
    spec =
      AGUI.ToolSpec
        artifactReadToolName
        "read back a stored tool result by artifact id"
        ( object
            [ "type" .= ("object" :: Text),
              "properties" .= object ["id" .= object ["type" .= ("string" :: Text)]],
              "required" .= (["id"] :: [Text]),
              "additionalProperties" .= False
            ]
        )
    readBack arguments = case fromJSON arguments of
      Error message -> pure (failure ("invalid tool arguments: " <> Text.pack message))
      Success (ArtifactRead identifier) ->
        artifactFetch store identifier
          >>= maybe (pure (failure ("unknown artifact: " <> identifier))) (pure . success)

newtype ArtifactRead = ArtifactRead Text

instance FromJSON ArtifactRead where
  parseJSON = withObject "ArtifactRead" $ \fields -> ArtifactRead <$> fields .: "id"

runAgent :: Runtime -> AGUI.RunAgentInput -> (Event -> IO ()) -> IO ()
runAgent runtime input emit =
  newIORef [] >>= \checkpoint ->
    maybe id (\registry -> withRunRegistrationFor registry runId (AGUI.runThreadId input)) (runtimeRuns runtime) (settle checkpoint)
  where
    runId = AGUI.runId input
    journal = subJournal runId <$> runtimeJournal runtime
    runtime' =
      runtime
        { runtimeJournal = journal,
          runtimeNewId = maybe (runtimeNewId runtime) (`journalNewId` runtimeNewId runtime) journal,
          runtimeSteer = maybe (runtimeSteer runtime) (\registry _ -> drainSteering registry runId) (runtimeRuns runtime),
          runtimeFollowUp = maybe (runtimeFollowUp runtime) (\registry _ -> drainFollowUps registry runId) (runtimeRuns runtime)
        }
    emit' event = recordMaybe journal (AgentEventEntry event) *> observeEvent hooks input event *> emit event
    hooks = runtimeHooks runtime
    settle checkpoint =
      newIORef False >>= \accounted ->
        recordMaybe journal (RunBegin input (runSettingsOf runtime))
          *> emit' (RunStarted (AGUI.runThreadId input) runId (AGUI.runParentId input))
          *> ( (terminal checkpoint >>= conclude accounted)
                 `onException` ( readIORef checkpoint
                                   >>= void
                                     . runAfter
                                       accounted
                                       (RunFailed "UNHANDLED_ERROR" "run aborted by an unhandled exception")
                               )
             )
      where
        conclude accounted = \case
          Completed messages ->
            runAfter accounted RunSucceeded messages >>= \case
              Left persistenceError -> emit' (RunError ("durable run close failed: " <> persistenceError) (Just "PERSISTENCE_ERROR"))
              Right () -> emit' (RunFinished (AGUI.runThreadId input) runId Nothing)
          Failed message code ->
            bestEffortAfter accounted (RunFailed code message) (readIORef checkpoint)
              *> emit' (RunError message (Just code))
          Cancelled ->
            bestEffortAfter accounted RunWasCancelled (readIORef checkpoint)
              *> emit' (Custom "run.cancelled" (object ["runId" .= runId]))
              *> emit' (RunFinished (AGUI.runThreadId input) runId Nothing)
        runAfter accounted outcome messages =
          trySync
            ( once
                accounted
                (afterRunOutcome hooks input outcome messages *> afterRun hooks input messages)
            )
        bestEffortAfter accounted outcome load =
          load >>= runAfter accounted outcome >>= \case
            Left persistenceError ->
              emit'
                ( Custom
                    "run.persistence_error"
                    (object ["runId" .= runId, "message" .= persistenceError])
                )
            Right () -> pure ()
    terminal checkpoint =
      (Completed <$> runCore runtime' input emit' checkpoint)
        `catches` [ Handler (\RunCancelled {} -> pure Cancelled),
                    Handler (\(AgentFailure message) -> pure (Failed message "AGENT_ERROR")),
                    Handler (\(ProviderFailure message) -> pure (Failed message "PROVIDER_ERROR"))
                  ]
trySync :: IO value -> IO (Either Text value)
trySync action =
  try @SomeException action >>= \case
    Right value -> pure (Right value)
    Left exception ->
      maybe
        (pure (Left (Text.pack (displayException exception))))
        throwIO
        (fromException exception :: Maybe SomeAsyncException)

data Terminal
  = Completed [ChatMessage]
  | Failed Text Text
  | Cancelled

newtype ContextOverflow = ContextOverflow ProviderFailure
  deriving stock (Show)

instance Exception ContextOverflow

once :: IORef Bool -> IO () -> IO ()
once ref action = atomicModifyIORef' ref (\done -> (True, done)) >>= bool action (pure ())

runSettingsOf :: Runtime -> RunSettings
runSettingsOf runtime =
  RunSettings
    { runSettingsMaxTurns = runtimeMaxTurns runtime,
      runSettingsToolExecution = runtimeToolExecution runtime,
      runSettingsSystemPrompt = runtimeSystemPrompt runtime,
      runSettingsDepth = runtimeDepth runtime,
      runSettingsSplice = runtimeSplice runtime,
      runSettingsContext = runtimeContext runtime,
      runSettingsContextTokens = runtimeContextWindow runtime
    }

newId :: IO Text
newId = liftA2 renderId timestamp (hashUnique <$> newUnique)

timestamp :: IO Integer
timestamp = round . (* 1000000) <$> getPOSIXTime

renderId :: Integer -> Int -> Text
renderId micros unique =
  "yuki-" <> Text.pack (show micros) <> "-" <> Text.pack (show unique)

newtype AgentFailure = AgentFailure Text
  deriving stock (Show)

instance Exception AgentFailure

failAgent :: Text -> IO value
failAgent = throwIO . AgentFailure

runCore :: Runtime -> AGUI.RunAgentInput -> (Event -> IO ()) -> IORef [ChatMessage] -> IO [ChatMessage]
runCore runtime input emit checkpoint =
  mkContext
    >>= \runContext ->
      either (throwIO . AgentFailure) pure (initialMessages runtime input) >>= loop runContext 1
  where
    hooks = runtimeHooks runtime
    tools = availableTools runtime input
    clientTools = Set.fromList (AGUI.toolName <$> AGUI.runTools input)
    mkContext =
      RunContext (AGUI.runId input) (AGUI.runThreadId input) (runtimeJournal runtime)
        <$> newIORef Map.empty
        <*> newIORef Map.empty

    loop runContext stepNum history
      | stepNum > runtimeMaxTurns runtime =
          throwIO (AgentFailure "maximum agent turns exceeded")
      | otherwise =
          runtimeSteer runtime stepNum >>= appendSteering stepNum history >>= \history' ->
            spliceContext runtime runContext history'
              >>= \(spliced, events) ->
                traverse_ emit events
                  *> emitContextStatus runtime tools False spliced emit
                  *> compactContext runtime input runContext stepNum tools False emit spliced
                  >>= \compacted ->
                    writeIORef checkpoint compacted
                      *> ( transformContext hooks input compacted
                             >>= \transformed ->
                               traverse_ emit (injected compacted transformed) *> modelTurn stepNum compacted transformed
                         )
      where
        modelTurn turn messages transformed =
          emit (StepStarted "model")
            *> request messages transformed
            >>= uncurry (finishTurn turn)
          where
            request base context =
              ((,) base <$> streamTurn runtime context tools emit) `catch` recover base
            recover base (ContextOverflow cause) =
              emitContextStatus runtime tools True base emit
                *> compactContext runtime input runContext turn tools True emit base
                >>= \compacted ->
                  transformContext hooks input compacted
                    >>= \transformed' ->
                      traverse_ emit (injected compacted transformed')
                        *> ((,) compacted <$> (streamTurn runtime transformed' tools emit `catch` unwrap))
              where
                unwrap (ContextOverflow _) = throwIO cause

        finishTurn turn messages (finishReason, assistant) =
          emit (StepFinished "model")
            *> advance turn (messages <> [ChatAssistant assistant]) finishReason (turnToolCalls assistant)

        advance turn messages finishReason calls
          | null calls = answer turn messages finishReason
          | finishReason == Length =
              failTruncated runtime calls emit >>= loop runContext (turn + 1) . (messages <>)
          | otherwise =
              emit (StepStarted "tools")
                *> executeTools runtime runContext clientTools calls emit
                >>= finishTools turn messages

        answer _ _ ToolUse =
          throwIO (ProviderFailure "provider reported tool use without a tool call")
        answer turn messages _ = continueAfterAnswer turn messages

        finishTools turn messages (results, awaitsFrontend, terminate) =
          emit (StepFinished "tools")
            *> bool (loop runContext (turn + 1) final) (pure final) (awaitsFrontend || terminate)
          where
            final = messages <> results

        continueAfterAnswer turn messages =
          liftA2 (<>) (runtimeSteer runtime next) (getSteeringMessages hooks input) >>= continueSteering
          where
            next = turn + 1
            continueSteering [] =
              liftA2 (<>) (runtimeFollowUp runtime next) (getFollowUpMessages hooks input) >>= continueFollowUp
            continueSteering extra = appendSteering next messages extra >>= loop runContext next
            continueFollowUp [] = pure messages
            continueFollowUp extra = appendFollowUp next messages extra >>= loop runContext next

        appendSteering = appendQueued "steering.inject" SteeringEntry
        appendFollowUp = appendQueued "followup.inject" FollowUpEntry
        appendQueued _ _ _ base [] = pure base
        appendQueued kind entry step base extra =
          recordMaybe (runtimeJournal runtime) (entry step extra)
            *> emit (Custom kind (object ["step" .= step, "count" .= length extra]))
            $> base <> extra

injected :: [ChatMessage] -> [ChatMessage] -> [Event]
injected before after =
  [ Custom "context.inject" (object ["content" .= text])
    | ChatSystem text <- after,
      ChatSystem text `notElem` before
  ]

historyChars :: [ChatMessage] -> Int
historyChars = sum . fmap messageChars
  where
    messageChars (ChatSystem text) = Text.length text
    messageChars (ChatUser text) = Text.length text
    messageChars (ChatToolResult _ content) = Text.length content
    messageChars (ChatAssistant turn) =
      maybe 0 Text.length (turnText turn)
        + maybe 0 Text.length (turnReasoning turn)
        + sum (Text.length . modelToolArguments <$> turnToolCalls turn)

spliceTargets :: Int -> [ChatMessage] -> [(Int, Text, Text)]
spliceTargets keep messages =
  [target | target@(_, _, content) <- aged, not (isArtifactStub content), Text.length content >= stubThreshold]
  where
    aged = dropLast keep [(index, callId, content) | (index, ChatToolResult callId content) <- zip [0 ..] messages]

dropLast :: Int -> [value] -> [value]
dropLast count values = take (length values - count) values

spliceContext :: Runtime -> RunContext -> [ChatMessage] -> IO ([ChatMessage], [Event])
spliceContext runtime runContext messages =
  maybe (pure (messages, [])) stub ((,) <$> runtimeArtifactStore runtime <*> runtimeSplice runtime)
  where
    stub (store, config)
      | historyChars messages <= spliceChars config = pure (messages, [])
      | otherwise =
          traverse (stubOne store) (spliceTargets (spliceKeep config) messages) >>= finish config
    stubOne store (index, callId, content) =
      toolNameOf callId >>= \name ->
        artifactSave store name content >>= \identifier ->
          let stubbed = artifactStub identifier name content
           in pure ((index, ChatToolResult callId stubbed), Text.length content - Text.length stubbed)
    toolNameOf callId = Map.findWithDefault "tool" callId <$> readIORef (runContextNames runContext)
    finish config done =
      pure
        ( [Map.findWithDefault message index replaced | (index, message) <- zip [0 ..] messages],
          [ Custom
              "context.splice"
              (object ["stubbed" .= length done, "savedChars" .= saved, "keep" .= spliceKeep config])
            | not (null done)
          ]
        )
      where
        replaced = Map.fromList (fmap fst done)
        saved = sum (fmap snd done)

compactContext :: Runtime -> AGUI.RunAgentInput -> RunContext -> Int -> [AGUI.ToolSpec] -> Bool -> (Event -> IO ()) -> [ChatMessage] -> IO [ChatMessage]
compactContext runtime input runContext step tools emergency emit messages =
  shouldSleep hooks input >>= \forced ->
    maybe (pure messages) (materialize forced) (planned forced)
  where
    hooks = runtimeHooks runtime
    planned forced =
      planCompaction runtime emergency tools messages
        <|> if forced then forcedCompaction runtime tools messages else Nothing
    materialize forced =
      materializeCompaction runtime
        >=> afterCompaction hooks input step emergency forced messages
        >=> record forced
    record forced compaction =
      recordMaybe
        (runContextJournal runContext)
        ( ContextCompactEntry
            step
            (compactionBeforeTokens compaction)
            (compactionAfterTokens compaction)
            (compactionBudgetTokens compaction)
            (length (compactionDropped compaction))
            emergency
            (compactionSummary compaction)
        )
        *> emit
          ( Custom
              "context.compact"
              ( object
                  [ "step" .= step,
                    "beforeTokens" .= compactionBeforeTokens compaction,
                    "afterTokens" .= compactionAfterTokens compaction,
                    "budgetTokens" .= compactionBudgetTokens compaction,
                    "droppedMessages" .= length (compactionDropped compaction),
                    "keptUnits" .= compactionKeptUnits compaction,
                    "emergency" .= emergency,
                    "sleep" .= isWakePacket compaction,
                    "selfRequested" .= forced
                  ]
              )
          )
        *> traverse_
          ( const
              ( emit
                  ( Custom
                      "context.sleep"
                      ( object
                          [ "step" .= step,
                            "emergency" .= emergency,
                            "selfRequested" .= forced,
                            "beforeTokens" .= compactionBeforeTokens compaction,
                            "afterTokens" .= compactionAfterTokens compaction
                          ]
                      )
                  )
              )
          )
          [() | isWakePacket compaction]
        $> compactionMessages compaction

forcedCompaction :: Runtime -> [AGUI.ToolSpec] -> [ChatMessage] -> Maybe Compaction
forcedCompaction runtime tools messages =
  runtimeContext runtime >>= \config ->
    let budget = max 64 (min (contextBudget config (runtimeContextWindow runtime) tools) (estimateMessagesTokens messages * 2 `div` 3))
     in Just
          ( fromMaybe
              (syntheticCompaction budget messages)
              (compactToBudget config budget messages)
          )

syntheticCompaction :: Int -> [ChatMessage] -> Compaction
syntheticCompaction budget messages =
  Compaction
    { compactionMessages = leading <> [ChatSystem contextSummaryMarker] <> body,
      compactionDropped = [],
      compactionBeforeTokens = before,
      compactionAfterTokens = estimateMessagesTokens (leading <> [ChatSystem contextSummaryMarker] <> body),
      compactionBudgetTokens = budget,
      compactionKeptUnits = length body,
      compactionSummary = contextSummaryMarker,
      compactionPayload = "self-requested sleep without token-pressure compaction"
    }
  where
    before = estimateMessagesTokens messages
    (leading, body) = span systemMessage messages
    systemMessage ChatSystem {} = True
    systemMessage _ = False

isWakePacket :: Compaction -> Bool
isWakePacket = Text.isPrefixOf "[wake packet" . compactionSummary

compactHistory :: Runtime -> Bool -> [ChatMessage] -> IO (Maybe Compaction)
compactHistory runtime emergency messages =
  maybe (pure Nothing) (fmap Just . materializeCompaction runtime) planned
  where
    tools = backendToolSpec <$> Map.elems (runtimeTools runtime)
    planned = planCompaction runtime emergency tools messages

planCompaction :: Runtime -> Bool -> [AGUI.ToolSpec] -> [ChatMessage] -> Maybe Compaction
planCompaction runtime emergency tools messages =
  runtimeContext runtime >>= \config ->
    (if emergency then emergencyCompactMessages else compactMessages)
      config
      (runtimeContextWindow runtime)
      tools
      messages

materializeCompaction :: Runtime -> Compaction -> IO Compaction
materializeCompaction runtime initial =
  maybe
    (pure initial)
    (\store -> artifactSave store "context_compaction" (compactionPayload initial) <&> flip attachCompactionArtifact initial)
    (runtimeArtifactStore runtime)

emitContextStatus :: Runtime -> [AGUI.ToolSpec] -> Bool -> [ChatMessage] -> (Event -> IO ()) -> IO ()
emitContextStatus runtime tools emergency messages emit =
  traverse_
    ( \config ->
        let normal = contextBudget config (runtimeContextWindow runtime) tools
            budget =
              bool
                normal
                (max 256 (normal `div` 2))
                emergency
            before = estimateMessagesTokens messages
            window = contextWindow config (runtimeContextWindow runtime)
            toolTokens = estimateToolsTokens tools
         in emit
              ( Custom
                  "context.status"
                  ( object
                      [ "tokens" .= before,
                        "windowTokens" .= window,
                        "reserveTokens" .= contextReserveTokens config,
                        "toolTokens" .= toolTokens,
                        "budgetTokens" .= budget,
                        "willCompact" .= (before > budget),
                        "emergency" .= emergency
                      ]
                  )
              )
    )
    (runtimeContext runtime)

runtimeContextWindow :: Runtime -> Maybe Int
runtimeContextWindow runtime =
  case catMaybes (modelContextTokens <$> runtimeModel runtime : runtimeFallbacks runtime) of
    [] -> Nothing
    windows -> Just (minimum windows)

initialMessages :: Runtime -> AGUI.RunAgentInput -> Either Text [ChatMessage]
initialMessages runtime input =
  (prefix <>) <$> toChatMessages (AGUI.runMessages input)
  where
    prefix =
      [ ChatSystem text
        | text <- [runtimeSystemPrompt runtime, renderContext (AGUI.runContext input)],
          not (Text.null text)
      ]

renderContext :: [AGUI.ContextItem] -> Text
renderContext =
  Text.intercalate "\n\n"
    . fmap (\item -> AGUI.contextDescription item <> ":\n" <> AGUI.contextValue item)

toChatMessages :: [AGUI.Message] -> Either Text [ChatMessage]
toChatMessages (AGUI.Reasoning reasoning : AGUI.Assistant assistant : rest) =
  (assistantMessage (Just (AGUI.reasoningContent reasoning)) assistant :) <$> toChatMessages rest
toChatMessages (AGUI.Developer developer : rest) =
  (ChatSystem (AGUI.developerContent developer) :) <$> toChatMessages rest
toChatMessages (AGUI.System system : rest) =
  (ChatSystem (AGUI.systemContent system) :) <$> toChatMessages rest
toChatMessages (AGUI.Assistant assistant : rest) =
  (assistantMessage Nothing assistant :) <$> toChatMessages rest
toChatMessages (AGUI.User user : rest) =
  AGUI.userText (AGUI.userContent user)
    >>= \text -> (ChatUser text :) <$> toChatMessages rest
toChatMessages (AGUI.Tool tool : rest) =
  (ChatToolResult (AGUI.toolMessageCallId tool) (AGUI.toolMessageContent tool) :)
    <$> toChatMessages rest
toChatMessages (AGUI.Activity _ : rest) = toChatMessages rest
toChatMessages (AGUI.Reasoning _ : rest) = toChatMessages rest
toChatMessages [] = Right []

assistantMessage :: Maybe Text -> AGUI.AssistantMessage -> ChatMessage
assistantMessage reasoning message =
  ChatAssistant
    AssistantTurn
      { turnMessageId = AGUI.assistantId message,
        turnText = AGUI.assistantContent message,
        turnReasoning = reasoning,
        turnToolCalls = fmap toolCall (AGUI.assistantToolCalls message)
      }
  where
    toolCall call =
      ModelToolCall
        { modelToolCallId = AGUI.toolCallId call,
          modelToolName = AGUI.functionName (AGUI.toolCallFunction call),
          modelToolArguments = AGUI.functionArguments (AGUI.toolCallFunction call)
        }

availableTools :: Runtime -> AGUI.RunAgentInput -> [AGUI.ToolSpec]
availableTools runtime input = reverse . snd $ foldl add (Set.empty, []) candidates
  where
    candidates = (backendToolSpec <$> Map.elems (runtimeTools runtime)) <> AGUI.runTools input
    add (seen, tools) tool
      | AGUI.toolName tool `Set.member` seen = (seen, tools)
      | otherwise = (Set.insert (AGUI.toolName tool) seen, tool : tools)

data ResponseState = ResponseState
  { responseText :: Text,
    responseTextStarted :: Bool,
    responseReasoning :: Text,
    responseReasoningOpen :: Bool,
    responseReasoningClosed :: Bool,
    responseTools :: Map Int PendingToolCall,
    responseUsage :: Maybe Usage
  }
  deriving stock Eq

data PendingToolCall = PendingToolCall
  { pendingId :: Maybe Text,
    pendingName :: Maybe Text,
    pendingArguments :: Text,
    pendingStarted :: Bool
  }
  deriving stock Eq

emptyResponse :: ResponseState
emptyResponse =
  ResponseState
    { responseText = "",
      responseTextStarted = False,
      responseReasoning = "",
      responseReasoningOpen = False,
      responseReasoningClosed = False,
      responseTools = Map.empty,
      responseUsage = Nothing
    }

emptyPendingTool :: PendingToolCall
emptyPendingTool =
  PendingToolCall
    { pendingId = Nothing,
      pendingName = Nothing,
      pendingArguments = "",
      pendingStarted = False
    }

streamTurn ::
  Runtime ->
  [ChatMessage] ->
  [AGUI.ToolSpec] ->
  (Event -> IO ()) ->
  IO (FinishReason, AssistantTurn)
streamTurn runtime messages tools emit =
  liftA2 (,) (runtimeNewId runtime) (runtimeNewId runtime) >>= begin
  where
    request = ModelRequest {requestMessages = messages, requestTools = tools}
    journal = runtimeJournal runtime
    maxAttempts = max 1 (runtimeProviderRetries runtime)
    models = runtimeModel runtime : runtimeFallbacks runtime
    begin (messageId, reasoningId) =
      recordMaybe journal (ModelRequestEntry request)
        *> newIORef emptyResponse
        >>= chain messageId reasoningId models
    chain _ _ [] _ = throwIO (ProviderFailure "provider chain exhausted")
    chain messageId reasoningId (model : rest) stateRef =
      recordMaybe journal (ApiRequestEntry (modelRender model request))
        *> attempt messageId reasoningId model rest 1 stateRef
    attempt messageId reasoningId model rest trial stateRef =
      try (streamModel model request (consume messageId reasoningId stateRef))
        >>= either (retry messageId reasoningId model rest trial stateRef) (finish messageId reasoningId stateRef)
    retry messageId reasoningId model rest trial stateRef cause =
      readIORef stateRef
        >>= decide
      where
        decide state
          | state == emptyResponse && isContextOverflow cause = throwIO (ContextOverflow cause)
          | state == emptyResponse && trial < maxAttempts =
              announce cause *> backoff *> attempt messageId reasoningId model rest (trial + 1) stateRef
          | otherwise = demote messageId reasoningId model rest stateRef cause
        delayMs = 1000 * 2 ^ (trial - 1)
        backoff = threadDelay (delayMs * 1000)
        announce (ProviderFailure reason) =
          emit
            ( Custom
                "provider.retry"
                ( object
                    [ "attempt" .= trial,
                      "maxAttempts" .= maxAttempts,
                      "delayMs" .= delayMs,
                      "reason" .= reason
                    ]
                )
            )
    demote messageId reasoningId model rest stateRef cause =
      readIORef stateRef >>= \state -> advance state rest
      where
        advance state (next : remaining)
          | state == emptyResponse =
              crossover model next cause *> chain messageId reasoningId (next : remaining) stateRef
        advance _ _ = throwIO cause
    crossover from to (ProviderFailure reason) =
      emit
        ( Custom
            "provider.fallback"
            ( object
                [ "from" .= (modelProvider from <> "/" <> modelName from),
                  "to" .= (modelProvider to <> "/" <> modelName to),
                  "reason" .= reason
                ]
            )
        )
    consume messageId reasoningId stateRef event =
      recordMaybe journal (ModelEventEntry event)
        *> ( readIORef stateRef
               >>= \state -> either throwIO commit (stepModelEvent messageId reasoningId state event)
           )
      where
        commit (state', events) = writeIORef stateRef state' *> traverse_ emit events
    finish messageId reasoningId stateRef reason =
      recordMaybe journal (ModelFinishEntry reason)
        *> (readIORef stateRef >>= either throwIO commit . closeModelTurn messageId reasoningId)
      where
        commit (events, turn) = traverse_ emit events *> pure (reason, turn)

stepModelEvent ::
  Text ->
  Text ->
  ResponseState ->
  ModelEvent ->
  Either ProviderFailure (ResponseState, [Event])
stepModelEvent messageId reasoningId state = \case
  ModelUsage usage -> Right (state {responseUsage = Just usage}, [])
  ModelReasoningDelta delta
    | Text.null delta -> Right (state, [])
    | responseReasoningClosed state ->
        Left (ProviderFailure "provider resumed reasoning after final content began")
    | otherwise ->
        Right
          ( state
              { responseReasoning = responseReasoning state <> delta,
                responseReasoningOpen = True
              },
            [ReasoningStarted reasoningId | not (responseReasoningOpen state)]
              <> [ReasoningMessageStarted reasoningId | not (responseReasoningOpen state)]
              <> [ReasoningMessageContent reasoningId delta]
          )
  ModelTextDelta delta
    | Text.null delta -> Right (state, [])
    | otherwise ->
        Right
          ( state
              { responseText = responseText state <> delta,
                responseTextStarted = True,
                responseReasoningOpen = False,
                responseReasoningClosed = True
              },
            reasoningEnds reasoningId state
              <> [TextMessageStarted messageId | not (responseTextStarted state)]
              <> [TextMessageContent messageId delta]
          )
  ModelToolCallDelta index callId name arguments ->
    let (state', events) = applyToolDelta messageId state index callId name arguments
     in Right
          ( state' {responseReasoningOpen = False, responseReasoningClosed = True},
            reasoningEnds reasoningId state <> events
          )

reasoningEnds :: Text -> ResponseState -> [Event]
reasoningEnds reasoningId state =
  [ReasoningMessageEnded reasoningId | responseReasoningOpen state]
    <> [ReasoningEnded reasoningId | responseReasoningOpen state]

applyToolDelta ::
  Text ->
  ResponseState ->
  Int ->
  Maybe Text ->
  Maybe Text ->
  Text ->
  (ResponseState, [Event])
applyToolDelta messageId state index callId name arguments =
  (state {responseTools = Map.insert index current' (responseTools state)}, announcements)
  where
    old = Map.findWithDefault emptyPendingTool index (responseTools state)
    current =
      old
        { pendingId = callId <|> pendingId old,
          pendingName = name <|> pendingName old,
          pendingArguments = pendingArguments old <> arguments
        }
    ready = (,) <$> pendingId current <*> pendingName current
    current' = current {pendingStarted = pendingStarted old || isJust ready}
    announcements = case ready of
      Nothing -> []
      Just (identifier, toolName)
        | pendingStarted old ->
            [ToolCallArguments identifier arguments | not (Text.null arguments)]
        | otherwise ->
            [ToolCallStarted identifier toolName (Just messageId)]
              <> [ToolCallArguments identifier (pendingArguments current) | not (Text.null (pendingArguments current))]

closeModelTurn ::
  Text ->
  Text ->
  ResponseState ->
  Either ProviderFailure ([Event], AssistantTurn)
closeModelTurn messageId reasoningId state =
  traverse closeTool (sortOn fst (Map.toList (responseTools state)))
    <&> \closed ->
      ( reasoningEnds reasoningId state
          <> [TextMessageEnded messageId | responseTextStarted state]
          <> concatMap fst closed
          <> maybeToList (usageEvent <$> responseUsage state),
        AssistantTurn
          { turnMessageId = messageId,
            turnText = nonEmpty (responseText state),
            turnReasoning = nonEmpty (responseReasoning state),
            turnToolCalls = fmap snd closed
          }
      )
  where
    closeTool (_, PendingToolCall (Just identifier) (Just name) arguments started) =
      Right
        ( [ToolCallStarted identifier name (Just messageId) | not started]
            <> [ToolCallArguments identifier arguments | not started && not (Text.null arguments)]
            <> [ToolCallEnded identifier],
          modelTool identifier name arguments
        )
    closeTool _ = Left (ProviderFailure "provider returned an incomplete tool call")

usageEvent :: Usage -> Event
usageEvent usage =
  Custom
    "usage"
    ( object
        [ "promptTokens" .= usagePromptTokens usage,
          "completionTokens" .= usageCompletionTokens usage,
          "cacheHitTokens" .= usageCacheHitTokens usage,
          "cacheMissTokens" .= usageCacheMissTokens usage
        ]
    )

modelTool :: Text -> Text -> Text -> ModelToolCall
modelTool identifier name arguments =
  ModelToolCall
    { modelToolCallId = identifier,
      modelToolName = name,
      modelToolArguments = arguments
    }

data PreparedTool
  = Execute ModelToolCall BackendTool Value ToolContext
  | Resolve ModelToolCall ToolOutcome
  | Defer ModelToolCall

data ResolvedTool
  = Resolved ModelToolCall ToolOutcome
  | Deferred

data RunContext = RunContext
  { runContextRunId :: Text,
    runContextThreadId :: Text,
    runContextJournal :: Maybe Journal,
    runContextSeen :: IORef (Map Text (Text, Text)),
    runContextNames :: IORef (Map Text Text)
  }

executeTools ::
  Runtime ->
  RunContext ->
  Set Text ->
  [ModelToolCall] ->
  (Event -> IO ()) ->
  IO ([ChatMessage], Bool, Bool)
executeTools runtime runContext clientTools calls emit =
  traverse prepare calls >>= resolveAll (runtimeToolExecution runtime) >>= conclude
  where
    hooks = runtimeHooks runtime

    prepare call =
      either
        (pure . Resolve call . failure)
        (authorize call)
        (decodeArguments call)

    authorize call arguments =
      beforeToolCall hooks call
        >>= either
          (pure . Resolve call . failure)
          (const (pure (dispatch call arguments)))

    dispatch call arguments =
      maybe
        (missing call)
        (\tool -> Execute call tool arguments (context call))
        (Map.lookup (modelToolName call) (runtimeTools runtime))

    context call =
      ToolContext
        { toolContextRunId = runContextRunId runContext,
          toolContextThreadId = runContextThreadId runContext,
          toolContextCallId = modelToolCallId call,
          toolContextEmit = emit,
          toolContextJournal = runContextJournal runContext
        }

    missing call
      | modelToolName call `Set.member` clientTools = Defer call
      | otherwise = Resolve call (failure ("unknown tool: " <> modelToolName call))

    resolveAll Sequential = traverse resolve
    resolveAll Parallel = mapConcurrently resolve

    resolve = \case
      Execute call tool arguments toolContext ->
        Resolved call <$> (safely (runBackendTool tool toolContext arguments) >>= afterToolCall hooks call)
      Resolve call outcome -> pure (Resolved call outcome)
      Defer _ -> pure Deferred

    emitResult = \case
      Deferred -> pure Nothing
      Resolved call outcome -> runtimeNewId runtime >>= emitResolved call outcome

    emitResolved call outcome messageId =
      present (modelToolName call) (toolOutcomeContent outcome)
        >>= \content ->
          Just (ChatToolResult (modelToolCallId call) content)
            <$ modifyIORef' (runContextNames runContext) (Map.insert (modelToolCallId call) (modelToolName call))
            <* recordMaybe
              (runContextJournal runContext)
              (ToolCallEntry (modelToolCallId call) (modelToolName call) (modelToolArguments call) outcome)
            <* emit (ToolCallResult messageId (modelToolCallId call) (toolOutcomeContent outcome))

    present name content =
      maybe (pure content) dedup (runtimeArtifactStore runtime)
      where
        dedup store
          | name == artifactReadToolName = pure content
          | Text.length content < stubThreshold = pure content
          | "\n[artifact art-" `Text.isInfixOf` content = pure content
          | otherwise =
              readIORef (runContextSeen runContext) >>= decide . Map.lookup key
          where
            key = artifactIdFor content
            decide (Just (identifier, original))
              | original == content = pure (artifactStub identifier name content)
            decide _ = retain
            retain =
              artifactSave store name content
                >>= \identifier ->
                  content <$ modifyIORef' (runContextSeen runContext) (Map.insert key (identifier, content))

    conclude resolved =
      traverse emitResult resolved
        <&> \results ->
          let outcomes = [outcome | Resolved _ outcome <- resolved]
              awaitsFrontend = any isDeferred resolved
              terminate = not (null outcomes) && all toolOutcomeTerminate outcomes && not awaitsFrontend
           in (catMaybes results, awaitsFrontend, terminate)

failTruncated :: Runtime -> [ModelToolCall] -> (Event -> IO ()) -> IO [ChatMessage]
failTruncated runtime calls emit =
  traverse failCall calls
  where
    message = "tool call was not executed because its arguments were truncated"
    failCall call = runtimeNewId runtime >>= record call
    record call messageId =
      ChatToolResult (modelToolCallId call) message
        <$ emit (ToolCallResult messageId (modelToolCallId call) message)

decodeArguments :: ModelToolCall -> Either Text Value
decodeArguments call =
  first
    (\message -> "invalid JSON arguments for " <> modelToolName call <> ": " <> Text.pack message)
    (eitherDecodeStrict' (TextEncoding.encodeUtf8 (modelToolArguments call)))

safely :: IO ToolOutcome -> IO ToolOutcome
safely action =
  (try action :: IO (Either SomeException ToolOutcome)) >>= either recover pure
  where
    recover exception =
      maybe
        (pure (failure (Text.pack (displayException exception))))
        throwIO
        (rethrowable exception)
    rethrowable exception =
      ((fromException exception :: Maybe SomeAsyncException) $> exception)
        <|> ((fromException exception :: Maybe RunCancelled) $> exception)

isDeferred :: ResolvedTool -> Bool
isDeferred Deferred = True
isDeferred _ = False

success :: Text -> ToolOutcome
success content = ToolOutcome content False False

failure :: Text -> ToolOutcome
failure content = ToolOutcome content True False

nonEmpty :: Text -> Maybe Text
nonEmpty text = bool (Just text) Nothing (Text.null text)
