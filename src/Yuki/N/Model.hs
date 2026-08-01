module Yuki.N.Model
  ( AssistantTurn (..),
    ChatMessage (..),
    FinishReason (..),
    Model (..),
    ModelEvent (..),
    ModelRequest (..),
    ModelToolCall (..),
    ProviderFailure (..),
    ToolExecution (..),
    ToolOutcome (..),
    Usage (..),
  )
where

import Control.Exception (Exception)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.:?), (.=))
import Data.Text (Text)
import GHC.Generics (Generic)
import Yuki.N.AGUI.Types (ToolSpec)

data Model = Model
  { modelProvider :: Text,
    modelName :: Text,
    modelContextTokens :: Maybe Int,
    streamModel :: ModelRequest -> (ModelEvent -> IO ()) -> IO FinishReason,
    modelRender :: ModelRequest -> Value
  }

data ModelRequest = ModelRequest
  { requestMessages :: [ChatMessage],
    requestTools :: [ToolSpec]
  }
  deriving stock (Eq, Show)
  deriving Generic

instance ToJSON ModelRequest

instance FromJSON ModelRequest

data ChatMessage
  = ChatSystem Text
  | ChatUser Text
  | ChatAssistant AssistantTurn
  | ChatToolResult Text Text
  deriving stock (Eq, Show)
  deriving Generic

instance ToJSON ChatMessage

instance FromJSON ChatMessage

data AssistantTurn = AssistantTurn
  { turnMessageId :: Text,
    turnText :: Maybe Text,
    turnReasoning :: Maybe Text,
    turnToolCalls :: [ModelToolCall]
  }
  deriving stock (Eq, Show)
  deriving Generic

instance ToJSON AssistantTurn

instance FromJSON AssistantTurn

data ModelToolCall = ModelToolCall
  { modelToolCallId :: Text,
    modelToolName :: Text,
    modelToolArguments :: Text
  }
  deriving stock (Eq, Show)
  deriving Generic

instance ToJSON ModelToolCall

instance FromJSON ModelToolCall

data ModelEvent
  = ModelTextDelta Text
  | ModelReasoningDelta Text
  | ModelToolCallDelta
      { deltaToolIndex :: Int,
        deltaToolId :: Maybe Text,
        deltaToolName :: Maybe Text,
        deltaToolArguments :: Text
      }
  | ModelUsage Usage
  deriving stock (Eq, Show)
  deriving Generic

instance ToJSON ModelEvent

instance FromJSON ModelEvent

data FinishReason
  = Stop
  | ToolUse
  | Length
  deriving stock (Eq, Show)
  deriving Generic

instance ToJSON FinishReason

instance FromJSON FinishReason

data ToolExecution
  = Sequential
  | Parallel
  deriving stock (Eq, Show)
  deriving Generic

instance ToJSON ToolExecution

instance FromJSON ToolExecution

data ToolOutcome = ToolOutcome
  { toolOutcomeContent :: Text,
    toolOutcomeError :: Bool,
    toolOutcomeTerminate :: Bool
  }
  deriving stock (Eq, Show)
  deriving Generic

instance ToJSON ToolOutcome

instance FromJSON ToolOutcome

data Usage = Usage
  { usagePromptTokens :: Maybe Int,
    usageCompletionTokens :: Maybe Int,
    usageCacheHitTokens :: Maybe Int,
    usageCacheMissTokens :: Maybe Int
  }
  deriving stock (Eq, Show)

instance ToJSON Usage where
  toJSON usage =
    object
      [ "prompt_tokens" .= usagePromptTokens usage,
        "completion_tokens" .= usageCompletionTokens usage,
        "prompt_cache_hit_tokens" .= usageCacheHitTokens usage,
        "prompt_cache_miss_tokens" .= usageCacheMissTokens usage
      ]

instance FromJSON Usage where
  parseJSON = withObject "Usage" $ \fields ->
    Usage
      <$> fields .:? "prompt_tokens"
      <*> fields .:? "completion_tokens"
      <*> fields .:? "prompt_cache_hit_tokens"
      <*> fields .:? "prompt_cache_miss_tokens"

newtype ProviderFailure = ProviderFailure Text
  deriving stock (Eq, Show)

instance Exception ProviderFailure
