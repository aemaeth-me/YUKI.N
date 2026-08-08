module Yuki.N.Domain.Model
  ( AssistantTurn (..),
    ChatMessage (..),
    ModelToolCall (..),
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)

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
