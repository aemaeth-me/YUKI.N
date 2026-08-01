module Yuki.N.Runs
  ( RunCancelled (..),
    RunHandle (..),
    RunRegistry,
    activeThreads,
    cancelRun,
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
import Yuki.N.Model (ChatMessage)

data RunHandle = RunHandle
  { runHandleThread :: ThreadId,
    runHandleTaskId :: Text,
    runHandleSteer :: IORef [ChatMessage],
    runHandleFollowUp :: IORef [ChatMessage]
  }

newtype RunRegistry = RunRegistry (IORef (Map Text RunHandle))

newRunRegistry :: IO RunRegistry
newRunRegistry = RunRegistry <$> newIORef Map.empty

withRunRegistration :: RunRegistry -> Text -> IO a -> IO a
withRunRegistration registry runId =
  withRunRegistrationFor registry runId runId

withRunRegistrationFor :: RunRegistry -> Text -> Text -> IO a -> IO a
withRunRegistrationFor (RunRegistry ref) runId taskId =
  bracket_ acquire release
 where
  acquire =
    myThreadId >>= \thread ->
      newIORef [] >>= \steer ->
        newIORef [] >>= \followUp ->
          mutate (Map.insert runId (RunHandle thread taskId steer followUp))
  release = mutate (Map.delete runId)
  mutate f = atomicModifyIORef' ref (\runs -> (f runs, ()))

activeThreads :: RunRegistry -> IO [Text]
activeThreads (RunRegistry ref) =
  Set.toList . Set.fromList . fmap runHandleTaskId . Map.elems <$> readIORef ref

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
