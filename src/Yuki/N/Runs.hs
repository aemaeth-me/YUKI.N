module Yuki.N.Runs
  ( CompletionOutcome (..),
    RunCancelled (..),
    RunCompletion (..),
    RunDescriptor (..),
    RunHandle (..),
    RunInfo (..),
    RunKind (..),
    RunRegistry,
    activeRuns,
    activeThreads,
    cancelRun,
    childrenOf,
    completionFor,
    completionsOf,
    drainFollowUps,
    drainSteering,
    followUpRun,
    newRunRegistry,
    noteCompletion,
    steerRun,
    withRunRegistration,
    withRunRegistrationFor,
    writeCompletion,
  )
where

import Control.Applicative (liftA2)
import Control.Concurrent (ThreadId, myThreadId, throwTo)
import Control.Exception (Exception, SomeAsyncException, SomeException, bracket_, displayException, fromException, throwIO, try)
import Data.Functor (($>))
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.IO (stderr)
import Yuki.N.Model (ChatMessage)

data RunKind = RunHome | RunTask | RunWorker
  deriving stock (Eq, Show)

data RunDescriptor = RunDescriptor
  { descriptorTaskId :: Text,
    descriptorIncarnation :: Text,
    descriptorParent :: Maybe Text,
    descriptorKind :: RunKind,
    descriptorObjective :: Maybe Text
  }
  deriving stock (Eq, Show)

data RunHandle = RunHandle
  { runHandleThread :: ThreadId,
    runHandleDescriptor :: RunDescriptor,
    runHandleStartedAt :: Integer,
    runHandleSteer :: IORef [ChatMessage],
    runHandleFollowUp :: IORef [ChatMessage]
  }

data RunInfo = RunInfo
  { runInfoId :: Text,
    runInfoTaskId :: Text,
    runInfoIncarnation :: Text,
    runInfoParent :: Maybe Text,
    runInfoKind :: RunKind,
    runInfoObjective :: Maybe Text,
    runInfoStartedAt :: Integer
  }
  deriving stock (Eq, Show)

data CompletionOutcome
  = Completed
  | Failed Text
  | Cancelled
  deriving stock (Eq, Show)

data RunCompletion = RunCompletion
  { completionRunId :: Text,
    completionParent :: Maybe Text,
    completionOutcome :: CompletionOutcome,
    completionResult :: Text,
    completionAt :: Integer
  }
  deriving stock (Eq, Show)

data RunRegistry = RunRegistry
  { registryRuns :: IORef (Map Text RunHandle),
    registryCompletions :: IORef (Map Text RunCompletion)
  }

newRunRegistry :: IO RunRegistry
newRunRegistry = liftA2 RunRegistry (newIORef Map.empty) (newIORef Map.empty)

withRunRegistration :: RunRegistry -> Text -> IO a -> IO a
withRunRegistration registry runId =
  withRunRegistrationFor registry runId (RunDescriptor runId "" Nothing RunTask Nothing)

withRunRegistrationFor :: RunRegistry -> Text -> RunDescriptor -> IO a -> IO a
withRunRegistrationFor registry runId descriptor =
  bracket_ acquire release
 where
  acquire =
    myThreadId >>= \thread ->
      newIORef [] >>= \steer ->
        newIORef [] >>= \followUp ->
          getPOSIXTime >>= \now ->
            mutate (Map.insert runId (RunHandle thread descriptor (round now) steer followUp))
  release =
    mutate (Map.delete runId)
      *> case descriptorParent descriptor of
        Nothing -> readIORef (registryCompletions registry) >>= \table -> dropIds (completionSubtree table runId)
        Just _ -> pure ()
  mutate f = atomicModifyIORef' (registryRuns registry) (\runs -> (f runs, ()))
  dropIds ids = atomicModifyIORef' (registryCompletions registry) (\table -> (foldr Map.delete table ids, ()))

completionSubtree :: Map Text RunCompletion -> Text -> [Text]
completionSubtree completions root =
  root : concatMap (completionSubtree completions . completionRunId) (children root)
 where
  children identifier =
    filter ((== Just identifier) . completionParent) (Map.elems completions)

