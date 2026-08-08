module Yuki.N.SubAgent
  ( registerSubAgent,
  )
where

import Control.Applicative (liftA3)
import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, mask, onException, throwIO, try)
import Control.Monad (void)
import Data.Aeson
import Data.Bool (bool)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor (($>), (<&>))
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.IO (stderr)
import Yuki.N.AGUI.Event (Event (..))
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent
import Yuki.N.Model (ChatMessage (..))
import Yuki.N.Runs

quietly :: IO () -> IO ()
quietly action =
  try @SomeException action >>= either rethrowAsync (const (pure ()))
 where
  rethrowAsync exception =
    maybe
      (TextIO.hPutStrLn stderr ("yuki.subagent: " <> Text.pack (displayException exception)))
      throwIO
      (fromException exception :: Maybe SomeAsyncException)

registerSubAgent :: Runtime -> Runtime
registerSubAgent parent = registered
 where
  registered =
    parent
      { runtimeTools =
          Map.insert
            syncName
            (subAgentTool syncName description parent)
            (Map.union (asyncToolSet parent) (runtimeTools parent))
      }
  syncName = "sub_agent"
  description =
    "Delegate a task to a sub-agent and return its final answer. "
      <> "The child inherits exactly these backend tools: "
      <> capabilities
      <> ". Do not delegate work that requires an unavailable capability."
  capabilities = renderCapabilities (delegableTools parent)

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

  execute context arguments = case fromJSON arguments of
    Error message ->
      pure ("invalid delegation arguments: " <> Text.pack message)
    Success (Delegation prompt) -> delegate context prompt

  delegate context prompt =
    liftA3 (,,) (runtimeNewId parent) (newIORef Nothing) (newIORef "")
      >>= runDelegation
   where
    runDelegation (subRunId, failed, text) =
      mask $ \restore ->
        reserveChildRun registry limit subRunId (workerDescriptor context prompt Nothing)
          >>= bool
            (pure "sub-agent parallel limit reached")
            ( restore (runChild subRunId failed text)
                `onException` releaseReservation registry subRunId
            )
    runChild subRunId failed text =
      runAgent (childRuntime parent) (workerInput context subRunId prompt Nothing) (consume context subRunId failed text)
        *> outcome failed text
    registry = runtimeRuns parent
    limit = runtimeSubAgentMaxParallel parent

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

  collect _ text (TextMessageContent _ delta) = modifyIORef' text (<> delta)
  collect failed _ (RunError message _) = writeIORef failed (Just message)
  collect _ _ _ = pure ()

  outcome failed text =
    readIORef failed
      >>= maybe
        (readIORef text)
        failedOutcome
   where
    failedOutcome message =
      pure ("sub-agent failed: " <> message)

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
  execute context arguments = case fromJSON arguments of
    Error message ->
      pure ("invalid tool arguments: " <> Text.pack message)
    Success (SpawnCall prompt objective) ->
      spawn (runtimeRuns parent) context prompt objective
  spawn registry context prompt objective =
    runtimeNewId parent >>= runSpawned
   where
    runSpawned subRunId =
      mask $ \restore ->
        reserveChildRun registry limit subRunId (workerDescriptor context prompt objective)
          >>= bool
            (pure "worker parallel limit reached")
            (launch restore subRunId)
    launch restore subRunId =
      void
        ( forkIO
            ( ( restore (runAgent (childRuntime parent) (workerInput context subRunId prompt objective) (const (pure ())))
                  `onException` releaseReservation registry subRunId
              )
                *> restore (notify registry context subRunId prompt objective)
            )
            `onException` releaseReservation registry subRunId
        )
        $> jsonOutcome (object ["agentId" .= subRunId, "status" .= ("running" :: Text)])
  notify registry context subRunId prompt objective =
    completionFor registry subRunId
      >>= maybe (pure ()) steerQuietly
   where
    steerQuietly completion =
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
  execute context arguments = case fromJSON arguments of
    Error message ->
      pure ("invalid tool arguments: " <> Text.pack message)
    Success (SendCall agentId text) ->
      childOf registry (toolContextRunId context) agentId
        >>= sendToChild registry agentId text
   where
    registry = runtimeRuns parent
  sendToChild registry agentId text isChild
    | not isChild = pure "unknown worker"
    | otherwise =
        steerRun registry agentId (ChatUser text) $> jsonOutcome (object ["delivered" .= True])

statusTool :: Runtime -> (Text, BackendTool)
statusTool parent =
  (name, BackendTool (AGUI.ToolSpec name description schema) execute)
 where
  name = "sub_agent_status"
  description =
    "Check one of your workers: returns running, or the terminal outcome (completed, failed or cancelled) with its result. Only workers spawned in this run are visible."
  schema = objectSchema ["agentId"] (object ["agentId" .= stringSchema])
  execute context arguments = case fromJSON arguments of
    Error message ->
      pure ("invalid tool arguments: " <> Text.pack message)
    Success (StatusCall agentId) ->
      childOf registry (toolContextRunId context) agentId
        >>= statusCheck registry context agentId
   where
    registry = runtimeRuns parent
  statusCheck registry context agentId running
    | running =
        pure (jsonOutcome (object ["status" .= ("running" :: Text)]))
    | otherwise =
        completionFor registry agentId >>= completionStatus context
  completionStatus context (Just completion)
    | completionParent completion == toolContextRunId context =
        pure
          ( jsonOutcome
              ( object
                  [ "status" .= statusName (completionOutcome completion),
                    "result" .= completionResult completion
                  ]
              )
          )
  completionStatus _ _ = pure "unknown worker"

