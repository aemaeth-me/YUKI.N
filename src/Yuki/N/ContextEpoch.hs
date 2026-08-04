module Yuki.N.ContextEpoch
  ( ContextAuthority (..),
    ContextEpoch (..),
    ContextEpochStore (..),
    ContextSegment (..),
    ContextSegmentInput (..),
    ContextSegmentKind (..),
    aguiSegments,
    newContextEpochStore,
    newMemoryContextEpochStore,
    projectedAguiMessages,
  )
where

import Control.Concurrent.MVar
import Control.Exception (IOException, displayException, try)
import Control.Monad (void, (>=>))
import Data.Aeson
import Data.Bool (bool)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor (($>), (<&>))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.AtomicFile (atomicEncodeFile)
import Yuki.N.Blob
import Yuki.N.Model (ModelToolCall (..))

data ContextSegmentKind
  = SegmentInstruction
  | SegmentUser
  | SegmentAssistant
  | SegmentToolCall
  | SegmentToolResult
  | SegmentWakePacket
  deriving stock (Eq, Show)

instance ToJSON ContextSegmentKind where
  toJSON =
    String . \case
      SegmentInstruction -> "instruction"
      SegmentUser -> "user"
      SegmentAssistant -> "assistant"
      SegmentToolCall -> "tool-call"
      SegmentToolResult -> "tool-result"
      SegmentWakePacket -> "wake-packet"

instance FromJSON ContextSegmentKind where
  parseJSON = withText "ContextSegmentKind" $ \case
    "instruction" -> pure SegmentInstruction
    "user" -> pure SegmentUser
    "assistant" -> pure SegmentAssistant
    "tool-call" -> pure SegmentToolCall
    "tool-result" -> pure SegmentToolResult
    "wake-packet" -> pure SegmentWakePacket
    value -> fail ("unknown context segment kind: " <> Text.unpack value)

data ContextAuthority
  = AuthorityKernel
  | AuthorityUser
  | AuthorityAgent
  | AuthorityTool
  | AuthorityDerived
  deriving stock (Eq, Show)

instance ToJSON ContextAuthority where
  toJSON =
    String . \case
      AuthorityKernel -> "kernel"
      AuthorityUser -> "user"
      AuthorityAgent -> "agent"
      AuthorityTool -> "tool"
      AuthorityDerived -> "derived"

instance FromJSON ContextAuthority where
  parseJSON = withText "ContextAuthority" $ \case
    "kernel" -> pure AuthorityKernel
    "user" -> pure AuthorityUser
    "agent" -> pure AuthorityAgent
    "tool" -> pure AuthorityTool
    "derived" -> pure AuthorityDerived
    value -> fail ("unknown context authority: " <> Text.unpack value)

data ContextSegmentInput = ContextSegmentInput
  { segmentInputSourceId :: Text,
    segmentInputKind :: ContextSegmentKind,
    segmentInputAuthority :: ContextAuthority,
    segmentInputContent :: Text,
    segmentInputCausalGroup :: Maybe Text,
    segmentInputTurnGroup :: Maybe Text
  }
  deriving stock (Eq, Show)

