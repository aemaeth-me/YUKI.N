module Yuki.N.Dispatch
  ( ConfirmOutcome (..),
    DispatchDraft (..),
    DispatchGeneration (..),
    DispatchPatch (..),
    DispatchService (..),
    DispatchSource (..),
    DispatchStatus (..),
    DispatchStore (..),
    NewDispatch (..),
    confirmDraft,
    draftGenerationPrompt,
    fallbackDraft,
    generateDraft,
    newDispatchService,
    newDispatchStore,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar
import Control.Exception (IOException, SomeException, displayException, try)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Bool (bool)
import Data.Functor (($>), (<&>))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Unique (hashUnique, newUnique)
import System.Directory (createDirectoryIfMissing)
import System.IO (stderr)
import System.IO.Error (isDoesNotExistError)
import Yuki.N.AtomicFile (atomicEncodeFile)
import Yuki.N.Incarnation
import Yuki.N.Invocation
import Yuki.N.Journal (Journal)
import Yuki.N.Model (ChatMessage (..), Model)
import Yuki.N.Sessions
import Yuki.N.ThreadConfig
import Yuki.N.Transcript

data DispatchSource
  = DispatchUser
  | DispatchAgent {dispatchAgentRunId :: Text, dispatchAgentCallId :: Text}
  deriving stock (Eq, Show)

instance ToJSON DispatchSource where
  toJSON DispatchUser = object ["type" .= ("user" :: Text)]
  toJSON (DispatchAgent runId callId) =
    object ["type" .= ("agent" :: Text), "runId" .= runId, "callId" .= callId]

instance FromJSON DispatchSource where
  parseJSON = withObject "DispatchSource" $ \fields ->
    fields .: "type" >>= \case
      "user" -> pure DispatchUser
      "agent" -> DispatchAgent <$> fields .: "runId" <*> fields .: "callId"
      other -> fail ("unknown dispatch source: " <> Text.unpack other)

data DispatchGeneration
  = GeneratedModel {generatedInvocationId :: Text}
  | GeneratedFallback
  | GeneratedAgent
  deriving stock (Eq, Show)

instance ToJSON DispatchGeneration where
  toJSON (GeneratedModel invocationId) =
    object ["type" .= ("model" :: Text), "invocationId" .= invocationId]
  toJSON GeneratedFallback = object ["type" .= ("fallback" :: Text)]
  toJSON GeneratedAgent = object ["type" .= ("agent" :: Text)]

instance FromJSON DispatchGeneration where
  parseJSON = withObject "DispatchGeneration" $ \fields ->
    fields .: "type" >>= \case
      "model" -> GeneratedModel <$> fields .: "invocationId"
      "fallback" -> pure GeneratedFallback
      "agent" -> pure GeneratedAgent
      other -> fail ("unknown dispatch generation: " <> Text.unpack other)

data DispatchStatus = Draft | Dispatched | Cancelled
  deriving stock (Eq, Show)

instance ToJSON DispatchStatus where
  toJSON =
    String . \case
      Draft -> "draft"
      Dispatched -> "dispatched"
      Cancelled -> "cancelled"

instance FromJSON DispatchStatus where
  parseJSON = withText "DispatchStatus" $ \case
    "draft" -> pure Draft
    "dispatched" -> pure Dispatched
    "cancelled" -> pure Cancelled
    value -> fail ("unknown dispatch status: " <> Text.unpack value)

data DispatchDraft = DispatchDraft
  { dispatchId :: Text,
    dispatchIncarnationId :: Text,
    dispatchSource :: DispatchSource,
    dispatchInput :: Text,
    dispatchTitle :: Text,
    dispatchPrompt :: Text,
    dispatchConfig :: ThreadConfig,
    dispatchGeneration :: DispatchGeneration,
    dispatchStatus :: DispatchStatus,
    dispatchCreatedThreadId :: Maybe Text,
    dispatchError :: Maybe Text,
    dispatchCreatedAt :: Integer,
    dispatchUpdatedAt :: Integer,
    dispatchDispatchedAt :: Maybe Integer
  }
  deriving stock (Eq, Show)

instance ToJSON DispatchDraft where
  toJSON draft =
    object
      [ "dispatchId" .= dispatchId draft,
        "incarnationId" .= dispatchIncarnationId draft,
        "source" .= dispatchSource draft,
        "input" .= dispatchInput draft,
        "title" .= dispatchTitle draft,
        "prompt" .= dispatchPrompt draft,
        "config" .= dispatchConfig draft,
        "generation" .= dispatchGeneration draft,
        "status" .= dispatchStatus draft,
        "createdThreadId" .= dispatchCreatedThreadId draft,
        "error" .= dispatchError draft,
        "createdAt" .= dispatchCreatedAt draft,
        "updatedAt" .= dispatchUpdatedAt draft,
        "dispatchedAt" .= dispatchDispatchedAt draft
      ]

instance FromJSON DispatchDraft where
  parseJSON = withObject "DispatchDraft" $ \fields ->
    DispatchDraft
      <$> fields .: "dispatchId"
      <*> fields .: "incarnationId"
      <*> fields .: "source"
      <*> fields .: "input"
      <*> fields .: "title"
      <*> fields .: "prompt"
      <*> fields .: "config"
      <*> fields .: "generation"
      <*> fields .:? "status" .!= Draft
      <*> fields .:? "createdThreadId"
      <*> fields .:? "error"
      <*> fields .: "createdAt"
      <*> fields .: "updatedAt"
      <*> fields .:? "dispatchedAt"

data NewDispatch = NewDispatch
  { newDispatchSource :: DispatchSource,
    newDispatchIncarnationId :: Text,
    newDispatchInput :: Text,
    newDispatchTitle :: Text,
    newDispatchPrompt :: Text,
    newDispatchConfig :: ThreadConfig,
    newDispatchGeneration :: DispatchGeneration
  }

data DispatchPatch = DispatchPatch
  { patchTitle :: Maybe Text,
    patchPrompt :: Maybe Text,
    patchConfig :: Maybe ThreadConfig
  }

data DispatchStore = DispatchStore
  { createDispatch :: NewDispatch -> IO DispatchDraft,
    getDispatch :: Text -> IO (Maybe DispatchDraft),
    listDispatches :: Text -> Maybe DispatchStatus -> IO [DispatchDraft],
    patchDispatch :: Text -> DispatchPatch -> IO (Either Text DispatchDraft),
    markDispatchDispatched :: Text -> Text -> IO (Either Text DispatchDraft),
    markDispatchCancelled :: Text -> IO (Either Text DispatchDraft),
    markDispatchError :: Text -> Text -> IO (Either Text DispatchDraft)
  }

newDispatchStore :: FilePath -> IO DispatchStore
newDispatchStore dir =
  createDirectoryIfMissing True dir
    *> loadDrafts path
    >>= newMVar
    <&> store
 where
  path = dir ++ "/dispatches.json"
  store lock =
    DispatchStore
      { createDispatch = create lock path,
        getDispatch = \identifier -> Map.lookup identifier <$> readMVar lock,
        listDispatches = \incarnation status ->
          sortOn (Down . dispatchCreatedAt)
            . filter (matches incarnation status)
            . Map.elems
            <$> readMVar lock,
        patchDispatch = \identifier patch -> mutate lock path identifier (applyPatch patch),
        markDispatchDispatched = \identifier threadId ->
          mutate lock path identifier $ \now draft ->
            draft
              { dispatchStatus = Dispatched,
                dispatchCreatedThreadId = Just threadId,
                dispatchError = Nothing,
                dispatchDispatchedAt = Just now,
                dispatchUpdatedAt = now
              },
        markDispatchCancelled = \identifier ->
          mutate lock path identifier $ \now draft ->
            draft {dispatchStatus = Cancelled, dispatchUpdatedAt = now},
        markDispatchError = \identifier failure ->
          mutate lock path identifier $ \now draft ->
            draft {dispatchError = Just failure, dispatchUpdatedAt = now}
      }
  matches incarnation status draft =
    dispatchIncarnationId draft == incarnation
      && maybe True (== dispatchStatus draft) status

create :: MVar (Map Text DispatchDraft) -> FilePath -> NewDispatch -> IO DispatchDraft
create lock path new =
  newDispatchId >>= \identifier ->
    getPOSIXTime >>= \now ->
      modifyMVar lock $ \drafts ->
        let stamp = round now
            draft =
              DispatchDraft
                identifier
                (newDispatchIncarnationId new)
                (newDispatchSource new)
                (newDispatchInput new)
                (newDispatchTitle new)
                (newDispatchPrompt new)
                (newDispatchConfig new)
                (newDispatchGeneration new)
                Draft
                Nothing
                Nothing
                stamp
                stamp
                Nothing
            updated = Map.insert identifier draft drafts
         in persist path updated $> (updated, draft)

applyPatch :: DispatchPatch -> Integer -> DispatchDraft -> DispatchDraft
applyPatch patch now draft =
  draft
    { dispatchTitle = fromMaybe (dispatchTitle draft) (patchTitle patch),
      dispatchPrompt = fromMaybe (dispatchPrompt draft) (patchPrompt patch),
      dispatchConfig = fromMaybe (dispatchConfig draft) (patchConfig patch),
      dispatchUpdatedAt = now
    }

mutate :: MVar (Map Text DispatchDraft) -> FilePath -> Text -> (Integer -> DispatchDraft -> DispatchDraft) -> IO (Either Text DispatchDraft)
mutate lock path identifier change =
  getPOSIXTime >>= \now ->
    modifyMVar lock $ \drafts ->
      case Map.lookup identifier drafts of
        Nothing -> pure (drafts, Left ("unknown dispatch: " <> identifier))
        Just current
          | dispatchStatus current /= Draft ->
              pure (drafts, Left ("dispatch is not draft: " <> identifier))
          | otherwise ->
              let changed = change (round now) current
                  updated = Map.insert identifier changed drafts
               in persist path updated $> (updated, Right changed)

persist :: FilePath -> Map Text DispatchDraft -> IO ()
persist path = atomicEncodeFile path . Map.elems

loadDrafts :: FilePath -> IO (Map Text DispatchDraft)
loadDrafts path =
  (try (eitherDecodeFileStrict path) :: IO (Either IOException (Either String [DispatchDraft]))) >>= \case
    Left failure
      | isDoesNotExistError failure -> pure Map.empty
      | otherwise -> warn (displayException failure)
    Right (Left failure) -> warn failure
    Right (Right drafts) -> pure (Map.fromList [(dispatchId draft, draft) | draft <- drafts])
 where
  warn failure =
    Map.empty
      <$ TextIO.hPutStrLn stderr ("YUKI.N dispatches index: " <> Text.pack failure)

newDispatchId :: IO Text
newDispatchId = liftA2 render timestamp (hashUnique <$> newUnique)
 where
  timestamp = round . (* 1000000) <$> getPOSIXTime
  render micros unique =
    "dsp-" <> Text.pack (show (micros :: Integer)) <> "-" <> Text.pack (show unique)

-- ORCHESTRATOR-REVIEW: prompt template placeholder, will be replaced at integration
draftGenerationPrompt :: Text
draftGenerationPrompt =
  "You draft task dispatches for the YUKI.N agent workbench. Given the target incarnation and the user request, answer with exactly one JSON object {\"title\": string, \"prompt\": string}: title is a short task label of at most 60 characters, prompt is the complete first task instruction for the dispatched thread. Output the JSON object only."

generateDraft :: (InvocationSpec -> IO (Either Text InvocationResult)) -> [Model] -> Int -> Maybe Journal -> Incarnation -> Text -> IO (Text, Text, DispatchGeneration)
generateDraft invoke models timeoutSeconds journal incarnation input
  | null models = pure (fallbackDraft input)
  | otherwise =
      newDispatchId >>= \identifier ->
        either (const (fallbackDraft input)) (generated identifier)
          <$> invoke (specification identifier)
 where
  specification identifier =
    InvocationSpec
      identifier
      "dispatch.draft"
      "dispatch-draft-generator/v1"
      models
      [ ChatSystem draftGenerationPrompt,
        ChatUser
          ( Text.intercalate
              "\n"
              [ "Incarnation: " <> incarnationName incarnation,
                "Direction: " <> incarnationDirection incarnation,
                "Request: " <> input
              ]
          )
      ]
      1
      2000
      (max 1 timeoutSeconds * 1000)
      journal
  generated identifier result =
    fromMaybe (fallbackDraft input) (parseGenerated identifier (invocationResultText result))

parseGenerated :: Text -> Text -> Maybe (Text, Text, DispatchGeneration)
parseGenerated identifier raw =
  either (const Nothing) validate decoded
 where
  decoded =
    eitherDecodeStrict (TextEncoding.encodeUtf8 (unfence raw))
      >>= parseEither (withObject "dispatch draft" (\fields -> (,) <$> fields .: "title" <*> fields .: "prompt"))
  validate (title, prompt)
    | Text.null cleanTitle || Text.null cleanPrompt = Nothing
    | otherwise = Just (Text.take 60 cleanTitle, cleanPrompt, GeneratedModel identifier)
   where
    cleanTitle = Text.strip title
    cleanPrompt = Text.strip prompt

unfence :: Text -> Text
unfence raw =
  fromMaybe trimmed $ do
    inner <- Text.stripPrefix "```json" trimmed <|> Text.stripPrefix "```" trimmed
    Text.stripSuffix "```" (Text.strip inner)
 where
  trimmed = Text.strip raw

fallbackDraft :: Text -> (Text, Text, DispatchGeneration)
fallbackDraft input = (fallbackTitle input, input, GeneratedFallback)

fallbackTitle :: Text -> Text
fallbackTitle input =
  bool firstLine (Text.take 60 (Text.strip input)) (Text.null firstLine)
 where
  firstLine = Text.take 60 (Text.takeWhile (/= '\n') (Text.strip input))

data ConfirmOutcome
  = ConfirmMissing
  | ConfirmConflict Text
  | ConfirmError Text
  | ConfirmOk Text
  deriving stock (Eq, Show)

confirmDraft :: DispatchStore -> SessionService -> IncarnationStore -> IO Text -> Text -> IO ConfirmOutcome
confirmDraft dispatches service incarnations newThreadId identifier =
  getDispatch dispatches identifier >>= maybe (pure ConfirmMissing) check
 where
  check draft
    | dispatchStatus draft /= Draft =
        pure (ConfirmConflict ("dispatch is not draft: " <> identifier))
    | otherwise =
        incarnationRead incarnations (dispatchIncarnationId draft) >>= \case
          Nothing -> report draft ("unknown incarnation: " <> dispatchIncarnationId draft)
          Just incarnation
            | incarnationStatus incarnation == IncarnationArchived ->
                report draft ("incarnation is archived: " <> dispatchIncarnationId draft)
            | otherwise -> newThreadId >>= execute draft
  execute draft threadId =
    createSession sessions threadId (Just (dispatchTitle draft)) (dispatchIncarnationId draft) Nothing Nothing >>= \case
      Left failure -> report draft failure
      Right _ ->
        attempt (threadConfigWrite configs threadId (dispatchConfig draft)) >>= \case
          Left failure -> rollbacks [rollbackSession] threadId failure draft
          Right () ->
            attempt (transcriptSave transcripts threadId [ChatUser (dispatchPrompt draft)]) >>= \case
              Left failure -> rollbacks [rollbackConfig, rollbackSession] threadId failure draft
              Right () ->
                markDispatchDispatched dispatches identifier threadId >>= \case
                  Left failure -> rollbacks [rollbackTranscript, rollbackConfig, rollbackSession] threadId failure draft
                  Right _ -> pure (ConfirmOk threadId)
  rollbacks actions threadId failure draft =
    mapM_ ($ threadId) actions *> report draft failure
  rollbackSession threadId = archiveSession service threadId $> ()
  rollbackConfig = threadConfigDelete configs
  rollbackTranscript = transcriptDelete transcripts
  report draft failure =
    markDispatchError dispatches (dispatchId draft) failure
      $> ConfirmError failure
  sessions = serviceSessions service
  configs = serviceConfigs service
  transcripts = serviceTranscripts service

attempt :: IO () -> IO (Either Text ())
attempt action =
  either (Left . Text.pack . displayException) Right
    <$> (try action :: IO (Either SomeException ()))

data DispatchService = DispatchService
  { dispatchServiceStore :: DispatchStore,
    dispatchServiceGenerate :: Incarnation -> Text -> IO DispatchDraft,
    dispatchServiceConfirm :: Text -> IO ConfirmOutcome
  }

newDispatchService :: DispatchStore -> SessionService -> IncarnationStore -> IO Text -> (Incarnation -> Text -> IO (Text, Text, DispatchGeneration)) -> DispatchService
newDispatchService dispatches service incarnations newThreadId generate =
  DispatchService dispatches materialize (confirmDraft dispatches service incarnations newThreadId)
 where
  materialize incarnation input =
    generate incarnation input >>= \(title, prompt, generation) ->
      createDispatch
        dispatches
        (NewDispatch DispatchUser (incarnationId incarnation) input title prompt emptyThreadConfig generation)
