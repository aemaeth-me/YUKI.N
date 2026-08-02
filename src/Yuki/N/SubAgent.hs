module Yuki.N.SubAgent
  ( childRuntime,
    delegableTools,
    subAgentTool,
    registerSubAgent,
  )
where

import Control.Applicative (liftA2)
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (void)
import Data.Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor (($>), (<&>))
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import Yuki.N.AGUI.Event (Event (..))
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent
import Yuki.N.Model (ChatMessage (..))
import Yuki.N.Runs
import Yuki.N.Telemetry.Ledger (quietly)

registerSubAgent :: Runtime -> Runtime
registerSubAgent parent
  | runtimeDepth parent <= 0 = parent
  | otherwise = registered
 where
  registered =
    parent
      { runtimeTools =
          Map.insert
            syncName
            (subAgentTool syncName description registered)
            (Map.union (asyncToolSet registered) (runtimeTools parent))
      }
  syncName = "sub_agent"
  description =
    "Delegate a task to a sub-agent and return its final answer. "
      <> "The child inherits exactly these backend tools: "
      <> capabilities
      <> ". Do not delegate work that requires an unavailable capability."
  capabilities = renderCapabilities (delegableTools registered)

asyncToolSet :: Runtime -> Map.Map Text BackendTool
asyncToolSet parent =
  Map.fromList
    [ spawnTool parent,
      sendTool parent,
      statusTool parent,
      listTool parent,
      waitTool parent,
      cancelTool parent
    ]

renderCapabilities :: Map.Map Text BackendTool -> Text
renderCapabilities tools = case Map.keys tools of
  [] -> "none"
  names -> Text.intercalate ", " names

subAgentTool :: Text -> Text -> Runtime -> BackendTool
subAgentTool name description parent =
  BackendTool (AGUI.ToolSpec name description schema) execute
 where
  schema =
    object
      [ "type" .= ("object" :: Text),
        "properties" .= object ["prompt" .= stringSchema],
        "required" .= (["prompt"] :: [Text]),
        "additionalProperties" .= False
      ]

  execute context arguments
    | runtimeDepth parent <= 0 =
        pure (ToolOutcome "delegation depth exhausted" True False)
    | otherwise =
        case fromJSON arguments of
          Error message ->
            pure (ToolOutcome ("invalid delegation arguments: " <> Text.pack message) True False)
          Success (Delegation prompt) -> delegate context prompt

  delegate context prompt =
    runtimeNewId parent >>= \subRunId ->
      newIORef Nothing >>= \failed ->
        newIORef "" >>= \text ->
          let sub = childRuntime parent context
              input = workerInput context subRunId prompt Nothing
           in runAgent sub input (consume context subRunId failed text)
                *> outcome failed text

  consume context subRunId failed text event =
    collect failed text event
      *> toolContextEmit context (scoped subRunId context event)

  scoped subRunId context event =
    Custom
      "agent.sub"
      ( object
          [ "runId" .= subRunId,
            "callId" .= toolContextCallId context,
            "event" .= event
          ]
      )

  collect failed text = \case
    TextMessageContent _ delta -> modifyIORef' text (<> delta)
    RunError message _ -> writeIORef failed (Just message)
    _ -> pure ()

  outcome failed text =
    readIORef failed
      >>= maybe
        (ToolOutcome <$> readIORef text <*> pure False <*> pure False)
        (\message -> pure (ToolOutcome ("sub-agent failed: " <> message) True False))

