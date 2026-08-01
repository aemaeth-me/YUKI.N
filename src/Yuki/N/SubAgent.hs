module Yuki.N.SubAgent
  ( subAgentTool,
    registerSubAgent,
  )
where

import Data.Aeson
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Yuki.N.AGUI.Event (Event (..))
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent

registerSubAgent :: Runtime -> Runtime
registerSubAgent parent
  | runtimeDepth parent <= 0 = parent
  | otherwise = registered
 where
  registered = parent {runtimeTools = Map.insert name (subAgentTool name description registered) (runtimeTools parent)}
  name = "sub_agent"
  description =
    "Delegate a task to a sub-agent and return its final answer. "
      <> "The child inherits exactly these backend tools: "
      <> capabilities
      <> ". Do not delegate work that requires an unavailable capability."
  capabilities =
    case Map.keys workerTools of
      [] -> "none"
      tools -> Text.intercalate ", " tools
  workerTools = delegableTools name parent

subAgentTool :: Text -> Text -> Runtime -> BackendTool
subAgentTool name description parent =
  BackendTool (AGUI.ToolSpec name description schema) execute
 where
  workerTools = delegableTools name parent

  schema =
    object
      [ "type" .= ("object" :: Text),
        "properties" .= object ["prompt" .= object ["type" .= ("string" :: Text)]],
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
          let sub =
                parent
                  { runtimeDepth = runtimeDepth parent - 1,
                    runtimeTools = workerTools,
                    runtimeJournal = toolContextJournal context
                  }
           in runAgent sub (subInput context subRunId prompt) (consume context subRunId failed text)
                *> outcome failed text

  subInput context subRunId prompt =
    AGUI.RunAgentInput
      { AGUI.runThreadId = toolContextThreadId context,
        AGUI.runId = subRunId,
        AGUI.runParentId = Just (toolContextRunId context),
        AGUI.runState = object [],
        AGUI.runMessages =
          [AGUI.User (AGUI.UserMessage (subRunId <> "-prompt") (AGUI.UserText prompt) Nothing)],
        AGUI.runTools = [],
        AGUI.runContext = [],
        AGUI.runForwardedProps = object []
      }

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

workerDeniedTools :: Set.Set Text
workerDeniedTools =
  Set.fromList
    [ "memory_remember",
      "memory_void",
      "self_update",
      "sleep"
    ]

delegableTools :: Text -> Runtime -> Map.Map Text BackendTool
delegableTools name =
  Map.filterWithKey (\toolName _ -> toolName `Set.notMember` workerDeniedTools)
    . Map.delete name
    . runtimeTools

newtype Delegation = Delegation
  { delegationPrompt :: Text
  }
  deriving stock (Eq, Show)

instance FromJSON Delegation where
  parseJSON = withObject "Delegation" $ \fields -> Delegation <$> fields .: "prompt"