runInfoOf :: Text -> RunHandle -> RunInfo
runInfoOf runId (RunHandle _ descriptor startedAt _ _) =
  RunInfo
    runId
    (descriptorTaskId descriptor)
    (descriptorIncarnation descriptor)
    (descriptorParent descriptor)
    (descriptorKind descriptor)
    (descriptorObjective descriptor)
    startedAt

activeRuns :: RunRegistry -> IO [RunInfo]
activeRuns registry =
  Map.foldrWithKey (\runId handle -> (runInfoOf runId handle :)) [] <$> readIORef (registryRuns registry)

childrenOf :: RunRegistry -> Text -> IO [RunInfo]
childrenOf registry parent =
  filter ((== Just parent) . runInfoParent) <$> activeRuns registry

activeThreads :: RunRegistry -> IO [Text]
activeThreads registry =
  Set.toList . Set.fromList . fmap (descriptorTaskId . runHandleDescriptor) . Map.elems <$> readIORef (registryRuns registry)

cancelRun :: RunRegistry -> Text -> IO Bool
cancelRun registry runId =
  readIORef (registryRuns registry)
    >>= maybe (pure False) (\handle -> throwTo (runHandleThread handle) (RunCancelled runId) $> True)
      . Map.lookup runId

steerRun :: RunRegistry -> Text -> ChatMessage -> IO Bool
steerRun registry =
  queueRun runHandleSteer (registryRuns registry)

followUpRun :: RunRegistry -> Text -> ChatMessage -> IO Bool
followUpRun registry =
  queueRun runHandleFollowUp (registryRuns registry)

queueRun :: (RunHandle -> IORef [ChatMessage]) -> IORef (Map Text RunHandle) -> Text -> ChatMessage -> IO Bool
queueRun field ref runId message =
  readIORef ref >>= maybe (pure False) push . Map.lookup runId
 where
  push handle = atomicModifyIORef' (field handle) (\queued -> (message : queued, ())) $> True

drainSteering :: RunRegistry -> Text -> IO [ChatMessage]
drainSteering registry =
  drainRun runHandleSteer (registryRuns registry)

drainFollowUps :: RunRegistry -> Text -> IO [ChatMessage]
drainFollowUps registry =
  drainRun runHandleFollowUp (registryRuns registry)

drainRun :: (RunHandle -> IORef [ChatMessage]) -> IORef (Map Text RunHandle) -> Text -> IO [ChatMessage]
drainRun field ref runId =
  readIORef ref >>= maybe (pure []) drain . Map.lookup runId
 where
  drain handle = atomicModifyIORef' (field handle) (\queued -> ([], reverse queued))

writeCompletion :: RunRegistry -> Text -> Maybe Text -> CompletionOutcome -> Text -> IO ()
writeCompletion registry runId parent outcome result =
  getPOSIXTime >>= \now ->
    noteCompletion registry (RunCompletion runId parent outcome (Text.take 4000 result) (round now))

noteCompletion :: RunRegistry -> RunCompletion -> IO ()
noteCompletion registry completion =
  try @SomeException (atomicModifyIORef' (registryCompletions registry) (\table -> (Map.insert (completionRunId completion) completion table, ()))) >>= \case
    Left exception ->
      maybe
        (TextIO.hPutStrLn stderr ("yuki.runs: completion write failed: " <> Text.pack (displayException exception)))
        throwIO
        (fromException exception :: Maybe SomeAsyncException)
    Right () -> pure ()

completionFor :: RunRegistry -> Text -> IO (Maybe RunCompletion)
completionFor registry runId =
  Map.lookup runId <$> readIORef (registryCompletions registry)

completionsOf :: RunRegistry -> Text -> IO [RunCompletion]
completionsOf registry parent =
  filter ((== Just parent) . completionParent) . Map.elems <$> readIORef (registryCompletions registry)

newtype RunCancelled = RunCancelled Text
  deriving stock (Eq, Show)

instance Exception RunCancelled