listTool :: Runtime -> (Text, BackendTool)
listTool parent =
  (name, BackendTool (AGUI.ToolSpec name description schema) execute)
 where
  name = "sub_agent_list"
  description = "List all workers spawned in this run with their status and objective."
  schema = objectSchema [] (object [])
  execute context _ =
    liftA2 (,) (childrenOf registry parentRunId) (completionsOf registry parentRunId)
      <&> jsonOutcome . object . pure . ("workers" .=) . render
   where
    registry = runtimeRuns parent
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
  execute context arguments = case fromJSON arguments of
    Error message ->
      pure ("invalid tool arguments: " <> Text.pack message)
    Success (WaitCall agentIds timeoutSeconds) ->
      getPOSIXTime
        >>= waitPhase (runtimeRuns parent) context agentIds timeoutSeconds
  waitPhase registry context agentIds timeoutSeconds start =
    poll registry (toolContextRunId context) (deadline start timeoutSeconds) agentIds
      <&> jsonOutcome . render
  deadline start seconds = start + fromIntegral (min 3600 (max 0 (fromMaybe 300 seconds)))
  poll registry parentRunId limit agentIds =
    traverse (scopedCompletion registry parentRunId) agentIds
      >>= pollPhase registry parentRunId limit agentIds
  pollPhase registry parentRunId limit agentIds done =
    getPOSIXTime
      >>= bool
        (threadDelay 500000 *> poll registry parentRunId limit agentIds)
        (pure (zip agentIds done))
        . deadlineReached limit done
  deadlineReached limit done now =
    now >= limit || all isJust done
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
  execute context arguments = case fromJSON arguments of
    Error message ->
      pure ("invalid tool arguments: " <> Text.pack message)
    Success (CancelCall agentId) ->
      childOf registry (toolContextRunId context) agentId
        >>= cancelChild registry agentId
   where
    registry = runtimeRuns parent
  cancelChild registry agentId isChild
    | not isChild = pure "unknown worker"
    | otherwise = cancelRun registry agentId $> jsonOutcome (object ["cancelled" .= True])

childOf :: RunRegistry -> Text -> Text -> IO Bool
childOf registry parent agentId =
  any ((== agentId) . runInfoId) <$> childrenOf registry parent

scopedCompletion :: RunRegistry -> Text -> Text -> IO (Maybe RunCompletion)
scopedCompletion registry parentRunId agentId =
  completionFor registry agentId
    >>= scopedToParent
 where
  scopedToParent (Just completion)
    | completionParent completion == parentRunId = pure (Just completion)
  scopedToParent _ = pure Nothing

childRuntime :: Runtime -> Runtime
childRuntime parent =
  parent
    { runtimeTools = delegableTools parent
    }

workerDescriptor :: ToolContext -> Text -> Maybe Text -> RunDescriptor
workerDescriptor context prompt objective =
  RunDescriptor
    (Just (toolContextRunId context))
    (Just (Text.take 120 (fromMaybe prompt objective)))

workerInput :: ToolContext -> Text -> Text -> Maybe Text -> AGUI.RunAgentInput
workerInput context subRunId prompt objective =
  AGUI.RunAgentInput
    { AGUI.runThreadId = toolContextThreadId context,
      AGUI.runId = subRunId,
      AGUI.runParentId = Just (toolContextRunId context),
      AGUI.runMessages =
        [ AGUI.User (AGUI.UserMessage (subRunId <> "-objective") label)
        | Just label <- [objective]
        ]
          <> [AGUI.User (AGUI.UserMessage (subRunId <> "-prompt") prompt)]
    }

delegableTools :: Runtime -> Map.Map Text BackendTool
delegableTools =
  Map.filterWithKey
    (\toolName _ -> not ("sub_agent" `Text.isPrefixOf` toolName))
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

jsonOutcome :: (ToJSON value) => value -> Text
jsonOutcome = TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

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

newtype Delegation = Delegation Text

instance FromJSON Delegation where
  parseJSON = withObject "Delegation" $ \fields -> Delegation <$> fields .: "prompt"

data SpawnCall = SpawnCall Text (Maybe Text)

instance FromJSON SpawnCall where
  parseJSON = withObject "SpawnCall" $ \fields -> SpawnCall <$> fields .: "prompt" <*> fields .:? "objective"

data SendCall = SendCall Text Text

instance FromJSON SendCall where
  parseJSON = withObject "SendCall" $ \fields -> SendCall <$> fields .: "agentId" <*> fields .: "text"

newtype StatusCall = StatusCall Text

instance FromJSON StatusCall where
  parseJSON = withObject "StatusCall" $ \fields -> StatusCall <$> fields .: "agentId"

data WaitCall = WaitCall [Text] (Maybe Int)

instance FromJSON WaitCall where
  parseJSON = withObject "WaitCall" $ \fields -> WaitCall <$> fields .: "agentIds" <*> fields .:? "timeoutSeconds"

newtype CancelCall = CancelCall Text

instance FromJSON CancelCall where
  parseJSON = withObject "CancelCall" $ \fields -> CancelCall <$> fields .: "agentId"
