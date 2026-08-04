module Yuki.N.Replay
  ( Divergence (..),
    ReplayReport (..),
    readJournal,
    replayEntries,
    replayFile,
  )
where

import Control.Exception (Exception, throwIO, try)
import Data.Aeson (ToJSON (..), object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Bool (bool)
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.IORef
import Data.List (find, nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Yuki.N.AGUI.Event (Event (..))
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent
import Yuki.N.Artifact (isArtifactStub, newMemoryArtifactStore)
import Yuki.N.Background (newBackgroundRegistry)
import Yuki.N.Journal
import Yuki.N.Model
import Yuki.N.Runs (RunCancelled (..))

data ReplayReport = ReplayReport
  { reportRunId :: Text,
    reportEvents :: Int,
    reportDivergence :: Maybe Divergence
  }
  deriving stock (Eq, Show)

instance ToJSON ReplayReport where
  toJSON report =
    object
      [ "runId" .= reportRunId report,
        "events" .= reportEvents report,
        "divergence" .= reportDivergence report
      ]

data Divergence = Divergence
  { divergenceAt :: Int,
    divergenceExpected :: Maybe Event,
    divergenceActual :: Maybe Event,
    divergenceNote :: Maybe Text
  }
  deriving stock (Eq, Show)

instance ToJSON Divergence where
  toJSON divergence =
    object
      [ "at" .= divergenceAt divergence,
        "expected" .= divergenceExpected divergence,
        "actual" .= divergenceActual divergence,
        "note" .= divergenceNote divergence
      ]

newtype ReplayFailure = ReplayFailure Text
  deriving stock Show

instance Exception ReplayFailure

replayFile :: AgentHooks -> FilePath -> Maybe Text -> IO (Either Text ReplayReport)
replayFile hooks path wanted =
  readJournal path >>= either (pure . Left) (replayEntries hooks wanted)

replayEntries :: AgentHooks -> Maybe Text -> [Entry] -> IO (Either Text ReplayReport)
replayEntries hooks wanted entries =
  maybe (pure (Left "no matching run.begin in journal")) replayRun (select wanted begins)
 where
  begins = [(input, settings) | Entry _ scope _ (RunBegin input settings) <- entries, length scope == 1]
  replayRun (input, settings) =
    replay hooks input settings (AGUI.runId input) (runEntries (AGUI.runId input))
  runEntries runId = filter ((== [runId]) . entryScope) entries

select :: Maybe Text -> [(AGUI.RunAgentInput, RunSettings)] -> Maybe (AGUI.RunAgentInput, RunSettings)
select Nothing = listToMaybe . reverse
select (Just runId) = find ((== runId) . AGUI.runId . fst)

replay :: AgentHooks -> AGUI.RunAgentInput -> RunSettings -> Text -> [Entry] -> IO (Either Text ReplayReport)
replay hooks input settings runId runEntries =
  replaySetup >>= replayRun
 where
  replaySetup =
    (,,,,,,)
      <$> newIORef modelEntries
      <*> newIORef idValues
      <*> newIORef steerEntries
      <*> newIORef followUpEntries
      <*> newIORef []
      <*> newMemoryArtifactStore
      <*> newBackgroundRegistry

  modelEntries = [entry | entry@(Entry _ _ _ kind) <- runEntries, isModelKind kind]
  idValues = [value | Entry _ _ _ (IdEntry value) <- runEntries]
  steerEntries = [(step, messages) | Entry _ _ _ (SteeringEntry step messages) <- runEntries]
  followUpEntries = [(step, messages) | Entry _ _ _ (FollowUpEntry step messages) <- runEntries]

  replayRun (modelCursor, idCursor, steerCursor, followUpCursor, actual, artifacts, background) =
    ( try
        (runAgent (runtime background modelCursor idCursor steerCursor followUpCursor artifacts) input (modifyIORef' actual . (:))) ::
        IO (Either ReplayFailure ())
    )
      >>= either (report actual . Just . showReplay) (const (report actual Nothing))

  runtime background modelCursor idCursor steerCursor followUpCursor artifacts =
    Runtime
      { runtimeModel = Model "replay" "replay" (runSettingsContextTokens settings) (replayStream (throwIO (RunCancelled runId)) modelCursor) (const (object [])),
        runtimeTools = replayTools subEvents toolEntries toolSpecs,
        runtimeToolExecution = runSettingsToolExecution settings,
        runtimeMaxTurns = runSettingsMaxTurns settings,
        runtimeSystemPrompt = runSettingsSystemPrompt settings,
        runtimeHooks = hooks,
        runtimeNewId = replayNewId idCursor,
        runtimeJournal = Nothing,
        runtimeArtifactStore = bool Nothing (Just artifacts) (recordsMaterialization runEntries),
        runtimeBackground = background,
        runtimeDepth = runSettingsDepth settings,
        runtimeSubAgentMaxParallel = 4,
        runtimeProviderRetries = 0,
        runtimeFallbacks = [],
        runtimeSplice = runSettingsSplice settings,
        runtimeContext = runSettingsContext settings,
        runtimeRuns = Nothing,
        runtimeTelemetry = Nothing,
        runtimeDispatchStore = Nothing,
        runtimeDispatchConfirmTimeout = 600,
        runtimeIdentity = defaultIdentity,
        runtimeSteer = replayQueue steerCursor,
        runtimeFollowUp = replayQueue followUpCursor
      }

  toolEntries =
    Map.fromList
      [ (callId, (name, outcome))
      | Entry _ _ _ (ToolCallEntry callId name _ outcome) <- runEntries
      ]

  toolSpecs =
    Map.fromList
      [ (AGUI.toolName spec, spec)
      | Entry _ _ _ (ModelRequestEntry request) <- runEntries,
        spec <- requestTools request
      ]

  subEvents =
    Map.fromListWith
      (flip (<>))
      [ (callId, [event])
      | Entry _ _ _ (AgentEventEntry event) <- runEntries,
        Just callId <- [subCallId event]
      ]

  subCallId = \case
    Custom "agent.sub" value -> parseMaybe (withObject "agent.sub" (.: "callId")) value
    _ -> Nothing

  expected =
    [ event
    | Entry _ _ _ (AgentEventEntry event) <- runEntries,
      not (operational event)
    ]

  report actual note =
    readIORef actual >>= buildReport . reverse
   where
    buildReport events =
      pure (Right (ReplayReport runId (length events) (firstDivergence note expected (filter (not . operational) events))))

  showReplay (ReplayFailure message) = message

operational :: Event -> Bool
operational (Custom "provider.retry" _) = True
operational (Custom "provider.fallback" _) = True
operational (Custom "plan" _) = True
operational (Custom "shell.output" _) = True
operational (Custom "run.cancelled" _) = True
operational _ = False

firstDivergence :: Maybe Text -> [Event] -> [Event] -> Maybe Divergence
firstDivergence note expected actual =
  listToMaybe (mismatches <> lengthMismatch)
 where
  mismatches =
    [ Divergence index (Just want) (Just got) note
    | (index, want, got) <- zip3 [0 ..] expected actual,
      want /= got
    ]
  lengthMismatch
    | length expected > length actual =
        [Divergence (length actual) (listToMaybe (drop (length actual) expected)) Nothing note]
    | length actual > length expected =
        [Divergence (length expected) Nothing (listToMaybe (drop (length expected) actual)) note]
    | otherwise = []

recordsStub :: [Entry] -> Bool
recordsStub = any (requestStub . entryKind)
 where
  requestStub (ModelRequestEntry request) = any messageStub (requestMessages request)
  requestStub _ = False
  messageStub (ChatToolResult _ content) = isArtifactStub content
  messageStub _ = False

recordsMaterialization :: [Entry] -> Bool
recordsMaterialization entries = recordsStub entries || any contextArtifact entries
 where
  contextArtifact (Entry _ _ _ (ContextCompactEntry _ _ _ _ _ _ summary)) =
    "Full dropped context: artifact " `Text.isInfixOf` summary
  contextArtifact _ = False

isModelKind :: EntryKind -> Bool
isModelKind = \case
  ModelRequestEntry _ -> True
  ModelEventEntry _ -> True
  ModelFinishEntry _ -> True
  _ -> False

pop :: IORef [Entry] -> IO Entry -> IO Entry
pop cursor exhausted =
  readIORef cursor >>= popCursor
 where
  popCursor [] = exhausted
  popCursor (entry : rest) = entry <$ writeIORef cursor rest

replayStream :: IO Entry -> IORef [Entry] -> ModelRequest -> (ModelEvent -> IO ()) -> IO FinishReason
replayStream exhausted cursor request emit =
  pop cursor exhausted >>= checkRequest >> pendingRequest >>= bool stream contextOverflow
 where
  checkRequest entry = case entryKind entry of
    ModelRequestEntry recorded
      | recorded == request -> pure ()
      | otherwise ->
          throwIO (ReplayFailure ("model request diverged at seq " <> Text.pack (show (entrySeq entry))))
    other -> throwIO (ReplayFailure ("expected model request, found " <> kindName other))

  pendingRequest = readIORef cursor <&> pending
  pending (Entry _ _ _ (ModelRequestEntry _) : _) = True
  pending _ = False
  contextOverflow = throwIO (ProviderFailure "context_length_exceeded (replay)")

  stream = pop cursor exhausted >>= streamEntry
  streamEntry entry = case entryKind entry of
    ModelEventEntry event -> emit event *> stream
    ModelFinishEntry reason -> pure reason
    other -> throwIO (ReplayFailure ("expected model event, found " <> kindName other))

replayTools ::
  Map.Map Text [Event] ->
  Map.Map Text (Text, ToolOutcome) ->
  Map.Map Text AGUI.ToolSpec ->
  Map.Map Text BackendTool
replayTools subEvents entries toolSpecs =
  Map.fromList [(name, replayTool name) | name <- names]
 where
  names = nub (Map.keys toolSpecs ++ [name | (name, _) <- Map.elems entries])

  replayTool name =
    BackendTool
      (Map.findWithDefault (AGUI.ToolSpec name "replay" (object [])) name toolSpecs)
      (\context _ -> resolve name context)

  resolve name context =
    case Map.lookup (toolContextCallId context) entries of
      Just (recorded, outcome)
        | recorded == name ->
            traverse_ (toolContextEmit context) (Map.findWithDefault [] (toolContextCallId context) subEvents)
              $> outcome
      _ -> throwIO (ReplayFailure ("unexpected tool call " <> toolContextCallId context))

replayNewId :: IORef [Text] -> IO Text
replayNewId cursor =
  readIORef cursor >>= popId
 where
  popId [] = throwIO (ReplayFailure "journal exhausted at id stream")
  popId (value : rest) = value <$ writeIORef cursor rest

replayQueue :: IORef [(Int, [ChatMessage])] -> Int -> IO [ChatMessage]
replayQueue cursor step = atomicModifyIORef' cursor drain
 where
  drain entries = case break ((== step) . fst) entries of
    (_, []) -> (entries, [])
    (before, (_, messages) : after) -> (before <> after, messages)

kindName :: EntryKind -> Text
kindName = \case
  RunBegin _ _ -> "run.begin"
  ModelRequestEntry _ -> "model.request"
  ApiRequestEntry _ -> "api.request"
  ModelEventEntry _ -> "model.event"
  ModelFinishEntry _ -> "model.finish"
  ToolCallEntry {} -> "tool.call"
  IdEntry _ -> "id"
  AgentEventEntry _ -> "agent.event"
  StoreBriefEntry _ -> "store.brief"
  StoreFactsEntry _ -> "store.facts"
  SteeringEntry _ _ -> "steering"
  FollowUpEntry _ _ -> "followup"
  ContextCompactEntry {} -> "context.compact"

readJournal :: FilePath -> IO (Either Text [Entry])
readJournal = fmap (fmap journalReadEntries) . readJournalFile