spawnTool :: Runtime -> (Text, BackendTool)
spawnTool parent =
  (name, BackendTool (AGUI.ToolSpec name description schema) execute)
 where
  name = "sub_agent_spawn"
  description =
    "Spawn an asynchronous worker sub-agent and return its agent id immediately; the worker runs in the background while you continue. Use for independent, bounded workstreams that can proceed in parallel. The worker inherits exactly these backend tools: "
      <> capabilities
      <> ". Provide a complete, self-contained prompt: the worker does not see this conversation's history. Optionally give objective, a short label shown to the user in the workbench. At most "
      <> Text.pack (show limit)
      <> " workers may be active per run; when the limit is reached spawn fails — wait for some to finish and retry."
  capabilities = renderCapabilities (delegableTools parent)
  limit = runtimeSubAgentMaxParallel parent
  schema =
    object
      [ "type" .= ("object" :: Text),
        "properties" .= object ["prompt" .= stringSchema, "objective" .= stringSchema],
        "required" .= (["prompt"] :: [Text]),
        "additionalProperties" .= False
      ]
  execute context arguments
    | runtimeDepth parent <= 0 =
        pure (ToolOutcome "delegation depth exhausted" True False)
    | otherwise =
        case (runtimeRuns parent, fromJSON arguments) of
          (Nothing, _) -> pure (ToolOutcome "worker orchestration unavailable" True False)
          (_, Error message) ->
            pure (ToolOutcome ("invalid tool arguments: " <> Text.pack message) True False)
          (Just registry, Success (SpawnCall prompt objective)) ->
            countActive registry context >>= \active ->
              if active >= limit
                then pure (ToolOutcome "worker parallel limit reached" True False)
                else spawn registry context prompt objective
  countActive registry context = length <$> childrenOf registry (toolContextRunId context)
  spawn registry context prompt objective =
    runtimeNewId parent >>= \subRunId ->
      let sub = childRuntime parent context
          input = workerInput context subRunId prompt objective
       in void
            ( forkIO
                ( runAgent sub input (const (pure ()))
                    *> notify registry context subRunId prompt objective
                )
            )
            $> jsonOutcome (object ["agentId" .= subRunId, "status" .= ("running" :: Text)])
  notify registry context subRunId prompt objective =
    completionFor registry subRunId >>= \case
      Nothing -> pure ()
      Just completion ->
        quietly
          ( steerRun
              registry
              (toolContextRunId context)
              ( ChatSystem
                  ( "[worker "
                      <> subRunId
                      <> " "
                      <> outcomeText (completionOutcome completion)
                      <> "] "
                      <> fromMaybe (firstLine prompt) objective
                      <> "\n"
                      <> Text.take 2000 (completionResult completion)
                  )
              )
              $> ()
          )

sendTool :: Runtime -> (Text, BackendTool)
sendTool parent =
  (name, BackendTool (AGUI.ToolSpec name description schema) execute)
 where
  name = "sub_agent_send"
  description =
    "Send a steering message to a running worker you spawned in this run. The worker receives it at its next turn boundary, like a user steering note. Use to narrow scope, add missing context, or redirect — not to change what it must deliver."
  schema = objectSchema ["agentId", "text"] (object ["agentId" .= stringSchema, "text" .= stringSchema])
  execute context arguments =
    case (runtimeRuns parent, fromJSON arguments) of
      (Nothing, _) -> pure (ToolOutcome "worker orchestration unavailable" True False)
      (_, Error message) ->
        pure (ToolOutcome ("invalid tool arguments: " <> Text.pack message) True False)
      (Just registry, Success (SendCall agentId text)) ->
        childOf registry (toolContextRunId context) agentId >>= \isChild ->
          if not isChild
            then pure (ToolOutcome "unknown worker" True False)
            else steerRun registry agentId (ChatUser text) $> jsonOutcome (object ["delivered" .= True])

statusTool :: Runtime -> (Text, BackendTool)
statusTool parent =
  (name, BackendTool (AGUI.ToolSpec name description schema) execute)
 where
  name = "sub_agent_status"
  description =
    "Check one of your workers: returns running, or the terminal outcome (completed, failed or cancelled) with its result. Only workers spawned in this run are visible."
  schema = objectSchema ["agentId"] (object ["agentId" .= stringSchema])
  execute context arguments =
    case (runtimeRuns parent, fromJSON arguments) of
      (Nothing, _) -> pure (ToolOutcome "worker orchestration unavailable" True False)
      (_, Error message) ->
        pure (ToolOutcome ("invalid tool arguments: " <> Text.pack message) True False)
      (Just registry, Success (StatusCall agentId)) ->
        childOf registry (toolContextRunId context) agentId >>= \running ->
          if running
            then pure (jsonOutcome (object ["status" .= ("running" :: Text)]))
            else
              completionFor registry agentId >>= \case
                Just completion
                  | completionParent completion == Just (toolContextRunId context) ->
                      pure
                        ( jsonOutcome
                            ( object
                                [ "status" .= statusName (completionOutcome completion),
                                  "outcome" .= statusName (completionOutcome completion),
                                  "result" .= completionResult completion
                                ]
                            )
                        )
                _ -> pure (ToolOutcome "unknown worker" True False)

