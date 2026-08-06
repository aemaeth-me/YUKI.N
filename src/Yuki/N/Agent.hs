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
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, listToMaybe, mapMaybe, maybeToList)
import Data.Set (Set)
import Data.Set qualified as Set
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
  ( RunCancelled (..),
    RunDescriptor (..),
    RunInfo (..),
    RunKind (..),
    RunRegistry,
    cancelRun,
    childrenOf,
    drainFollowUps,
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
    runtimeHooks :: AgentHooks,
    runtimeNewId :: IO Text,
    runtimeArtifactStore :: Maybe ArtifactStore,
    runtimeBackground :: BackgroundRegistry,
    runtimeDepth :: Int,
    runtimeSubAgentMaxParallel :: Int,
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
    toolContextEmit :: Event -> IO ()
  }

newtype AgentHooks = AgentHooks
  { afterRun :: AGUI.RunAgentInput -> [ChatMessage] -> IO ()
  }

data RunOutcome
  = RunSucceeded
  | RunFailed Text Text
  | RunWasCancelled
  deriving stock (Eq, Show)

defaultHooks :: AgentHooks
defaultHooks = AgentHooks {afterRun = \_ _ -> pure ()}

instance Semigroup AgentHooks where
  left <> right =
    AgentHooks
      { afterRun = \input messages -> afterRun left input messages *> afterRun right input messages
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
  newIORef [] >>= registered . settle
 where
  runId = AGUI.runId input
  descriptor = descriptorOf input
  registered = maybe id (\registry -> withRunRegistrationFor registry runId descriptor) (runtimeRuns runtime)
  runtime' =
    runtime
      { runtimeSteer = maybe (runtimeSteer runtime) (\registry _ -> drainSteering registry runId) (runtimeRuns runtime),
        runtimeFollowUp = maybe (runtimeFollowUp runtime) (\registry _ -> drainFollowUps registry runId) (runtimeRuns runtime)
      }
  emit' = deliver
  hooks = runtimeHooks runtime
  deliver event = try @SomeException (emit event) >>= either relay pure
  relay exception
    | isJust (fromException exception :: Maybe RunCancelled) = throwIO exception
    | isJust (fromException exception :: Maybe SomeAsyncException) = throwIO exception
    | otherwise = throwIO (DeliveryFailure exception)
  settle checkpoint =
    newIORef False >>= settled
   where
    settled accounted =
      emit' (RunStarted (AGUI.runThreadId input) runId (AGUI.runParentId input))
        *> ( (terminal checkpoint >>= conclude accounted)
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
          *> bestEffortAfter accounted (readIORef checkpoint)
          *> readIORef checkpoint
          >>= closeFailed code message
      Cancelled ->
        cascadeChildren
          *> bestEffortAfter accounted (readIORef checkpoint)
          *> readIORef checkpoint
          >>= closeCancelled
    closeCompleted messages (Left persistenceError) =
      recordCompletion Runs.Completed (finalText messages)
        *> emit' (RunError ("durable run close failed: " <> persistenceError) (Just "PERSISTENCE_ERROR"))
    closeCompleted messages (Right ()) =
      recordCompletion Runs.Completed (finalText messages)
        *> emit' (RunFinished (AGUI.runThreadId input) runId Nothing)
    closeFailed code message history =
      recordCompletion (failureOutcome code message) (finalText history)
        *> emit' (RunError message (Just code))
    closeCancelled history =
      recordCompletion Runs.Cancelled (finalText history)
        *> emit' (Custom "run.cancelled" (object ["runId" .= runId]))
        *> emit' (RunFinished (AGUI.runThreadId input) runId Nothing)
    cascadeChildren =
      quietlyOrch "cascade" $
        maybe
          (pure ())
          (\registry -> childrenOf registry runId >>= traverse_ (cancelRun registry . runInfoId))
          (runtimeRuns runtime)
    recordCompletion outcome result =
      maybe
        (pure ())
        (\registry -> writeCompletion registry runId (AGUI.runParentId input) outcome result)
        (runtimeRuns runtime)
    runAfter accounted messages =
      trySync
        ( once
            accounted
            (afterRun hooks input messages)
        )
    bestEffortAfter accounted load =
      load >>= runAfter accounted >>= reportPersistence
    reportPersistence (Left persistenceError) =
      emit'
        ( Custom
            "run.persistence_error"
            (object ["runId" .= runId, "message" .= persistenceError])
        )
    reportPersistence (Right ()) = pure ()
  terminal checkpoint =
    (Completed <$> runCore runtime' input emit' checkpoint)
      `catches` [ Handler (\RunCancelled {} -> pure Cancelled),
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

failureOutcome :: Text -> Text -> Runs.CompletionOutcome
failureOutcome code message
  | Text.null code = Runs.Failed message
  | otherwise = Runs.Failed (code <> ": " <> message)

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

workerNotice :: Text -> Maybe (Text, Text, Text)
workerNotice text =
  Text.stripPrefix "[worker " text >>= parse
 where
  parse rest =
    let (worker, afterId) = Text.breakOn " " rest
        (outcome, summary) = Text.breakOn "] " (Text.drop 1 afterId)
     in if Text.null worker || Text.null outcome || Text.null summary
          then Nothing
          else Just (worker, outcome, Text.drop 2 summary)

descriptorOf :: AGUI.RunAgentInput -> RunDescriptor
descriptorOf input =
  RunDescriptor
    (AGUI.runThreadId input)
    ""
    (AGUI.runParentId input)
    (maybe RunTask (const RunWorker) (AGUI.runParentId input))
    (objectiveOf input)

objectiveOf :: AGUI.RunAgentInput -> Maybe Text
objectiveOf input =
  Text.take 120 <$> listToMaybe [text | AGUI.User message <- AGUI.runMessages input, Just text <- [contentText (AGUI.userContent message)]]
 where
  contentText (AGUI.UserText text) = Just text
  contentText (AGUI.UserParts parts) = listToMaybe [text | AGUI.InputText text <- parts]

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

failAgent :: Text -> IO value
failAgent = throwIO . AgentFailure "AGENT_ERROR"

runCore :: Runtime -> AGUI.RunAgentInput -> (Event -> IO ()) -> IORef [ChatMessage] -> IO [ChatMessage]
runCore runtime input emit checkpoint =
  mkContext >>= start
 where
  tools = availableTools runtime input
  clientTools = Set.fromList (AGUI.toolName <$> AGUI.runTools input)
  mkContext =
    RunContext (AGUI.runId input) (AGUI.runThreadId input)
      <$> newIORef Map.empty
      <*> newIORef Map.empty

  start runContext =
    either failAgent pure (initialMessages runtime input) >>= loop runContext 1

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
        runtimeSteer runtime stepNum >>= appendSteering stepNum history >>= afterSteer stepNum
   where
    afterSteer step history' =
      spliceContext runtime runContext history' >>= afterSplice step
    afterSplice step (spliced, events) =
      traverse_ emit events
        *> emitContextStatus runtime tools False spliced emit
        *> compactContext runtime step tools False emit spliced
        >>= afterCompact step
    afterCompact step compacted =
      writeIORef checkpoint compacted *> modelTurn step compacted compacted

    modelTurn turn messages transformed =
      emit (StepStarted "model")
        *> request messages transformed
        >>= uncurry (finishTurn turn)
     where
      request base context =
        ((,) base <$> streamTurn runtime context tools emit) `catch` recover base
      recover base (ContextOverflow cause) =
        emitContextStatus runtime tools True base emit
          *> compactContext runtime turn tools True emit base
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
      runtimeSteer runtime next >>= continueSteering
     where
      next = turn + 1
      continueSteering [] =
        runtimeFollowUp runtime next >>= continueFollowUp
      continueSteering extra = appendSteering next messages extra >>= loop runContext next
      continueFollowUp [] = pure messages
      continueFollowUp extra = appendFollowUp next messages extra >>= loop runContext next

    appendSteering = appendQueued "steering.inject"
    appendFollowUp = appendQueued "followup.inject"
    appendQueued _ _ base [] = pure base
    appendQueued kind step base extra =
      emit (Custom kind (object ["step" .= step, "count" .= length extra]))
        *> traverse_ (emit . workerNoticeEvent) (workerNotices kind)
        $> base <> extra
     where
      workerNotices "steering.inject" = mapMaybe workerNotice [text | ChatSystem text <- extra]
      workerNotices _ = []
      workerNoticeEvent (worker, outcome, summary) =
        Custom
          "worker.notice"
          ( object
              [ "runId" .= worker,
                "parentRunId" .= AGUI.runId input,
                "outcome" .= outcome,
                "summary" .= summary
              ]
          )

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
    toolNameOf callId >>= saveSplice
   where
    saveSplice name =
      artifactSave store name content >>= finishSplice name
    finishSplice name identifier =
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

compactContext :: Runtime -> Int -> [AGUI.ToolSpec] -> Bool -> (Event -> IO ()) -> [ChatMessage] -> IO [ChatMessage]
compactContext runtime step tools emergency emit messages =
  maybe (pure messages) materialize (planCompaction runtime emergency tools messages)
 where
  materialize =
    materializeCompaction runtime >=> record
  record compaction =
    emit
      ( Custom
          "context.compact"
          ( object
              [ "step" .= step,
                "beforeTokens" .= compactionBeforeTokens compaction,
                "afterTokens" .= compactionAfterTokens compaction,
                "budgetTokens" .= compactionBudgetTokens compaction,
                "droppedMessages" .= length (compactionDropped compaction),
                "keptUnits" .= compactionKeptUnits compaction,
                "emergency" .= emergency
              ]
          )
      )
      $> compactionMessages compaction

forcedCompaction :: Runtime -> [AGUI.ToolSpec] -> [ChatMessage] -> Maybe Compaction
forcedCompaction runtime tools messages =
  runtimeContext runtime >>= build
 where
  build config =
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
      compactionPayload = "synthetic compaction without token pressure"
    }
 where
  before = estimateMessagesTokens messages
  (leading, body) = span systemMessage messages
  systemMessage ChatSystem {} = True
  systemMessage _ = False

compactHistory :: Runtime -> Bool -> [ChatMessage] -> IO (Maybe Compaction)
compactHistory runtime emergency messages =
  maybe (pure Nothing) (fmap Just . materializeCompaction runtime) planned
 where
  tools = backendToolSpec <$> Map.elems (runtimeTools runtime)
  planned = planCompaction runtime emergency tools messages

planCompaction :: Runtime -> Bool -> [AGUI.ToolSpec] -> [ChatMessage] -> Maybe Compaction
planCompaction runtime emergency tools messages =
  runtimeContext runtime >>= plan
 where
  plan config =
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
  case mapMaybe modelContextTokens (runtimeModel runtime : runtimeFallbacks runtime) of
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
    . fmap (liftA2 (<>) ((<> ":\n") . AGUI.contextDescription) AGUI.contextValue)

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
  AGUI.userText (AGUI.userContent user) >>= prependUser rest
toChatMessages (AGUI.Tool tool : rest) =
  (ChatToolResult (AGUI.toolMessageCallId tool) (AGUI.toolMessageContent tool) :)
    <$> toChatMessages rest
toChatMessages (AGUI.Activity _ : rest) = toChatMessages rest
toChatMessages (AGUI.Reasoning _ : rest) = toChatMessages rest
toChatMessages [] = Right []

prependUser :: [AGUI.Message] -> Text -> Either Text [ChatMessage]
prependUser rest text = (ChatUser text :) <$> toChatMessages rest

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
    readIORef stateRef >>= advance rest
   where
    advance (next : remaining) state
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
    <&> assemble
 where
  assemble closed =
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
  prepare call =
    either
      (pure . Resolve call . failure)
      (pure . dispatch call)
      (decodeArguments call)

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
        toolContextEmit = emit
      }

  missing call
    | modelToolName call `Set.member` clientTools = Defer call
    | otherwise = Resolve call (failure ("unknown tool: " <> modelToolName call))

  resolveAll Sequential = traverse resolve
  resolveAll Parallel = mapConcurrently resolve

  resolve = \case
    Execute call tool arguments toolContext ->
      Resolved call <$> safely (runBackendTool tool toolContext arguments)
    Resolve call outcome -> pure (Resolved call outcome)
    Defer _ -> pure Deferred

  emitResult = \case
    Deferred -> pure Nothing
    Resolved call outcome -> runtimeNewId runtime >>= emitResolved call outcome

  emitResolved call outcome messageId =
    present (modelToolName call) (toolOutcomeContent outcome)
      >>= announce
   where
    announce content =
      Just (ChatToolResult (modelToolCallId call) content)
        <$ modifyIORef' (runContextNames runContext) (Map.insert (modelToolCallId call) (modelToolName call))
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
        artifactSave store name content >>= storeResult
      storeResult identifier =
        content <$ modifyIORef' (runContextSeen runContext) (Map.insert key (identifier, content))

  conclude resolved =
    traverse emitResult resolved <&> summarize
   where
    summarize results =
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
