module Yuki.N.Runs
  ( RunCancelled (..),
    RunDescriptor (..),
    RunHandle (..),
    RunInfo (..),
    RunKind (..),
    RunRegistry,
    activeRuns,
    activeThreads,
    cancelRun,
    childrenOf,
    drainFollowUps,
    drainSteering,
    followUpRun,
    newRunRegistry,
    steerRun,
    withRunRegistration,
    withRunRegistrationFor,
  )
where

import Control.Concurrent (ThreadId, myThreadId, throwTo)
import Control.Exception (Exception, bracket_)
import Data.Functor (($>))
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
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

newtype RunRegistry = RunRegistry (IORef (Map Text RunHandle))

newRunRegistry :: IO RunRegistry
newRunRegistry = RunRegistry <$> newIORef Map.empty

withRunRegistration :: RunRegistry -> Text -> IO a -> IO a
withRunRegistration registry runId =
  withRunRegistrationFor registry runId (RunDescriptor runId "" Nothing RunTask Nothing)

withRunRegistrationFor :: RunRegistry -> Text -> RunDescriptor -> IO a -> IO a
withRunRegistrationFor (RunRegistry ref) runId descriptor =
  bracket_ acquire release
 where
  acquire =
    myThreadId >>= \thread ->
      newIORef [] >>= \steer ->
        newIORef [] >>= \followUp ->
          getPOSIXTime >>= \now ->
            mutate (Map.insert runId (RunHandle thread descriptor (round now) steer followUp))
  release = mutate (Map.delete runId)
  mutate f = atomicModifyIORef' ref (\runs -> (f runs, ()))

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
activeRuns (RunRegistry ref) =
  Map.foldrWithKey (\runId handle -> (runInfoOf runId handle :)) [] <$> readIORef ref

childrenOf :: RunRegistry -> Text -> IO [RunInfo]
childrenOf registry parent =
  filter ((== Just parent) . runInfoParent) <$> activeRuns registry

activeThreads :: RunRegistry -> IO [Text]
activeThreads (RunRegistry ref) =
  Set.toList . Set.fromList . fmap (descriptorTaskId . runHandleDescriptor) . Map.elems <$> readIORef ref

cancelRun :: RunRegistry -> Text -> IO Bool
cancelRun (RunRegistry ref) runId =
  readIORef ref
    >>= maybe (pure False) (\handle -> throwTo (runHandleThread handle) (RunCancelled runId) $> True)
      . Map.lookup runId

steerRun :: RunRegistry -> Text -> ChatMessage -> IO Bool
steerRun (RunRegistry ref) =
  queueRun runHandleSteer ref

followUpRun :: RunRegistry -> Text -> ChatMessage -> IO Bool
followUpRun (RunRegistry ref) =
  queueRun runHandleFollowUp ref

queueRun :: (RunHandle -> IORef [ChatMessage]) -> IORef (Map Text RunHandle) -> Text -> ChatMessage -> IO Bool
queueRun field ref runId message =
  readIORef ref >>= maybe (pure False) push . Map.lookup runId
 where
  push handle = atomicModifyIORef' (field handle) (\queued -> (message : queued, ())) $> True

drainSteering :: RunRegistry -> Text -> IO [ChatMessage]
drainSteering (RunRegistry ref) =
  drainRun runHandleSteer ref

drainFollowUps :: RunRegistry -> Text -> IO [ChatMessage]
drainFollowUps (RunRegistry ref) =
  drainRun runHandleFollowUp ref

drainRun :: (RunHandle -> IORef [ChatMessage]) -> IORef (Map Text RunHandle) -> Text -> IO [ChatMessage]
drainRun field ref runId =
  readIORef ref >>= maybe (pure []) drain . Map.lookup runId
 where
  drain handle = atomicModifyIORef' (field handle) (\queued -> ([], reverse queued))

newtype RunCancelled = RunCancelled Text
  deriving stock (Eq, Show)

instance Exception RunCancelled
