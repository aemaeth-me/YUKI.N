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
import Data.Bool (bool)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char qualified as Char
import Data.List (mapAccumL)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Yuki.N.AGUI.Types (ToolSpec)
import Yuki.N.Model

data ContextConfig = ContextConfig
  { contextReserveTokens :: Int,
    contextKeepUnits :: Int,
    contextSummaryTokens :: Int,
    contextFallbackChars :: Int
  }
  deriving stock (Eq, Show)

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

data Compaction = Compaction
  { compactionMessages :: [ChatMessage],
    compactionDropped :: [ChatMessage],
    compactionBeforeTokens :: Int,
    compactionAfterTokens :: Int,
    compactionBudgetTokens :: Int,
    compactionKeptUnits :: Int,
    compactionSummary :: Text,
    compactionPayload :: Text
  }
  deriving stock (Eq, Show)

contextSummaryMarker :: Text
contextSummaryMarker = "[context summary]"

compactMessages :: ContextConfig -> Maybe Int -> [ToolSpec] -> [ChatMessage] -> Maybe Compaction
compactMessages config window tools messages =
  compactToBudget config (contextBudget config window tools) messages

emergencyCompactMessages :: ContextConfig -> Maybe Int -> [ToolSpec] -> [ChatMessage] -> Maybe Compaction
emergencyCompactMessages config window tools =
  compactToBudget emergency (max 256 (contextBudget config window tools `div` 2))
 where
  emergency =
    config
      { contextKeepUnits = min 2 (contextKeepUnits config),
        contextSummaryTokens = min 384 (contextSummaryTokens config)
      }

contextBudget :: ContextConfig -> Maybe Int -> [ToolSpec] -> Int
contextBudget config window tools =
  max 256 (contextWindow config window - contextReserveTokens config - estimateToolsTokens tools)

contextWindow :: ContextConfig -> Maybe Int -> Int
contextWindow config = fromMaybe (max 1024 (contextFallbackChars config `div` 3))

compactToBudget :: ContextConfig -> Int -> [ChatMessage] -> Maybe Compaction
compactToBudget config budget messages
  | before <= budget = Nothing
  | null body = Nothing
  | otherwise =
      Just
        Compaction
          { compactionMessages = final,
            compactionDropped = concat dropped,
            compactionBeforeTokens = before,
            compactionAfterTokens = estimateMessagesTokens final,
            compactionBudgetTokens = budget,
            compactionKeptUnits = length kept,
            compactionSummary = summary,
            compactionPayload = payload
          }
 where
  before = estimateMessagesTokens messages
  (leading, bodyMessages) = span isSystem messages
  systems = filter (not . isSummary) leading
  previous = Text.intercalate "\n\n" [text | ChatSystem text <- leading, isSummary (ChatSystem text)]
  body = messageUnits bodyMessages
  summaryBudget = max 96 (min (contextSummaryTokens config) (budget `div` 3))
  anchorBudget = min 128 (max 32 (budget `div` 16))
  available = budget - estimateMessagesTokens systems - summaryBudget - 12
  initial = recentUnits (contextKeepUnits config) (max 64 available) body
  anchorNeeded = needsUserAnchor (concat (snd initial))
  (dropped, kept) =
    bool
      initial
      (recentUnits (contextKeepUnits config) (max 64 (available - anchorBudget - 4)) body)
      anchorNeeded
  recent = concat kept
  anchor =
    [ ChatUser
        ( clipTextTokens
            anchorBudget
            (fromMaybe "Continue from the compacted user request above." (lastUser (concat dropped)))
        )
    | anchorNeeded
    ]
  payload = Text.intercalate "\n\n" (filter (not . Text.null) [previous, renderMessages (concat dropped)])
  summary =
    contextSummaryMarker
      <> "\nEarlier conversation was compacted locally. Preserve decisions, facts, constraints and open work from these excerpts.\n\n"
      <> clipTextTokens summaryBudget payload
  candidate = systems <> [ChatSystem summary] <> anchor <> recent
  final = fitSummary budget candidate

lastUser :: [ChatMessage] -> Maybe Text
lastUser = listToMaybe . reverse . foldr keep []
 where
  keep (ChatUser text) users = text : users
  keep _ users = users

needsUserAnchor :: [ChatMessage] -> Bool
needsUserAnchor [] = False
needsUserAnchor (ChatUser {} : _) = False
needsUserAnchor _ = True

isSystem :: ChatMessage -> Bool
isSystem (ChatSystem _) = True
isSystem _ = False

isSummary :: ChatMessage -> Bool
isSummary (ChatSystem text) = contextSummaryMarker `Text.isPrefixOf` text
isSummary _ = False

messageUnits :: [ChatMessage] -> [[ChatMessage]]
messageUnits [] = []
messageUnits (message@(ChatAssistant turn) : rest)
  | null (turnToolCalls turn) = [message] : messageUnits rest
  | otherwise =
      let (results, remaining) = span isToolResult rest
       in (message : results) : messageUnits remaining
messageUnits (message : rest) = [message] : messageUnits rest

isToolResult :: ChatMessage -> Bool
isToolResult (ChatToolResult _ _) = True
isToolResult _ = False

recentUnits :: Int -> Int -> [[ChatMessage]] -> ([[ChatMessage]], [[ChatMessage]])
recentUnits keep budget units =
  (take (length units - length fitted) units, reverse fitted)
 where
  candidates = take (max 1 keep) (reverse units)
  fitted = fitRecent budget candidates

