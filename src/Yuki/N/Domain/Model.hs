module Yuki.N.Domain.Model
  ( AssistantTurn (..),
    ChatMessage (..),
    ModelToolCall (..),
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)

-- | 协议中立的 chat 值类型，供纯领域算法（如 `Domain.Context`）使用。
-- 不持有 JSON 实例；序列化实例由兼容门面 `Yuki.N.Model` 以刻意保留的孤儿实例提供。
data ChatMessage
  = ChatSystem Text
  | ChatUser Text
  | ChatAssistant AssistantTurn
  | ChatToolResult Text Text
  deriving stock (Eq, Show)
  deriving Generic

data AssistantTurn = AssistantTurn
  { turnMessageId :: Text,
    turnText :: Maybe Text,
    turnReasoning :: Maybe Text,
    turnToolCalls :: [ModelToolCall]
  }
  deriving stock (Eq, Show)
  deriving Generic

data ModelToolCall = ModelToolCall
  { modelToolCallId :: Text,
    modelToolName :: Text,
    modelToolArguments :: Text
  }
  deriving stock (Eq, Show)
  deriving Generic
