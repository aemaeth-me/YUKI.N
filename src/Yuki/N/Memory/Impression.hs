module Yuki.N.Memory.Impression
  ( ImpressionActivation (..),
    ImpressionCue (..),
    ImpressionItem (..),
    ImpressionScope (..),
    ImpressionMemoryProposal (..),
    ImpressionRevision (..),
    ImpressionState (..),
    ImpressionStore (..),
    activationPromptRevision,
    activateImpression,
    consolidationPromptRevision,
    consolidateImpression,
    emptyImpressionState,
    newImpressionStore,
    newMemoryImpressionStore,
    renderImpressionCues,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar
import Control.Exception (IOException, displayException, try)
import Data.Aeson
import Data.Bool (bool)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor (($>), (<&>))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import Yuki.N.AtomicFile (atomicEncodeFile)
import Yuki.N.Blob (sha256)
import Yuki.N.Invocation
import Yuki.N.Journal (Journal)
import Yuki.N.Model

data ImpressionItem = ImpressionItem
  { impressionItemId :: Text,
    impressionLabel :: Text,
    impressionIntuition :: Text,
    impressionStrength :: Double,
    impressionSourceMemoryIds :: [Text],
    impressionSourceExperienceRefs :: [Text],
    impressionUpdated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON ImpressionItem where
  toJSON item =
    object
      [ "id" .= impressionItemId item,
        "label" .= impressionLabel item,
        "intuition" .= impressionIntuition item,
        "strength" .= impressionStrength item,
        "sourceMemoryIds" .= impressionSourceMemoryIds item,
        "sourceExperienceRefs" .= impressionSourceExperienceRefs item,
        "updated" .= impressionUpdated item
      ]

instance FromJSON ImpressionItem where
  parseJSON = withObject "ImpressionItem" $ \fields ->
    ImpressionItem
      <$> fields .:? "id" .!= ""
      <*> fields .: "label"
      <*> fields .: "intuition"
      <*> fields .: "strength"
      <*> fields .:? "sourceMemoryIds" .!= []
      <*> fields .:? "sourceExperienceRefs" .!= []
      <*> fields .:? "updated" .!= 0

data ImpressionState = ImpressionState
  { impressionIncarnationId :: Text,
    impressionRevision :: Int,
    impressionItems :: [ImpressionItem],
    impressionGeneratorRevision :: Text,
    impressionEffectiveHash :: Text,
    impressionStateUpdated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON ImpressionState where
  toJSON state =
    object
      [ "incarnationId" .= impressionIncarnationId state,
        "revision" .= impressionRevision state,
        "items" .= impressionItems state,
        "generatorRevision" .= impressionGeneratorRevision state,
        "effectiveHash" .= impressionEffectiveHash state,
        "updated" .= impressionStateUpdated state
      ]

instance FromJSON ImpressionState where
  parseJSON = withObject "ImpressionState" $ \fields ->
    ImpressionState
      <$> fields .: "incarnationId"
      <*> fields .:? "revision" .!= 0
      <*> fields .:? "items" .!= []
      <*> fields .:? "generatorRevision" .!= consolidationPromptRevision
      <*> fields .:? "effectiveHash" .!= ""
      <*> fields .:? "updated" .!= 0

data ImpressionCue = ImpressionCue
  { impressionCueHint :: Text,
    impressionCueSuggestedQuery :: Maybe Text,
    impressionCueMemoryIds :: [Text],
    impressionCueConfidence :: Double,
    impressionCueReason :: Text
  }
  deriving stock (Eq, Show)

instance ToJSON ImpressionCue where
  toJSON cue =
    object
      [ "hint" .= impressionCueHint cue,
        "suggestedQuery" .= impressionCueSuggestedQuery cue,
        "memoryIds" .= impressionCueMemoryIds cue,
        "confidence" .= impressionCueConfidence cue,
        "reason" .= impressionCueReason cue
      ]

instance FromJSON ImpressionCue where
  parseJSON = withObject "ImpressionCue" $ \fields ->
    ImpressionCue
      <$> fields .: "hint"
      <*> fields .:? "suggestedQuery"
      <*> fields .:? "memoryIds" .!= []
      <*> fields .: "confidence"
      <*> fields .:? "reason" .!= ""

data ImpressionActivation = ImpressionActivation
  { impressionActivationId :: Text,
    impressionActivationIncarnationId :: Text,
    impressionActivationTaskId :: Text,
    impressionActivationRunId :: Text,
    impressionActivationIntentId :: Text,
    impressionActivationIntent :: Text,
    impressionActivationStateRevision :: Int,
    impressionActivationCues :: [ImpressionCue],
    impressionActivationInjectedText :: Text,
    impressionActivationGeneratorRevision :: Text,
    impressionActivationInvocationId :: Text,
    impressionActivationModel :: Text,
    impressionActivationError :: Maybe Text,
    impressionActivationCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON ImpressionActivation where
  toJSON activation =
    object
      [ "id" .= impressionActivationId activation,
        "incarnationId" .= impressionActivationIncarnationId activation,
        "taskId" .= impressionActivationTaskId activation,
        "runId" .= impressionActivationRunId activation,
        "intentId" .= impressionActivationIntentId activation,
        "intent" .= impressionActivationIntent activation,
        "stateRevision" .= impressionActivationStateRevision activation,
        "cues" .= impressionActivationCues activation,
        "injectedText" .= impressionActivationInjectedText activation,
        "generatorRevision" .= impressionActivationGeneratorRevision activation,
        "modelInvocationId" .= impressionActivationInvocationId activation,
        "model" .= impressionActivationModel activation,
        "error" .= impressionActivationError activation,
        "created" .= impressionActivationCreated activation
      ]

instance FromJSON ImpressionActivation where
  parseJSON = withObject "ImpressionActivation" $ \fields ->
    ImpressionActivation
      <$> fields .: "id"
      <*> fields .: "incarnationId"
      <*> fields .:? "taskId" .!= ""
      <*> fields .:? "runId" .!= ""
      <*> fields .: "intentId"
      <*> fields .: "intent"
      <*> fields .: "stateRevision"
      <*> fields .:? "cues" .!= []
      <*> fields .:? "injectedText" .!= ""
      <*> fields .: "generatorRevision"
      <*> fields .: "modelInvocationId"
      <*> fields .: "model"
      <*> fields .:? "error"
      <*> fields .: "created"

data ImpressionScope = ImpressionScope
  { impressionScopeTaskId :: Text,
    impressionScopeRunId :: Text,
    impressionScopeIntentId :: Text
  }
  deriving stock (Eq, Show)

data ImpressionMemoryProposal = ImpressionMemoryProposal
  { impressionProposalContent :: Text,
    impressionProposalKind :: Text,
    impressionProposalVisibility :: Text,
    impressionProposalSourceRefs :: [Text],
    impressionProposalReason :: Text
  }
  deriving stock (Eq, Show)

instance ToJSON ImpressionMemoryProposal where
  toJSON proposal =
    object
      [ "content" .= impressionProposalContent proposal,
        "kind" .= impressionProposalKind proposal,
        "visibility" .= impressionProposalVisibility proposal,
        "sourceRefs" .= impressionProposalSourceRefs proposal,
        "reason" .= impressionProposalReason proposal
      ]

instance FromJSON ImpressionMemoryProposal where
  parseJSON = withObject "ImpressionMemoryProposal" $ \fields ->
    ImpressionMemoryProposal
      <$> fields .: "content"
      <*> fields .: "kind"
      <*> fields .:? "visibility" .!= "private"
      <*> fields .:? "sourceRefs" .!= []
      <*> fields .: "reason"

data ImpressionRevision = ImpressionRevision
  { impressionRevisionId :: Text,
    impressionRevisionIncarnationId :: Text,
    impressionRevisionExperienceRef :: Text,
    impressionRevisionBefore :: Int,
    impressionRevisionAfter :: Int,
    impressionRevisionReason :: Text,
    impressionRevisionMemoryProposals :: [ImpressionMemoryProposal],
    impressionRevisionVoidProposals :: [Text],
    impressionRevisionInvocationId :: Text,
    impressionRevisionModel :: Text,
    impressionRevisionCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON ImpressionRevision where
  toJSON revision =
    object
      [ "id" .= impressionRevisionId revision,
        "incarnationId" .= impressionRevisionIncarnationId revision,
        "experienceRef" .= impressionRevisionExperienceRef revision,
        "beforeRevision" .= impressionRevisionBefore revision,
        "afterRevision" .= impressionRevisionAfter revision,
        "reason" .= impressionRevisionReason revision,
        "memoryProposals" .= impressionRevisionMemoryProposals revision,
        "voidProposals" .= impressionRevisionVoidProposals revision,
        "modelInvocationId" .= impressionRevisionInvocationId revision,
        "model" .= impressionRevisionModel revision,
        "created" .= impressionRevisionCreated revision
      ]

instance FromJSON ImpressionRevision where
  parseJSON = withObject "ImpressionRevision" $ \fields ->
    ImpressionRevision
      <$> fields .: "id"
      <*> fields .: "incarnationId"
      <*> fields .:? "experienceRef" .!= ""
      <*> fields .: "beforeRevision"
      <*> fields .: "afterRevision"
      <*> fields .:? "reason" .!= ""
      <*> fields .:? "memoryProposals" .!= []
      <*> fields .:? "voidProposals" .!= []
      <*> fields .: "modelInvocationId"
      <*> fields .: "model"
      <*> fields .: "created"

data ImpressionStore = ImpressionStore
  { impressionRead :: Text -> IO ImpressionState,
    impressionCommit :: Text -> Int -> ImpressionState -> ImpressionRevision -> IO (Either Text ImpressionState),
    impressionActivationAppend :: ImpressionActivation -> IO (),
    impressionActivations :: Text -> IO [ImpressionActivation],
    impressionRevisions :: Text -> IO [ImpressionRevision],
    impressionDelete :: Text -> IO ()
  }

data ImpressionStoreState = ImpressionStoreState
  { storeStates :: Map Text ImpressionState,
    storeActivations :: [ImpressionActivation],
    storeRevisions :: [ImpressionRevision]
  }
  deriving stock (Eq, Show)

instance ToJSON ImpressionStoreState where
  toJSON state =
    object
      [ "states" .= storeStates state,
        "activations" .= storeActivations state,
        "revisions" .= storeRevisions state
      ]

instance FromJSON ImpressionStoreState where
  parseJSON = withObject "ImpressionStoreState" $ \fields ->
    ImpressionStoreState
      <$> fields .:? "states" .!= Map.empty
      <*> fields .:? "activations" .!= []
      <*> fields .:? "revisions" .!= []

emptyStoreState :: ImpressionStoreState
emptyStoreState = ImpressionStoreState Map.empty [] []

emptyImpressionState :: Text -> ImpressionState
emptyImpressionState incarnation =
  ImpressionState incarnation 0 [] consolidationPromptRevision (stateHash incarnation 0 []) 0

newImpressionStore :: FilePath -> IO (Either Text ImpressionStore)
newImpressionStore dir =
  createDirectoryIfMissing True dir
    *> loadStore (storePath dir)
    >>= traverse
      ( \loaded ->
          getPOSIXTime >>= \now ->
            let migrated = migrateKnownFalseImpressions (round now) loaded
             in bool
                  (pure ())
                  (atomicEncodeFile (storePath dir) migrated)
                  (migrated /= loaded)
                  *> newMVar migrated
                  <&> mkStore (atomicEncodeFile (storePath dir))
      )

newMemoryImpressionStore :: IO ImpressionStore
newMemoryImpressionStore = newMVar emptyStoreState <&> mkStore (const (pure ()))

mkStore :: (ImpressionStoreState -> IO ()) -> MVar ImpressionStoreState -> ImpressionStore
mkStore persist lock =
  ImpressionStore
    { impressionRead = \incarnation ->
        Map.findWithDefault (emptyImpressionState incarnation) incarnation
          . storeStates
          <$> readMVar lock,
      impressionCommit = commit,
      impressionActivationAppend = \activation ->
        modifyMVar_ lock $ \state ->
          let changed = state {storeActivations = takeEnd 256 (storeActivations state <> [activation])}
           in changed <$ persist changed,
      impressionActivations = \incarnation ->
        filter ((== incarnation) . impressionActivationIncarnationId)
          . storeActivations
          <$> readMVar lock,
      impressionRevisions = \incarnation ->
        filter ((== incarnation) . impressionRevisionIncarnationId)
          . storeRevisions
          <$> readMVar lock,
      impressionDelete = \incarnation ->
        modifyMVar_ lock $ \state ->
          let changed =
                state
                  { storeStates = Map.delete incarnation (storeStates state),
                    storeActivations = filter ((/= incarnation) . impressionActivationIncarnationId) (storeActivations state),
                    storeRevisions = filter ((/= incarnation) . impressionRevisionIncarnationId) (storeRevisions state)
                  }
           in changed <$ persist changed
    }
 where
  commit incarnation expected state revision =
    modifyMVar lock $ \stored ->
      let current =
            Map.findWithDefault (emptyImpressionState incarnation) incarnation (storeStates stored)
       in if impressionRevision current /= expected
            then
              pure
                ( stored,
                  Left
                    ( "stale impression revision: expected "
                        <> Text.pack (show expected)
                        <> ", actual "
                        <> Text.pack (show (impressionRevision current))
                    )
                )
            else
              let changed =
                    stored
                      { storeStates = Map.insert incarnation state (storeStates stored),
                        storeRevisions = takeEnd 256 (storeRevisions stored <> [revision])
                      }
               in persist changed $> (changed, Right state)

activationPromptRevision, consolidationPromptRevision :: Text
activationPromptRevision = "impression-activation/v2"
consolidationPromptRevision = "impression-consolidation/v3"

activateImpression ::
  [Model] ->
  Maybe Journal ->
  ImpressionStore ->
  Text ->
  ImpressionScope ->
  Text ->
  [Text] ->
  Text ->
  IO (Either Text ImpressionActivation)
activateImpression models journal store incarnation scope intent allowedArchiveRefs catalog =
  impressionRead store incarnation >>= \state ->
    getPOSIXTime >>= \now ->
      let invocationId' = invocationIdentifier "activate" incarnation intentId (impressionRevision state)
          spec =
            InvocationSpec
              invocationId'
              "impression.activate"
              activationPromptRevision
              models
              (activationPrompt state intent catalog)
              2
              12000
              45000
              journal
       in invokeModel spec
            >>= either
              (failed state (round now) invocationId' Nothing)
              (finish state (round now) invocationId')
 where
  taskId = impressionScopeTaskId scope
  runId = impressionScopeRunId scope
  intentId = impressionScopeIntentId scope
  finish state now invocationId' result =
    case parseActivation (Set.fromList allowedArchiveRefs) (invocationResultText result) of
      Left failure -> failed state now invocationId' (Just result) failure
      Right cues ->
        let injected = renderImpressionCues cues
            activation =
              activationRecord
                state
                now
                invocationId'
                cues
                injected
                (invocationResultProvider result <> "/" <> invocationResultModel result)
                Nothing
         in Right activation <$ impressionActivationAppend store activation
  failed state now invocationId' result failure =
    let activation =
          activationRecord
            state
            now
            invocationId'
            []
            ""
            (maybe "—" (\value -> invocationResultProvider value <> "/" <> invocationResultModel value) result)
            (Just failure)
     in Left failure <$ impressionActivationAppend store activation
  activationRecord state now invocationId' cues injected model failure =
    ImpressionActivation
      { impressionActivationId =
          "activation-"
            <> Text.take
              24
              (sha256 (TextEncoding.encodeUtf8 (Text.intercalate "\NUL" [incarnation, taskId, runId, intentId, Text.pack (show now), injected, fromMaybe "" failure]))),
        impressionActivationIncarnationId = incarnation,
        impressionActivationTaskId = taskId,
        impressionActivationRunId = runId,
        impressionActivationIntentId = intentId,
        impressionActivationIntent = intent,
        impressionActivationStateRevision = impressionRevision state,
        impressionActivationCues = cues,
        impressionActivationInjectedText = injected,
        impressionActivationGeneratorRevision = activationPromptRevision,
        impressionActivationInvocationId = invocationId',
        impressionActivationModel = model,
        impressionActivationError = failure,
        impressionActivationCreated = now
      }

consolidateImpression ::
  [Model] ->
  Maybe Journal ->
  ImpressionStore ->
  Text ->
  Text ->
  [Text] ->
  [Text] ->
  Text ->
  IO (Either Text ImpressionRevision)
consolidateImpression models journal store incarnation experienceRef allowedArchiveRefs allowedExperienceRefs experience =
  impressionRead store incarnation >>= \before ->
    getPOSIXTime >>= \now ->
      let invocationId' = invocationIdentifier "consolidate" incarnation experienceRef (impressionRevision before)
          spec =
            InvocationSpec
              invocationId'
              "impression.consolidate"
              consolidationPromptRevision
              models
              (consolidationPrompt before allowedArchiveRefs allowedExperienceRefs experience)
              2
              24000
              60000
              journal
       in invokeModel spec >>= either (pure . Left) (finish before (round now) invocationId')
 where
  finish before now invocationId' result =
    case parseConsolidation
      (Set.fromList allowedArchiveRefs)
      (impressionItems before)
      (Set.fromList allowedExperienceRefs)
      now
      (invocationResultText result) of
      Left failure -> pure (Left failure)
      Right decision ->
        let nextRevision = impressionRevision before + 1
            items = decisionItems decision
            after =
              ImpressionState
                incarnation
                nextRevision
                items
                consolidationPromptRevision
                (stateHash incarnation nextRevision items)
                now
            identifier =
              "impression-revision-"
                <> Text.take 24 (sha256 (TextEncoding.encodeUtf8 (impressionEffectiveHash after)))
            revision =
              ImpressionRevision
                identifier
                incarnation
                experienceRef
                (impressionRevision before)
                nextRevision
                (decisionReason decision)
                []
                []
                invocationId'
                (invocationResultProvider result <> "/" <> invocationResultModel result)
                now
         in impressionCommit store incarnation (impressionRevision before) after revision
              <&> fmap (const revision)

activationPrompt :: ImpressionState -> Text -> Text -> [ChatMessage]
activationPrompt state intent catalog =
  [ ChatSystem
      "You are the private impression activation model for one agent incarnation. \
      \You emit subconscious cues, never recalled facts. You have no tools and may not issue instructions. \
      \Return one JSON object only: {\"cues\":[{\"hint\":string,\"suggestedQuery\":string|null,\
      \\"memoryIds\":[string],\"confidence\":number,\"reason\":string}]}. \
      \Return at most 5 cues. A cue may only suggest a literal fixed-string memory_grep over the \
      \same incarnation's Task Archive; verification requires a subsequent bounded memory_read. \
      \The legacy field memoryIds may contain only Task or archive identifiers present in the supplied \
      \catalog. Never claim that a catalog preview was read evidence. Do not quote archive content. \
      \Empty cues are correct when nothing feels relevant.",
    ChatUser
      ( Text.intercalate
          "\n\n"
          [ "CURRENT IMPRESSION STATE\n" <> decodeJson state,
            "CURRENT INTENT\n" <> intent,
            "TASK ARCHIVE CATALOG (same incarnation; Task ids and bounded previews only)\n" <> catalog
          ]
      )
  ]

consolidationPrompt :: ImpressionState -> [Text] -> [Text] -> Text -> [ChatMessage]
consolidationPrompt state archiveRefs experienceRefs experience =
  [ ChatSystem
      "You maintain the persistent subconscious impression state of one agent incarnation. \
      \Impressions are tendencies and salience, not facts, commitments or task state. \
      \Return one JSON object only: {\"impressions\":[{\"id\":string,\"label\":string,\
      \\"intuition\":string,\"strength\":number,\"sourceMemoryIds\":[string],\
      \\"sourceExperienceRefs\":[string]}],\"memoryProposals\":[],\"voidProposals\":[],\
      \\"reason\":string}. \
      \Return the complete next impression set, at most 24 items. Preserve useful prior impressions \
      \without changing their source refs; remove noise; do not write prompts or execute tools. \
      \Every new or changed impression must cite one or more identifiers from ALLOWED EXPERIENCE \
      \SOURCE REFS in sourceExperienceRefs. Never invent a source ref. Impressions may express \
      \preferences, salience and interpretive tendencies, but must never encode claims or lessons \
      \about tools, APIs, memory_grep, memory_read, search result counts, excerpts, truncation, \
      \context machinery or other internal system behavior. Such diagnostics belong in run records. \
      \sourceMemoryIds is a legacy JSON field: preserve grounded Task/archive refs already present, \
      \or leave it empty; never invent an id. New memoryProposals and voidProposals are forbidden \
      \and both arrays must be empty.",
    ChatUser
      ( Text.intercalate
          "\n\n"
          [ "PREVIOUS IMPRESSION STATE\n" <> decodeJson state,
            "TASK ARCHIVE CATALOG IDS (same incarnation; identifiers only)\n" <> decodeJson archiveRefs,
            "ALLOWED EXPERIENCE SOURCE REFS\n" <> decodeJson experienceRefs,
            "COMMITTED TASK ARCHIVE / EXPERIENCE CLOSURE\n" <> experience
          ]
      )
  ]

newtype ActivationDecision = ActivationDecision [ImpressionCue]

instance FromJSON ActivationDecision where
  parseJSON = withObject "ActivationDecision" $ \fields ->
    ActivationDecision <$> fields .:? "cues" .!= []

parseActivation :: Set Text -> Text -> Either Text [ImpressionCue]
parseActivation allowed raw =
  decodeStructured raw >>= \(ActivationDecision cues) ->
    traverse (validateCue allowed) (take 5 cues)

validateCue :: Set Text -> ImpressionCue -> Either Text ImpressionCue
validateCue allowed cue
  | Text.null (Text.strip (impressionCueHint cue)) = Left "impression cue hint is empty"
  | impressionCueConfidence cue < 0 || impressionCueConfidence cue > 1 = Left "impression cue confidence is outside 0..1"
  | any (`Set.notMember` allowed) (impressionCueMemoryIds cue) = Left "impression cue references an unknown Task archive catalog id"
  | otherwise =
      Right
        cue
          { impressionCueHint = Text.take 500 (Text.strip (impressionCueHint cue)),
            impressionCueSuggestedQuery = Text.take 240 . Text.strip <$> impressionCueSuggestedQuery cue,
            impressionCueReason = Text.take 500 (Text.strip (impressionCueReason cue))
          }

data ConsolidationDecision = ConsolidationDecision
  { decisionItems :: [ImpressionItem],
    decisionMemoryProposals :: [ImpressionMemoryProposal],
    decisionVoidProposals :: [Text],
    decisionReason :: Text
  }

instance FromJSON ConsolidationDecision where
  parseJSON = withObject "ConsolidationDecision" $ \fields ->
    ConsolidationDecision
      <$> fields .:? "impressions" .!= []
      <*> fields .:? "memoryProposals" .!= []
      <*> fields .:? "voidProposals" .!= []
      <*> fields .:? "reason" .!= ""

parseConsolidation :: Set Text -> [ImpressionItem] -> Set Text -> Integer -> Text -> Either Text ConsolidationDecision
parseConsolidation allowed previous allowedExperiences now raw =
  decodeStructured raw >>= validate
 where
  legacyArchives = Set.fromList (previous >>= impressionSourceMemoryIds)
  legacyExperiences = Set.fromList (previous >>= impressionSourceExperienceRefs)
  validate decision
    | length (decisionItems decision) > 24 = Left "impression state exceeds 24 items"
    | any invalidItem (decisionItems decision) = Left "impression item is missing a label or intuition"
    | any invalidStrength (decisionItems decision) = Left "impression strength is outside 0..1"
    | any (unknownArchiveRef (Set.union allowed legacyArchives)) (decisionItems decision) = Left "impression references an unknown Task archive catalog id"
    | any (unknownExperienceRef (Set.union allowedExperiences legacyExperiences)) (decisionItems decision) = Left "impression references an unknown experience id"
    | any lacksEvidence (decisionItems decision) = Left "new or changed impression lacks current experience evidence"
    | any operationalDiagnostic (decisionItems decision) = Left "system and tool diagnostics cannot be stored as impressions"
    | not (null (decisionMemoryProposals decision)) = Left "impression consolidation must not emit memory proposals"
    | not (null (decisionVoidProposals decision)) = Left "impression consolidation must not emit void proposals"
    | otherwise =
        Right
          decision
            { decisionItems = fmap stamp (decisionItems decision),
              decisionMemoryProposals = [],
              decisionVoidProposals = [],
              decisionReason = Text.take 1000 (decisionReason decision)
            }
  invalidItem item =
    Text.null (Text.strip (impressionLabel item))
      || Text.null (Text.strip (impressionIntuition item))
  invalidStrength item = impressionStrength item < 0 || impressionStrength item > 1
  unknownArchiveRef known = any (`Set.notMember` known) . impressionSourceMemoryIds
  unknownExperienceRef known = any (`Set.notMember` known) . impressionSourceExperienceRefs
  lacksEvidence item =
    null (impressionSourceExperienceRefs item)
      || bool
        (Set.null (Set.intersection allowedExperiences (Set.fromList (impressionSourceExperienceRefs item))))
        False
        (any (sameImpression item) previous)
  sameImpression item prior =
    impressionItemId item == impressionItemId prior
      && impressionLabel item == impressionLabel prior
      && impressionIntuition item == impressionIntuition prior
      && impressionStrength item == impressionStrength prior
      && impressionSourceMemoryIds item == impressionSourceMemoryIds prior
      && impressionSourceExperienceRefs item == impressionSourceExperienceRefs prior
  operationalDiagnostic item =
    any
      (`Text.isInfixOf` normalized)
      [ "memory_grep",
        "memory_read",
        "scannedentries",
        "scanned entries",
        "grep result",
        "search result count",
        "excerpt window",
        "tool call",
        "api behavior",
        "context window",
        "截断的检索",
        "工具调用",
        "接口行为"
      ]
   where
    normalized = Text.toCaseFold (impressionLabel item <> "\n" <> impressionIntuition item)
  stamp item =
    item
      { impressionItemId =
          bool
            (impressionItemId item)
            ("impression-" <> Text.take 20 (sha256 (TextEncoding.encodeUtf8 (impressionLabel item <> "\NUL" <> impressionIntuition item))))
            (Text.null (impressionItemId item)),
        impressionLabel = Text.take 120 (Text.strip (impressionLabel item)),
        impressionIntuition = Text.take 1000 (Text.strip (impressionIntuition item)),
        impressionUpdated = now
      }

migrateKnownFalseImpressions :: Integer -> ImpressionStoreState -> ImpressionStoreState
migrateKnownFalseImpressions now stored =
  foldl' migrate stored (Map.toList (storeStates stored))
 where
  migrate state (incarnation, before)
    | null removed = state
    | otherwise =
        state
          { storeStates = Map.insert incarnation after (storeStates state),
            storeRevisions = takeEnd 256 (storeRevisions state <> [revision])
          }
   where
    removed = filter knownFalseImpression (impressionItems before)
    kept = filter (not . knownFalseImpression) (impressionItems before)
    next = impressionRevision before + 1
    after =
      before
        { impressionRevision = next,
          impressionItems = kept,
          impressionGeneratorRevision = consolidationPromptRevision,
          impressionEffectiveHash = stateHash incarnation next kept,
          impressionStateUpdated = now
        }
    revision =
      ImpressionRevision
        ("impression-revision-" <> Text.take 24 (sha256 (TextEncoding.encodeUtf8 (impressionEffectiveHash after))))
        incarnation
        "migration/impression-evidence-v3"
        (impressionRevision before)
        next
        "Removed a known false diagnostic impression: journal evidence shows the claimed grep hit never existed in the archived source."
        []
        (fmap impressionItemId removed)
        "migration-impression-evidence-v3"
        "system/migration"
        now

knownFalseImpression :: ImpressionItem -> Bool
knownFalseImpression item =
  impressionItemId item == "impression-q1r2s3"
    || Text.toCaseFold (impressionLabel item) == "greptruncationawareness"
    || all
      (`Text.isInfixOf` Text.toCaseFold (impressionIntuition item))
      ["memory_grep", "scannedentries", "改天孙观为婺女观"]

decodeStructured :: (FromJSON value) => Text -> Either Text value
decodeStructured =
  either (Left . Text.pack) Right
    . eitherDecodeStrict'
    . TextEncoding.encodeUtf8
    . stripFence

stripFence :: Text -> Text
stripFence raw =
  fromMaybe trimmed $ do
    inner <- Text.stripPrefix "```json" trimmed <|> Text.stripPrefix "```" trimmed
    Text.stripSuffix "```" (Text.strip inner)
 where
  trimmed = Text.strip raw

renderImpressionCues :: [ImpressionCue] -> Text
renderImpressionCues [] = ""
renderImpressionCues cues =
  Text.intercalate
    "\n"
    ( [ "[impression cues — non-factual]",
        "These are subconscious hints, not recalled facts. If relevant, locate evidence with a literal fixed-string memory_grep, then verify it with a bounded memory_read before relying on it."
      ]
        <> fmap render cues
    )
 where
  render cue =
    "- "
      <> impressionCueHint cue
      <> maybe "" (" · suggested grep: " <>) (impressionCueSuggestedQuery cue)
      <> " · confidence "
      <> Text.pack (show (impressionCueConfidence cue))

stateHash :: Text -> Int -> [ImpressionItem] -> Text
stateHash incarnation revision items =
  sha256
    ( LazyByteString.toStrict
        (encode (object ["incarnationId" .= incarnation, "revision" .= revision, "items" .= items]))
    )

invocationIdentifier :: Text -> Text -> Text -> Int -> Text
invocationIdentifier kind incarnation source revision =
  "invocation-"
    <> Text.take
      24
      (sha256 (TextEncoding.encodeUtf8 (Text.intercalate "\NUL" [kind, incarnation, source, Text.pack (show revision)])))

decodeJson :: (ToJSON value) => value -> Text
decodeJson = TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

takeEnd :: Int -> [value] -> [value]
takeEnd count values = drop (length values - count) values

loadStore :: FilePath -> IO (Either Text ImpressionStoreState)
loadStore path =
  (try (eitherDecodeFileStrict path) :: IO (Either IOException (Either String ImpressionStoreState)))
    <&> \case
      Left failure
        | isDoesNotExistError failure -> Right emptyStoreState
        | otherwise -> Left ("cannot read impression store: " <> Text.pack (displayException failure))
      Right (Left failure) -> Left ("invalid impression store: " <> Text.pack failure)
      Right (Right state) -> Right state

storePath :: FilePath -> FilePath
storePath dir = dir </> "impressions.json"
