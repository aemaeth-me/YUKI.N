module Yuki.N.Cognition.Sleep
  ( boundedInsert,
    closeExperience,
    cognitionSleepCompaction,
    cognitionSleepMessages,
    commitContext,
    commitWakeEpoch,
    ensureAguiContext,
    runChatSegments,
    sleepCompaction,
    wakeFocusFrame,
  )
where

import Control.Concurrent.MVar (modifyMVar)
import Control.Monad (void)
import Data.Aeson (eitherDecodeStrict', encode, object, toJSON, (.=))
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent
import Yuki.N.Blob
import Yuki.N.Cognition.Experience
import Yuki.N.Cognition.Prompt
import Yuki.N.Cognition.Tools (encodeText, nonEmpty, stripFence)
import Yuki.N.Cognition.Types
import Yuki.N.ContextEpoch
import Yuki.N.Domain.Context
import Yuki.N.Experience
import Yuki.N.Incarnation
import Yuki.N.Invocation
import Yuki.N.Memory.Working
import Yuki.N.Model

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
        newId >>= invokeWith head' frame segments
   where
    invokeWith head'' frame' segments' invocationId' =
      let allowed = Set.fromList (contextSegmentId . fst <$> segments')
          specification =
            InvocationSpec
              invocationId'
              "working.sleep"
              sleepDreamRevision
              (cognitionModels cognition)
              (dreamPrompt (sleepInputChars (cognitionModels cognition)) incarnation task trigger frame' segments' (compactionPayload compaction))
              2
              16000
              60000
              (cognitionJournal cognition)
       in invokeModel specification
            >>= either (pure . Left) (parseAndCommit head'' frame' segments' allowed invocationId')
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
    (,,,)
      <$> getPOSIXTime
      <*> newId
      <*> newId
      <*> newId
      >>= persistWith retainedMessages
   where
    persistWith retainedMessages' (now, cycleId, packetId, checkpointId) =
      persistPayload cognition identity "wake-packet" packetId (toJSON decision)
        >>= requestSleep retainedMessages' now cycleId packetId checkpointId
    requestSleep retainedMessages' now cycleId packetId checkpointId packetPayload =
      workingRequestSleep
        working
        identity
        (workingMemoryRevision initialHead)
        cycleId
        task
        run
        (contextEpochId baseEpoch)
        trigger
        >>= either (pure . Left) (prepare retainedMessages' now cycleId packetId checkpointId packetPayload)
  prepare retainedMessages now cycleId packetId checkpointId packetPayload (quiescing, _) =
    persistPayload cognition identity "working-checkpoint" checkpointId (toJSON quiescing)
      >>= prepareCheckpoint retainedMessages now cycleId packetId packetPayload quiescing
   where
    prepareCheckpoint retainedMessages'' now' cycleId' packetId' packetPayload' quiescing' statePayload =
      let packet =
            WakePacket
              packetId'
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
              packetPayload'
              sleepDreamRevision
              invocationId'
              (round now')
          checkpoint =
            WorkingMemoryCheckpoint
              checkpointId
              identity
              (workingMemoryRevision quiescing')
              (workingMemoryCursor quiescing')
              (workingMemoryFocusFrames quiescing')
              (workingMemoryActiveTaskId quiescing')
              statePayload
              ( sourceClosure
                  baseEpoch
                  (workingMemoryCursor quiescing')
                  (workingMemoryFocusFrames quiescing')
              )
              packetId'
              sleepDreamRevision
              (round now')
       in workingPrepareCheckpoint
            working
            identity
            (workingMemoryRevision quiescing')
            cycleId'
            checkpoint
            packet
            >>= either (pure . Left) (const (commit retainedMessages'' packet cycleId' quiescing'))
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
    liftA2
      (,)
      (experienceHead (cognitionExperiences cognition) identity)
      getPOSIXTime
      >>= commitFocus retainedMessages packet cycleId wakeEpoch initialFrame waking
   where
    commitFocus retainedMessages' packet' cycleId' wakeEpoch' initialFrame' waking' (replayed, now) =
      let frame = wakeFocusFrame packet' wakeEpoch' replayed (round now) initialFrame'
       in workingCommitWakeFocus working identity (workingMemoryRevision waking') cycleId' replayed frame
            >>= either
              (degradeWaking waking' cycleId')
              (result packet' retainedMessages' wakeEpoch')
    result packet' retainedMessages' wakeEpoch' (awake, cycle') =
      let changed = wakeCompaction packet' retainedMessages' compaction
       in pure (Right (SleepResult changed awake cycle' packet' wakeEpoch'))
  degradeAsleep head' cycleId failure =
    workingBeginWake working identity (workingMemoryRevision head') cycleId
      >>= either
        (const (pure (Left failure)))
        (uncurry (degradeWhenAwake cycleId failure))
   where
    degradeWhenAwake cycleId' failure' waking _ =
      degradeWaking waking cycleId' failure'
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
          >>= commitResult
   where
    commitResult result =
      let changed = either (const cache) (cacheEpoch key) result
       in result
            <$ traverse_ (void . workingReady cognition incarnation task) result
            <&> (changed,)
    cacheEpoch cacheKey epoch =
      boundedInsert cacheKey (contextEpochId epoch) cache

commitContext :: Cognition -> Text -> Text -> [ContextSegmentInput] -> IO (Either Text ContextEpoch)
commitContext cognition identity task segments =
  contextEpochHead contexts identity task >>= attempt
 where
  contexts = cognitionContexts cognition
  attempt current =
    contextEpochCommit contexts identity task (contextEpochId <$> current) segments Nothing
      >>= either (const retryLatest) (pure . Right)
  retryLatest =
    contextEpochHead contexts identity task >>= retryCommit
  retryCommit latest =
    contextEpochCommit contexts identity task (contextEpochId <$> latest) segments Nothing

workingReady ::
  Cognition ->
  Incarnation ->
  Text ->
  ContextEpoch ->
  IO (Either Text (WorkingMemoryHead, FocusFrame))
workingReady cognition incarnation task epoch =
  experienceHead experiences identity >>= readyCursor
 where
  identity = incarnationId incarnation
  experiences = cognitionExperiences cognition
  working = cognitionWorking cognition
  readyCursor cursor =
    workingRead working identity
      >>= maybe
        (workingCreate working identity cursor >>= either (pure . Left) (sync cursor))
        (sync cursor)
  sync cursor head'
    | workingMemoryStatus head' /= WorkingAwake =
        pure (Left ("working memory is not awake: " <> statusText (workingMemoryStatus head')))
    | cursorSeq cursor > cursorSeq (workingMemoryCursor head') =
        workingAppendCursor working identity (workingMemoryRevision head') cursor
          >>= either (pure . Left) putFrame
    | otherwise = putFrame head'
  putFrame head' =
    liftA2
      (,)
      getPOSIXTime
      (workingReadFocus working identity task)
      >>= putFrameWith head'
   where
    putFrameWith head'' (now, current) =
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
              (workingMemoryCursor head'')
              (round now)
       in if maybe False (sameFrame frame) current
            then pure (Right (head'', fromMaybe frame current))
            else
              workingPutFocus working identity (workingMemoryRevision head'') frame
                <&> fmap (,frame)
  sameFrame next current =
    focusFrameEpochId current == focusFrameEpochId next
      && focusFrameStatus current == FocusActive

statusText :: WorkingStatus -> Text
statusText = Text.toLower . Text.drop 7 . Text.pack . show

closeExperience :: Cognition -> Incarnation -> AGUI.RunAgentInput -> RunOutcome -> [ChatMessage] -> IO ()
closeExperience cognition incarnation input outcome messages =
  archiveTaskRun cognition incarnation input outcome messages
    >>= either
      (ioError . userError . Text.unpack)
      (const (appendRunEvents cognition incarnation input outcome messages >>= closeEvents))
 where
  identity = incarnationId incarnation
  task = AGUI.runThreadId input
  closeEvents events =
    case reverse events of
      [] -> pure ()
      finalEvent : _
        | isJust (AGUI.runParentId input) -> pure ()
        | otherwise -> closeFinal events finalEvent
  closeFinal events finalEvent =
    commitFinalContext >>= enqueue finalEvent events
  enqueue finalEvent events epoch =
    enqueueConsolidation cognition incarnation events >>= project finalEvent epoch
  project finalEvent epoch requestEvent =
    projectClosure epoch requestEvent (experienceEventId finalEvent)
  projectClosure epoch cursorEvent outcomeRef =
    workingReady cognition incarnation task epoch
      >>= either
        (ioError . userError . Text.unpack)
        (uncurry (projectFrame cursorEvent outcomeRef))
   where
    projectFrame cursorEvent' outcomeRef' head' frame =
      let cursor = ExperienceCursor (experienceStreamId cursorEvent') (experienceSeq cursorEvent')
       in advanceWorking head' cursor >>= either (ioError . userError . Text.unpack) (updateFocus frame cursor outcomeRef')
  advanceWorking head' cursor
    | cursorSeq cursor <= cursorSeq (workingMemoryCursor head') = pure (Right head')
    | otherwise =
        workingAppendCursor
          (cognitionWorking cognition)
          identity
          (workingMemoryRevision head')
          cursor
  updateFocus frame cursor outcomeRef head' =
    getPOSIXTime >>= putFocus frame cursor outcomeRef head'
   where
    putFocus frame' cursor' outcomeRef' head'' now =
      let changed =
            frame'
              { focusFrameRevision = focusFrameRevision frame' + 1,
                focusFrameCursor = cursor',
                focusFrameRecentOutcomeRefs = takeEnd 12 (focusFrameRecentOutcomeRefs frame' <> [outcomeRef']),
                focusFrameUpdated = round now
              }
       in workingPutFocus
            (cognitionWorking cognition)
            identity
            (workingMemoryRevision head'')
            changed
            >>= either (ioError . userError . Text.unpack) (const (pure ()))
  commitFinalContext =
    let segments = runChatSegments input (AGUI.runId input) messages
     in commitContext cognition identity task segments
          >>= either (ioError . userError . Text.unpack) pure

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