listTool :: Runtime -> (Text, BackendTool)
listTool parent =
  (name, BackendTool (AGUI.ToolSpec name description schema) execute)
 where
  name = "sub_agent_list"
  description = "List all workers spawned in this run with their status and objective."
  schema = objectSchema [] (object [])
  execute context arguments =
    case runtimeRuns parent of
      Nothing -> pure (ToolOutcome "worker orchestration unavailable" True False)
      Just registry ->
        liftA2 (,) (childrenOf registry parentRunId) (completionsOf registry parentRunId) >>= \pair ->
          pure (jsonOutcome (object ["workers" .= render pair]))
   where
    parentRunId = toolContextRunId context
    render (active, completed) = fmap running active <> fmap terminal completed
    running info =
      object
        [ "agentId" .= runInfoId info,
          "status" .= ("running" :: Text),
          "objective" .= runInfoObjective info,
          "startedAt" .= runInfoStartedAt info
        ]
    terminal completion =
      object
        [ "agentId" .= completionRunId completion,
          "status" .= statusName (completionOutcome completion),
          "objective" .= (Nothing :: Maybe Text),
          "startedAt" .= completionAt completion
        ]

waitTool :: Runtime -> (Text, BackendTool)
waitTool parent =
  (name, BackendTool (AGUI.ToolSpec name description schema) execute)
 where
  name = "sub_agent_wait"
  description =
    "Block until the given workers finish (or the timeout elapses) and collect their results. Prefer waiting over polling status in a loop. Use before integrating worker outputs into your answer."
  schema =
    objectSchema
      ["agentIds"]
      ( object
          [ "agentIds" .= arraySchema stringSchema,
            "timeoutSeconds" .= integerSchema
          ]
      )
  execute context arguments =
    case (runtimeRuns parent, fromJSON arguments) of
      (Nothing, _) -> pure (ToolOutcome "worker orchestration unavailable" True False)
      (_, Error message) ->
        pure (ToolOutcome ("invalid tool arguments: " <> Text.pack message) True False)
      (Just registry, Success (WaitCall agentIds timeoutSeconds)) ->
        getPOSIXTime >>= \start ->
          poll registry (toolContextRunId context) (deadline start timeoutSeconds) agentIds
            <&> jsonOutcome . render
  deadline start seconds = start + fromIntegral (min 3600 (max 0 (fromMaybe 300 seconds)))
  poll registry parentRunId limit agentIds = do
    done <- traverse (scopedCompletion registry parentRunId) agentIds
    now <- getPOSIXTime
    if now >= limit || all isJust done
      then pure (zip agentIds done)
      else threadDelay 500000 *> poll registry parentRunId limit agentIds
  render done =
    object
      [ "results"
          .= [ object
                 [ "agentId" .= agentId,
                   "status" .= statusName (completionOutcome completion),
                   "result" .= completionResult completion
                 ]
             | (agentId, Just completion) <- done
             ],
        "timedOut" .= [agentId | (agentId, Nothing) <- done]
      ]

cancelTool :: Runtime -> (Text, BackendTool)
cancelTool parent =
  (name, BackendTool (AGUI.ToolSpec name description schema) execute)
 where
  name = "sub_agent_cancel"
  description = "Cancel a running worker you spawned in this run. Its partial work is discarded."
  schema = objectSchema ["agentId"] (object ["agentId" .= stringSchema])
  execute context arguments =
    case (runtimeRuns parent, fromJSON arguments) of
      (Nothing, _) -> pure (ToolOutcome "worker orchestration unavailable" True False)
      (_, Error message) ->
        pure (ToolOutcome ("invalid tool arguments: " <> Text.pack message) True False)
      (Just registry, Success (CancelCall agentId)) ->
        childOf registry (toolContextRunId context) agentId >>= \isChild ->
          if not isChild
            then pure (ToolOutcome "unknown worker" True False)
            else cancelRun registry agentId $> jsonOutcome (object ["cancelled" .= True])

childOf :: RunRegistry -> Text -> Text -> IO Bool
childOf registry parent agentId =
  any ((== agentId) . runInfoId) <$> childrenOf registry parent

scopedCompletion :: RunRegistry -> Text -> Text -> IO (Maybe RunCompletion)
scopedCompletion registry parentRunId agentId =
  completionFor registry agentId >>= \case
    Just completion | completionParent completion == Just parentRunId -> pure (Just completion)
    _ -> pure Nothing

