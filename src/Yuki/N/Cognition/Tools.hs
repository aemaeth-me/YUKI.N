module Yuki.N.Cognition.Tools
  ( cognitionGeneratePrompt,
    cognitionTools,
    encodeText,
    latestActive,
    nonEmpty,
    stripFence,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar (modifyMVar_)
import Data.Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor (($>), (<&>))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing, listToMaybe)
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent
import Yuki.N.Cognition.Types
import Yuki.N.Incarnation
import Yuki.N.Invocation
import Yuki.N.Memory.Archive
import Yuki.N.Memory.Impression
import Yuki.N.Memory.Working
import Yuki.N.Model

latestActive :: PromptLayer -> [PromptRevision] -> Maybe PromptRevision
latestActive layer =
  listToMaybe
    . sortOn (Down . promptOrdinal)
    . filter ((== PromptActive) . promptStatus)
    . filter ((== layer) . promptLayer)

cognitionGeneratePrompt :: Cognition -> Incarnation -> Text -> IO (Either Text PromptRevision)
cognitionGeneratePrompt cognition incarnation source
  | null (cognitionModels cognition) = pure (Left "no model is available for prompt generation")
  | Text.null (Text.strip source) = pure (Left "prompt generation source intent must not be empty")
  | otherwise =
      promptList (cognitionIncarnations cognition) Nothing
        >>= maybe (pure (Left "no active Root Constitution is available")) generate . latestActive RootConstitution
 where
  generate root =
    newId >>= invokeGenerator root
  invokeGenerator root invocationId' =
    let generator = "incarnation-charter-generator/v2@" <> promptRevisionId root
        specification =
          InvocationSpec
            invocationId'
            "prompt.generate"
            generator
            (cognitionModels cognition)
            [ ChatSystem (promptGenerator root),
              ChatUser
                ( Text.intercalate
                    "\n"
                    [ "Incarnation id: " <> incarnationId incarnation,
                      "Name: " <> incarnationName incarnation,
                      "Direction: " <> incarnationDirection incarnation,
                      "Revision intent: " <> Text.strip source,
                      "Root revision: " <> promptRevisionId root,
                      "Root effective hash: " <> promptEffectiveHash root
                    ]
                )
            ]
            2
            20000
            60000
            (cognitionJournal cognition)
     in invokeModel specification >>= either (pure . Left) (store generator invocationId')
  promptGenerator root =
    Text.intercalate
      "\n\n"
      [ promptContent root,
        "Generate only one composite incarnation charter with explicit sections for working style, judgment tendencies, capability/tool policy, memory policy, self-management and boundaries. This charter is the sole generated incarnation layer beneath Root; task and worker prompts remain local descendants. Do not repeat the Root Constitution. Use clear Markdown. The charter must be concrete enough for the incarnation to recognize and manage itself."
      ]
  store generator invocationId' result =
    let content = Text.strip (stripFence (invocationResultText result))
     in if Text.null content
          then pure (Left "prompt generator returned empty content")
          else
            Right
              <$> promptAppend
                (cognitionIncarnations cognition)
                (Just (incarnationId incarnation))
                IncarnationCharter
                (Text.take 1000 (Text.strip source))
                content
                generator
                (Just invocationId')
                (incarnationPromptRevision incarnation)
                PromptDraft

cognitionTools :: Cognition -> Incarnation -> Map Text BackendTool
cognitionTools cognition incarnation =
  Map.fromList
    [ named (jsonContextTool grepSpec grepMemory),
      named (jsonContextTool readSpec readMemory),
      named (jsonContextTool inspectSpec inspectSelf),
      named (jsonContextTool updateSpec updateSelf),
      named sleepTool
    ]
 where
  identity = incarnationId incarnation
  named tool = (AGUI.toolName (backendToolSpec tool), tool)
  grepMemory context call =
    taskArchiveGrep
      (cognitionArchive cognition)
      ( ArchiveGrepRequest
          identity
          (grepCallQuery call)
          (grepCallTaskId call)
          (grepCallKinds call)
          (grepCallCaseSensitive call)
          (fromMaybe 20 (grepCallLimit call))
          (fromMaybe 0 (grepCallOffset call))
          (grepCallIncludeProcess call)
          (if isNothing (grepCallTaskId call) then Just (toolContextThreadId context) else Nothing)
      )
  readMemory _ call =
    taskArchiveRead
      (cognitionArchive cognition)
      ( ArchiveReadRequest
          identity
          (readCallId call)
          (fromMaybe 2 (readCallBefore call))
          (fromMaybe 2 (readCallAfter call))
          (fromMaybe 0 (readCallOffset call))
          (fromMaybe 6000 (readCallChars call))
      )
  inspectSelf _ NoArguments =
    liftA2
      inspectObject
      (maybe (pure Nothing) (promptRead (cognitionIncarnations cognition)) (incarnationPromptRevision incarnation))
      (liftA2 (,) (workingRead (cognitionWorking cognition) identity) (impressionRead (cognitionImpressions cognition) identity))
      <&> Right
   where
    inspectObject prompt (working, impression) =
      object
        [ "incarnation" .= incarnation,
          "activePrompt" .= prompt,
          "workingMemory" .= working,
          "impression" .= impression
        ]
  updateSelf _ call =
    incarnationRead (cognitionIncarnations cognition) identity
      >>= maybe
        (pure (Left ("unknown incarnation: " <> identity)))
        updateCurrent
   where
    updateCurrent current =
      incarnationUpdate
        (cognitionIncarnations cognition)
        identity
        (selfCallExpectedRevision call)
        (fromMaybe (incarnationName current) (selfCallName call))
        (fromMaybe (incarnationDirection current) (selfCallDirection call))
        (selfCallImpressionModel call <|> incarnationImpressionModel current)
        >>= either (pure . Left) generate
    generate changed =
      cognitionGeneratePrompt cognition changed (selfCallReason call)
        >>= either (pure . Left) (finish changed)
    finish changed prompt
      | selfCallActivate call =
          promptActivate
            (cognitionIncarnations cognition)
            identity
            (incarnationRevision changed)
            (promptRevisionId prompt)
            <&> fmap (activateResult prompt)
      | otherwise = pure (Right (object ["incarnation" .= changed, "prompt" .= prompt]))
    activateResult prompt activated =
      object ["incarnation" .= activated, "prompt" .= prompt]
  sleepTool =
    BackendTool sleepSpec $ \context arguments ->
      case fromJSON arguments of
        Error failure -> pure (ToolOutcome ("invalid sleep arguments: " <> Text.pack failure) True False)
        Success (SleepCall reason) ->
          modifyMVar_ (cognitionSleepRequests cognition) (pure . Set.insert (identity, toolContextRunId context))
            $> ToolOutcome
              ( "Sleep requested"
                  <> maybe "" (": " <>) (nonEmpty =<< reason)
                  <> ". On the next cognition boundary, decide what to forget, wake, and continue."
              )
              False
              False

data GrepCall = GrepCall
  { grepCallQuery :: Text,
    grepCallTaskId :: Maybe Text,
    grepCallKinds :: [ArchiveKind],
    grepCallCaseSensitive :: Bool,
    grepCallLimit :: Maybe Int,
    grepCallOffset :: Maybe Int,
    grepCallIncludeProcess :: Bool
  }

instance FromJSON GrepCall where
  parseJSON = withObject "GrepCall" $ \fields ->
    GrepCall
      <$> fields .: "query"
      <*> fields .:? "taskId"
      <*> fields .:? "kinds" .!= []
      <*> fields .:? "caseSensitive" .!= False
      <*> fields .:? "limit"
      <*> fields .:? "offset"
      <*> fields .:? "includeProcess" .!= False

data ReadCall = ReadCall
  { readCallId :: Text,
    readCallBefore :: Maybe Int,
    readCallAfter :: Maybe Int,
    readCallOffset :: Maybe Int,
    readCallChars :: Maybe Int
  }

instance FromJSON ReadCall where
  parseJSON = withObject "ReadCall" $ \fields ->
    ReadCall
      <$> (fields .: "entryId" <|> fields .: "id")
      <*> fields .:? "before"
      <*> fields .:? "after"
      <*> fields .:? "offset"
      <*> fields .:? "chars"

data SelfCall = SelfCall
  { selfCallExpectedRevision :: Int,
    selfCallName :: Maybe Text,
    selfCallDirection :: Maybe Text,
    selfCallImpressionModel :: Maybe Text,
    selfCallReason :: Text,
    selfCallActivate :: Bool
  }

instance FromJSON SelfCall where
  parseJSON = withObject "SelfCall" $ \fields ->
    SelfCall
      <$> fields .: "expectedRevision"
      <*> fields .:? "name"
      <*> fields .:? "direction"
      <*> fields .:? "impressionModel"
      <*> fields .: "reason"
      <*> fields .:? "activate" .!= False

newtype SleepCall = SleepCall (Maybe Text)

instance FromJSON SleepCall where
  parseJSON = withObject "SleepCall" $ \fields -> SleepCall <$> fields .:? "reason"

data NoArguments = NoArguments

instance FromJSON NoArguments where
  parseJSON = withObject "NoArguments" (const (pure NoArguments))

jsonContextTool ::
  (FromJSON input, ToJSON output) =>
  AGUI.ToolSpec ->
  (ToolContext -> input -> IO (Either Text output)) ->
  BackendTool
jsonContextTool specification execute =
  BackendTool specification $ \context arguments ->
    case fromJSON arguments of
      Error failure -> pure (ToolOutcome ("invalid tool arguments: " <> Text.pack failure) True False)
      Success input ->
        execute context input
          <&> either
            (\failure -> ToolOutcome failure True False)
            (\output -> ToolOutcome (encodeText output) False False)

grepSpec, readSpec, inspectSpec, updateSpec, sleepSpec :: AGUI.ToolSpec
grepSpec =
  toolSpec
    "memory_grep"
    "Deterministically scan this incarnation's Task archive for a fixed string. The current task is excluded by default since its transcript is already in context; pass an explicit taskId to search a specific task including the current one. Source evidence is ranked before derived assistant text; memory_grep/memory_read process records are excluded unless includeProcess is true. Pagination and source completeness are explicit. Follow source hits with bounded memory_read before relying on them."
    ( object
        [ "query" .= stringSchema,
          "taskId" .= stringSchema,
          "kinds" .= arraySchema (enumSchema ["instruction", "user", "reasoning", "assistant", "tool-call", "tool-result", "wake-packet"]),
          "caseSensitive" .= boolSchema,
          "limit" .= integerSchema,
          "offset" .= integerSchema,
          "includeProcess" .= boolSchema
        ]
    )
    ["query"]
readSpec =
  toolSpec
    "memory_read"
    "Read a bounded structured window around one exact Task archive entry returned by memory_grep. Increase offset to inspect another slice of a large entry."
    ( object
        [ "entryId" .= stringSchema,
          "before" .= integerSchema,
          "after" .= integerSchema,
          "offset" .= integerSchema,
          "chars" .= integerSchema
        ]
    )
    ["entryId"]
inspectSpec =
  toolSpec
    "self_inspect"
    "Inspect this incarnation's identity, active charter, working-memory state and impression state before managing itself."
    (object [])
    []
updateSpec =
  toolSpec
    "self_update"
    "Update this incarnation's direction or name, then automatically generate an auditable charter revision. Activation is explicit."
    ( object
        [ "expectedRevision" .= integerSchema,
          "name" .= stringSchema,
          "direction" .= stringSchema,
          "impressionModel" .= stringSchema,
          "reason" .= stringSchema,
          "activate" .= boolSchema
        ]
    )
    ["expectedRevision", "reason"]
sleepSpec =
  toolSpec
    "sleep"
    "Sleep at the next cognition boundary: use a model to decide what to forget, create a durable Wake Packet, wake, then continue this same task."
    (object ["reason" .= stringSchema])
    []

toolSpec :: Text -> Text -> Value -> [Text] -> AGUI.ToolSpec
toolSpec name description properties required =
  AGUI.ToolSpec
    name
    description
    ( object
        [ "type" .= ("object" :: Text),
          "properties" .= properties,
          "required" .= required,
          "additionalProperties" .= False
        ]
    )

stringSchema, integerSchema, boolSchema :: Value
stringSchema = object ["type" .= ("string" :: Text)]
integerSchema = object ["type" .= ("integer" :: Text)]
boolSchema = object ["type" .= ("boolean" :: Text)]

enumSchema :: [Text] -> Value
enumSchema values = object ["type" .= ("string" :: Text), "enum" .= values]

arraySchema :: Value -> Value
arraySchema items = object ["type" .= ("array" :: Text), "items" .= items]

nonEmpty :: Text -> Maybe Text
nonEmpty text
  | Text.null (Text.strip text) = Nothing
  | otherwise = Just (Text.strip text)

encodeText :: (ToJSON value) => value -> Text
encodeText = TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

stripFence :: Text -> Text
stripFence raw =
  fromMaybe trimmed (prefix >>= stripSuffix)
 where
  trimmed = Text.strip raw
  prefix = Text.stripPrefix "```json" trimmed <|> Text.stripPrefix "```" trimmed
  stripSuffix inner = Text.stripSuffix "```" (Text.strip inner)
