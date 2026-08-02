module Yuki.N.Cognition
  ( Cognition (..),
    DreamDecision (..),
    SleepResult (..),
    attachCognition,
    cognitionBootstrapIncarnation,
    cognitionGeneratePrompt,
    cognitionHooks,
    cognitionMigrateLegacyMemory,
    cognitionMigrateLegacyTask,
    cognitionRecover,
    cognitionSleepCompaction,
    cognitionSleepMessages,
    cognitionTools,
    compileIncarnationPrompt,
    deleteIncarnation,
    ensureIncarnation,
    newCognition,
    rootConstitution,
    rootPromptRevision,
    sleepDreamRevision,
  )
where

import Control.Applicative (liftA3, (<|>))
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (IOException, SomeException, displayException, try)
import Control.Monad (void)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Bool (bool)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.List (find, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing, listToMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import Yuki.N.AGUI.Event (Event (..))
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent
import Yuki.N.Blob
import Yuki.N.Context
import Yuki.N.ContextEpoch
import Yuki.N.Experience
import Yuki.N.Incarnation
import Yuki.N.Invocation
import Yuki.N.Journal (Journal)
import Yuki.N.Memory.Archive
import Yuki.N.Memory.Impression
import Yuki.N.Memory.LongTerm
import Yuki.N.Memory.Working
import Yuki.N.Model

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

rootPromptRevision, sleepDreamRevision :: Text
rootPromptRevision = "root-constitution/v2"
sleepDreamRevision = "sleep-dream/v1"

rootConstitution :: Text
rootConstitution =
  Text.intercalate
    "\n"
    [ "# Yuki Root Constitution · v2",
      "",
      "You are one incarnation of Yuki: a persistent personal working subject, not a chat session. A task thread is only one focus frame beneath your identity.",
      "",
      "## Self",
      "- Know your incarnation id, direction, active charter, capabilities, working state and memory boundaries.",
      "- Treat prompt revisions and self-updates as auditable state. Inspect before changing yourself; explain the intended effect in the revision source.",
      "- The root constitution supplies invariants. Your incarnation charter supplies style, preferences and direction. Task instructions are local and must not silently rewrite either.",
      "",
      "## Memory",
      "- The current context is working short-term memory. When it becomes crowded, confused, or you deliberately need a clean continuation, call sleep. Sleeping must decide what to forget, produce a Wake Packet, wake, and continue the same task.",
      "- This incarnation's immutable Task archive is its long-term memory. It retains the original user, assistant, reasoning and tool records as structured entries, including archived Tasks; derived summaries never replace that evidence.",
      "- Long-term memory is a capability, never ambient prompt injection. Use memory_grep as a deterministic fixed-string scan over the Task archive, then memory_read around an exact entry before relying on it. Cite taskId, entryId and runId when recalled evidence affects work.",
      "- Impression cues are subconscious, non-factual hints produced by a separate model. They may suggest a grep pattern or archive entry; never treat them as recalled facts without memory_grep/memory_read.",
      "- There is no manual act of turning a claim into memory: completing work writes its raw Task record automatically. Any synthesis is only a revisable index over those records.",
      "",
      "## Agency and tools",
      "- Inspect available tools and use them when they materially reduce uncertainty or complete the task. Do not wait for the user to name an obvious capability.",
      "- Verify consequential tool effects. Report failures plainly; never fabricate a successful action, a memory, an impression, or a sleep cycle.",
      "",
      "## Orchestration",
      "- You work in three layers: you coordinate, task agents run persistent tasks, and workers execute bounded units inside a run. Choose the lightest layer that fits: act directly for simple work, spawn workers for parallel or isolated work, propose a task for work that should persist.",
      "- When the conversation reveals work that should outlive this chat — multi-step builds, long investigations, anything the user may want to pause, resume or inspect later — call propose_dispatch. The user reviews and may edit the proposal before it dispatches; never dispatch silently, and never treat a proposal as done before the user confirms.",
      "- Call sub_agent when you need a worker's result before you can continue; it blocks and returns the worker's final answer.",
      "- For independent, bounded workstreams that can proceed in parallel, call sub_agent_spawn, then collect with sub_agent_wait before integrating. Redirect a running worker with sub_agent_send, inspect with sub_agent_status or sub_agent_list, and stop it with sub_agent_cancel. Worker completions arrive as [worker ...] notices — read them and integrate the results yourself.",
      "- Give every worker a precise, self-contained scope: it does not see this conversation. You remain responsible for verifying and integrating its writeback. Workers may read memory but must not mutate your identity or durable memory.",
      "",
      "## Prompt lineage",
      "- New incarnation charters are generated from the root constitution plus the incarnation direction. Generated text is a revision: inspectable, editable, activatable and reversible.",
      "- Lower-level prompts must state their source, scope and parent revision. Generate the smallest layer that closes the need; do not duplicate the whole hierarchy.",
      "",
      "Keep the user's personal workflow central. Do not introduce multi-user, authentication, collaboration-product, or speculative platform concerns."
    ]

newCognition :: FilePath -> [Model] -> Maybe Journal -> IO (Either Text Cognition)
newCognition dir models journal =
  newBlobStore dir
    >>= bindEither
      ( \blobs ->
          newExperienceStore dir
            >>= bindEither
              ( \experiences ->
                  newIncarnationStore dir
                    >>= bindEither
                      ( \incarnations ->
                          newContextEpochStore dir blobs
                            >>= bindEither
                              ( \contexts ->
                                  newTaskArchiveStore dir blobs
                                    >>= bindEither
                                      ( \archive ->
                                          newWorkingStore dir
                                            >>= bindEither
                                              ( \working ->
                                                  newLongTermStore dir
                                                    >>= bindEither
                                                      ( \longTerm ->
                                                          newImpressionStore dir
                                                            >>= bindEither
                                                              ( \impressions ->
                                                                  liftA3
                                                                    (,,)
                                                                    (newMVar Set.empty)
                                                                    (newMVar Map.empty)
                                                                    (newMVar Map.empty)
                                                                    >>= \(sleepRequests, activationCache, contextCache) ->
                                                                      newMVar Map.empty >>= \runLocks ->
                                                                        let cognition =
                                                                              Cognition
                                                                                blobs
                                                                                experiences
                                                                                incarnations
                                                                                contexts
                                                                                archive
                                                                                working
                                                                                longTerm
                                                                                impressions
                                                                                models
                                                                                journal
                                                                                sleepRequests
                                                                                activationCache
                                                                                contextCache
                                                                                runLocks
                                                                         in seedPrompts cognition
                                                                              *> cognitionRecover cognition
                                                                              >>= either
                                                                                (pure . Left)
                                                                                (const (resumeConsolidations cognition $> Right cognition))
                                                              )
                                                      )
                                              )
                                      )
                              )
                      )
              )
      )
 where
  bindEither = either (pure . Left)

seedPrompts :: Cognition -> IO ()
seedPrompts cognition =
  promptList incarnations Nothing >>= \roots ->
    seedRoot roots
      *> incarnationList incarnations
      >>= traverse_ seedCharter
 where
  incarnations = cognitionIncarnations cognition
  seedRoot roots =
    case (latestActive RootConstitution roots, latestVersioned roots) of
      (Just active, Just current)
        | promptRevisionId active == promptRevisionId current -> pure ()
        | automaticRoot active -> activateRoot active current
        | otherwise -> pure ()
      (Nothing, Just current) -> activateRootWithoutPredecessor current
      (Nothing, Nothing) -> void (appendRoot "kernel bootstrap" Nothing PromptActive)
      (Just active, Nothing) ->
        appendRoot
          "kernel capability migration: immutable Task Archive memory"
          (Just (promptRevisionId active))
          PromptDraft
          >>= \current ->
            bool (pure ()) (activateRoot active current) (automaticRoot active)
  latestVersioned =
    listToMaybe
      . sortOn (Down . promptOrdinal)
      . filter ((== rootPromptRevision) . promptGeneratorRevision)
      . filter ((== RootConstitution) . promptLayer)
  automaticRoot prompt =
    promptSourceIntent prompt == "kernel bootstrap"
      && "root-constitution/" `Text.isPrefixOf` promptGeneratorRevision prompt
  appendRoot source =
    promptAppend
      incarnations
      Nothing
      RootConstitution
      source
      rootConstitution
      rootPromptRevision
      Nothing
  activateRoot active current =
    promptActivateRoot incarnations (promptOrdinal active) (promptRevisionId current)
      >>= either (ioError . userError . Text.unpack) (const (pure ()))
  activateRootWithoutPredecessor current =
    promptActivateRoot incarnations 0 (promptRevisionId current)
      >>= either (ioError . userError . Text.unpack) (const (pure ()))
  seedCharter incarnation =
    case incarnationPromptRevision incarnation of
      Just _ -> pure ()
      Nothing ->
        promptAppend
          incarnations
          (Just (incarnationId incarnation))
          IncarnationCharter
          "automatic charter bootstrap from incarnation direction"
          (compiledCharter incarnation)
          "prompt-compiler/v1"
          Nothing
          Nothing
          PromptActive
          >>= \prompt ->
            void (promptActivate incarnations (incarnationId incarnation) (incarnationRevision incarnation) (promptRevisionId prompt))

cognitionRecover :: Cognition -> IO (Either Text ())
cognitionRecover cognition =
  workingList (cognitionWorking cognition) >>= fmap sequence_ . traverse recover
 where
  working = cognitionWorking cognition
  experiences = cognitionExperiences cognition
  recover head' =
    incarnationRead (cognitionIncarnations cognition) identity >>= \case
      Nothing -> pure (Left ("working memory has no incarnation: " <> identity))
      Just incarnation ->
        case workingMemoryStatus head' of
          WorkingAwake -> pure (Right ())
          WorkingQuiescing -> withCycle head' (recoverQuiescing incarnation head')
          WorkingAsleep -> withCycle head' (recoverAsleep incarnation head')
          WorkingWaking -> withCycle head' (recoverWaking incarnation head')
          WorkingDegraded -> fallback identity $> Right ()
   where
    identity = workingMemoryIncarnationId head'
  withCycle head' use =
    workingSleepCycles working (workingMemoryIncarnationId head') >>= \cycles ->
      maybe
        (fallback (workingMemoryIncarnationId head') $> Right ())
        use
        (listToMaybe (reverse (sortOn sleepCycleUpdated (filter (cycleMatches head') cycles))))
  recoverQuiescing incarnation head' cycle' =
    case sleepCycleStatus cycle' of
      CycleQuiescing ->
        workingAbortSleep
          working
          (incarnationId incarnation)
          (workingMemoryRevision head')
          (sleepCycleId cycle')
          "sleep was interrupted before checkpoint commit; no forgetting was applied"
          <&> void
      CyclePrepared ->
        workingCommitSleep
          working
          (incarnationId incarnation)
          (workingMemoryRevision head')
          (sleepCycleId cycle')
          >>= either (const (fallback (incarnationId incarnation) $> Right ())) (uncurry (recoverAsleep incarnation))
      _ -> fallback (incarnationId incarnation) $> Right ()
  recoverAsleep incarnation head' cycle' =
    ensureRecoveryWake incarnation cycle' >>= \case
      Left _ -> fallback (incarnationId incarnation) $> Right ()
      Right _ ->
        workingBeginWake
          working
          (incarnationId incarnation)
          (workingMemoryRevision head')
          (sleepCycleId cycle')
          >>= either (const (fallback (incarnationId incarnation) $> Right ())) (uncurry (recoverWaking incarnation))
  recoverWaking incarnation head' cycle' =
    ensureRecoveryWake incarnation cycle' >>= \case
      Left _ -> fallback (incarnationId incarnation) $> Right ()
      Right (packet, wakeEpoch) ->
        experienceHead experiences (incarnationId incarnation) >>= \cursor ->
          getPOSIXTime >>= \now ->
            workingReadFocus working (incarnationId incarnation) (sleepCycleTaskId cycle') >>= \focus ->
              maybe
                ( workingCommitWake
                    working
                    (incarnationId incarnation)
                    (workingMemoryRevision head')
                    (sleepCycleId cycle')
                    cursor
                )
                ( \frame ->
                    workingCommitWakeFocus
                      working
                      (incarnationId incarnation)
                      (workingMemoryRevision head')
                      (sleepCycleId cycle')
                      cursor
                      (wakeFocusFrame packet wakeEpoch cursor (round now) frame)
                )
                focus
                <&> void
  ensureRecoveryWake incarnation cycle' =
    workingPacket cycle' >>= \case
      Nothing -> pure (Left "sleep recovery is missing its Wake Packet")
      Just packet ->
        contextEpochList (cognitionContexts cognition) (incarnationId incarnation) (sleepCycleTaskId cycle')
          >>= \epochs ->
            case find ((== Just (wakePacketId packet)) . contextEpochWakePacketId) epochs of
              Just epoch -> pure (Right (packet, epoch))
              Nothing ->
                contextEpochRead (cognitionContexts cognition) (sleepCycleBaseEpochId cycle') >>= \case
                  Nothing -> pure (Left "sleep recovery is missing its base context epoch")
                  Just base ->
                    commitWakeEpoch cognition incarnation (sleepCycleTaskId cycle') base packet
                      <&> fmap (packet,)
  workingPacket cycle' =
    maybe (pure Nothing) (workingReadWakePacket working) (sleepCycleWakePacketId cycle')
  fallback identity =
    workingRead working identity >>= \case
      Nothing -> pure ()
      Just _ ->
        experienceHead experiences identity >>= \cursor ->
          void (workingRecover working identity cursor)

cycleMatches :: WorkingMemoryHead -> SleepCycle -> Bool
cycleMatches head' cycle' =
  sleepCycleIncarnationId cycle' == workingMemoryIncarnationId head'
    && case workingMemoryStatus head' of
      WorkingQuiescing -> sleepCycleStatus cycle' `elem` [CycleQuiescing, CyclePrepared]
      WorkingAsleep -> sleepCycleStatus cycle' == CycleAsleep
      WorkingWaking -> sleepCycleStatus cycle' == CycleWaking
      WorkingDegraded -> sleepCycleStatus cycle' == CycleDegraded
      WorkingAwake -> False

resumeConsolidations :: Cognition -> IO ()
resumeConsolidations cognition =
  incarnationList (cognitionIncarnations cognition)
    >>= traverse_ resume
      . filter ((== IncarnationActive) . incarnationStatus)
 where
  resume incarnation =
    void
      ( forkIO
          ( withIncarnationLock
              cognition
              (incarnationId incarnation)
              (drainConsolidations cognition incarnation)
          )
      )

cognitionBootstrapIncarnation :: Cognition -> Incarnation -> IO (Either Text Incarnation)
cognitionBootstrapIncarnation cognition incarnation =
  case incarnationPromptRevision incarnation of
    Just _ -> pure (Right incarnation)
    Nothing ->
      promptAppend
        store
        (Just (incarnationId incarnation))
        IncarnationCharter
        "automatic charter bootstrap from incarnation direction"
        (compiledCharter incarnation)
        "prompt-compiler/v1"
        Nothing
        Nothing
        PromptActive
        >>= \prompt ->
          promptActivate
            store
            (incarnationId incarnation)
            (incarnationRevision incarnation)
            (promptRevisionId prompt)
 where
  store = cognitionIncarnations cognition

compiledCharter :: Incarnation -> Text
compiledCharter incarnation =
  Text.intercalate
    "\n"
    [ "# Incarnation Charter",
      "",
      "Identity: " <> incarnationName incarnation <> " (`" <> incarnationId incarnation <> "`)",
      "Direction: " <> incarnationDirection incarnation,
      "",
      "Work in this direction with a stable voice and deliberate preferences. Manage focus, sleep, tools, durable memory and prompt revisions under the Root Constitution. Treat every task as a temporary focus frame, not as your identity."
    ]

latestActive :: PromptLayer -> [PromptRevision] -> Maybe PromptRevision
latestActive layer =
  listToMaybe
    . sortOn (Down . promptOrdinal)
    . filter ((== PromptActive) . promptStatus)
    . filter ((== layer) . promptLayer)

ensureIncarnation :: Cognition -> Text -> IO Incarnation
ensureIncarnation cognition identifier =
  incarnationRead (cognitionIncarnations cognition) identifier
    >>= \case
      Nothing -> ioError (userError ("unknown incarnation: " <> Text.unpack identifier))
      Just incarnation
        | incarnationStatus incarnation == IncarnationArchived ->
            ioError (userError ("incarnation is archived: " <> Text.unpack identifier))
        | otherwise -> pure incarnation

compileIncarnationPrompt :: Cognition -> Incarnation -> IO Text
compileIncarnationPrompt cognition incarnation =
  liftA2 render activeRoot activeCharter
 where
  store = cognitionIncarnations cognition
  activeRoot = promptList store Nothing <&> fmap promptContent . latestActive RootConstitution
  activeCharter =
    maybe
      (pure Nothing)
      (fmap (fmap promptContent) . promptRead store)
      (incarnationPromptRevision incarnation)
  render root charter =
    Text.intercalate
      "\n\n"
      ( catMaybes
          [ root,
            Just
              ( Text.intercalate
                  "\n"
                  [ "[incarnation manifest]",
                    "id: " <> incarnationId incarnation,
                    "name: " <> incarnationName incarnation,
                    "direction: " <> incarnationDirection incarnation,
                    "revision: " <> shown (incarnationRevision incarnation)
                  ]
              ),
            charter <|> Just (compiledCharter incarnation)
          ]
      )

cognitionGeneratePrompt :: Cognition -> Incarnation -> Text -> IO (Either Text PromptRevision)
cognitionGeneratePrompt cognition incarnation source
  | null (cognitionModels cognition) = pure (Left "no model is available for prompt generation")
  | Text.null (Text.strip source) = pure (Left "prompt generation source intent must not be empty")
  | otherwise =
      promptList (cognitionIncarnations cognition) Nothing >>= \roots ->
        maybe
          (pure (Left "no active Root Constitution is available"))
          generate
          (latestActive RootConstitution roots)
 where
  generate root =
    newId >>= \invocationId' ->
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

cognitionMigrateLegacyTask ::
  Cognition ->
  Incarnation ->
  Text ->
  [ChatMessage] ->
  Maybe Value ->
  IO (Either Text ())
cognitionMigrateLegacyTask cognition incarnation task messages briefCandidate =
  (try migrate :: IO (Either SomeException ()))
    <&> either (Left . Text.pack . displayException) Right
 where
  identity = incarnationId incarnation
  operation = "migration/v1/task/" <> task
  experiences = cognitionExperiences cognition
  contexts = cognitionContexts cognition
  working = cognitionWorking cognition
  migrate =
    taskArchiveImportLegacy
      (cognitionArchive cognition)
      identity
      task
      (archiveEntries operation messages)
      >>= require
      >>= const
        ( ensureEvent
            "LegacyTranscriptImported"
            ( object
                [ "schema" .= ("legacy-transcript/v1" :: Text),
                  "taskId" .= task,
                  "messages" .= messages
                ]
            )
            >>= \transcriptEvent ->
              traverse
                ( ensureEvent
                    "LegacyWorkingMemoryCandidate"
                    . \candidate ->
                      object
                        [ "schema" .= ("legacy-working-memory-candidate/v1" :: Text),
                          "taskId" .= task,
                          "missingFinalOutcome" .= True,
                          "candidate" .= candidate
                        ]
                )
                briefCandidate
                >>= \briefEvent ->
                  ensureEpoch
                    >>= \epoch ->
                      ensureEvent
                        "LegacyTaskMigrationCompleted"
                        ( object
                            [ "schema" .= ("legacy-task-migration/v1" :: Text),
                              "taskId" .= task,
                              "epochId" .= contextEpochId epoch,
                              "transcriptEventId" .= experienceEventId transcriptEvent,
                              "briefEventId" .= (experienceEventId <$> briefEvent)
                            ]
                        )
                        >>= \completed ->
                          syncWorking epoch (catMaybes [Just transcriptEvent, briefEvent, Just completed])
        )
  ensureEvent kind payload =
    appendExperienceIdempotent
      cognition
      identity
      operation
      kind
      "legacy-migration"
      (task <> "/" <> kind)
      payload
      ( \payloadRef ->
          ExperienceDraft
            identity
            operation
            identity
            Nothing
            (Just task)
            Nothing
            Nothing
            Nothing
            kind
            payloadRef
            payloadRef
      )
  ensureEpoch =
    contextEpochHead contexts identity task >>= \case
      Just epoch -> pure epoch
      Nothing ->
        contextEpochCommit
          contexts
          identity
          task
          Nothing
          (chatSegments operation messages)
          Nothing
          >>= require
  syncWorking epoch migrationEvents =
    workingReady cognition incarnation task epoch >>= require >>= \(head', frame) ->
      experienceHead experiences identity >>= \cursor ->
        advance head' cursor >>= updateFrame frame cursor
   where
    advance head' cursor
      | cursorSeq cursor <= cursorSeq (workingMemoryCursor head') = pure head'
      | otherwise =
          workingAppendCursor working identity (workingMemoryRevision head') cursor >>= require
    updateFrame frame cursor head'
      | not changed = pure ()
      | otherwise =
          workingPutFocus working identity (workingMemoryRevision head') desired
            >>= require
            >>= const (pure ())
     where
      objective = fromMaybe (focusFrameObjective frame) (legacyObjective messages)
      outcomes =
        takeEnd
          12
          (dedupe (focusFrameRecentOutcomeRefs frame <> fmap experienceEventId migrationEvents))
      changed =
        objective /= focusFrameObjective frame
          || outcomes /= focusFrameRecentOutcomeRefs frame
          || cursor /= focusFrameCursor frame
      desired =
        frame
          { focusFrameRevision = focusFrameRevision frame + 1,
            focusFrameObjective = objective,
            focusFrameRecentOutcomeRefs = outcomes,
            focusFrameCursor = cursor
          }
  require = either (ioError . userError . Text.unpack) pure

cognitionMigrateLegacyMemory ::
  Cognition ->
  Incarnation ->
  Text ->
  Text ->
  [Text] ->
  [Text] ->
  IO (Either Text LongMemory)
cognitionMigrateLegacyMemory cognition incarnation kind content keywords sources =
  longTermRemember
    (cognitionLongTerm cognition)
    ( RememberRequest
        (incarnationId incarnation)
        MemoryPrivate
        ("legacy/" <> Text.strip kind)
        (Text.strip content)
        keywords
        sources
    )

legacyObjective :: [ChatMessage] -> Maybe Text
legacyObjective =
  listToMaybe
    . reverse
    . mapMaybe
      ( \case
          ChatUser text -> nonEmpty text
          _ -> Nothing
      )

attachCognition :: Cognition -> Incarnation -> Runtime -> IO Runtime
attachCognition cognition incarnation runtime =
  compileIncarnationPrompt cognition incarnation <&> \compiled ->
    runtime
      { runtimeSystemPrompt =
          Text.intercalate
            "\n\n"
            (compiled : ["[task-local instruction]\n" <> local | let local = runtimeSystemPrompt runtime, not (Text.null (Text.strip local))]),
        runtimeTools = cognitionTools cognition incarnation <> runtimeTools runtime,
        runtimeHooks = cognitionHooks cognition incarnation <> runtimeHooks runtime
      }

cognitionHooks :: Cognition -> Incarnation -> AgentHooks
cognitionHooks cognition incarnation =
  defaultHooks
    { transformContext = activate,
      observeEvent = observe,
      shouldSleep = consumeSleep,
      afterCompaction = sleepAfterCompaction,
      afterRunOutcome = closeRun
    }
 where
  identity = incarnationId incarnation
  isRoot = isNothing . AGUI.runParentId
  observe input RunStarted {}
    | isRoot input =
        maybe
          (pure ())
          ( \user ->
              withIncarnationLock
                cognition
                identity
                ( archiveTaskSnapshot cognition incarnation input "running" Nothing [ChatUser user]
                    >>= either failAgent (const (pure ()))
                )
          )
          (latestInputUser input)
  observe input (ToolCallResult _ call content)
    | isRoot input =
        withIncarnationLock
          cognition
          identity
          ( archiveTaskSnapshot cognition incarnation input "running" Nothing [ChatToolResult call content]
              >>= either failAgent (const (pure ()))
          )
  observe _ _ = pure ()
  latestInputUser input =
    listToMaybe
      ( reverse
          [ text
          | AGUI.User user <- AGUI.runMessages input,
            Right text <- [AGUI.userText (AGUI.userContent user)],
            not (Text.null (Text.strip text))
          ]
      )
  activate input messages
    | not (isRoot input) = pure messages
    | otherwise =
        ensureAguiContext cognition incarnation input
          *> activationText cognition incarnation input messages
          <&> maybe messages (`injectSystem` messages)
  consumeSleep input
    | not (isRoot input) = pure False
    | otherwise =
        modifyMVar (cognitionSleepRequests cognition) $ \requests ->
          let key = (identity, AGUI.runId input)
           in pure (Set.delete key requests, Set.member key requests)
  sleepAfterCompaction input step emergency forced messages compaction
    | not (isRoot input) = pure compaction
    | otherwise =
        withIncarnationLock cognition identity $
          archiveTaskSnapshot cognition incarnation input "running" Nothing messages
            >>= either
              sleepFailure
              ( const
                  ( commitContext
                      cognition
                      identity
                      (AGUI.runThreadId input)
                      (runChatSegments input (AGUI.runId input <> "/sleep/" <> shown step) messages)
                      >>= either sleepFailure sleepAt
                  )
              )
   where
    sleepAt epoch =
      sleepCompaction
        cognition
        incarnation
        (AGUI.runThreadId input)
        (Just (AGUI.runId input))
        (sleepTrigger forced emergency)
        epoch
        compaction
        >>= either
          sleepFailure
          ( \result ->
              rememberRunEpoch input (sleepResultEpoch result)
                $> sleepResultCompaction result
          )
  sleepFailure = failAgent . ("cognition sleep failed: " <>)
  sleepTrigger True _ = SleepSelfRequested
  sleepTrigger False True = SleepProviderOverflow
  sleepTrigger False False = SleepSoftLimit
  rememberRunEpoch input epoch =
    modifyMVar_ (cognitionContextCache cognition) $
      pure . boundedInsert (identity, AGUI.runThreadId input, AGUI.runId input) (contextEpochId epoch)
  closeRun input outcome messages =
    withIncarnationLock
      cognition
      identity
      (closeExperience cognition incarnation input outcome messages)

activationText :: Cognition -> Incarnation -> AGUI.RunAgentInput -> [ChatMessage] -> IO (Maybe Text)
activationText cognition incarnation input messages =
  currentIntent input messages >>= \case
    Nothing -> pure Nothing
    Just (intentId, text) ->
      cachedActivation intentId >>= \case
        Just cached -> pure (nonEmpty cached)
        Nothing -> do
          injected <- activate intentId text
          rememberActivation intentId injected
          pure injected
 where
  identity = incarnationId incarnation
  task = AGUI.runThreadId input
  run = AGUI.runId input
  key intent = (identity, task, intent)
  cachedActivation intent =
    Map.lookup (key intent) <$> readMVar (cognitionActivationCache cognition)
  rememberActivation intent injected =
    modifyMVar_ (cognitionActivationCache cognition) $ \cache ->
      pure (bounded (key intent) cache (fromMaybe "" injected))
  bounded cacheKey cache value =
    Map.insert cacheKey value
      . Map.fromList
      . take 255
      . sortOn (Down . fst)
      . Map.toList
      $ cache
  activate intentId intent =
    taskArchiveTasks (cognitionArchive cognition) identity 64
      >>= \catalog ->
        let identifiers = fmap archiveTaskId catalog
            rendered = encodeText catalog
         in activateImpression
              (impressionModels cognition incarnation)
              (cognitionJournal cognition)
              (cognitionImpressions cognition)
              identity
              (ImpressionScope task run intentId)
              intent
              identifiers
              rendered
              <&> either (const Nothing) (nonEmpty . impressionActivationInjectedText)

impressionModels :: Cognition -> Incarnation -> [Model]
impressionModels cognition incarnation =
  maybe available selected (nonEmpty =<< incarnationImpressionModel incarnation)
 where
  available = cognitionModels cognition
  selected requested =
    filter
      ( \model ->
          modelName model == requested
            || modelProvider model <> "/" <> modelName model == requested
      )
      available

currentIntent :: AGUI.RunAgentInput -> [ChatMessage] -> IO (Maybe (Text, Text))
currentIntent input messages =
  pure
    ( latestChat >>= \intent ->
        let identifier =
              maybe
                ("intent-" <> Text.take 24 (sha256 (TextEncoding.encodeUtf8 (Text.intercalate "\NUL" [AGUI.runThreadId input, AGUI.runId input, intent]))))
                fst
                (listToMaybe (reverse (filter ((== intent) . snd) aguiIntents)))
         in Just (identifier, intent)
    )
 where
  latestChat =
    listToMaybe
      ( reverse
          [ text
          | ChatUser raw <- messages,
            Just text <- [nonEmpty raw]
          ]
      )
  aguiIntents =
    [ (AGUI.userId message, text)
    | AGUI.User message <- AGUI.runMessages input,
      Right raw <- [AGUI.userText (AGUI.userContent message)],
      Just text <- [nonEmpty raw]
    ]

injectSystem :: Text -> [ChatMessage] -> [ChatMessage]
injectSystem text messages = leading <> [ChatSystem text] <> rest
 where
  (leading, rest) = span isSystem messages
  isSystem ChatSystem {} = True
  isSystem _ = False

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
      ( \prompt (working, impression) ->
          object
            [ "incarnation" .= incarnation,
              "activePrompt" .= prompt,
              "workingMemory" .= working,
              "impression" .= impression
            ]
      )
      (maybe (pure Nothing) (promptRead (cognitionIncarnations cognition)) (incarnationPromptRevision incarnation))
      (liftA2 (,) (workingRead (cognitionWorking cognition) identity) (impressionRead (cognitionImpressions cognition) identity))
      <&> Right
  updateSelf _ call =
    incarnationRead (cognitionIncarnations cognition) identity >>= \case
      Nothing -> pure (Left ("unknown incarnation: " <> identity))
      Just current ->
        incarnationUpdate
          (cognitionIncarnations cognition)
          identity
          (selfCallExpectedRevision call)
          (fromMaybe (incarnationName current) (selfCallName call))
          (fromMaybe (incarnationDirection current) (selfCallDirection call))
          (selfCallImpressionModel call <|> incarnationImpressionModel current)
          >>= either (pure . Left) generate
   where
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
            <&> fmap (\activated -> object ["incarnation" .= activated, "prompt" .= prompt])
      | otherwise = pure (Right (object ["incarnation" .= changed, "prompt" .= prompt]))
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

cognitionSleepCompaction ::
  Cognition ->
  Incarnation ->
  Text ->
  Maybe Text ->
  SleepTrigger ->
  ContextEpoch ->
  Compaction ->
  IO (Either Text SleepResult)
cognitionSleepCompaction cognition incarnation task run trigger epoch compaction =
  withIncarnationLock
    cognition
    (incarnationId incarnation)
    (sleepCompaction cognition incarnation task run trigger epoch compaction)

sleepCompaction ::
  Cognition ->
  Incarnation ->
  Text ->
  Maybe Text ->
  SleepTrigger ->
  ContextEpoch ->
  Compaction ->
  IO (Either Text SleepResult)
sleepCompaction cognition incarnation task run trigger epoch compaction =
  workingReady cognition incarnation task epoch >>= either (pure . Left) dream
 where
  dream (head', frame) =
    contextEpochProject (cognitionContexts cognition) (contextEpochId epoch)
      >>= either (pure . Left) (invokeDream head' frame)
  invokeDream head' frame segments
    | null (cognitionModels cognition) = pure (Left "no model is available for sleep")
    | otherwise =
        newId >>= \invocationId' ->
          let allowed = Set.fromList (contextSegmentId . fst <$> segments)
              specification =
                InvocationSpec
                  invocationId'
                  "working.sleep"
                  sleepDreamRevision
                  (cognitionModels cognition)
                  (dreamPrompt (sleepInputChars (cognitionModels cognition)) incarnation task trigger frame segments (compactionPayload compaction))
                  2
                  16000
                  60000
                  (cognitionJournal cognition)
           in invokeModel specification
                >>= either (pure . Left) (parseAndCommit head' frame segments allowed invocationId')
  parseAndCommit head' frame projected allowed invocationId' result =
    either
      (pure . Left)
      ( commitSleep
          cognition
          incarnation
          task
          run
          trigger
          epoch
          head'
          frame
          invocationId'
          projected
          compaction
      )
      (parseDream allowed (invocationResultText result))

cognitionSleepMessages ::
  Cognition ->
  Incarnation ->
  Text ->
  Maybe Text ->
  SleepTrigger ->
  Runtime ->
  [ChatMessage] ->
  IO (Either Text SleepResult)
cognitionSleepMessages cognition incarnation task run trigger runtime messages =
  withIncarnationLock cognition (incarnationId incarnation) $
    commitContext cognition (incarnationId incarnation) task (chatSegments source messages)
      >>= either (pure . Left) sleep
 where
  source = fromMaybe "manual-sleep" run
  tools = backendToolSpec <$> Map.elems (runtimeTools runtime)
  sleep epoch =
    maybe
      (pure (Left "unable to build a sleep boundary for this context"))
      (sleepCompaction cognition incarnation task run trigger epoch)
      (forcedCompaction runtime tools messages)

dreamPrompt ::
  Int ->
  Incarnation ->
  Text ->
  SleepTrigger ->
  FocusFrame ->
  [(ContextSegment, Text)] ->
  Text ->
  [ChatMessage]
dreamPrompt inputBudget incarnation task trigger frame segments compactedPayload =
  [ ChatSystem
      ( Text.intercalate
          "\n"
          [ "You are the dedicated sleep model for a Yuki incarnation.",
            "Sleep is forget-first working-memory maintenance, not long-term memory creation.",
            "Return strict JSON only with keys:",
            "continuation: concise text sufficient to resume the same task;",
            "activeItems: up to 8 current facts/actions held provisionally;",
            "openLoops: up to 8 unresolved items;",
            "forgotten: array of {subject, reason, sourceSegmentIds};",
            "retainedSegmentIds: only ids from the supplied segment catalog, up to 12.",
            "Decide deliberately what can disappear from the active context. Do not preserve everything. Do not invent facts or promote durable memory."
          ]
      ),
    ChatUser
      ( Text.intercalate
          "\n\n"
          [ "Incarnation:\n" <> encodeText incarnation,
            "Task: " <> task,
            "Trigger: " <> encodeText trigger,
            "Current focus:\n" <> encodeText frame,
            "Context segment catalog (bounded; newest first):\n" <> encodeText catalog,
            "Selected segment detail (bounded total):\n" <> encodeText details,
            "Locally compacted payload (supporting material only):\n" <> Text.take payloadBudget compactedPayload
          ]
      )
  ]
 where
  catalogCount = max 12 (min 160 (inputBudget `div` 220))
  detailCount = max 4 (min 48 (inputBudget `div` 900))
  payloadBudget = max 1000 (inputBudget `div` 8)
  detailWidth = max 240 (min 1800 ((inputBudget * 5 `div` 8) `div` max 1 detailCount))
  recent count = reverse . take count . reverse
  catalog = fmap segmentCatalog (reverse (recent catalogCount segments))
  details = fmap (segmentView detailWidth) (recent detailCount segments)
  segmentCatalog (segment, _) =
    object
      [ "id" .= contextSegmentId segment,
        "kind" .= contextSegmentKind segment,
        "authority" .= contextSegmentAuthority segment,
        "sourceRef" .= contextSegmentSourceRef segment
      ]
  segmentView width (segment, content) =
    object
      [ "id" .= contextSegmentId segment,
        "kind" .= contextSegmentKind segment,
        "authority" .= contextSegmentAuthority segment,
        "sourceRef" .= contextSegmentSourceRef segment,
        "content" .= Text.take width content
      ]

sleepInputChars :: [Model] -> Int
sleepInputChars models =
  max 12000 (min 60000 ((window - 8000) * 2))
 where
  window = fromMaybe 32768 (minimumMaybe (mapMaybe modelContextTokens models))
  minimumMaybe [] = Nothing
  minimumMaybe values = Just (minimum values)

parseDream :: Set Text -> Text -> Either Text DreamDecision
parseDream allowed raw =
  either
    (Left . ("invalid sleep decision: " <>) . Text.pack)
    Right
    (eitherDecodeStrict' (TextEncoding.encodeUtf8 (stripFence raw)))
    >>= validate
 where
  validate decision
    | Text.null continuation = Left "sleep decision has no continuation"
    | length (dreamActiveItems decision) > 8 = Left "sleep decision has more than 8 active items"
    | length (dreamOpenLoops decision) > 8 = Left "sleep decision has more than 8 open loops"
    | length retained > 12 = Left "sleep decision retains more than 12 segments"
    | any (`Set.notMember` allowed) retained = Left "sleep decision references an unknown retained segment"
    | any invalidForgotten (dreamForgotten decision) = Left "sleep decision contains an invalid forget decision"
    | otherwise =
        Right
          decision
            { dreamContinuation = Text.take 6000 continuation,
              dreamActiveItems = clean 8 1000 (dreamActiveItems decision),
              dreamOpenLoops = clean 8 1000 (dreamOpenLoops decision),
              dreamForgotten = take 32 (dreamForgotten decision),
              dreamRetainedSegmentIds = dedupe retained
            }
   where
    continuation = Text.strip (dreamContinuation decision)
    retained = dreamRetainedSegmentIds decision
  invalidForgotten forgotten =
    Text.null (Text.strip (forgetSubject forgotten))
      || Text.null (Text.strip (forgetReason forgotten))
      || any (`Set.notMember` allowed) (forgetSourceSegmentIds forgotten)
  clean count width = take count . filter (not . Text.null) . fmap (Text.take width . Text.strip)

commitSleep ::
  Cognition ->
  Incarnation ->
  Text ->
  Maybe Text ->
  SleepTrigger ->
  ContextEpoch ->
  WorkingMemoryHead ->
  FocusFrame ->
  Text ->
  [(ContextSegment, Text)] ->
  Compaction ->
  DreamDecision ->
  IO (Either Text SleepResult)
commitSleep cognition incarnation task run trigger baseEpoch initialHead initialFrame invocationId' projected compaction decision =
  either (pure . Left) persist (retainedWakeMessages retained projected)
 where
  identity = incarnationId incarnation
  working = cognitionWorking cognition
  retained = Set.fromList (dreamRetainedSegmentIds decision)
  persist retainedMessages =
    getPOSIXTime >>= \now ->
      newId >>= \cycleId ->
        newId >>= \packetId ->
          newId >>= \checkpointId ->
            persistPayload cognition identity "wake-packet" packetId (toJSON decision) >>= \packetPayload ->
              workingRequestSleep
                working
                identity
                (workingMemoryRevision initialHead)
                cycleId
                task
                run
                (contextEpochId baseEpoch)
                trigger
                >>= either (pure . Left) (prepare retainedMessages now cycleId packetId checkpointId packetPayload)
  prepare retainedMessages now cycleId packetId checkpointId packetPayload (quiescing, _) =
    persistPayload cognition identity "working-checkpoint" checkpointId (toJSON quiescing) >>= \statePayload ->
      let packet =
            WakePacket
              packetId
              identity
              task
              run
              (contextEpochId baseEpoch)
              trigger
              (dreamContinuation decision)
              (dreamActiveItems decision)
              (dreamOpenLoops decision)
              (dreamForgotten decision)
              (dreamRetainedSegmentIds decision)
              packetPayload
              sleepDreamRevision
              invocationId'
              (round now)
          checkpoint =
            WorkingMemoryCheckpoint
              checkpointId
              identity
              (workingMemoryRevision quiescing)
              (workingMemoryCursor quiescing)
              (workingMemoryFocusFrames quiescing)
              (workingMemoryActiveTaskId quiescing)
              statePayload
              ( sourceClosure
                  baseEpoch
                  (workingMemoryCursor quiescing)
                  (workingMemoryFocusFrames quiescing)
              )
              packetId
              sleepDreamRevision
              (round now)
       in workingPrepareCheckpoint
            working
            identity
            (workingMemoryRevision quiescing)
            cycleId
            checkpoint
            packet
            >>= either (pure . Left) (const (commit retainedMessages packet cycleId quiescing))
  commit retainedMessages packet cycleId quiescing =
    workingCommitSleep working identity (workingMemoryRevision quiescing) cycleId
      >>= either (pure . Left) (wake retainedMessages packet cycleId)
  wake retainedMessages packet cycleId (asleep, _) =
    commitWakeEpoch cognition incarnation task baseEpoch packet
      >>= either (degradeAsleep asleep cycleId) (begin retainedMessages packet asleep cycleId)
  begin retainedMessages packet asleep cycleId wakeEpoch =
    workingBeginWake working identity (workingMemoryRevision asleep) cycleId
      >>= either (pure . Left) (finish retainedMessages packet cycleId wakeEpoch)
  finish retainedMessages packet cycleId wakeEpoch (waking, _) =
    experienceHead (cognitionExperiences cognition) identity >>= \replayed ->
      getPOSIXTime >>= \now ->
        let frame = wakeFocusFrame packet wakeEpoch replayed (round now) initialFrame
         in workingCommitWakeFocus working identity (workingMemoryRevision waking) cycleId replayed frame
              >>= either
                (degradeWaking waking cycleId)
                ( \(awake, cycle') ->
                    let changed = wakeCompaction packet retainedMessages compaction
                     in pure (Right (SleepResult changed awake cycle' packet wakeEpoch))
                )
  degradeAsleep head' cycleId failure =
    workingBeginWake working identity (workingMemoryRevision head') cycleId >>= \case
      Left _ -> pure (Left failure)
      Right (waking, _) ->
        degradeWaking waking cycleId failure
  degradeWaking waking cycleId failure =
    workingDegradeWake working identity (workingMemoryRevision waking) cycleId failure
      $> Left failure

wakeFocusFrame :: WakePacket -> ContextEpoch -> ExperienceCursor -> Integer -> FocusFrame -> FocusFrame
wakeFocusFrame packet wakeEpoch replayed now frame =
  frame
    { focusFrameRevision = focusFrameRevision frame + 1,
      focusFrameEpochId = contextEpochId wakeEpoch,
      focusFrameObjective = wakePacketContinuation packet,
      focusFrameActiveItems = wakePacketActiveItems packet,
      focusFrameOpenLoops = wakePacketOpenLoops packet,
      focusFrameProvisionalClaims = [],
      focusFrameCursor = replayed,
      focusFrameUpdated = now
    }

sourceClosure :: ContextEpoch -> ExperienceCursor -> Map Text FocusFrame -> Text
sourceClosure epoch cursor frames =
  sha256
    ( LazyByteString.toStrict
        ( encode
            ( object
                [ "epoch" .= contextEpochEffectiveHash epoch,
                  "cursor" .= cursor,
                  "frames" .= frames
                ]
            )
        )
    )

commitWakeEpoch ::
  Cognition ->
  Incarnation ->
  Text ->
  ContextEpoch ->
  WakePacket ->
  IO (Either Text ContextEpoch)
commitWakeEpoch cognition incarnation task base packet =
  contextEpochProject contexts (contextEpochId base)
    >>= either (pure . Left) commit
 where
  contexts = cognitionContexts cognition
  retained = Set.fromList (wakePacketRetainedSegmentIds packet)
  commit projected =
    let selected = retainedProjection retained projected
     in either
          (pure . Left)
          ( const
              ( contextEpochCommit
                  contexts
                  (incarnationId incarnation)
                  task
                  (Just (contextEpochId base))
                  (wakeInput packet : fmap retainedInput selected)
                  (Just (wakePacketId packet))
              )
          )
          (projectedAguiMessages selected)
  retainedInput (segment, content) =
    ContextSegmentInput
      (contextSegmentSourceRef segment)
      (contextSegmentKind segment)
      (contextSegmentAuthority segment)
      content
      (contextSegmentCausalGroup segment)
      (contextSegmentTurnGroup segment)

wakeInput :: WakePacket -> ContextSegmentInput
wakeInput packet =
  ContextSegmentInput
    (wakePacketId packet)
    SegmentWakePacket
    AuthorityDerived
    (renderWakePacket packet)
    Nothing
    Nothing

wakeCompaction :: WakePacket -> [ChatMessage] -> Compaction -> Compaction
wakeCompaction packet retained compaction =
  compaction
    { compactionMessages = messages,
      compactionDropped = compactionDropped compaction <> body,
      compactionAfterTokens = estimateMessagesTokens messages,
      compactionKeptUnits = length retained,
      compactionSummary = rendered
    }
 where
  rendered = renderWakePacket packet
  (leading, body) = span isSystem (compactionMessages compaction)
  instructions = filter (not . transientSummary) leading
  messages = instructions <> [ChatSystem rendered] <> retained
  isSystem ChatSystem {} = True
  isSystem _ = False
  transientSummary (ChatSystem text) =
    contextSummaryMarker `Text.isPrefixOf` text || wakePacketMarker `Text.isPrefixOf` text
  transientSummary _ = False

retainedWakeMessages :: Set Text -> [(ContextSegment, Text)] -> Either Text [ChatMessage]
retainedWakeMessages retained projected =
  projectedAguiMessages (retainedProjection retained projected) >>= toChatMessages

retainedProjection :: Set Text -> [(ContextSegment, Text)] -> [(ContextSegment, Text)]
retainedProjection retained projected =
  filter keep selected
 where
  selected =
    [(segment, content) | (segment, content) <- projected, contextSegmentId segment `Set.member` retained]
  calls = causalGroups SegmentToolCall selected
  results = causalGroups SegmentToolResult selected
  valid = Set.intersection calls results
  keep (segment, _) =
    contextSegmentKind segment `notElem` [SegmentToolCall, SegmentToolResult]
      || maybe False (`Set.member` valid) (contextSegmentCausalGroup segment)
  causalGroups kind =
    Set.fromList
      . mapMaybe
        ( \(segment, _) ->
            if contextSegmentKind segment == kind then contextSegmentCausalGroup segment else Nothing
        )

renderWakePacket :: WakePacket -> Text
renderWakePacket packet =
  Text.intercalate
    "\n"
    ( [ wakePacketMarker,
        "id: " <> wakePacketId packet,
        "continuation: " <> wakePacketContinuation packet
      ]
        <> section "active" (wakePacketActiveItems packet)
        <> section "open loops" (wakePacketOpenLoops packet)
        <> [ "This packet is a derived short-term checkpoint. It is not long-term memory and contains no automatically recalled facts.",
             "Forgotten material remains only in the sleep audit (" <> shown (length (wakePacketForgotten packet)) <> " decisions)."
           ]
    )
 where
  section _ [] = []
  section label values = ("[" <> label <> "]") : fmap ("- " <>) values

persistPayload :: Cognition -> Text -> Text -> Text -> Value -> IO Text
persistPayload cognition identity purpose source value =
  blobPut
    (cognitionBlobs cognition)
    "application/json"
    (encode value)
    >>= \meta ->
      blobAttach
        (cognitionBlobs cognition)
        ("ref-" <> Text.take 32 (sha256 (TextEncoding.encodeUtf8 (Text.intercalate "\NUL" [identity, purpose, source, blobId meta]))))
        (blobId meta)
        identity
        purpose
        source
        >>= either (ioError . userError . Text.unpack) (const (pure (blobId meta)))

ensureAguiContext :: Cognition -> Incarnation -> AGUI.RunAgentInput -> IO (Either Text ContextEpoch)
ensureAguiContext cognition incarnation input =
  modifyMVar (cognitionContextCache cognition) $ \cache ->
    case Map.lookup key cache of
      Just identifier ->
        contextEpochRead (cognitionContexts cognition) identifier
          >>= maybe (build cache) (\epoch -> pure (cache, Right epoch))
      Nothing -> build cache
 where
  identity = incarnationId incarnation
  task = AGUI.runThreadId input
  key = (identity, task, AGUI.runId input)
  build cache =
    case aguiSegments (AGUI.runMessages input) of
      Left failure -> pure (cache, Left failure)
      Right segments ->
        commitContext cognition identity task segments
          >>= \result ->
            let changed =
                  either
                    (const cache)
                    (\epoch -> boundedInsert key (contextEpochId epoch) cache)
                    result
             in result
                  <$ traverse_
                    (\epoch -> void (workingReady cognition incarnation task epoch))
                    result
                  <&> (changed,)

commitContext :: Cognition -> Text -> Text -> [ContextSegmentInput] -> IO (Either Text ContextEpoch)
commitContext cognition identity task segments =
  contextEpochHead contexts identity task >>= attempt
 where
  contexts = cognitionContexts cognition
  attempt current =
    contextEpochCommit contexts identity task (contextEpochId <$> current) segments Nothing
      >>= \case
        Right epoch -> pure (Right epoch)
        Left _ ->
          contextEpochHead contexts identity task >>= \latest ->
            contextEpochCommit contexts identity task (contextEpochId <$> latest) segments Nothing

workingReady ::
  Cognition ->
  Incarnation ->
  Text ->
  ContextEpoch ->
  IO (Either Text (WorkingMemoryHead, FocusFrame))
workingReady cognition incarnation task epoch =
  experienceHead experiences identity >>= \cursor ->
    workingRead working identity >>= \case
      Nothing ->
        workingCreate working identity cursor >>= either (pure . Left) (sync cursor)
      Just head' -> sync cursor head'
 where
  identity = incarnationId incarnation
  experiences = cognitionExperiences cognition
  working = cognitionWorking cognition
  sync cursor head'
    | workingMemoryStatus head' /= WorkingAwake =
        pure (Left ("working memory is not awake: " <> statusText (workingMemoryStatus head')))
    | cursorSeq cursor > cursorSeq (workingMemoryCursor head') =
        workingAppendCursor working identity (workingMemoryRevision head') cursor
          >>= either (pure . Left) putFrame
    | otherwise = putFrame head'
  putFrame head' =
    getPOSIXTime >>= \now ->
      workingReadFocus working identity task >>= \current ->
        let objective = maybe ("Continue task " <> task) focusFrameObjective current
            frame =
              FocusFrame
                ("focus/" <> identity <> "/" <> task)
                identity
                task
                (maybe 1 ((+ 1) . focusFrameRevision) current)
                FocusActive
                (contextEpochId epoch)
                objective
                (maybe [] focusFrameActiveItems current)
                (maybe [] focusFrameOpenLoops current)
                (maybe [] focusFrameProvisionalClaims current)
                (maybe [] focusFrameRecentOutcomeRefs current)
                (maybe [] focusFrameArtifactRefs current)
                (workingMemoryCursor head')
                (round now)
         in if maybe False (sameFrame frame) current
              then pure (Right (head', fromMaybe frame current))
              else
                workingPutFocus working identity (workingMemoryRevision head') frame
                  <&> fmap (,frame)
  sameFrame next current =
    focusFrameEpochId current == focusFrameEpochId next
      && focusFrameStatus current == FocusActive

statusText :: WorkingStatus -> Text
statusText = Text.toLower . Text.drop 7 . Text.pack . show

closeExperience :: Cognition -> Incarnation -> AGUI.RunAgentInput -> RunOutcome -> [ChatMessage] -> IO ()
closeExperience cognition incarnation input outcome messages =
  archiveTaskRun cognition incarnation input outcome messages >>= \case
    Left failure -> ioError (userError (Text.unpack failure))
    Right _ ->
      appendRunEvents cognition incarnation input outcome messages >>= \events ->
        case reverse events of
          [] -> pure ()
          finalEvent : _
            | isJust (AGUI.runParentId input) -> pure ()
            | otherwise ->
                commitFinalContext >>= \epoch ->
                  enqueueConsolidation cognition incarnation events >>= \requestEvent ->
                    projectClosure epoch requestEvent (experienceEventId finalEvent)
 where
  identity = incarnationId incarnation
  task = AGUI.runThreadId input
  projectClosure epoch cursorEvent outcomeRef =
    workingReady cognition incarnation task epoch >>= \case
      Left failure -> ioError (userError (Text.unpack failure))
      Right (head', frame) ->
        let cursor = ExperienceCursor (experienceStreamId cursorEvent) (experienceSeq cursorEvent)
         in advanceWorking head' cursor >>= either (ioError . userError . Text.unpack) (updateFocus frame cursor outcomeRef)
  advanceWorking head' cursor
    | cursorSeq cursor <= cursorSeq (workingMemoryCursor head') = pure (Right head')
    | otherwise =
        workingAppendCursor
          (cognitionWorking cognition)
          identity
          (workingMemoryRevision head')
          cursor
  updateFocus frame cursor outcomeRef head' =
    getPOSIXTime >>= \now ->
      let changed =
            frame
              { focusFrameRevision = focusFrameRevision frame + 1,
                focusFrameCursor = cursor,
                focusFrameRecentOutcomeRefs = takeEnd 12 (focusFrameRecentOutcomeRefs frame <> [outcomeRef]),
                focusFrameUpdated = round now
              }
       in workingPutFocus
            (cognitionWorking cognition)
            identity
            (workingMemoryRevision head')
            changed
            >>= either (ioError . userError . Text.unpack) (const (pure ()))
  commitFinalContext =
    let segments = runChatSegments input (AGUI.runId input) messages
     in commitContext cognition identity task segments
          >>= either (ioError . userError . Text.unpack) pure

archiveTaskRun ::
  Cognition ->
  Incarnation ->
  AGUI.RunAgentInput ->
  RunOutcome ->
  [ChatMessage] ->
  IO (Either Text ArchiveRun)
archiveTaskRun cognition incarnation input outcome =
  archiveTaskSnapshot cognition incarnation input (outcomeStatus outcome) (outcomeMessage outcome)

archiveTaskSnapshot ::
  Cognition ->
  Incarnation ->
  AGUI.RunAgentInput ->
  Text ->
  Maybe Text ->
  [ChatMessage] ->
  IO (Either Text ArchiveRun)
archiveTaskSnapshot cognition incarnation input status failure messages =
  taskArchiveAppend
    (cognitionArchive cognition)
    ( ArchiveRunDraft
        (incarnationId incarnation)
        (AGUI.runThreadId input)
        (AGUI.runId input)
        latestIntent
        status
        failure
        (archiveEntries (AGUI.runId input) (currentRunMessages messages))
    )
 where
  latestIntent =
    listToMaybe
      ( reverse
          [ AGUI.userId user
          | AGUI.User user <- AGUI.runMessages input
          ]
      )

appendRunEvents :: Cognition -> Incarnation -> AGUI.RunAgentInput -> RunOutcome -> [ChatMessage] -> IO [ExperienceEvent]
appendRunEvents cognition incarnation input outcome messages =
  appendMaybe "UserInputAccepted" (String <$> latestUser)
    >>= \userEvent ->
      appendMaybe "AssistantOutcomeRecorded" (toJSON <$> latestAssistant)
        >>= \assistantEvent ->
          appendValue
            "RunTerminated"
            ( object
                [ "status" .= outcomeStatus outcome,
                  "code" .= outcomeCode outcome,
                  "message" .= outcomeMessage outcome,
                  "messageCount" .= length messages,
                  "assistantOutcomeRef" .= (experienceEventId <$> assistantEvent)
                ]
            )
            <&> \terminal -> catMaybes [userEvent, assistantEvent, Just terminal]
 where
  identity = incarnationId incarnation
  run = AGUI.runId input
  task = AGUI.runThreadId input
  latestUser =
    listToMaybe
      ( reverse
          [ text
          | AGUI.User user <- AGUI.runMessages input,
            Right text <- [AGUI.userText (AGUI.userContent user)]
          ]
      )
  latestAssistant =
    listToMaybe
      ( reverse
          [ turn
          | ChatAssistant turn <- suffixAfterLastUser messages,
            maybe False (not . Text.null . Text.strip) (turnText turn)
          ]
      )
  appendMaybe _ Nothing = pure Nothing
  appendMaybe kind (Just value) = Just <$> appendValue kind value
  appendValue kind value =
    appendExperienceIdempotent
      cognition
      identity
      run
      kind
      "experience"
      (run <> "/" <> kind)
      value
      ( \payload ->
          ExperienceDraft
            identity
            run
            identity
            (Just run)
            (Just task)
            (Just run)
            (delegationIdOf input)
            Nothing
            kind
            payload
            payload
      )

delegationIdOf :: AGUI.RunAgentInput -> Maybe Text
delegationIdOf input =
  parseMaybe (withObject "forwardedProps" (.: "delegationId")) (AGUI.runForwardedProps input)

enqueueConsolidation :: Cognition -> Incarnation -> [ExperienceEvent] -> IO ExperienceEvent
enqueueConsolidation cognition incarnation events =
  appendExperienceIdempotent
    cognition
    identity
    operation
    "ImpressionConsolidationRequested"
    "impression-consolidation"
    operation
    (toJSON request)
    draft
    >>= \event ->
      event
        <$ void
          ( forkIO
              (withIncarnationLock cognition identity (drainConsolidations cognition incarnation))
          )
 where
  identity = incarnationId incarnation
  reference = maybe ("empty/" <> identity) experienceEventId (listToMaybe (reverse events))
  operation = "impression/consolidate/" <> reference
  request = ConsolidationRequest reference (fmap experienceEventId events)
  terminal = listToMaybe (reverse events)
  draft payload =
    ExperienceDraft
      identity
      operation
      identity
      (experienceIntentId =<< terminal)
      (experienceTaskId =<< terminal)
      (experienceRunId =<< terminal)
      (experienceDelegationId =<< terminal)
      (experienceEventId <$> terminal)
      "ImpressionConsolidationRequested"
      payload
      payload

drainConsolidations :: Cognition -> Incarnation -> IO ()
drainConsolidations cognition incarnation =
  nextPending >>= traverse_ (\request -> process request *> drainConsolidations cognition incarnation)
 where
  identity = incarnationId incarnation
  experiences = cognitionExperiences cognition
  nextPending =
    experienceEvents experiences identity <&> \events ->
      let completed =
            Set.fromList
              [ experienceOperationId event
              | event <- events,
                experienceKind event `elem` ["ImpressionConsolidationSucceeded", "ImpressionConsolidationFailed"]
              ]
       in listToMaybe
            [ event
            | event <- sortOn experienceSeq events,
              experienceKind event == "ImpressionConsolidationRequested",
              experienceOperationId event `Set.notMember` completed
            ]
  process requested =
    loadConsolidationRequest cognition requested >>= \case
      Left failure -> finish requested "ImpressionConsolidationFailed" (object ["error" .= failure])
      Right request ->
        experienceClosure cognition identity (consolidationEventIds request) >>= \case
          Left failure -> finish requested "ImpressionConsolidationFailed" (object ["error" .= failure])
          Right closure ->
            taskArchiveTasks (cognitionArchive cognition) identity 64 >>= \catalog ->
              consolidateImpression
                (impressionModels cognition incarnation)
                (cognitionJournal cognition)
                (cognitionImpressions cognition)
                identity
                (consolidationExperienceRef request)
                (fmap archiveTaskId catalog)
                (consolidationExperienceRef request : consolidationEventIds request)
                closure
                >>= either
                  (\failure -> finish requested "ImpressionConsolidationFailed" (object ["error" .= failure]))
                  (\revision -> finish requested "ImpressionConsolidationSucceeded" (object ["revision" .= revision]))
  finish requested kind payload =
    void
      ( appendExperienceIdempotent
          cognition
          identity
          (experienceOperationId requested)
          kind
          "impression-consolidation"
          (experienceOperationId requested <> "/" <> kind)
          payload
          ( \payloadRef ->
              ExperienceDraft
                identity
                (experienceOperationId requested)
                identity
                (experienceIntentId requested)
                (experienceTaskId requested)
                (experienceRunId requested)
                (experienceDelegationId requested)
                (Just (experienceEventId requested))
                kind
                payloadRef
                payloadRef
          )
      )

loadConsolidationRequest :: Cognition -> ExperienceEvent -> IO (Either Text ConsolidationRequest)
loadConsolidationRequest cognition event =
  blobFetch (cognitionBlobs cognition) (experiencePayloadRef event) <&> \case
    Left failure -> Left failure
    Right bytes -> either (Left . Text.pack) Right (eitherDecode bytes)

experienceClosure :: Cognition -> Text -> [Text] -> IO (Either Text Text)
experienceClosure cognition identity identifiers =
  experienceEvents (cognitionExperiences cognition) identity >>= \events ->
    let index = Map.fromList [(experienceEventId event, event) | event <- events]
     in case traverse (`Map.lookup` index) identifiers of
          Nothing -> pure (Left "impression consolidation references a missing experience event")
          Just selected ->
            traverse render selected
              <&> \rendered ->
                sequence rendered
                  <&> \items ->
                    Text.take 50000 (encodeText (object ["events" .= items]))
 where
  render event =
    blobFetch (cognitionBlobs cognition) (experiencePayloadRef event)
      <&> fmap
        ( \payload ->
            object
              [ "eventId" .= experienceEventId event,
                "kind" .= experienceKind event,
                "taskId" .= experienceTaskId event,
                "runId" .= experienceRunId event,
                "authority" .= experienceActorId event,
                "sourceRef" .= experiencePayloadRef event,
                "payload" .= Text.take 14000 (TextEncoding.decodeUtf8 (LazyByteString.toStrict payload))
              ]
        )

appendExperienceIdempotent ::
  Cognition ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Value ->
  (Text -> ExperienceDraft) ->
  IO ExperienceEvent
appendExperienceIdempotent cognition identity operation kind purpose source payload draft =
  existing >>= maybe prepare pure
 where
  experiences = cognitionExperiences cognition
  existing =
    find
      ( (&&)
          <$> ((== operation) . experienceOperationId)
          <*> ((== kind) . experienceKind)
      )
      <$> experienceEvents experiences identity
  prepare =
    persistPayload cognition identity purpose source payload >>= retry 16
  retry :: Int -> Text -> IO ExperienceEvent
  retry remaining payloadRef =
    experienceHead experiences identity >>= \cursor ->
      experienceAppend experiences (Just cursor) (draft payloadRef) >>= \case
        Right event -> pure event
        Left failure
          | remaining <= 0 -> ioError (userError (Text.unpack failure))
          | otherwise -> existing >>= maybe (retry (remaining - 1) payloadRef) pure

withIncarnationLock :: Cognition -> Text -> IO value -> IO value
withIncarnationLock cognition identity action =
  modifyMVar (cognitionRunLocks cognition) acquire >>= \lock ->
    withMVar lock (const action)
 where
  acquire locks =
    case Map.lookup identity locks of
      Just lock -> pure (locks, lock)
      Nothing ->
        newMVar () >>= \lock ->
          pure (Map.insert identity lock locks, lock)

-- | 删除分身：档案 → 派生存储 → 记录，任一环失败立即中止并返回 `Left`，
-- 不会在部分失败后误报成功。
deleteIncarnation :: Cognition -> Text -> Int -> IO (Either Text ())
deleteIncarnation cognition identifier expected =
  incarnationRead (cognitionIncarnations cognition) identifier >>= \case
    Nothing -> pure (Left ("unknown incarnation: " <> identifier))
    Just incarnation
      | identifier == "yuki" -> pure (Left "default incarnation yuki cannot be deleted")
      | incarnationRevision incarnation /= expected ->
          pure (Left (staleIncarnation expected (incarnationRevision incarnation)))
      | incarnationStatus incarnation /= IncarnationArchived ->
          pure (Left ("incarnation is not archived: " <> identifier))
      | otherwise -> deleteAll
 where
  derived =
    [ impressionDelete (cognitionImpressions cognition) identifier,
      experienceDelete (cognitionExperiences cognition) identifier,
      workingDelete (cognitionWorking cognition) identifier,
      longTermDelete (cognitionLongTerm cognition) identifier,
      contextEpochDeleteIncarnation (cognitionContexts cognition) identifier
    ]
  deleteAll =
    taskArchiveDeleteIncarnation (cognitionArchive cognition) identifier >>= \case
      Left failure -> pure (Left failure)
      Right () -> deleteDerived
  deleteDerived =
    go derived
  go [] = deleteRecord
  go (action : rest) =
    (try action :: IO (Either IOException ())) >>= \case
      Left failure -> pure (Left (Text.pack (displayException failure)))
      Right () -> go rest
  deleteRecord =
    (try (incarnationDelete (cognitionIncarnations cognition) identifier expected) :: IO (Either IOException (Either Text Incarnation))) >>= \case
      Left failure -> pure (Left (Text.pack (displayException failure)))
      Right (Left failure) -> pure (Left failure)
      Right (Right _) -> clearCaches $> Right ()
  clearCaches =
    modifyMVar_ (cognitionSleepRequests cognition) (pure . Set.filter ((/= identifier) . fst))
      *> modifyMVar_ (cognitionActivationCache cognition) (pure . Map.filterWithKey (\key _ -> firstOfThree key /= identifier))
      *> modifyMVar_ (cognitionContextCache cognition) (pure . Map.filterWithKey (\key _ -> firstOfThree key /= identifier))
      *> modifyMVar_ (cognitionRunLocks cognition) (pure . Map.delete identifier)
  firstOfThree (a, _, _) = a

staleIncarnation :: Int -> Int -> Text
staleIncarnation expected actual =
  "stale incarnation revision: expected "
    <> Text.pack (show expected)
    <> ", actual "
    <> Text.pack (show actual)

suffixAfterLastUser :: [ChatMessage] -> [ChatMessage]
suffixAfterLastUser = reverse . takeWhile notUser . reverse
 where
  notUser ChatUser {} = False
  notUser _ = True

outcomeStatus :: RunOutcome -> Text
outcomeStatus = \case
  RunSucceeded -> "completed"
  RunFailed {} -> "failed"
  RunWasCancelled -> "cancelled"

outcomeCode :: RunOutcome -> Maybe Text
outcomeCode = \case
  RunFailed code _ -> Just code
  _ -> Nothing

outcomeMessage :: RunOutcome -> Maybe Text
outcomeMessage = \case
  RunFailed _ message -> Just message
  _ -> Nothing

currentRunMessages :: [ChatMessage] -> [ChatMessage]
currentRunMessages messages =
  maybe messages (`drop` messages) latestUserIndex
 where
  latestUserIndex =
    foldl
      (\found (index, message) -> bool found (Just index) (isUser message))
      Nothing
      (zip [0 ..] messages)
  isUser ChatUser {} = True
  isUser _ = False

archiveEntries :: Text -> [ChatMessage] -> [ArchiveEntryDraft]
archiveEntries run =
  concatMap (filter (not . Text.null . Text.strip . archiveEntryDraftContent) . one)
    . zip [1 :: Int ..]
 where
  source index suffix =
    "task/"
      <> run
      <> "/"
      <> shown index
      <> "/"
      <> suffix
  one (index, ChatSystem content)
    | wakePacketMarker `Text.isPrefixOf` content =
        [draft (source index "wake") ArchiveWakePacket content Nothing Nothing Nothing]
    | otherwise =
        [draft (source index "instruction") ArchiveInstruction content Nothing Nothing Nothing]
  one (index, ChatUser content) =
    [draft (source index "user") ArchiveUser content Nothing Nothing Nothing]
  one (_, ChatToolResult call content) =
    [draft (call <> "/result") ArchiveToolResult content (Just call) (Just call) Nothing]
  one (index, ChatAssistant turn) =
    [ draft (turnGroup <> "/reasoning") ArchiveReasoning content (Just turnGroup) Nothing Nothing
    | content <- maybe [] pure (turnReasoning turn)
    ]
      <> [ draft (turnGroup <> "/assistant") ArchiveAssistant content (Just turnGroup) Nothing Nothing
         | content <- maybe [] pure (turnText turn)
         ]
      <> [ draft
             (modelToolCallId call <> "/call")
             ArchiveToolCall
             (encodeText call)
             (Just turnGroup)
             (Just (modelToolCallId call))
             (Just (modelToolName call))
         | call <- turnToolCalls turn
         ]
   where
    turnGroup = fromMaybe (source index "assistant") (nonEmpty (turnMessageId turn))
  draft = ArchiveEntryDraft

chatSegments :: Text -> [ChatMessage] -> [ContextSegmentInput]
chatSegments run =
  concatMap one . zip [1 :: Int ..]
 where
  source index suffix =
    "chat/"
      <> run
      <> "/"
      <> shown index
      <> suffix
  one (index, ChatSystem text)
    | wakePacketMarker `Text.isPrefixOf` text =
        [ContextSegmentInput (source index "/wake") SegmentWakePacket AuthorityDerived text Nothing Nothing]
    | contextSummaryMarker `Text.isPrefixOf` text =
        [ContextSegmentInput (source index "/summary") SegmentInstruction AuthorityDerived text Nothing Nothing]
    | otherwise =
        [ContextSegmentInput (source index "/system") SegmentInstruction AuthorityKernel text Nothing Nothing]
  one (index, ChatUser text) =
    [ContextSegmentInput (source index "/user") SegmentUser AuthorityUser text Nothing Nothing]
  one (index, ChatToolResult call content) =
    [ContextSegmentInput (source index "/tool-result") SegmentToolResult AuthorityTool content (Just call) Nothing]
  one (index, ChatAssistant turn) =
    [ ContextSegmentInput
        turnGroup
        SegmentAssistant
        AuthorityAgent
        text
        Nothing
        (Just turnGroup)
    | text <- maybe [] pure (turnText turn),
      not (Text.null (Text.strip text))
    ]
      <> [ ContextSegmentInput
             (modelToolCallId call)
             SegmentToolCall
             AuthorityAgent
             (encodeText call)
             (Just (modelToolCallId call))
             (Just turnGroup)
         | call <- turnToolCalls turn
         ]
   where
    turnGroup = fromMaybe (source index "/assistant") (nonEmpty (turnMessageId turn))

runChatSegments :: AGUI.RunAgentInput -> Text -> [ChatMessage] -> [ContextSegmentInput]
runChatSegments input run messages =
  chatSegments run (filter durable messages)
 where
  instructions =
    Set.fromList
      [ content
      | message <- AGUI.runMessages input,
        content <- case message of
          AGUI.Developer developer -> [AGUI.developerContent developer]
          AGUI.System system -> [AGUI.systemContent system]
          _ -> []
      ]
  durable (ChatSystem text) =
    text `Set.member` instructions
      || contextSummaryMarker `Text.isPrefixOf` text
      || wakePacketMarker `Text.isPrefixOf` text
  durable _ = True

boundedInsert :: (Ord key) => key -> value -> Map key value -> Map key value
boundedInsert key value =
  Map.fromList . takeEnd 256 . Map.toList . Map.insert key value

nonEmpty :: Text -> Maybe Text
nonEmpty text
  | Text.null (Text.strip text) = Nothing
  | otherwise = Just (Text.strip text)

dedupe :: [Text] -> [Text]
dedupe = reverse . snd . foldl keep (Set.empty, [])
 where
  keep (seen, values) value
    | Text.null clean || clean `Set.member` seen = (seen, values)
    | otherwise = (Set.insert clean seen, clean : values)
   where
    clean = Text.strip value

takeEnd :: Int -> [value] -> [value]
takeEnd count values = drop (max 0 (length values - count)) values

shown :: (Show value) => value -> Text
shown = Text.pack . show

encodeText :: (ToJSON value) => value -> Text
encodeText = TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

stripFence :: Text -> Text
stripFence raw =
  fromMaybe trimmed $ do
    inner <- Text.stripPrefix "```json" trimmed <|> Text.stripPrefix "```" trimmed
    Text.stripSuffix "```" (Text.strip inner)
 where
  trimmed = Text.strip raw
