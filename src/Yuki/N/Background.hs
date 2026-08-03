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
  createProcess sh >>= setup
 where
  sh =
    (shell command)
      { cwd = Just root,
        std_in = CreatePipe,
        std_out = CreatePipe,
        std_err = CreatePipe,
        create_group = True
      }

  setup (Just input, Just out, Just err, process) =
    newEmptyMVar >>= launch registry threadId taskId input out err process
  setup rest = cleanupProcess rest $> Nothing

  launch registry' threadId' taskId' input out err process drained =
    mkTask threadId' input process >>= forkAll registry' taskId' out err process drained

  mkTask threadId' input process =
    BackgroundProc process threadId'
      <$> getPOSIXTime
      <*> newIORef (Just input)
      <*> newIORef ""
      <*> newIORef False
      <*> newEmptyMVar

  forkAll registry' taskId' out err process drained task =
    register task
      *> forkIO (pump out (backgroundBuffer task) (backgroundTruncated task) *> putMVar drained ())
      *> forkIO (pump err (backgroundBuffer task) (backgroundTruncated task) *> putMVar drained ())
      *> forkIO
        ( waitForProcess process
            >>= (timeout 5000000 (takeMVar drained *> takeMVar drained) *>)
              . finish registry' (backgroundExit task)
              . exitCodeOf
        )
      *> (fmap fromIntegral <$> getPid process)
   where
    register task' =
      atomicModifyIORef' (registryProcesses registry') (\procs -> (Map.insert taskId' task' procs, ()))

finish :: BackgroundRegistry -> MVar Int -> Int -> IO ()
finish registry exit code = putMVar exit code *> pruneCompleted registry

exitCodeOf :: ExitCode -> Int
exitCodeOf ExitSuccess = 0
exitCodeOf (ExitFailure code) = code

pump :: Handle -> IORef Text -> IORef Bool -> IO ()
pump handle buffer truncated = loop
 where
  loop = TextIO.hGetChunk handle >>= continue
  continue chunk = bool (append chunk *> loop) (pure ()) (Text.null chunk)
  append chunk =
    atomicModifyIORef' buffer (keep chunk)
      >>= bool (pure ()) (writeIORef truncated True)
  keep chunk existing =
    let merged = existing <> chunk
     in (Text.takeEnd ringLimit merged, Text.length merged > ringLimit)

snapshotBackground :: BackgroundRegistry -> Text -> Text -> Maybe Int -> IO (Either Text BackgroundSnapshot)
snapshotBackground registry threadId taskId waitSeconds =
  owned registry threadId taskId >>= withOwned
 where
  withOwned Nothing = pure (Left (unknown taskId))
  withOwned (Just task) = Right <$> poll task

  poll task =
    await (backgroundExit task) >>= snapshotOf task

  snapshotOf task code =
    BackgroundSnapshot (isNothing code) code
      <$> readIORef (backgroundBuffer task)
      <*> readIORef (backgroundTruncated task)

  await exit = maybe (tryReadMVar exit) (\seconds -> timeout (seconds * 1000000) (readMVar exit)) waitSeconds

feedBackground :: BackgroundRegistry -> Text -> Text -> Text -> Bool -> IO (Either Text Bool)
feedBackground registry threadId taskId text eof =
  owned registry threadId taskId >>= withOwned
 where
  withOwned Nothing = pure (Left (unknown taskId))
  withOwned (Just task) = feed task

  feed task =
    readIORef (backgroundStdin task) >>= writeStdin
   where
    writeStdin Nothing = pure (Left ("stdin is closed for background task: " <> taskId))
    writeStdin (Just handle) =
      (try (TextIO.hPutStr handle text *> hFlush handle) :: IO (Either IOException ()))
        >>= closeAfter
    closeAfter (Left failure) = pure (Left (Text.pack (displayException failure)))
    closeAfter (Right ()) = close task eof

  close task True =
    atomicModifyIORef' (backgroundStdin task) (\current -> (Nothing, current))
      >>= closeResult
   where
    closeResult Nothing = pure (Right False)
    closeResult (Just open) = (try (hClose open) :: IO (Either IOException ())) $> Right False
  close _ False = pure (Right True)

killBackground :: BackgroundRegistry -> Text -> Text -> IO (Either Text Bool)
killBackground registry threadId taskId =
  atomicModifyIORef' (registryProcesses registry) takeOwned >>= stopped
 where
  stopped Nothing = pure (Left (unknown taskId))
  stopped (Just task) = stopTask task <&> Right
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
    <&> (>>= owns)
 where
  owns task = bool Nothing (Just task) (backgroundThreadId task == threadId)

pruneCompleted :: BackgroundRegistry -> IO ()
pruneCompleted registry =
  readIORef (registryProcesses registry)
    >>= traverse completed . Map.toList
    >>= trimExpired registry
 where
  trimExpired registry' states =
    let done = sortOn (backgroundStarted . snd) (catMaybes states)
        excess = max 0 (length done - registryCompletedLimit registry')
        expired = Map.fromList [(taskId, ()) | (taskId, _) <- take excess done]
     in atomicModifyIORef'
          (registryProcesses registry')
          (\processes -> (Map.withoutKeys processes (Map.keysSet expired), ()))
  completed pair@(_, task) = tryReadMVar (backgroundExit task) <&> bool Nothing (Just pair) . isJust

unknown :: Text -> Text
unknown taskId = "unknown background task: " <> taskId
