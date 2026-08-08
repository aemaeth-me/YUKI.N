module Yuki.N.Agent
  ( BackendTool (..),
    artifactReadTool,
    Runtime (..),
    ToolContext (..),
    newId,
    runAgent,
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
    Value,
    eitherDecodeStrict',
    fromJSON,
    object,
    withObject,
    (.:),
    (.=),
  )
import Data.Bifunctor (first)
import Data.Bool (bool)
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Unique (hashUnique, newUnique)
import System.IO (stderr)
import Yuki.N.AGUI.Event (Event (..))
import Yuki.N.AGUI.Types qualified as AGUI
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
import Yuki.N.Model
import Yuki.N.Runs
  ( RunDescriptor (..),
    RunInfo (..),
    RunRegistry,
    cancelRun,
    childrenOf,
    drainSteering,
    withRunRegistrationFor,
    writeCompletion,
  )
import Yuki.N.Runs qualified as Runs

data Runtime = Runtime
  { runtimeModel :: Model,
    runtimeTools :: Map Text BackendTool,
    runtimeToolExecution :: ToolExecution,
    runtimeMaxTurns :: Int,
    runtimeSystemPrompt :: Text,
    runtimeAfterRun :: AGUI.RunAgentInput -> [ChatMessage] -> IO (),
    runtimeNewId :: IO Text,
    runtimeArtifactStore :: Maybe ArtifactStore,
    runtimeBackground :: BackgroundRegistry,
    runtimeSubAgentMaxParallel :: Int,
    runtimeProviderRetries :: Int,
    runtimeFallbacks :: [Model],
    runtimeSplice :: SpliceConfig,
    runtimeContext :: ContextConfig,
    runtimeRuns :: RunRegistry
  }

data BackendTool = BackendTool
  { backendToolSpec :: AGUI.ToolSpec,
    runBackendTool :: ToolContext -> Value -> IO Text
  }

data ToolContext = ToolContext
  { toolContextRunId :: Text,
    toolContextThreadId :: Text,
    toolContextCallId :: Text,
    toolContextEmit :: Event -> IO ()
  }

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
    Error message -> pure ("invalid tool arguments: " <> Text.pack message)
    Success (ArtifactRead identifier) ->
      artifactFetch store identifier
        <&> fromMaybe ("unknown artifact: " <> identifier)

newtype ArtifactRead = ArtifactRead Text

instance FromJSON ArtifactRead where
  parseJSON = withObject "ArtifactRead" $ \fields -> ArtifactRead <$> fields .: "id"

