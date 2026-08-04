module Yuki.N.Cognition.Types
  ( Cognition (..),
    ConsolidationRequest (..),
    DreamDecision (..),
    SleepResult (..),
    shown,
  )
where

import Control.Concurrent.MVar (MVar)
import Data.Aeson
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as Text
import Yuki.N.Blob (BlobStore)
import Yuki.N.ContextEpoch (ContextEpoch, ContextEpochStore)
import Yuki.N.Domain.Context (Compaction (..))
import Yuki.N.Experience (ExperienceStore)
import Yuki.N.Incarnation (IncarnationStore)
import Yuki.N.Journal (Journal)
import Yuki.N.Memory.Archive (TaskArchiveStore)
import Yuki.N.Memory.Impression (ImpressionStore)
import Yuki.N.Memory.LongTerm (LongTermStore)
import Yuki.N.Memory.Working (ForgetDecision, SleepCycle, WakePacket, WorkingMemoryHead, WorkingStore)
import Yuki.N.Model (Model)

data Cognition = Cognition
  { cognitionBlobs :: BlobStore,
    cognitionExperiences :: ExperienceStore,
    cognitionIncarnations :: IncarnationStore,
    cognitionContexts :: ContextEpochStore,
    cognitionArchive :: TaskArchiveStore,
    cognitionWorking :: WorkingStore,
    cognitionLongTerm :: LongTermStore,
    cognitionImpressions :: ImpressionStore,
    cognitionModels :: [Model],
    cognitionJournal :: Maybe Journal,
    cognitionSleepRequests :: MVar (Set (Text, Text)),
    cognitionActivationCache :: MVar (Map (Text, Text, Text) Text),
    cognitionContextCache :: MVar (Map (Text, Text, Text) Text),
    cognitionRunLocks :: MVar (Map Text (MVar ()))
  }

data DreamDecision = DreamDecision
  { dreamContinuation :: Text,
    dreamActiveItems :: [Text],
    dreamOpenLoops :: [Text],
    dreamForgotten :: [ForgetDecision],
    dreamRetainedSegmentIds :: [Text]
  }
  deriving stock (Eq, Show)

instance FromJSON DreamDecision where
  parseJSON = withObject "DreamDecision" $ \fields ->
    DreamDecision
      <$> fields .: "continuation"
      <*> fields .:? "activeItems" .!= []
      <*> fields .:? "openLoops" .!= []
      <*> fields .:? "forgotten" .!= []
      <*> fields .:? "retainedSegmentIds" .!= []

instance ToJSON DreamDecision where
  toJSON decision =
    object
      [ "continuation" .= dreamContinuation decision,
        "activeItems" .= dreamActiveItems decision,
        "openLoops" .= dreamOpenLoops decision,
        "forgotten" .= dreamForgotten decision,
        "retainedSegmentIds" .= dreamRetainedSegmentIds decision
      ]

data SleepResult = SleepResult
  { sleepResultCompaction :: Compaction,
    sleepResultHead :: WorkingMemoryHead,
    sleepResultCycle :: SleepCycle,
    sleepResultPacket :: WakePacket,
    sleepResultEpoch :: ContextEpoch
  }
  deriving stock (Eq, Show)

instance ToJSON SleepResult where
  toJSON result =
    object
      [ "head" .= sleepResultHead result,
        "cycle" .= sleepResultCycle result,
        "wakePacket" .= sleepResultPacket result,
        "contextEpoch" .= sleepResultEpoch result,
        "beforeTokens" .= compactionBeforeTokens compaction,
        "afterTokens" .= compactionAfterTokens compaction,
        "droppedMessages" .= length (compactionDropped compaction),
        "messages" .= compactionMessages compaction
      ]
   where
    compaction = sleepResultCompaction result

data ConsolidationRequest = ConsolidationRequest
  { consolidationExperienceRef :: Text,
    consolidationEventIds :: [Text]
  }
  deriving stock (Eq, Show)

instance ToJSON ConsolidationRequest where
  toJSON request =
    object
      [ "experienceRef" .= consolidationExperienceRef request,
        "eventIds" .= consolidationEventIds request
      ]

instance FromJSON ConsolidationRequest where
  parseJSON = withObject "ConsolidationRequest" $ \fields ->
    ConsolidationRequest
      <$> fields .: "experienceRef"
      <*> fields .:? "eventIds" .!= []

shown :: (Show value) => value -> Text
shown = Text.pack . show
