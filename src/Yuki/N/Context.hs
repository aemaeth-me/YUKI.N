module Yuki.N.Context
  ( Compaction (..),
    ContextConfig (..),
    attachCompactionArtifact,
    compactMessages,
    contextBudget,
    contextSummaryMarker,
    emergencyCompactMessages,
    estimateMessagesTokens,
    isContextOverflow,
  )
where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text qualified as Text
import Yuki.N.AGUI.Types (ToolSpec)
import Yuki.N.Domain.Context
  ( Compaction (..),
    ContextConfig (..),
    attachCompactionArtifact,
    contextSummaryMarker,
    estimateMessagesTokens,
  )
import Yuki.N.Domain.Context qualified as Domain
import Yuki.N.Model (ChatMessage, ProviderFailure (..))

compactMessages :: ContextConfig -> Int -> [ToolSpec] -> [ChatMessage] -> Maybe Compaction
compactMessages config window tools =
  Domain.compactMessages config window (estimateToolsTokens tools)

emergencyCompactMessages :: ContextConfig -> Int -> [ToolSpec] -> [ChatMessage] -> Maybe Compaction
emergencyCompactMessages config window tools =
  Domain.emergencyCompactMessages config window (estimateToolsTokens tools)

contextBudget :: ContextConfig -> Int -> [ToolSpec] -> Int
contextBudget config window tools =
  Domain.contextBudget config window (estimateToolsTokens tools)

estimateToolsTokens :: [ToolSpec] -> Int
estimateToolsTokens = (`div` 3) . fromIntegral . LazyByteString.length . encode

isContextOverflow :: ProviderFailure -> Bool
isContextOverflow (ProviderFailure message) = any (`Text.isInfixOf` normalized) needles
 where
  normalized = Text.toLower message
  needles =
    [ "context_length_exceeded",
      "context length",
      "context window",
      "maximum context",
      "too many tokens",
      "prompt is too long",
      "token limit"
    ]
