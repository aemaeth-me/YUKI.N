{-# OPTIONS_GHC -Wno-orphans #-}

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
import Yuki.N.Domain.Model

-- 兼容序列化（刻意保留的孤儿实例）：
-- `Yuki.N.Domain.Model` 按纯度规则不持有 JSON 实例；以下三个实例为 journal/金样与
-- provider wire 格式的持久兼容契约而存在，与迁移前的 JSON 输出逐字节一致。
instance ToJSON ChatMessage

instance FromJSON ChatMessage

instance ToJSON AssistantTurn

instance FromJSON AssistantTurn

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

-- | effectful provider port：纯 chat 值类型在 `Yuki.N.Domain.Model`，
-- provider/运行时值类型（事件、终止原因、工具执行/结果、用量）定义于此；
-- `ModelRequest` 作为端口载荷保留 AG-UI 工具规格引用以维持既有调用方兼容。
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

newtype ProviderFailure = ProviderFailure Text
  deriving stock (Eq, Show)

instance Exception ProviderFailure
