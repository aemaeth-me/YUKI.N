module Yuki.N.Cognition
  ( Cognition (..),
    DreamDecision (..),
    SleepResult (..),
    attachCognition,
    cognitionBootstrapIncarnation,
    cognitionGeneratePrompt,
    cognitionHooks,
    cognitionRecover,
    cognitionSleepMessages,
    compileIncarnationPrompt,
    deleteIncarnation,
    ensureIncarnation,
    newCognition,
    rootConstitution,
    rootPromptRevision,
    sleepDreamRevision,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (IOException, displayException, try)
import Control.Monad (void)
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.List (find, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing, listToMaybe)
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import Yuki.N.AGUI.Event (Event (..))
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent
import Yuki.N.Blob
import Yuki.N.Cognition.Experience
import Yuki.N.Cognition.Prompt
import Yuki.N.Cognition.Sleep
import Yuki.N.Cognition.Tools
  ( cognitionGeneratePrompt,
    cognitionTools,
    encodeText,
    nonEmpty,
  )
import Yuki.N.Cognition.Types
  ( Cognition (..),
    DreamDecision (..),
    SleepResult (..),
    shown,
  )
import Yuki.N.ContextEpoch
import Yuki.N.Experience
import Yuki.N.Incarnation
import Yuki.N.Journal (Journal)
import Yuki.N.Memory.Archive
import Yuki.N.Memory.Impression
import Yuki.N.Memory.LongTerm
import Yuki.N.Memory.Working
import Yuki.N.Model

newCognition :: FilePath -> [Model] -> Maybe Journal -> IO (Either Text Cognition)
newCognition dir models journal =
  newBlobStore dir >>= bindEither openExperience
 where
  bindEither = either (pure . Left)
  openExperience blobs =
    newExperienceStore dir >>= bindEither (openIncarnation blobs)
  openIncarnation blobs experiences =
    newIncarnationStore dir >>= bindEither (openContexts blobs experiences)
  openContexts blobs experiences incarnations =
    newContextEpochStore dir blobs >>= bindEither (openArchive blobs experiences incarnations)
  openArchive blobs experiences incarnations contexts =
    newTaskArchiveStore dir blobs >>= bindEither (openWorking blobs experiences incarnations contexts)
  openWorking blobs experiences incarnations contexts archive =
    newWorkingStore dir >>= bindEither (openLongTerm blobs experiences incarnations contexts archive)
  openLongTerm blobs experiences incarnations contexts archive working =
    newLongTermStore dir >>= bindEither (openImpressions blobs experiences incarnations contexts archive working)
  openImpressions blobs experiences incarnations contexts archive working longTerm =
    newImpressionStore dir >>= bindEither (assemble blobs experiences incarnations contexts archive working longTerm)
  assemble blobs experiences incarnations contexts archive working longTerm impressions =
    (,,,)
      <$> newMVar Set.empty
      <*> newMVar Map.empty
      <*> newMVar Map.empty
      <*> newMVar Map.empty
      >>= buildCognition blobs experiences incarnations contexts archive working longTerm impressions
   where
    buildCognition blobs' experiences' incarnations' contexts' archive' working' longTerm' impressions' (sleepRequests, activationCache, contextCache, runLocks) =
      let cognition =
            Cognition
              blobs'
              experiences'
              incarnations'
              contexts'
              archive'
              working'
              longTerm'
              impressions'
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

cognitionRecover :: Cognition -> IO (Either Text ())
cognitionRecover cognition =
  workingList (cognitionWorking cognition) >>= fmap sequence_ . traverse recover
 where
  working = cognitionWorking cognition
  experiences = cognitionExperiences cognition
  recover head' =
    incarnationRead (cognitionIncarnations cognition) identity
      >>= maybe
        (pure (Left ("working memory has no incarnation: " <> identity)))
        (recoverWith head')
   where
    identity = workingMemoryIncarnationId head'
    recoverWith head'' incarnation =
      case workingMemoryStatus head'' of
        WorkingAwake -> pure (Right ())
        WorkingQuiescing -> withCycle head'' (recoverQuiescing incarnation head'')
        WorkingAsleep -> withCycle head'' (recoverAsleep incarnation head'')
        WorkingWaking -> withCycle head'' (recoverWaking incarnation head'')
        WorkingDegraded -> fallback identity $> Right ()
  withCycle head' use =
    workingSleepCycles working (workingMemoryIncarnationId head')
      >>= maybe (fallback (workingMemoryIncarnationId head') $> Right ()) use . latestCycle (cycleMatches head')
   where
    latestCycle matches cycles =
      listToMaybe (reverse (sortOn sleepCycleUpdated (filter matches cycles)))
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
    ensureRecoveryWake incarnation cycle'
      >>= either
        (const (fallback (incarnationId incarnation) $> Right ()))
        (const (beginWake incarnation head' cycle'))
   where
    beginWake incarnation' head'' cycle'' =
      workingBeginWake
        working
        (incarnationId incarnation')
        (workingMemoryRevision head'')
        (sleepCycleId cycle'')
        >>= either (const (fallback (incarnationId incarnation') $> Right ())) (uncurry (recoverWaking incarnation'))
  recoverWaking incarnation head' cycle' =
    ensureRecoveryWake incarnation cycle'
      >>= either
        (const (fallback (incarnationId incarnation) $> Right ()))
        (uncurry (resumeWake incarnation head' cycle'))
   where
    resumeWake incarnation' head'' cycle'' packet wakeEpoch =
      liftA2
        (,)
        (experienceHead experiences (incarnationId incarnation'))
        getPOSIXTime
        >>= commitFrame incarnation' head'' cycle''
     where
      commitFrame incarnation'' head''' cycle''' (cursor, now) =
        workingReadFocus working (incarnationId incarnation'') (sleepCycleTaskId cycle''')
          >>= commitFocus incarnation'' head''' cycle''' cursor now
       where
        commitFocus incarnation''' head'''' cycle'''' cursor'' now'' focus =
          maybe
            ( workingCommitWake
                working
                (incarnationId incarnation''')
                (workingMemoryRevision head'''')
                (sleepCycleId cycle'''')
                cursor''
            )
            ( \frame ->
                workingCommitWakeFocus
                  working
                  (incarnationId incarnation''')
                  (workingMemoryRevision head'''')
                  (sleepCycleId cycle'''')
                  cursor''
                  (wakeFocusFrame packet wakeEpoch cursor'' (round now'') frame)
            )
            focus
            <&> void
  ensureRecoveryWake incarnation cycle' =
    workingPacket cycle'
      >>= maybe
        (pure (Left "sleep recovery is missing its Wake Packet"))
        (recoverWithPacket incarnation cycle')
   where
    recoverWithPacket incarnation' cycle'' packet =
      contextEpochList (cognitionContexts cognition) (incarnationId incarnation') (sleepCycleTaskId cycle'')
        >>= foundEpoch packet
     where
      foundEpoch packet' epochs =
        case find ((== Just (wakePacketId packet')) . contextEpochWakePacketId) epochs of
          Just epoch -> pure (Right (packet', epoch))
          Nothing ->
            contextEpochRead (cognitionContexts cognition) (sleepCycleBaseEpochId cycle')
              >>= maybe
                (pure (Left "sleep recovery is missing its base context epoch"))
                (commitBase packet')
      commitBase packet'' base =
        commitWakeEpoch cognition incarnation (sleepCycleTaskId cycle') base packet''
          <&> fmap (packet'',)
  workingPacket cycle' =
    maybe (pure Nothing) (workingReadWakePacket working) (sleepCycleWakePacketId cycle')
  fallback identity =
    workingRead working identity
      >>= maybe (pure ()) (const (recoverCursor identity))
   where
    recoverCursor identity' =
      experienceHead experiences identity' >>= void . workingRecover working identity'

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
        >>= promptActivate
          store
          (incarnationId incarnation)
          (incarnationRevision incarnation)
          . promptRevisionId
 where
  store = cognitionIncarnations cognition

ensureIncarnation :: Cognition -> Text -> IO Incarnation
ensureIncarnation cognition identifier =
  incarnationRead (cognitionIncarnations cognition) identifier
    >>= maybe
      (ioError (userError ("unknown incarnation: " <> Text.unpack identifier)))
      checkArchived
 where
  checkArchived incarnation
    | incarnationStatus incarnation == IncarnationArchived =
        ioError (userError ("incarnation is archived: " <> Text.unpack identifier))
    | otherwise = pure incarnation

attachCognition :: Cognition -> Incarnation -> Runtime -> IO Runtime
attachCognition cognition incarnation runtime =
  compileIncarnationPrompt cognition incarnation <&> attach
 where
  attach compiled =
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
  currentIntent input messages
    >>= maybe (pure Nothing) (uncurry activateIntent)
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
  activateIntent intentId intent =
    cachedActivation intentId
      >>= maybe
        (injectAndRemember intentId intent)
        (pure . nonEmpty)
  injectAndRemember intentId intent =
    activate intentId intent >>= rememberAndReturn intentId
  rememberAndReturn intentId injected =
    rememberActivation intentId injected $> injected
  activate intentId intent =
    taskArchiveTasks (cognitionArchive cognition) identity 64
      >>= invokeImpression intentId intent
   where
    invokeImpression intentId' intent' catalog =
      let identifiers = fmap archiveTaskId catalog
          rendered = encodeText catalog
       in activateImpression
            (impressionModels cognition incarnation)
            (cognitionJournal cognition)
            (cognitionImpressions cognition)
            identity
            (ImpressionScope task run intentId')
            intent'
            identifiers
            rendered
            <&> either (const Nothing) (nonEmpty . impressionActivationInjectedText)

currentIntent :: AGUI.RunAgentInput -> [ChatMessage] -> IO (Maybe (Text, Text))
currentIntent input messages =
  pure (computeIntent <$> latestChat)
 where
  computeIntent intent =
    let identifier =
          maybe
            ("intent-" <> Text.take 24 (sha256 (TextEncoding.encodeUtf8 (Text.intercalate "\NUL" [AGUI.runThreadId input, AGUI.runId input, intent]))))
            fst
            (listToMaybe (reverse (filter ((== intent) . snd) aguiIntents)))
     in (identifier, intent)
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

-- | 删除分身：档案 → 派生存储 → 记录，任一环失败立即中止并返回 `Left`，
-- 不会在部分失败后误报成功。
deleteIncarnation :: Cognition -> Text -> Int -> IO (Either Text ())
deleteIncarnation cognition identifier expected =
  incarnationRead (cognitionIncarnations cognition) identifier
    >>= maybe
      (pure (Left ("unknown incarnation: " <> identifier)))
      deleteWhenArchived
 where
  derived =
    [ impressionDelete (cognitionImpressions cognition) identifier,
      experienceDelete (cognitionExperiences cognition) identifier,
      workingDelete (cognitionWorking cognition) identifier,
      longTermDelete (cognitionLongTerm cognition) identifier,
      contextEpochDeleteIncarnation (cognitionContexts cognition) identifier
    ]
  deleteWhenArchived incarnation
    | identifier == "yuki" = pure (Left "default incarnation yuki cannot be deleted")
    | incarnationRevision incarnation /= expected =
        pure (Left (staleIncarnation expected (incarnationRevision incarnation)))
    | incarnationStatus incarnation /= IncarnationArchived =
        pure (Left ("incarnation is not archived: " <> identifier))
    | otherwise = deleteAll
  deleteAll =
    taskArchiveDeleteIncarnation (cognitionArchive cognition) identifier
      >>= either (pure . Left) (const deleteDerived)
  deleteDerived =
    go derived
  go [] = deleteRecord
  go (action : rest) =
    (try action :: IO (Either IOException ()))
      >>= either (pure . Left . Text.pack . displayException) (const (go rest))
  deleteRecord =
    (try (incarnationDelete (cognitionIncarnations cognition) identifier expected) :: IO (Either IOException (Either Text Incarnation)))
      >>= either
        (pure . Left . Text.pack . displayException)
        (either (pure . Left) (const (clearCaches $> Right ())))
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
