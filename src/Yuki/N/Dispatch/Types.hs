module Yuki.N.Dispatch.Types
  ( ConfirmOutcome (..),
    DispatchDraft (..),
    DispatchGeneration (..),
    DispatchPatch (..),
    DispatchSource (..),
    DispatchStatus (..),
    DispatchStore (..),
    NewDispatch (..),
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import Data.Text qualified as Text
import Yuki.N.ThreadConfig.Types (ThreadConfig)

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
    fields .: "type" >>= parseDispatchSource fields

parseDispatchSource :: Object -> Text -> Parser DispatchSource
parseDispatchSource fields = \case
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
    fields .: "type" >>= parseDispatchGeneration fields

parseDispatchGeneration :: Object -> Text -> Parser DispatchGeneration
parseDispatchGeneration fields = \case
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

data ConfirmOutcome
  = ConfirmMissing
  | ConfirmConflict Text
  | ConfirmError Text
  | ConfirmOk Text
  deriving stock (Eq, Show)
