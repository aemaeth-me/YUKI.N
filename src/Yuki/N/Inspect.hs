module Yuki.N.Inspect
  ( Inspection (..),
    RunTrace (..),
    RunTraceStep (..),
    RunSummary (..),
    UsageSum (..),
    emptyInspection,
    forRun,
    newInspection,
    runIds,
    runSummary,
    runTrace,
    withCognition,
    withLiveJournal,
    withSessionService,
  )
where

import Data.Aeson (ToJSON (..), Value, object, withObject, (.:?), (.=))
import Data.Aeson.Types (Parser, parseMaybe, (.!=))
import Data.Bool (bool)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Functor ((<&>))
import Data.List (nub, sortOn)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Yuki.N.AGUI.Event (Event (..))
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Artifact (ArtifactStore)
import Yuki.N.Cognition (Cognition)
import Yuki.N.Facts (FactStore)
import Yuki.N.Journal (Entry (..), EntryKind (..), Journal)
import Yuki.N.Memory (ThreadStore)
import Yuki.N.Model (ToolOutcome (..))
import Yuki.N.Sessions (SessionService)
import Yuki.N.Transcript (TranscriptStore)

data Inspection = Inspection
  { inspectionMemory :: Maybe (ThreadStore, FactStore),
    inspectionArtifacts :: Maybe ArtifactStore,
    inspectionJournal :: Maybe FilePath,
    inspectionLiveJournal :: Maybe Journal,
    inspectionTranscripts :: Maybe TranscriptStore,
    inspectionSessions :: Maybe SessionService,
    inspectionCognition :: Maybe Cognition
  }

newInspection :: Maybe (ThreadStore, FactStore) -> Maybe ArtifactStore -> Maybe FilePath -> Maybe TranscriptStore -> Inspection
newInspection memory artifacts journal transcripts = Inspection memory artifacts journal Nothing transcripts Nothing Nothing

emptyInspection :: Inspection
emptyInspection = Inspection Nothing Nothing Nothing Nothing Nothing Nothing Nothing

withLiveJournal :: Journal -> Inspection -> Inspection
withLiveJournal journal inspection = inspection {inspectionLiveJournal = Just journal}

withSessionService :: SessionService -> Inspection -> Inspection
withSessionService sessions inspection = inspection {inspectionSessions = Just sessions}

withCognition :: Cognition -> Inspection -> Inspection
withCognition cognition inspection = inspection {inspectionCognition = Just cognition}

runIds :: [Entry] -> [Text]
runIds entries = nub [AGUI.runId input | Entry _ scope _ (RunBegin input _) <- entries, length scope == 1]

forRun :: Maybe Text -> [Entry] -> [Entry]
forRun Nothing = id
forRun (Just runId) = filter ((== Just runId) . listToMaybe . entryScope)

data UsageSum = UsageSum
  { usagePrompt :: Int,
    usageCompletion :: Int,
    usageCacheHit :: Int
  }
  deriving stock (Eq, Show)

