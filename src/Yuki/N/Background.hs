module Yuki.N.Background
  ( BackgroundProc (..),
    BackgroundRegistry,
    BackgroundSnapshot (..),
    backgroundTaskCount,
    completedRetentionLimit,
    feedBackground,
    killBackground,
    lookupBackground,
    newBackgroundRegistry,
    newBackgroundRegistryWithLimit,
    shutdownBackground,
    shutdownBackgroundThread,
    snapshotBackground,
    spawnBackground,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryReadMVar)
import Control.Exception (IOException, displayException, try)
import Data.Bool (bool)
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hFlush)
import System.Process
import System.Timeout (timeout)

data BackgroundRegistry = BackgroundRegistry
  { registryProcesses :: IORef (Map Text BackgroundProc),
    registryCompletedLimit :: Int
  }

data BackgroundProc = BackgroundProc
  { backgroundProcess :: ProcessHandle,
    backgroundThreadId :: Text,
    backgroundStarted :: POSIXTime,
    backgroundStdin :: IORef (Maybe Handle),
    backgroundBuffer :: IORef Text,
    backgroundTruncated :: IORef Bool,
    backgroundExit :: MVar Int
  }

data BackgroundSnapshot = BackgroundSnapshot
  { snapshotRunning :: Bool,
    snapshotExitCode :: Maybe Int,
    snapshotOutput :: Text,
    snapshotTruncated :: Bool
  }

completedRetentionLimit :: Int
completedRetentionLimit = 32

newBackgroundRegistry :: IO BackgroundRegistry
newBackgroundRegistry = newBackgroundRegistryWithLimit completedRetentionLimit

newBackgroundRegistryWithLimit :: Int -> IO BackgroundRegistry
newBackgroundRegistryWithLimit limit =
  newIORef Map.empty <&> flip BackgroundRegistry (max 0 limit)

backgroundTaskCount :: BackgroundRegistry -> IO Int
backgroundTaskCount = fmap Map.size . readIORef . registryProcesses

lookupBackground :: BackgroundRegistry -> Text -> IO (Maybe BackgroundProc)
lookupBackground registry taskId = Map.lookup taskId <$> readIORef (registryProcesses registry)

ringLimit :: Int
ringLimit = 64 * 1024

spawnBackground :: BackgroundRegistry -> Text -> Text -> FilePath -> String -> IO (Maybe Int)
spawnBackground registry threadId taskId root command =
  createProcess sh >>= \case
    (Just input, Just out, Just err, process) ->
      getPOSIXTime >>= \started ->
        newIORef "" >>= \buffer ->
          newIORef False >>= \truncated ->
            newIORef (Just input) >>= \stdin ->
              newEmptyMVar >>= \exit ->
                newEmptyMVar >>= \drained ->
                  let task = BackgroundProc process threadId started stdin buffer truncated exit
                   in atomicModifyIORef' (registryProcesses registry) (\procs -> (Map.insert taskId task procs, ()))
                        *> forkIO (pump out buffer truncated *> putMVar drained ())
                        *> forkIO (pump err buffer truncated *> putMVar drained ())
                        *> forkIO
                          ( waitForProcess process
                              >>= (timeout 5000000 (takeMVar drained *> takeMVar drained) *>)
                                . finish registry exit
                                . exitCodeOf
                          )
                        *> (fmap fromIntegral <$> getPid process)
    setup -> cleanupProcess setup $> Nothing
 where
  sh =
    (shell command)
      { cwd = Just root,
        std_in = CreatePipe,
        std_out = CreatePipe,
        std_err = CreatePipe,
        create_group = True
      }

finish :: BackgroundRegistry -> MVar Int -> Int -> IO ()
finish registry exit code = putMVar exit code *> pruneCompleted registry

exitCodeOf :: ExitCode -> Int
exitCodeOf ExitSuccess = 0
exitCodeOf (ExitFailure code) = code

pump :: Handle -> IORef Text -> IORef Bool -> IO ()
pump handle buffer truncated = loop
 where
  loop =
    TextIO.hGetChunk handle >>= \chunk ->
      bool (append chunk *> loop) (pure ()) (Text.null chunk)
  append chunk =
    atomicModifyIORef' buffer (keep chunk)
      >>= \dropped -> bool (pure ()) (writeIORef truncated True) dropped
  keep chunk existing =
    let merged = existing <> chunk
     in (Text.takeEnd ringLimit merged, Text.length merged > ringLimit)

