module Yuki.N.Runs
  ( CompletionOutcome (..),
    RunCancelled (..),
    RunCompletion (..),
    RunDescriptor (..),
    RunInfo (..),
    RunRegistry,
    cancelRun,
    childrenOf,
    completionFor,
    completionsOf,
    drainSteering,
    newRunRegistry,
    releaseReservation,
    reserveChildRun,
    steerRun,
    withRunRegistrationFor,
    writeCompletion,
  )
where

import Control.Concurrent (ThreadId, myThreadId, throwTo)
import Control.Exception (Exception, SomeAsyncException, SomeException, bracket, displayException, fromException, throwIO, try)
import Data.Functor (($>))
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.IO (stderr)
import Yuki.N.Model (ChatMessage)

data RunDescriptor = RunDescriptor
  { descriptorParent :: Maybe Text,
    descriptorObjective :: Maybe Text
  }
  deriving stock (Eq, Show)

data RunHandle = RunHandle
  { runHandleThread :: Maybe ThreadId,
    runHandleDescriptor :: RunDescriptor,
    runHandleStartedAt :: Integer,
    runHandleSteer :: IORef [ChatMessage],
    runHandleCancelled :: IORef Bool
  }

data RunInfo = RunInfo
  { runInfoId :: Text,
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
    completionParent :: Text,
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

reserveChildRun :: RunRegistry -> Int -> Text -> RunDescriptor -> IO Bool
reserveChildRun registry limit runId descriptor =
  newHandle Nothing descriptor >>= reserve
 where
  reserve handle = atomicModifyIORef' (registryRuns registry) (insert handle)
  insert handle runs
    | Map.member runId runs = (runs, False)
    | childCount runs >= limit = (runs, False)
    | otherwise = (Map.insert runId handle runs, True)
  childCount =
    Map.size
      . Map.filter ((== descriptorParent descriptor) . descriptorParent . runHandleDescriptor)

releaseReservation :: RunRegistry -> Text -> IO ()
releaseReservation registry runId =
  atomicModifyIORef'
    (registryRuns registry)
    release
    >>= maybe (pure ()) (uncurry (cleanupReleased registry runId))
 where
  release runs = case Map.lookup runId runs of
    Just handle
      | Nothing <- runHandleThread handle ->
          let remaining = Map.delete runId runs
           in (remaining, Just (runHandleDescriptor handle, remaining))
    _ -> (runs, Nothing)

withRunRegistrationFor :: RunRegistry -> Text -> RunDescriptor -> (Bool -> IO value) -> IO value
withRunRegistrationFor registry runId descriptor action =
  bracket acquire (const release) run
 where
  acquire =
    liftA2 (,) myThreadId (newHandle Nothing descriptor) >>= uncurry activate
  activate thread fresh =
    atomicModifyIORef'
      (registryRuns registry)
      (activateIn thread fresh)
      >>= either throwIO pure
  activateIn thread fresh runs =
    case Map.lookup runId runs of
      Nothing -> activateHandle fresh
      Just reserved
        | runHandleDescriptor reserved == descriptor,
          Nothing <- runHandleThread reserved ->
            activateHandle reserved
      _ -> (runs, Left (DuplicateRun runId))
   where
    activateHandle handle =
      let active = handle {runHandleThread = Just thread}
       in (Map.insert runId active runs, Right (runHandleCancelled active))
  run cancelled = readIORef cancelled >>= action
  release =
    atomicModifyIORef'
      (registryRuns registry)
      (\runs -> let remaining = Map.delete runId runs in (remaining, remaining))
      >>= cleanupReleased registry runId descriptor

cleanupReleased :: RunRegistry -> Text -> RunDescriptor -> Map Text RunHandle -> IO ()
cleanupReleased registry runId descriptor runs
  | Map.member root runs || any (childOf root) (Map.elems runs) = pure ()
  | otherwise = readIORef completions >>= dropSubtree
 where
  root = fromMaybe runId (descriptorParent descriptor)
  completions = registryCompletions registry
  childOf parent = (== Just parent) . descriptorParent . runHandleDescriptor
  dropSubtree table =
    atomicModifyIORef'
      completions
      (\current -> (foldr Map.delete current (completionSubtree table root), ()))

newHandle :: Maybe ThreadId -> RunDescriptor -> IO RunHandle
newHandle thread descriptor =
  (RunHandle thread descriptor . round <$> getPOSIXTime)
    <*> newIORef []
    <*> newIORef False

completionSubtree :: Map Text RunCompletion -> Text -> [Text]
completionSubtree completions root =
  root : concatMap (completionSubtree completions . completionRunId) (children root)
 where
  children identifier =
    filter ((== identifier) . completionParent) (Map.elems completions)

runInfoOf :: Text -> RunHandle -> RunInfo
runInfoOf runId handle =
  RunInfo
    runId
    (descriptorObjective descriptor)
    (runHandleStartedAt handle)
 where
  descriptor = runHandleDescriptor handle

childrenOf :: RunRegistry -> Text -> IO [RunInfo]
childrenOf registry parent =
  Map.foldrWithKey child [] <$> readIORef (registryRuns registry)
 where
  child runId handle children
    | descriptorParent (runHandleDescriptor handle) == Just parent = runInfoOf runId handle : children
    | otherwise = children

cancelRun :: RunRegistry -> Text -> IO Bool
cancelRun registry runId =
  readIORef (registryRuns registry)
    >>= maybe (pure False) cancel . Map.lookup runId
 where
  cancel handle =
    maybe
      (atomicModifyIORef' (runHandleCancelled handle) (const (True, True)))
      (\thread -> throwTo thread RunCancelled $> True)
      (runHandleThread handle)

steerRun :: RunRegistry -> Text -> ChatMessage -> IO Bool
steerRun registry = queueRun runHandleSteer (registryRuns registry)

queueRun :: (RunHandle -> IORef [ChatMessage]) -> IORef (Map Text RunHandle) -> Text -> ChatMessage -> IO Bool
queueRun field ref runId message =
  readIORef ref >>= maybe (pure False) push . Map.lookup runId
 where
  push handle = atomicModifyIORef' (field handle) (\queued -> (message : queued, ())) $> True

drainSteering :: RunRegistry -> Text -> IO [ChatMessage]
drainSteering registry = drainRun runHandleSteer (registryRuns registry)

drainRun :: (RunHandle -> IORef [ChatMessage]) -> IORef (Map Text RunHandle) -> Text -> IO [ChatMessage]
drainRun field ref runId =
  readIORef ref >>= maybe (pure []) drain . Map.lookup runId
 where
  drain handle = atomicModifyIORef' (field handle) (\queued -> ([], reverse queued))

writeCompletion :: RunRegistry -> Text -> Text -> CompletionOutcome -> Text -> IO ()
writeCompletion registry runId parent outcome result =
  getPOSIXTime >>= noteCompletion registry . RunCompletion runId parent outcome result . round

noteCompletion :: RunRegistry -> RunCompletion -> IO ()
noteCompletion registry completion =
  try @SomeException (atomicModifyIORef' (registryCompletions registry) (\table -> (Map.insert (completionRunId completion) completion table, ())))
    >>= handleCompletionWrite
 where
  handleCompletionWrite (Left exception) =
    maybe
      (TextIO.hPutStrLn stderr ("yuki.runs: completion write failed: " <> Text.pack (displayException exception)))
      throwIO
      (fromException exception :: Maybe SomeAsyncException)
  handleCompletionWrite (Right ()) = pure ()

completionFor :: RunRegistry -> Text -> IO (Maybe RunCompletion)
completionFor registry runId =
  Map.lookup runId <$> readIORef (registryCompletions registry)

completionsOf :: RunRegistry -> Text -> IO [RunCompletion]
completionsOf registry parent =
  filter ((== parent) . completionParent) . Map.elems <$> readIORef (registryCompletions registry)

data RunCancelled = RunCancelled
  deriving stock (Eq, Show)

instance Exception RunCancelled

newtype DuplicateRun = DuplicateRun Text
  deriving stock (Eq, Show)

instance Exception DuplicateRun
