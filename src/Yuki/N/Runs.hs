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
import Control.Exception (Exception, bracket)
import Data.Functor (($>))
import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
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
withRunRegistrationFor (RunRegistry ref) runId taskId action =
  bracket acquire (const release) (const action)
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
steerRun (RunRegistry ref) runId message =
  queueRun runHandleSteer ref runId message

followUpRun :: RunRegistry -> Text -> ChatMessage -> IO Bool
followUpRun (RunRegistry ref) runId message =
  queueRun runHandleFollowUp ref runId message

queueRun :: (RunHandle -> IORef [ChatMessage]) -> IORef (Map Text RunHandle) -> Text -> ChatMessage -> IO Bool
queueRun field ref runId message =
  readIORef ref >>= maybe (pure False) push . Map.lookup runId
  where
    push handle = atomicModifyIORef' (field handle) (\queued -> (message : queued, ())) $> True

drainSteering :: RunRegistry -> Text -> IO [ChatMessage]
drainSteering (RunRegistry ref) runId =
  drainRun runHandleSteer ref runId

drainFollowUps :: RunRegistry -> Text -> IO [ChatMessage]
drainFollowUps (RunRegistry ref) runId =
  drainRun runHandleFollowUp ref runId

drainRun :: (RunHandle -> IORef [ChatMessage]) -> IORef (Map Text RunHandle) -> Text -> IO [ChatMessage]
drainRun field ref runId =
  readIORef ref >>= maybe (pure []) drain . Map.lookup runId
  where
    drain handle = atomicModifyIORef' (field handle) (\queued -> ([], reverse queued))

newtype RunCancelled = RunCancelled Text
  deriving stock (Eq, Show)

instance Exception RunCancelled
