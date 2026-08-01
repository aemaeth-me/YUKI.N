{-# OPTIONS_GHC -Wno-orphans #-}

module Yuki.N.Context
  ( Compaction (..),
    ContextConfig (..),
    attachCompactionArtifact,
    compactMessages,
    compactToBudget,
    contextBudget,
    contextSummaryMarker,
    contextWindow,
    emergencyCompactMessages,
    estimateMessageTokens,
    estimateMessagesTokens,
    estimateTextTokens,
    estimateToolsTokens,
    isContextOverflow,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), encode, object, withObject, (.:), (.=))
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Yuki.N.AGUI.Types (ToolSpec)
import Yuki.N.Domain.Context
  ( Compaction (..),
    ContextConfig (..),
    attachCompactionArtifact,
    compactToBudget,
    contextSummaryMarker,
    contextWindow,
    estimateMessageTokens,
    estimateMessagesTokens,
    estimateTextTokens,
  )
import Yuki.N.Domain.Context qualified as Domain
import Yuki.N.Model (ChatMessage, ProviderFailure (..))

-- 兼容门面：纯压缩核心在 `Yuki.N.Domain.Context`（无 JSON/协议依赖，工具规格以
-- 显式 token 代价标量传入）。本模块保留旧的 `[ToolSpec]` 签名与 JSON 行为。

-- 刻意保留的孤儿实例：旧 `Yuki.N.Context` 曾在此定义 `ContextConfig` 的 JSON 契约，
-- 为既有持久/配置兼容而保留；Domain 本身不持有任何 JSON 实例。
instance ToJSON ContextConfig where
  toJSON config =
    object
      [ "reserveTokens" .= contextReserveTokens config,
        "keepUnits" .= contextKeepUnits config,
        "summaryTokens" .= contextSummaryTokens config,
        "fallbackChars" .= contextFallbackChars config
      ]

instance FromJSON ContextConfig where
  parseJSON = withObject "ContextConfig" $ \fields ->
    ContextConfig
      <$> fields .: "reserveTokens"
      <*> fields .: "keepUnits"
      <*> fields .: "summaryTokens"
      <*> fields .: "fallbackChars"

compactMessages :: ContextConfig -> Maybe Int -> [ToolSpec] -> [ChatMessage] -> Maybe Compaction
compactMessages config window tools =
  Domain.compactMessages config window (estimateToolsTokens tools)

emergencyCompactMessages :: ContextConfig -> Maybe Int -> [ToolSpec] -> [ChatMessage] -> Maybe Compaction
emergencyCompactMessages config window tools =
  Domain.emergencyCompactMessages config window (estimateToolsTokens tools)

contextBudget :: ContextConfig -> Maybe Int -> [ToolSpec] -> Int
contextBudget config window tools =
  Domain.contextBudget config window (estimateToolsTokens tools)

-- | 工具规格的 token 代价估计：对工具定义做 JSON 序列化后按字节估算。
-- 协议相关，故保留在门面层而非 Domain。
estimateToolsTokens :: [ToolSpec] -> Int
estimateToolsTokens =
  (`div` 3)
    . fromIntegral
    . LazyByteString.length
    . encode

-- | provider 失败文本的上下文溢出判定（provider 兼容启发式，非领域规则）。
isContextOverflow :: ProviderFailure -> Bool
isContextOverflow (ProviderFailure message) = isContextOverflowText message

isContextOverflowText :: Text -> Bool
isContextOverflowText message = any (`Text.isInfixOf` normalized) needles
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