instance Semigroup UsageSum where
  UsageSum prompt completion hit <> UsageSum prompt' completion' hit' =
    UsageSum (prompt + prompt') (completion + completion') (hit + hit')

instance Monoid UsageSum where
  mempty = UsageSum 0 0 0

instance ToJSON UsageSum where
  toJSON (UsageSum prompt completion hit) =
    object ["prompt" .= prompt, "completion" .= completion, "cacheHit" .= hit]

data RunSummary = RunSummary
  { summaryRunId :: Text,
    summaryThreadId :: Text,
    summaryEntryCount :: Int,
    summaryTurns :: Int,
    summaryToolCalls :: Int,
    summaryAgentEvents :: Int,
    summaryApiRequests :: Int,
    summaryUsage :: UsageSum,
    summaryMemoryCalls :: Int,
    summaryStatus :: Text,
    summaryFirstSeq :: Int,
    summaryLastSeq :: Int,
    summaryFirstTime :: Maybe Integer,
    summaryLastTime :: Maybe Integer
  }
  deriving stock (Eq, Show)

instance ToJSON RunSummary where
  toJSON summary =
    object
      [ "runId" .= summaryRunId summary,
        "threadId" .= summaryThreadId summary,
        "entryCount" .= summaryEntryCount summary,
        "turns" .= summaryTurns summary,
        "toolCalls" .= summaryToolCalls summary,
        "agentEvents" .= summaryAgentEvents summary,
        "apiRequests" .= summaryApiRequests summary,
        "usage" .= summaryUsage summary,
        "memoryCalls" .= summaryMemoryCalls summary,
        "status" .= summaryStatus summary,
        "firstSeq" .= summaryFirstSeq summary,
        "lastSeq" .= summaryLastSeq summary,
        "firstTime" .= summaryFirstTime summary,
        "lastTime" .= summaryLastTime summary
      ]

data RunTraceStep = RunTraceStep
  { traceStepSeq :: Int,
    traceStepTime :: Maybe Integer,
    traceStepKind :: Text,
    traceStepLabel :: Text,
    traceStepDetail :: Text,
    traceStepStatus :: Text,
    traceStepCallId :: Maybe Text,
    traceStepArtifactIds :: [Text]
  }
  deriving stock (Eq, Show)

instance ToJSON RunTraceStep where
  toJSON item =
    object
      [ "seq" .= traceStepSeq item,
        "time" .= traceStepTime item,
        "kind" .= traceStepKind item,
        "label" .= traceStepLabel item,
        "detail" .= traceStepDetail item,
        "status" .= traceStepStatus item,
        "callId" .= traceStepCallId item,
        "artifactIds" .= traceStepArtifactIds item
      ]

data RunTrace = RunTrace
  { traceRunId :: Text,
    traceThreadId :: Text,
    traceStatus :: Text,
    traceSteps :: [RunTraceStep]
  }
  deriving stock (Eq, Show)

instance ToJSON RunTrace where
  toJSON trace =
    object
      [ "runId" .= traceRunId trace,
        "threadId" .= traceThreadId trace,
        "status" .= traceStatus trace,
        "steps" .= traceSteps trace
      ]

runSummary :: Text -> [Entry] -> Maybe RunSummary
runSummary runId entries = summarize <$> listToMaybe begins
 where
  scoped = filter ((== Just runId) . listToMaybe . entryScope) entries
  begins = [input | Entry _ scope _ (RunBegin input _) <- scoped, length scope == 1]
  events = [event | Entry _ _ _ (AgentEventEntry event) <- scoped]
  firstEntry = listToMaybe scoped
  lastEntry = listToMaybe (reverse scoped)
  ofKind predicate = length (filter (predicate . entryKind) scoped)
  summarize input =
    RunSummary
      { summaryRunId = runId,
        summaryThreadId = AGUI.runThreadId input,
        summaryEntryCount = length scoped,
        summaryTurns = ofKind isModelRequest,
        summaryToolCalls = ofKind isToolCall,
        summaryAgentEvents = length events,
        summaryApiRequests = ofKind isApiRequest,
        summaryUsage = foldMap usageOf scoped,
        summaryMemoryCalls = length (filter (elem "memory" . entryScope) scoped),
        summaryStatus = statusOf events,
        summaryFirstSeq = maybe 0 entrySeq firstEntry,
        summaryLastSeq = maybe 0 entrySeq lastEntry,
        summaryFirstTime = firstEntry >>= entryTime,
        summaryLastTime = lastEntry >>= entryTime
      }
  isModelRequest (ModelRequestEntry _) = True
  isModelRequest _ = False
  isToolCall (ToolCallEntry {}) = True
  isToolCall _ = False
  isApiRequest (ApiRequestEntry _) = True
  isApiRequest _ = False

runTrace :: Text -> [Entry] -> Maybe RunTrace
runTrace runId entries = build <$> listToMaybe begins
 where
  scoped = filter ((== Just runId) . listToMaybe . entryScope) entries
  topLevel = filter ((== 1) . length . entryScope) scoped
  begins = [(entry, input) | entry@(Entry _ _ _ (RunBegin input _)) <- topLevel]
  events = [(entry, event) | entry@(Entry _ _ _ (AgentEventEntry event)) <- topLevel]
  build (begin, input) =
    RunTrace
      runId
      (AGUI.runThreadId input)
      (statusOf (fmap snd events))
      (sortOn traceStepSeq (inputStep begin input : contextSteps <> modelSteps <> reasoningSteps <> assistantSteps <> toolSteps <> compactSteps <> terminalSteps))
  contextSteps =
    [ step entry "context" "加入运行材料" (contextContent value) "completed" Nothing []
    | entry@(Entry _ _ _ (AgentEventEntry (Custom "context.inject" value))) <- topLevel
    ]
  modelSteps =
    zipWith
      (\turn entry -> step entry "model" ("第 " <> Text.pack (show turn) <> " 轮模型请求") "" "completed" Nothing [])
      [(1 :: Int) ..]
      [entry | entry@(Entry _ _ _ (ModelRequestEntry _)) <- topLevel]
  assistantSteps = mapMaybe assistantStep messageIds
  messageIds = nub [identifier | (_, TextMessageContent identifier _) <- events]
  assistantStep identifier =
    listToMaybe matching <&> assistantOf
   where
    matching = [(entry, delta) | (entry, TextMessageContent message delta) <- events, message == identifier]
    content = Text.concat (fmap snd matching)
    assistantOf (first, _) = step first "assistant" "Yuki 回答" (Text.take 1200 content) "completed" Nothing []
  reasoningSteps = mapMaybe reasoningStep reasoningIds
  reasoningIds = nub [identifier | (_, ReasoningStarted identifier) <- events]
  reasoningStep identifier =
    listToMaybe matching <&> reasoningOf
   where
    matching = [entry | (entry, event) <- events, reasoningId event == Just identifier]
    ended = any ((== ReasoningEnded identifier) . snd) events
    detail = Text.pack (show (length [() | (_, ReasoningMessageContent message _) <- events, message == identifier])) <> " 个推理片段"
    reasoningOf first = step first "reasoning" "模型推理" detail (bool "running" "completed" ended) Nothing []
  toolSteps =
    [ step
        entry
        "tool"
        name
        (compactToolDetail arguments outcome)
        (if toolOutcomeError outcome then "failed" else "completed")
        (Just callId)
        (artifactIds (toolOutcomeContent outcome))
    | entry@(Entry _ _ _ (ToolCallEntry callId name arguments outcome)) <- topLevel
    ]
  compactSteps =
    [ step
        entry
        "context"
        "整理上下文"
        (Text.pack (show before) <> " → " <> Text.pack (show after) <> " tokens")
        "completed"
        Nothing
        []
    | entry@(Entry _ _ _ (ContextCompactEntry _ before after _ _ _ _)) <- topLevel
    ]
  terminalSteps =
    maybe
      []
      (\(entry, label, detail, state) -> [step entry "terminal" label detail state Nothing []])
      (listToMaybe (reverse [(entry, label, detail, state) | (entry, event) <- events, Just (label, detail, state) <- [terminal event]]))

inputStep :: Entry -> AGUI.RunAgentInput -> RunTraceStep
inputStep entry input = step entry "user" "用户请求" (Text.take 1200 (lastUserText (AGUI.runMessages input))) "completed" Nothing []

step :: Entry -> Text -> Text -> Text -> Text -> Maybe Text -> [Text] -> RunTraceStep
step entry =
  RunTraceStep (entrySeq entry) (entryTime entry)

lastUserText :: [AGUI.Message] -> Text
lastUserText =
  maybe "" userText
    . listToMaybe
    . reverse
    . filter isUser
 where
  isUser AGUI.User {} = True
  isUser _ = False
  userText (AGUI.User message) =
    case AGUI.userContent message of
      AGUI.UserText content -> content
      AGUI.UserParts parts -> Text.intercalate "\n" [content | AGUI.InputText content <- parts]
  userText _ = ""

reasoningId :: Event -> Maybe Text
reasoningId = \case
  ReasoningStarted identifier -> Just identifier
  ReasoningMessageStarted identifier -> Just identifier
  ReasoningMessageContent identifier _ -> Just identifier
  ReasoningMessageEnded identifier -> Just identifier
  ReasoningEnded identifier -> Just identifier
  _ -> Nothing

terminal :: Event -> Maybe (Text, Text, Text)
terminal = \case
  RunFinished {} -> Just ("运行完成", "", "completed")
  RunError message _ -> Just ("运行失败", Text.take 1200 message, "failed")
  _ -> Nothing

compactToolDetail :: Text -> ToolOutcome -> Text
compactToolDetail arguments outcome =
  Text.take 900 arguments
    <> bool ("\n→ " <> Text.take 900 (toolOutcomeContent outcome)) "" (Text.null (Text.strip (toolOutcomeContent outcome)))

contextContent :: Value -> Text
contextContent =
  Text.take 1200
    . fromMaybe ""
    . parseMaybe
      (withObject "context.inject" (\fields -> fields .:? "content" .!= ""))

artifactIds :: Text -> [Text]
artifactIds = nub . unfold
 where
  unfold content =
    case Text.breakOn "art-" content of
      (_, suffix)
        | Text.null suffix -> []
        | otherwise ->
            let identifier = Text.takeWhile artifactChar suffix
             in identifier : unfold (Text.drop (Text.length identifier) suffix)
  artifactChar character =
    isAsciiLower character
      || isAsciiUpper character
      || isDigit character
      || character `elem` ("-_" :: String)

usageOf :: Entry -> UsageSum
usageOf = fromMaybe mempty . usageValue . entryKind
 where
  usageValue (AgentEventEntry (Custom "usage" value)) = parseMaybe usageParser value
  usageValue _ = Nothing
  usageParser :: Value -> Parser UsageSum
  usageParser =
    withObject "usage" $ \fields ->
      UsageSum
        <$> fields .:? "promptTokens" .!= 0
        <*> fields .:? "completionTokens" .!= 0
        <*> fields .:? "cacheHitTokens" .!= 0

statusOf :: [Event] -> Text
statusOf =
  fromMaybe "open"
    . listToMaybe
    . reverse
    . mapMaybe status
 where
  status RunFinished {} = Just "finished"
  status RunError {} = Just "error"
  status _ = Nothing
