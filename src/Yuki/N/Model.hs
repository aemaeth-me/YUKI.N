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
  )
where

import Control.Exception (Exception)
import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Yuki.N.AGUI.Types (ToolSpec)
import Yuki.N.Domain.Model

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
  deriving stock (Eq, Show)

data FinishReason
  = Stop
  | ToolUse
  | Length
  deriving stock (Eq, Show)

data ToolExecution
  = Sequential
  | Parallel
  deriving stock (Eq, Show)

data Model = Model
  { modelContextTokens :: Int,
    streamModel :: ModelRequest -> (ModelEvent -> IO ()) -> IO FinishReason
  }

data ModelRequest = ModelRequest
  { requestMessages :: [ChatMessage],
    requestTools :: [ToolSpec]
  }
  deriving stock (Eq, Show)

newtype ProviderFailure = ProviderFailure Text
  deriving stock (Eq, Show)

instance Exception ProviderFailure