snapshotBackground :: BackgroundRegistry -> Text -> Text -> Maybe Int -> IO (Either Text BackgroundSnapshot)
snapshotBackground registry threadId taskId waitSeconds =
  owned registry threadId taskId >>= \case
    Nothing -> pure (Left (unknown taskId))
    Just task -> Right <$> poll task
 where
  poll task =
    await (backgroundExit task) >>= \code ->
      BackgroundSnapshot (isNothing code) code
        <$> readIORef (backgroundBuffer task)
        <*> readIORef (backgroundTruncated task)
  await exit = maybe (tryReadMVar exit) (\seconds -> timeout (seconds * 1000000) (readMVar exit)) waitSeconds

feedBackground :: BackgroundRegistry -> Text -> Text -> Text -> Bool -> IO (Either Text Bool)
feedBackground registry threadId taskId text eof =
  owned registry threadId taskId >>= \case
    Nothing -> pure (Left (unknown taskId))
    Just task -> feed task
 where
  feed task =
    readIORef (backgroundStdin task) >>= \case
      Nothing -> pure (Left ("stdin is closed for background task: " <> taskId))
      Just handle ->
        (try (TextIO.hPutStr handle text *> hFlush handle) :: IO (Either IOException ())) >>= \case
          Left failure -> pure (Left (Text.pack (displayException failure)))
          Right () -> close task eof
  close task True =
    atomicModifyIORef' (backgroundStdin task) (\current -> (Nothing, current)) >>= \case
      Nothing -> pure (Right False)
      Just open -> (try (hClose open) :: IO (Either IOException ())) $> Right False
  close _ False = pure (Right True)

killBackground :: BackgroundRegistry -> Text -> Text -> IO (Either Text Bool)
killBackground registry threadId taskId =
  atomicModifyIORef' (registryProcesses registry) takeOwned >>= \case
    Nothing -> pure (Left (unknown taskId))
    Just task -> stopTask task <&> Right
 where
  takeOwned procs =
    case Map.lookup taskId procs of
      Just task
        | backgroundThreadId task == threadId -> (Map.delete taskId procs, Just task)
      _ -> (procs, Nothing)

shutdownBackgroundThread :: BackgroundRegistry -> Text -> IO ()
shutdownBackgroundThread registry threadId =
  atomicModifyIORef' (registryProcesses registry) detach >>= traverse_ stopTask
 where
  detach processes =
    let (ownedTasks, remaining) = Map.partition ((== threadId) . backgroundThreadId) processes
     in (remaining, Map.elems ownedTasks)

shutdownBackground :: BackgroundRegistry -> IO ()
shutdownBackground registry =
  atomicModifyIORef' (registryProcesses registry) (\processes -> (Map.empty, Map.elems processes))
    >>= traverse_ stopTask

stopTask :: BackgroundProc -> IO Bool
stopTask task =
  closeInput task
    *> tryReadMVar (backgroundExit task)
    >>= maybe stop (const (pure True))
 where
  stop =
    ignoringIO (interruptProcessGroupOf (backgroundProcess task))
      *> timeout 5000000 (readMVar (backgroundExit task))
      >>= maybe force (const (pure True))
  force =
    ignoringIO (terminateProcess (backgroundProcess task))
      *> timeout 5000000 (readMVar (backgroundExit task))
      <&> isJust

closeInput :: BackgroundProc -> IO ()
closeInput task =
  atomicModifyIORef' (backgroundStdin task) (\current -> (Nothing, current))
    >>= traverse_ (ignoringIO . hClose)

ignoringIO :: IO () -> IO ()
ignoringIO action = (try action :: IO (Either IOException ())) $> ()

owned :: BackgroundRegistry -> Text -> Text -> IO (Maybe BackgroundProc)
owned registry threadId taskId =
  Map.lookup taskId <$> readIORef (registryProcesses registry)
    <&> (>>= \task -> bool Nothing (Just task) (backgroundThreadId task == threadId))

pruneCompleted :: BackgroundRegistry -> IO ()
pruneCompleted registry =
  readIORef (registryProcesses registry)
    >>= traverse completed . Map.toList
    >>= \states ->
      let done = sortOn (backgroundStarted . snd) (catMaybes states)
          excess = max 0 (length done - registryCompletedLimit registry)
          expired = Map.fromList [(taskId, ()) | (taskId, _) <- take excess done]
       in atomicModifyIORef'
            (registryProcesses registry)
            (\processes -> (Map.withoutKeys processes (Map.keysSet expired), ()))
 where
  completed pair@(_, task) = tryReadMVar (backgroundExit task) <&> bool Nothing (Just pair) . isJust

unknown :: Text -> Text
unknown taskId = "unknown background task: " <> taskId