fitRecent :: Int -> [[ChatMessage]] -> [[ChatMessage]]
fitRecent budget = go 0
 where
  go _ [] = []
  go spent (unit : rest)
    | spent + cost <= budget = unit : go (spent + cost) rest
    | spent == 0 = [clipUnit budget unit]
    | otherwise = []
   where
    cost = estimateMessagesTokens unit

clipUnit :: Int -> [ChatMessage] -> [ChatMessage]
clipUnit budget unit = snd (mapAccumL clip budget unit)
 where
  share remaining = max 12 (remaining `div` max 1 (length unit))
  clip remaining message =
    let allowance = share remaining
        clipped = clipMessage allowance message
     in (max 0 (remaining - estimateMessageTokens clipped), clipped)

clipMessage :: Int -> ChatMessage -> ChatMessage
clipMessage limit = \case
  ChatSystem text -> ChatSystem (clipTextTokens limit text)
  ChatUser text -> ChatUser (clipTextTokens limit text)
  ChatToolResult call content -> ChatToolResult call (clipTextTokens limit content)
  ChatAssistant turn ->
    ChatAssistant
      turn
        { turnText = clipTextTokens (limit `div` 2) <$> turnText turn,
          turnReasoning = Nothing,
          turnToolCalls =
            [call {modelToolArguments = clipTextTokens (max 8 (limit `div` max 1 (length (turnToolCalls turn)))) (modelToolArguments call)} | call <- turnToolCalls turn]
        }

fitSummary :: Int -> [ChatMessage] -> [ChatMessage]
fitSummary budget messages
  | estimateMessagesTokens messages <= budget = messages
  | otherwise =
      [ case message of
          ChatSystem text
            | contextSummaryMarker `Text.isPrefixOf` text -> ChatSystem (clipTextTokens allowance text)
          _ -> message
      | message <- messages
      ]
 where
  other = estimateMessagesTokens (filter (not . isSummary) messages)
  allowance = max 24 (budget - other - 4)

attachCompactionArtifact :: Text -> Compaction -> Compaction
attachCompactionArtifact identifier compaction =
  compaction
    { compactionMessages = attached,
      compactionAfterTokens = estimateMessagesTokens attached,
      compactionSummary = summary
    }
 where
  suffix = "\nFull dropped context: artifact " <> identifier <> "."
  other = estimateMessagesTokens (filter (not . isSummary) (compactionMessages compaction))
  allowance = max 24 (compactionBudgetTokens compaction - other - 4)
  summary = clipTextTokens (max 1 (allowance - estimateTextTokens suffix)) (compactionSummary compaction) <> suffix
  attached = fmap attach (compactionMessages compaction)
  attach (ChatSystem text)
    | contextSummaryMarker `Text.isPrefixOf` text = ChatSystem summary
  attach message = message

estimateMessagesTokens :: [ChatMessage] -> Int
estimateMessagesTokens = sum . fmap estimateMessageTokens

estimateMessageTokens :: ChatMessage -> Int
estimateMessageTokens =
  (4 +) . \case
    ChatSystem text -> estimateTextTokens text
    ChatUser text -> estimateTextTokens text
    ChatToolResult call content -> estimateTextTokens call + estimateTextTokens content
    ChatAssistant turn ->
      sum
        [ maybe 0 estimateTextTokens (turnText turn),
          maybe 0 estimateTextTokens (turnReasoning turn),
          sum [estimateTextTokens (modelToolName call) + estimateTextTokens (modelToolArguments call) + 4 | call <- turnToolCalls turn]
        ]

estimateTextTokens :: Text -> Int
estimateTextTokens text = max 1 (nonAscii + asciiTokens)
 where
  (ascii, nonAscii) =
    Text.foldl'
      (\(a, n) char -> if Char.isAscii char then (a + 1, n) else (a, n + 1))
      (0, 0)
      text
  asciiTokens = (ascii + 2) `div` 3

estimateToolsTokens :: [ToolSpec] -> Int
estimateToolsTokens =
  (`div` 3)
    . fromIntegral
    . LazyByteString.length
    . encode

clipTextTokens :: Int -> Text -> Text
clipTextTokens limit text
  | estimateTextTokens text <= limit = text
  | otherwise = Text.take (fit 0 (Text.length text)) text <> "\n[…truncated…]"
 where
  marker = estimateTextTokens "\n[…truncated…]"
  target = max 1 (limit - marker)
  fit low high
    | low >= high = low
    | estimateTextTokens (Text.take middle text) <= target = fit middle high
    | otherwise = fit low (middle - 1)
   where
    middle = (low + high + 1) `div` 2

renderMessages :: [ChatMessage] -> Text
renderMessages = Text.intercalate "\n" . fmap renderMessage

renderMessage :: ChatMessage -> Text
renderMessage = \case
  ChatSystem text -> "system: " <> text
  ChatUser text -> "user: " <> text
  ChatToolResult call content -> "tool[" <> call <> "]: " <> content
  ChatAssistant turn ->
    "assistant: "
      <> fromMaybe "" (turnText turn)
      <> maybe "" ("\nreasoning: " <>) (turnReasoning turn)
      <> Text.concat
        [ "\ntool-call[" <> modelToolCallId call <> "] " <> modelToolName call <> ": " <> modelToolArguments call
        | call <- turnToolCalls turn
        ]

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