runAgent :: Runtime -> AGUI.RunAgentInput -> (Event -> IO ()) -> IO ()
runAgent runtime input emit =
  newIORef [] >>= registered . settle
 where
  runId = AGUI.runId input
  descriptor = descriptorOf input
  registered = withRunRegistrationFor (runtimeRuns runtime) runId descriptor
  emit' = deliver
  deliver event = try @SomeException (emit event) >>= either relay pure
  relay exception
    | isJust (fromException exception :: Maybe Runs.RunCancelled) = throwIO exception
    | isJust (fromException exception :: Maybe SomeAsyncException) = throwIO exception
    | otherwise = throwIO (DeliveryFailure exception)
  settle checkpoint cancelled =
    newIORef False >>= settled
   where
    settled accounted =
      emit' (RunStarted (AGUI.runThreadId input) runId)
        *> ( (terminal checkpoint cancelled >>= conclude accounted)
               `onException` ( readIORef checkpoint
                                 >>= void
                                   . runAfter accounted
                             )
           )
    conclude accounted = \case
      Completed messages ->
        cascadeChildren
          *> runAfter accounted messages
          >>= closeCompleted messages
      Failed message code ->
        cascadeChildren
          *> readIORef checkpoint
          >>= finishCheckpoint accounted (closeFailed code message)
      Cancelled ->
        cascadeChildren
          *> readIORef checkpoint
          >>= finishCheckpoint accounted closeCancelled
    closeCompleted messages (Left persistenceError) =
      recordCompletion Runs.Completed (finalText messages)
        *> emit' (RunError ("durable run close failed: " <> persistenceError) "PERSISTENCE_ERROR")
    closeCompleted messages (Right ()) =
      recordCompletion Runs.Completed (finalText messages)
        *> emit' (RunFinished (AGUI.runThreadId input) runId)
    closeFailed code message history =
      recordCompletion (Runs.Failed (code <> ": " <> message)) (finalText history)
        *> emit' (RunError message code)
    closeCancelled history =
      recordCompletion Runs.Cancelled (finalText history)
        *> emit' (RunCancelled runId)
    cascadeChildren =
      quietlyOrch "cascade" $
        childrenOf registry runId >>= traverse_ (cancelRun registry . runInfoId)
     where
      registry = runtimeRuns runtime
    recordCompletion outcome result =
      traverse_
        (\parent -> writeCompletion (runtimeRuns runtime) runId parent outcome result)
        (AGUI.runParentId input)
    runAfter accounted messages =
      trySync
        ( once
            accounted
            (runtimeAfterRun runtime input messages)
        )
    finishCheckpoint accounted close history =
      runAfter accounted history *> close history
  terminal checkpoint cancelled =
    bool
      (Completed <$> runCore runtime input emit' checkpoint)
      (pure Cancelled)
      cancelled
      `catches` [ Handler (\Runs.RunCancelled -> pure Cancelled),
                  Handler (\(AgentFailure code message) -> pure (Failed message code)),
                  Handler (\(ProviderFailure message) -> pure (Failed message "PROVIDER_ERROR")),
                  Handler (\(DeliveryFailure exception) -> throwIO exception),
                  Handler (\(exception :: SomeAsyncException) -> throwIO exception),
                  Handler (\(exception :: SomeException) -> pure (Failed (Text.pack (displayException exception)) "UNHANDLED_ERROR"))
                ]
trySync :: IO value -> IO (Either Text value)
trySync action =
  try @SomeException action >>= outcome
 where
  outcome (Right value) = pure (Right value)
  outcome (Left exception) =
    maybe
      (pure (Left (Text.pack (displayException exception))))
      throwIO
      (fromException exception :: Maybe SomeAsyncException)

data Terminal
  = Completed [ChatMessage]
  | Failed Text Text
  | Cancelled

finalText :: [ChatMessage] -> Text
finalText =
  Text.take 4000
    . fromMaybe ""
    . listToMaybe
    . reverse
    . mapMaybe assistantText
 where
  assistantText (ChatAssistant turn) = nonEmpty =<< turnText turn
  assistantText _ = Nothing

quietlyOrch :: Text -> IO () -> IO ()
quietlyOrch label action =
  try @SomeException action >>= report
 where
  report (Left exception) =
    maybe
      (TextIO.hPutStrLn stderr ("yuki.orch: " <> label <> ": " <> Text.pack (displayException exception)))
      throwIO
      (fromException exception :: Maybe SomeAsyncException)
  report (Right ()) = pure ()

descriptorOf :: AGUI.RunAgentInput -> RunDescriptor
descriptorOf input =
  RunDescriptor
    (AGUI.runParentId input)
    (objectiveOf input)

objectiveOf :: AGUI.RunAgentInput -> Maybe Text
objectiveOf input =
  Text.take 120 <$> listToMaybe [AGUI.userContent message | AGUI.User message <- AGUI.runMessages input]

newtype ContextOverflow = ContextOverflow ProviderFailure
  deriving stock Show

instance Exception ContextOverflow

once :: IORef Bool -> IO () -> IO ()
once ref action = atomicModifyIORef' ref (True,) >>= bool action (pure ())

newId :: IO Text
newId = liftA2 renderId timestamp (hashUnique <$> newUnique)

timestamp :: IO Integer
timestamp = round . (* 1000000) <$> getPOSIXTime

renderId :: Integer -> Int -> Text
renderId micros unique =
  "yuki-" <> Text.pack (show micros) <> "-" <> Text.pack (show unique)

data AgentFailure = AgentFailure Text Text
  deriving stock Show

instance Exception AgentFailure

newtype DeliveryFailure = DeliveryFailure SomeException
  deriving stock Show

instance Exception DeliveryFailure

runCore :: Runtime -> AGUI.RunAgentInput -> (Event -> IO ()) -> IORef [ChatMessage] -> IO [ChatMessage]
runCore runtime input emit checkpoint =
  mkContext >>= start
 where
  tools = availableTools runtime
  mkContext =
    RunContext (AGUI.runId input) (AGUI.runThreadId input)
      <$> newIORef Map.empty
      <*> newIORef Map.empty

  start runContext =
    loop runContext 1 (initialMessages runtime input)

  loop runContext stepNum history
    | stepNum > runtimeMaxTurns runtime =
        throwIO
          ( AgentFailure
              "MAX_TURNS_EXCEEDED"
              ( "YUKI.N stopped this run after reaching its configured limit of "
                  <> Text.pack (show (runtimeMaxTurns runtime))
                  <> " model turns (YUKI_MAX_TURNS); this local guard prevents unbounded model/tool loops."
              )
          )
    | otherwise =
        steering >>= afterSteer stepNum . (history <>)
   where
    afterSteer step history' =
      spliceContext runtime runContext history' >>= afterSplice step
    afterSplice step spliced =
      emitContextStatus runtime tools False spliced emit
        *> compactContext runtime tools False emit spliced
        >>= afterCompact step
    afterCompact step compacted =
      writeIORef checkpoint compacted *> modelTurn step compacted

    modelTurn turn messages =
      emit (StepStarted "model")
        *> request messages
        >>= uncurry (finishTurn turn)
     where
      request base =
        ((,) base <$> streamTurn runtime base tools emit) `catch` recover base
      recover base (ContextOverflow cause) =
        emitContextStatus runtime tools True base emit
          *> compactContext runtime tools True emit base
          >>= restream
       where
        restream compacted =
          (,) compacted <$> (streamTurn runtime compacted tools emit `catch` unwrap)
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
            *> executeTools runtime runContext calls emit
            >>= finishTools turn messages

    answer _ _ ToolUse =
      throwIO (ProviderFailure "provider reported tool use without a tool call")
    answer turn messages _ = continueAfterAnswer turn messages

    finishTools turn messages results =
      emit (StepFinished "tools")
        *> loop runContext (turn + 1) (messages <> results)

    continueAfterAnswer turn messages =
      steering >>= continueSteering
     where
      next = turn + 1
      continueSteering [] = pure messages
      continueSteering extra = loop runContext next (messages <> extra)

    steering = drainSteering (runtimeRuns runtime) (AGUI.runId input)

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

spliceContext :: Runtime -> RunContext -> [ChatMessage] -> IO [ChatMessage]
spliceContext runtime runContext messages =
  maybe (pure messages) (stub (runtimeSplice runtime)) (runtimeArtifactStore runtime)
 where
  stub config store
    | historyChars messages <= spliceChars config = pure messages
    | otherwise =
        traverse (stubOne store) (spliceTargets (spliceKeep config) messages) >>= finish
  stubOne store (index, callId, content) =
    toolNameOf callId >>= saveSplice
   where
    saveSplice name =
      artifactSave store content >>= finishSplice name
    finishSplice name identifier =
      let stubbed = artifactStub identifier name content
       in pure (index, ChatToolResult callId stubbed)
  toolNameOf callId = Map.findWithDefault "tool" callId <$> readIORef (runContextNames runContext)
  finish done =
    pure [Map.findWithDefault message index replaced | (index, message) <- zip [0 ..] messages]
   where
    replaced = Map.fromList done

compactContext :: Runtime -> [AGUI.ToolSpec] -> Bool -> (Event -> IO ()) -> [ChatMessage] -> IO [ChatMessage]
compactContext runtime tools emergency emit messages =
  maybe (pure messages) materialize (planCompaction runtime emergency tools messages)
 where
  materialize =
    materializeCompaction runtime >=> record
  record compaction =
    emit
      ( Custom
          "context.compact"
          ( object
              [ "beforeTokens" .= compactionBeforeTokens compaction,
                "afterTokens" .= compactionAfterTokens compaction
              ]
          )
      )
      $> compactionMessages compaction

planCompaction :: Runtime -> Bool -> [AGUI.ToolSpec] -> [ChatMessage] -> Maybe Compaction
planCompaction runtime emergency =
  bool
    compactMessages
    emergencyCompactMessages
    emergency
    (runtimeContext runtime)
    (runtimeContextWindow runtime)

materializeCompaction :: Runtime -> Compaction -> IO Compaction
materializeCompaction runtime initial =
  maybe
    (pure initial)
    (\store -> artifactSave store (compactionPayload initial) <&> flip attachCompactionArtifact initial)
    (runtimeArtifactStore runtime)

emitContextStatus :: Runtime -> [AGUI.ToolSpec] -> Bool -> [ChatMessage] -> (Event -> IO ()) -> IO ()
emitContextStatus runtime tools emergency messages emit =
  emit
    ( Custom
        "context.status"
        ( object
            [ "tokens" .= before,
              "budgetTokens" .= budget,
              "willCompact" .= (before > budget),
              "emergency" .= emergency
            ]
        )
    )
 where
  config = runtimeContext runtime
  normal = contextBudget config (runtimeContextWindow runtime) tools
  budget = bool normal (max 256 (normal `div` 2)) emergency
  before = estimateMessagesTokens messages

runtimeContextWindow :: Runtime -> Int
runtimeContextWindow = minimum . fmap modelContextTokens . liftA2 (:) runtimeModel runtimeFallbacks

initialMessages :: Runtime -> AGUI.RunAgentInput -> [ChatMessage]
initialMessages runtime input =
  prefix <> toChatMessages (AGUI.runMessages input)
 where
  prefix =
    [ChatSystem prompt | let prompt = runtimeSystemPrompt runtime, not (Text.null prompt)]

toChatMessages :: [AGUI.Message] -> [ChatMessage]
toChatMessages (AGUI.Reasoning reasoning : AGUI.Assistant assistant : rest) =
  assistantMessage (Just (AGUI.reasoningContent reasoning)) assistant : toChatMessages rest
toChatMessages (AGUI.System system : rest) =
  ChatSystem (AGUI.systemContent system) : toChatMessages rest
toChatMessages (AGUI.Assistant assistant : rest) =
  assistantMessage Nothing assistant : toChatMessages rest
toChatMessages (AGUI.User user : rest) =
  ChatUser (AGUI.userContent user) : toChatMessages rest
toChatMessages (AGUI.Tool tool : rest) =
  ChatToolResult (AGUI.toolMessageCallId tool) (AGUI.toolMessageContent tool) : toChatMessages rest
toChatMessages (AGUI.Reasoning _ : rest) = toChatMessages rest
toChatMessages [] = []

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

availableTools :: Runtime -> [AGUI.ToolSpec]
availableTools = fmap backendToolSpec . Map.elems . runtimeTools

data ResponseState = ResponseState
  { responseText :: Text,
    responseTextStarted :: Bool,
    responseReasoning :: Text,
    responseReasoningOpen :: Bool,
    responseReasoningClosed :: Bool,
    responseTools :: Map Int PendingToolCall
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
      responseTools = Map.empty
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
  maxAttempts = max 1 (runtimeProviderRetries runtime)
  models = runtimeModel runtime : runtimeFallbacks runtime
  begin (messageId, reasoningId) =
    newIORef emptyResponse
      >>= chain messageId reasoningId models
  chain _ _ [] _ = throwIO (ProviderFailure "provider chain exhausted")
  chain messageId reasoningId (model : rest) stateRef =
    attempt messageId reasoningId model rest 1 stateRef
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
      | otherwise = demote messageId reasoningId rest stateRef cause
    delayMs = 1000 * 2 ^ (trial - 1)
    backoff = threadDelay (delayMs * 1000)
    announce (ProviderFailure reason) =
      emit
        ( Custom
            "provider.retry"
            ( object
                [ "attempt" .= trial,
                  "maxAttempts" .= maxAttempts,
                  "reason" .= reason
                ]
            )
        )
  demote messageId reasoningId rest stateRef cause =
    readIORef stateRef >>= advance rest
   where
    advance fallbacks@(_ : _) state
      | state == emptyResponse =
          chain messageId reasoningId fallbacks stateRef
    advance _ _ = throwIO cause
  consume messageId reasoningId stateRef event =
    readIORef stateRef >>= accept
   where
    accept state =
      either throwIO commit (stepModelEvent messageId reasoningId state event)
    commit (state', events) = writeIORef stateRef state' *> traverse_ emit events
  finish messageId reasoningId stateRef reason =
    readIORef stateRef >>= either throwIO commit . closeModelTurn messageId reasoningId
   where
    commit (events, turn) = traverse_ emit events $> (reason, turn)

stepModelEvent ::
  Text ->
  Text ->
  ResponseState ->
  ModelEvent ->
  Either ProviderFailure (ResponseState, [Event])
stepModelEvent messageId reasoningId state = \case
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
    let (state', events) = applyToolDelta state index callId name arguments
     in Right
          ( state' {responseReasoningOpen = False, responseReasoningClosed = True},
            reasoningEnds reasoningId state <> events
          )

reasoningEnds :: Text -> ResponseState -> [Event]
reasoningEnds reasoningId state =
  [ReasoningMessageEnded reasoningId | responseReasoningOpen state]
    <> [ReasoningEnded reasoningId | responseReasoningOpen state]

applyToolDelta ::
  ResponseState ->
  Int ->
  Maybe Text ->
  Maybe Text ->
  Text ->
  (ResponseState, [Event])
applyToolDelta state index callId name arguments =
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
          [ToolCallStarted identifier toolName]
            <> [ToolCallArguments identifier (pendingArguments current) | not (Text.null (pendingArguments current))]

closeModelTurn ::
  Text ->
  Text ->
  ResponseState ->
  Either ProviderFailure ([Event], AssistantTurn)
closeModelTurn messageId reasoningId state =
  traverse closeTool (sortOn fst (Map.toList (responseTools state)))
    <&> assemble
 where
  assemble closed =
    ( reasoningEnds reasoningId state
        <> [TextMessageEnded messageId | responseTextStarted state]
        <> concatMap fst closed,
      AssistantTurn
        { turnMessageId = messageId,
          turnText = nonEmpty (responseText state),
          turnReasoning = nonEmpty (responseReasoning state),
          turnToolCalls = fmap snd closed
        }
    )
  closeTool (_, PendingToolCall (Just identifier) (Just name) arguments started) =
    Right
      ( [ToolCallStarted identifier name | not started]
          <> [ToolCallArguments identifier arguments | not started && not (Text.null arguments)]
          <> [ToolCallEnded identifier],
        modelTool identifier name arguments
      )
  closeTool _ = Left (ProviderFailure "provider returned an incomplete tool call")

modelTool :: Text -> Text -> Text -> ModelToolCall
modelTool identifier name arguments =
  ModelToolCall
    { modelToolCallId = identifier,
      modelToolName = name,
      modelToolArguments = arguments
    }

data PreparedTool
  = Execute ModelToolCall BackendTool Value ToolContext
  | Resolve ModelToolCall Text

data RunContext = RunContext
  { runContextRunId :: Text,
    runContextThreadId :: Text,
    runContextSeen :: IORef (Map Text (Text, Text)),
    runContextNames :: IORef (Map Text Text)
  }

executeTools ::
  Runtime ->
  RunContext ->
  [ModelToolCall] ->
  (Event -> IO ()) ->
  IO [ChatMessage]
executeTools runtime runContext calls emit =
  traverse prepare calls >>= resolveAll (runtimeToolExecution runtime) >>= traverse emitResult
 where
  prepare call =
    either
      (pure . Resolve call)
      (pure . dispatch call)
      (decodeArguments call)

  dispatch call arguments =
    maybe
      (Resolve call ("unknown tool: " <> modelToolName call))
      (\tool -> Execute call tool arguments (context call))
      (Map.lookup (modelToolName call) (runtimeTools runtime))

  context call =
    ToolContext
      { toolContextRunId = runContextRunId runContext,
        toolContextThreadId = runContextThreadId runContext,
        toolContextCallId = modelToolCallId call,
        toolContextEmit = emit
      }

  resolveAll Sequential = traverse resolve
  resolveAll Parallel = mapConcurrently resolve

  resolve = \case
    Execute call tool arguments toolContext ->
      (call,) <$> safely (runBackendTool tool toolContext arguments)
    Resolve call outcome -> pure (call, outcome)

  emitResult (call, content) = runtimeNewId runtime >>= emitResolved call content

  emitResolved call content messageId =
    present (modelToolName call) content
      >>= announce
   where
    announce presented =
      ChatToolResult (modelToolCallId call) presented
        <$ modifyIORef' (runContextNames runContext) (Map.insert (modelToolCallId call) (modelToolName call))
        <* emit (ToolCallResult messageId (modelToolCallId call) content)

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
        artifactSave store content >>= storeResult
      storeResult identifier =
        content <$ modifyIORef' (runContextSeen runContext) (Map.insert key (identifier, content))

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

safely :: IO Text -> IO Text
safely action =
  try @SomeException action >>= either recover pure
 where
  recover exception =
    maybe
      (pure (Text.pack (displayException exception)))
      throwIO
      (rethrowable exception)
  rethrowable exception =
    ((fromException exception :: Maybe SomeAsyncException) $> exception)
      <|> ((fromException exception :: Maybe Runs.RunCancelled) $> exception)

nonEmpty :: Text -> Maybe Text
nonEmpty text = bool (Just text) Nothing (Text.null text)