childRuntime :: Runtime -> ToolContext -> Runtime
childRuntime parent context =
  parent
    { runtimeDepth = runtimeDepth parent - 1,
      runtimeTools = delegableTools parent,
      runtimeJournal = toolContextJournal context
    }

workerInput :: ToolContext -> Text -> Text -> Maybe Text -> AGUI.RunAgentInput
workerInput context subRunId prompt objective =
  AGUI.RunAgentInput
    { AGUI.runThreadId = toolContextThreadId context,
      AGUI.runId = subRunId,
      AGUI.runParentId = Just (toolContextRunId context),
      AGUI.runState = object [],
      AGUI.runMessages =
        [ AGUI.User (AGUI.UserMessage (subRunId <> "-objective") (AGUI.UserText label) Nothing)
        | Just label <- [objective]
        ]
          <> [ AGUI.User (AGUI.UserMessage (subRunId <> "-prompt") (AGUI.UserText prompt) Nothing)
             ],
      AGUI.runTools = [],
      AGUI.runContext = [],
      AGUI.runForwardedProps = object ["delegationId" .= toolContextCallId context]
    }

workerDeniedTools :: Set.Set Text
workerDeniedTools =
  Set.fromList
    [ "memory_remember",
      "memory_void",
      "self_update",
      "sleep",
      "propose_dispatch"
    ]

delegableTools :: Runtime -> Map.Map Text BackendTool
delegableTools =
  Map.filterWithKey
    ( \toolName _ ->
        toolName `Set.notMember` workerDeniedTools
          && not ("sub_agent" `Text.isPrefixOf` toolName)
    )
    . runtimeTools

outcomeText :: CompletionOutcome -> Text
outcomeText Completed = "completed"
outcomeText (Failed reason) = "failed: " <> reason
outcomeText Cancelled = "cancelled"

statusName :: CompletionOutcome -> Text
statusName Completed = "completed"
statusName (Failed _) = "failed"
statusName Cancelled = "cancelled"

firstLine :: Text -> Text
firstLine = fromMaybe "" . listToMaybe . Text.lines

jsonOutcome :: (ToJSON value) => value -> ToolOutcome
jsonOutcome value =
  ToolOutcome (TextEncoding.decodeUtf8 (LazyByteString.toStrict (encode value))) False False

stringSchema, integerSchema :: Value
stringSchema = object ["type" .= ("string" :: Text)]
integerSchema = object ["type" .= ("integer" :: Text)]

arraySchema :: Value -> Value
arraySchema items = object ["type" .= ("array" :: Text), "items" .= items]

objectSchema :: [Text] -> Value -> Value
objectSchema required properties =
  object
    [ "type" .= ("object" :: Text),
      "properties" .= properties,
      "required" .= required,
      "additionalProperties" .= False
    ]

newtype Delegation = Delegation
  { delegationPrompt :: Text
  }
  deriving stock (Eq, Show)

instance FromJSON Delegation where
  parseJSON = withObject "Delegation" $ \fields -> Delegation <$> fields .: "prompt"

data SpawnCall = SpawnCall
  { spawnPrompt :: Text,
    spawnObjective :: Maybe Text
  }
  deriving stock (Eq, Show)

instance FromJSON SpawnCall where
  parseJSON = withObject "SpawnCall" $ \fields -> SpawnCall <$> fields .: "prompt" <*> fields .:? "objective"

data SendCall = SendCall
  { sendAgentId :: Text,
    sendText :: Text
  }
  deriving stock (Eq, Show)

instance FromJSON SendCall where
  parseJSON = withObject "SendCall" $ \fields -> SendCall <$> fields .: "agentId" <*> fields .: "text"

newtype StatusCall = StatusCall
  { statusAgentId :: Text
  }
  deriving stock (Eq, Show)

instance FromJSON StatusCall where
  parseJSON = withObject "StatusCall" $ \fields -> StatusCall <$> fields .: "agentId"

data WaitCall = WaitCall
  { waitAgentIds :: [Text],
    waitTimeoutSeconds :: Maybe Int
  }
  deriving stock (Eq, Show)

instance FromJSON WaitCall where
  parseJSON = withObject "WaitCall" $ \fields -> WaitCall <$> fields .: "agentIds" <*> fields .:? "timeoutSeconds"

newtype CancelCall = CancelCall
  { cancelAgentId :: Text
  }
  deriving stock (Eq, Show)

instance FromJSON CancelCall where
  parseJSON = withObject "CancelCall" $ \fields -> CancelCall <$> fields .: "agentId"