data ContextSegment = ContextSegment
  { contextSegmentId :: Text,
    contextSegmentKind :: ContextSegmentKind,
    contextSegmentAuthority :: ContextAuthority,
    contextSegmentSourceRef :: Text,
    contextSegmentContentRef :: Text,
    contextSegmentContentHash :: Text,
    contextSegmentCausalGroup :: Maybe Text,
    contextSegmentTurnGroup :: Maybe Text,
    contextSegmentCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON ContextSegment where
  toJSON segment =
    object
      [ "id" .= contextSegmentId segment,
        "kind" .= contextSegmentKind segment,
        "authority" .= contextSegmentAuthority segment,
        "sourceRef" .= contextSegmentSourceRef segment,
        "contentRef" .= contextSegmentContentRef segment,
        "contentHash" .= contextSegmentContentHash segment,
        "causalGroup" .= contextSegmentCausalGroup segment,
        "turnGroup" .= contextSegmentTurnGroup segment,
        "created" .= contextSegmentCreated segment
      ]

instance FromJSON ContextSegment where
  parseJSON = withObject "ContextSegment" $ \fields ->
    ContextSegment
      <$> fields .: "id"
      <*> fields .: "kind"
      <*> fields .: "authority"
      <*> fields .: "sourceRef"
      <*> fields .: "contentRef"
      <*> fields .: "contentHash"
      <*> fields .:? "causalGroup"
      <*> fields .:? "turnGroup"
      <*> fields .: "created"

data ContextEpoch = ContextEpoch
  { contextEpochId :: Text,
    contextEpochIncarnationId :: Text,
    contextEpochTaskId :: Text,
    contextEpochParentId :: Maybe Text,
    contextEpochRevision :: Int,
    contextEpochSegmentIds :: [Text],
    contextEpochTokenEstimate :: Int,
    contextEpochWakePacketId :: Maybe Text,
    contextEpochEffectiveHash :: Text,
    contextEpochCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON ContextEpoch where
  toJSON epoch =
    object
      [ "id" .= contextEpochId epoch,
        "incarnationId" .= contextEpochIncarnationId epoch,
        "taskId" .= contextEpochTaskId epoch,
        "parentEpochId" .= contextEpochParentId epoch,
        "revision" .= contextEpochRevision epoch,
        "segmentIds" .= contextEpochSegmentIds epoch,
        "tokenEstimate" .= contextEpochTokenEstimate epoch,
        "wakePacketId" .= contextEpochWakePacketId epoch,
        "effectiveHash" .= contextEpochEffectiveHash epoch,
        "created" .= contextEpochCreated epoch
      ]

instance FromJSON ContextEpoch where
  parseJSON = withObject "ContextEpoch" $ \fields ->
    ContextEpoch
      <$> fields .: "id"
      <*> fields .: "incarnationId"
      <*> fields .: "taskId"
      <*> fields .:? "parentEpochId"
      <*> fields .:? "revision" .!= 1
      <*> fields .: "segmentIds"
      <*> fields .:? "tokenEstimate" .!= 0
      <*> fields .:? "wakePacketId"
      <*> fields .: "effectiveHash"
      <*> fields .: "created"

data ContextEpochStore = ContextEpochStore
  { contextEpochCommit ::
      Text ->
      Text ->
      Maybe Text ->
      [ContextSegmentInput] ->
      Maybe Text ->
      IO (Either Text ContextEpoch),
    contextEpochHead :: Text -> Text -> IO (Maybe ContextEpoch),
    contextEpochRead :: Text -> IO (Maybe ContextEpoch),
    contextEpochList :: Text -> Text -> IO [ContextEpoch],
    contextSegmentRead :: Text -> IO (Maybe ContextSegment),
    contextEpochProject :: Text -> IO (Either Text [(ContextSegment, Text)]),
    contextEpochDeleteIncarnation :: Text -> IO ()
  }

data ContextState = ContextState
  { stateEpochs :: Map Text ContextEpoch,
    stateSegments :: Map Text ContextSegment,
    stateHeads :: Map Text Text
  }

instance ToJSON ContextState where
  toJSON state =
    object
      [ "epochs" .= stateEpochs state,
        "segments" .= stateSegments state,
        "heads" .= stateHeads state
      ]

instance FromJSON ContextState where
  parseJSON = withObject "ContextState" $ \fields ->
    ContextState
      <$> fields .:? "epochs" .!= Map.empty
      <*> fields .:? "segments" .!= Map.empty
      <*> fields .:? "heads" .!= Map.empty

emptyState :: ContextState
emptyState = ContextState Map.empty Map.empty Map.empty

newContextEpochStore :: FilePath -> BlobStore -> IO (Either Text ContextEpochStore)
newContextEpochStore dir blobs =
  createDirectoryIfMissing True dir
    *> loadState (statePath dir)
    >>= traverse (newMVar >=> pure . mkStore (atomicEncodeFile (statePath dir)) blobs)

newMemoryContextEpochStore :: BlobStore -> IO ContextEpochStore
newMemoryContextEpochStore blobs = newMVar emptyState <&> mkStore (const (pure ())) blobs

mkStore :: (ContextState -> IO ()) -> BlobStore -> MVar ContextState -> ContextEpochStore
mkStore persist blobs lock =
  ContextEpochStore
    { contextEpochCommit = commit,
      contextEpochHead = \incarnationId taskId ->
        headEpoch incarnationId taskId <$> readMVar lock,
      contextEpochRead = \identifier -> Map.lookup identifier . stateEpochs <$> readMVar lock,
      contextEpochList = \incarnationId taskId ->
        sortOn contextEpochRevision
          . filter
            ( (&&)
                <$> ((== incarnationId) . contextEpochIncarnationId)
                <*> ((== taskId) . contextEpochTaskId)
            )
          . Map.elems
          . stateEpochs
          <$> readMVar lock,
      contextSegmentRead = \identifier -> Map.lookup identifier . stateSegments <$> readMVar lock,
      contextEpochProject = project,
      contextEpochDeleteIncarnation = deleteIncarnation persist lock
    }
 where
  commit incarnation task expected inputs wake =
    liftA2 (,) (materializeSegments blobs incarnation task inputs) getPOSIXTime
      >>= commitNow incarnation task expected inputs wake
  commitNow incarnation task expected inputs wake (segments, now) =
    modifyMVar lock $ \state ->
      let scope = headKey incarnation task
          currentId = Map.lookup scope (stateHeads state)
       in if currentId /= expected
            then pure (state, Left (stale currentId expected))
            else
              let parent = currentId >>= flip Map.lookup (stateEpochs state)
                  revision = maybe 1 ((+ 1) . contextEpochRevision) parent
                  segmentIds = fmap contextSegmentId segments
                  effective = epochHash incarnation task revision segmentIds wake
                  identifier = "epoch-" <> Text.take 32 effective
                  epoch =
                    ContextEpoch identifier incarnation task currentId revision segmentIds (sum (fmap (estimateTokens . segmentInputContent) inputs)) wake effective (round now)
                  changed =
                    state
                      { stateEpochs = Map.insert identifier epoch (stateEpochs state),
                        stateSegments = foldr (\segment -> Map.insert (contextSegmentId segment) segment) (stateSegments state) segments,
                        stateHeads = Map.insert scope identifier (stateHeads state)
                      }
               in persist changed $> (changed, Right epoch)
  project identifier =
    readMVar lock >>= projectState identifier
  projectState identifier state =
    maybe
      (pure (Left ("unknown context epoch: " <> identifier)))
      (projectEpoch (stateSegments state))
      (Map.lookup identifier (stateEpochs state))
  projectEpoch segments epoch =
    traverse (fetchSegment segments) (contextEpochSegmentIds epoch) <&> sequence
  fetchSegment segments segmentId =
    maybe
      (pure (Left ("missing context segment: " <> segmentId)))
      fetchContent
      (Map.lookup segmentId segments)
  fetchContent segment =
    blobFetch blobs (contextSegmentContentRef segment)
      <&> fmap ((,) segment . TextEncoding.decodeUtf8 . LazyByteString.toStrict)
  headEpoch incarnationId taskId state =
    Map.lookup (headKey incarnationId taskId) (stateHeads state) >>= flip Map.lookup (stateEpochs state)

materializeSegments :: BlobStore -> Text -> Text -> [ContextSegmentInput] -> IO [ContextSegment]
materializeSegments blobs incarnation task =
  traverse materialize
 where
  materialize input =
    getPOSIXTime >>= persistSegment input
  persistSegment input now =
    blobPut blobs "text/plain; charset=utf-8" (LazyByteString.fromStrict contentBytes)
      >>= attachBlob
   where
    contentBytes = TextEncoding.encodeUtf8 (segmentInputContent input)
    contentHash = sha256 contentBytes
    identifier =
      "segment-"
        <> Text.take
          32
          ( sha256
              ( TextEncoding.encodeUtf8
                  ( Text.intercalate
                      "\NUL"
                      [ incarnation,
                        task,
                        segmentInputSourceId input,
                        Text.pack (show (segmentInputKind input)),
                        contentHash,
                        fromMaybe "" (segmentInputCausalGroup input),
                        fromMaybe "" (segmentInputTurnGroup input)
                      ]
                  )
              )
          )
    attachBlob meta =
      blobAttach blobs identifier (blobId meta) incarnation "context-segment" (segmentInputSourceId input)
        >>= either (ioError . userError . Text.unpack) (const (pure (segment identifier contentHash (blobId meta) (round now) input)))
  segment identifier contentHash contentRef now input =
    ContextSegment
      identifier
      (segmentInputKind input)
      (segmentInputAuthority input)
      (segmentInputSourceId input)
      contentRef
      contentHash
      (segmentInputCausalGroup input)
      (segmentInputTurnGroup input)
      now

deleteIncarnation :: (ContextState -> IO ()) -> MVar ContextState -> Text -> IO ()
deleteIncarnation persist lock incarnation =
  void
    ( modifyMVar
        lock
        ( \state ->
            let owned = Map.filter ((== incarnation) . contextEpochIncarnationId) (stateEpochs state)
                segmentIds = Set.fromList (concatMap contextEpochSegmentIds (Map.elems owned))
                keptEpochs = Map.filter ((/= incarnation) . contextEpochIncarnationId) (stateEpochs state)
                keptSegments = Map.filterWithKey (\key _ -> Set.notMember key segmentIds) (stateSegments state)
                keptHeads =
                  Map.filterWithKey
                    (\_ epochId -> maybe True ((/= incarnation) . contextEpochIncarnationId) (Map.lookup epochId (stateEpochs state)))
                    (stateHeads state)
                changed =
                  state
                    { stateEpochs = keptEpochs,
                      stateSegments = keptSegments,
                      stateHeads = keptHeads
                    }
             in persist changed $> (changed, ())
        )
    )

epochHash :: Text -> Text -> Int -> [Text] -> Maybe Text -> Text
epochHash incarnation task revision segments wake =
  sha256
    ( TextEncoding.encodeUtf8
        (Text.intercalate "\NUL" ([incarnation, task, Text.pack (show revision)] <> segments <> maybe [] pure wake))
    )

headKey :: Text -> Text -> Text
headKey incarnation task =
  "scope-" <> sha256 (TextEncoding.encodeUtf8 (Text.intercalate "\NUL" [incarnation, task]))

stale :: Maybe Text -> Maybe Text -> Text
stale current expected =
  "stale context epoch: expected "
    <> fromMaybe "(none)" expected
    <> ", actual "
    <> fromMaybe "(none)" current

estimateTokens :: Text -> Int
estimateTokens text = max 1 ((Text.length text + 2) `div` 3)

aguiSegments :: [AGUI.Message] -> Either Text [ContextSegmentInput]
aguiSegments = fmap concat . traverse one
 where
  one = \case
    AGUI.Developer message ->
      pure
        [ ContextSegmentInput
            (AGUI.developerId message)
            (bool SegmentInstruction SegmentWakePacket (AGUI.developerName message == Just "wake-packet"))
            (bool AuthorityKernel AuthorityDerived (AGUI.developerName message `elem` [Just "context-summary", Just "wake-packet"]))
            (AGUI.developerContent message)
            Nothing
            Nothing
        ]
    AGUI.System message ->
      pure [ContextSegmentInput (AGUI.systemId message) SegmentInstruction AuthorityKernel (AGUI.systemContent message) Nothing Nothing]
    AGUI.User message ->
      AGUI.userText (AGUI.userContent message)
        <&> userSegment message
    AGUI.Assistant message ->
      pure
        ( [ ContextSegmentInput (AGUI.assistantId message) SegmentAssistant AuthorityAgent content Nothing (Just (AGUI.assistantId message))
          | content <- maybe [] pure (AGUI.assistantContent message),
            not (Text.null content)
          ]
            <> [ ContextSegmentInput
                   (AGUI.toolCallId call)
                   SegmentToolCall
                   AuthorityAgent
                   (encodeText (modelCall call))
                   (Just (AGUI.toolCallId call))
                   (Just (AGUI.assistantId message))
               | call <- AGUI.assistantToolCalls message
               ]
        )
    AGUI.Tool message ->
      pure
        [ ContextSegmentInput
            (AGUI.toolMessageId message)
            SegmentToolResult
            AuthorityTool
            (AGUI.toolMessageContent message)
            (Just (AGUI.toolMessageCallId message))
            Nothing
        ]
    AGUI.Reasoning _ -> pure []
    AGUI.Activity _ -> pure []
  userSegment message content =
    [ContextSegmentInput (AGUI.userId message) SegmentUser AuthorityUser content Nothing Nothing]
  modelCall call =
    ModelToolCall
      (AGUI.toolCallId call)
      (AGUI.functionName (AGUI.toolCallFunction call))
      (AGUI.functionArguments (AGUI.toolCallFunction call))
  encodeText = TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

projectedAguiMessages :: [(ContextSegment, Text)] -> Either Text [AGUI.Message]
projectedAguiMessages = project
 where
  project [] = Right []
  project (current@(segment, _) : rest) =
    case contextSegmentKind segment of
      SegmentAssistant -> projectAssistant current rest
      SegmentToolCall -> projectCalls Nothing (spanCalls segment (current : rest))
      SegmentToolResult -> Left (invalid segment "orphan tool result")
      _ -> prepend current rest
  projectAssistant assistant@(segment, _) rest =
    case spanCalls segment rest of
      ([], _) -> prepend assistant rest
      calls -> projectCalls (Just assistant) calls
  projectCalls assistant (calls, remaining) =
    traverse decodeCall calls >>= assemble
   where
    assemble decoded =
      let (results, following) = span (isKind SegmentToolResult) remaining
       in validateBatch calls decoded results
            *> ( (:)
                   (assistantMessage assistant calls decoded)
                   <$> ((<>) <$> traverse toolResultMessage results <*> project following)
               )
  prepend current rest =
    (:) <$> projectedMessage current <*> project rest
  spanCalls leader =
    span
      ( \candidate ->
          isKind SegmentToolCall candidate
            && sameTurn leader (fst candidate)
      )
  sameTurn left right =
    contextSegmentTurnGroup left == contextSegmentTurnGroup right
  validateBatch calls decoded results =
    traverse validateCall (zip calls decoded)
      *> traverse resultId results
      >>= validateIds (modelToolCallId <$> decoded)
   where
    validateCall ((segment, _), call)
      | contextSegmentCausalGroup segment == Just (modelToolCallId call) = Right ()
      | otherwise = Left (invalid segment "tool call id disagrees with its causal group")
    validateIds calls' results'
      | not (unique calls') = Left (invalidBatch calls "duplicate tool call id")
      | not (unique results') = Left (invalidBatch calls "duplicate tool result id")
      | length calls' /= length results' = Left (invalidBatch calls "tool call/result count differs")
      | Set.fromList calls' /= Set.fromList results' = Left (invalidBatch calls "tool call/result ids differ")
      | otherwise = Right ()
  assistantMessage assistant calls decoded =
    AGUI.Assistant
      ( AGUI.AssistantMessage
          (turnId assistant calls)
          (snd <$> assistant)
          Nothing
          (aguiCall <$> decoded)
      )
  aguiCall call =
    AGUI.ToolCall
      (modelToolCallId call)
      (AGUI.FunctionCall (modelToolName call) (modelToolArguments call))
      Nothing
  toolResultMessage projected =
    resultId projected <&> toolMessage projected
   where
    toolMessage (segment, content) call =
      AGUI.Tool
        ( AGUI.ToolMessage
            (contextSegmentSourceRef segment)
            content
            call
            Nothing
            Nothing
        )
  resultId (segment, _) =
    maybe
      (Left (invalid segment "tool result has no causal group"))
      Right
      (contextSegmentCausalGroup segment)
  decodeCall (segment, content) =
    case eitherDecodeStrict' payload of
      Right call -> Right call
      Left _ -> Left (invalid segment "tool call payload cannot be decoded")
   where
    payload = TextEncoding.encodeUtf8 content
  projectedMessage (segment, content) =
    case contextSegmentKind segment of
      SegmentInstruction ->
        Right
          ( AGUI.Developer
              ( AGUI.DeveloperMessage
                  identifier
                  content
                  (Just (instructionName (contextSegmentAuthority segment) content))
              )
          )
      SegmentUser ->
        Right (AGUI.User (AGUI.UserMessage identifier (AGUI.UserText content) Nothing))
      SegmentAssistant ->
        Right (AGUI.Assistant (AGUI.AssistantMessage identifier (Just content) Nothing []))
      SegmentWakePacket ->
        Right (AGUI.Developer (AGUI.DeveloperMessage identifier content (Just "wake-packet")))
      _ -> Left (invalid segment "unexpected causal segment")
   where
    identifier = contextSegmentSourceRef segment
  instructionName AuthorityDerived content
    | "[context summary]" `Text.isPrefixOf` content = "context-summary"
  instructionName AuthorityDerived _ = "derived-context"
  instructionName _ _ = "instruction"
  turnId (Just (segment, _)) _ =
    fromMaybe (contextSegmentSourceRef segment) (contextSegmentTurnGroup segment)
  turnId Nothing ((segment, _) : _) =
    fromMaybe (contextSegmentSourceRef segment) (contextSegmentTurnGroup segment)
  turnId Nothing [] = "context-tool-turn"
  isKind kind (segment, _) = contextSegmentKind segment == kind
  unique values = Set.size (Set.fromList values) == length values
  invalid segment reason =
    "invalid "
      <> Text.pack (show (contextSegmentKind segment))
      <> " segment "
      <> contextSegmentId segment
      <> ": "
      <> reason
  invalidBatch ((segment, _) : _) reason = invalid segment reason
  invalidBatch [] reason = "invalid empty tool batch: " <> reason

loadState :: FilePath -> IO (Either Text ContextState)
loadState path =
  handleLoadError
    <$> (try (eitherDecodeFileStrict path) :: IO (Either IOException (Either String ContextState)))
 where
  handleLoadError = \case
    Left failure
      | isDoesNotExistError failure -> Right emptyState
      | otherwise -> Left ("cannot read context epoch store: " <> Text.pack (displayException failure))
    Right (Left failure) -> Left ("invalid context epoch store: " <> Text.pack failure)
    Right (Right state) -> validate (rebuildHeads state)
  rebuildHeads state =
    state
      { stateHeads =
          fmap contextEpochId
            . Map.fromListWith latest
            $ [ (headKey (contextEpochIncarnationId epoch) (contextEpochTaskId epoch), epoch)
              | epoch <- Map.elems (stateEpochs state)
              ]
      }
  latest left right
    | contextEpochRevision left >= contextEpochRevision right = left
    | otherwise = right
  validate state =
    maybe
      (Right state)
      (Left . ("invalid context epoch head: " <>))
      ( firstMissing
          [ identifier
          | identifier <- Map.elems (stateHeads state),
            Map.notMember identifier (stateEpochs state)
          ]
      )
  firstMissing [] = Nothing
  firstMissing (identifier : _) = Just identifier

statePath :: FilePath -> FilePath
statePath dir = dir </> "context-epochs.json"
