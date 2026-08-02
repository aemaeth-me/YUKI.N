module Yuki.N.AdversarialTest
  ( adversarialTests,
    escapeFamily,
    rootReachable,
    symlinkEscape,
    symlinkInternal,
    walkerSymlinks,
    concurrentRuns,
    duplicateRunIdRace,
    killReaps,
    externalKill,
    deadEntryNeverJams,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (parseEither, parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>))
import Data.IORef
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Network.HTTP.Types
import Network.Wai.Test
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory)
import System.Process (getProcessExitCode)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Background
import Yuki.N.Model
import Yuki.N.Provider.OpenAI
import Yuki.N.Runs
import Yuki.N.Server
import Yuki.N.TestSupport
import Yuki.N.Tools
import Yuki.N.Transcript

pidOf :: ToolOutcome -> IO Int
pidOf outcome =
  outcomeValue outcome >>= either assertFailure pure . parseEither (withObject "background" (.: "pid"))

streamBegan :: IORef [Builder.Builder] -> IO Bool
streamBegan ref =
  any (ByteString.isInfixOf "RUN_STARTED" . LazyByteString.toStrict . Builder.toLazyByteString) <$> readIORef ref
adversarialTests :: TestTree
adversarialTests =
  testGroup
    "adversarial"
    [ testGroup
        "sandbox escapes"
        [ testCase "dotdot, nested-dotdot and absolute escapes are rejected by every fs tool" escapeFamily,
          testCase "the work directory itself stays reachable" rootReachable,
          testCase "symlinks to outside files, chains and directories are rejected" symlinkEscape,
          testCase "symlinks inside the sandbox resolve and work" symlinkInternal,
          testCase "glob and grep never cross symlinks and survive cycles" walkerSymlinks
        ],
      testGroup
        "concurrent runs on one thread"
        [ testCase "two runs coexist, streams stay separate and the transcript lands untorn" concurrentRuns,
          testCase "duplicate runId cancel race ends both streams then 404s" duplicateRunIdRace
        ],
      testGroup
        "background leaks"
        [ testCase "shell_kill reaps the process and drops the registry entry" killReaps,
          testCase "an externally killed task reports exit and leaves no zombie" externalKill,
          testCase "a dead registry entry never jams new background tasks" deadEntryNeverJams
        ],
      testGroup
        "SSE chunking"
        [ testCase "one-shot SSE specimen decode is chunking-robust" sseSpecimenRobust
        ]
    ]
assertEscape :: ToolOutcome -> Assertion
assertEscape outcome =
  sequence_
    [ toolOutcomeError outcome @?= True,
      toolOutcomeContent outcome @?= "path escapes the work directory"
    ]

escapeFamily :: Assertion
escapeFamily = withSandbox exercise
 where
  exercise root = do
    tools <- workTools Nothing root
    traverse_ (fmap assertEscape . readAt tools) fileEscapes
    traverse_ (fmap assertEscape . writeAt tools) fileEscapes
    traverse_ (fmap assertEscape . editAt tools) fileEscapes
    traverse_ (fmap assertEscape . globAt tools) dirEscapes
    traverse_ (fmap assertEscape . grepAt tools) dirEscapes
   where
    absolute = Text.pack (takeDirectory root ++ "/outside")
    fileEscapes =
      [ "../outside/secret.txt",
        "sub/../../outside/secret.txt",
        "ghost/../../outside/secret.txt",
        absolute <> "/secret.txt"
      ]
    dirEscapes = ["../outside", "ghost/../../outside", absolute]
    readAt tools path = callTool tools "fs_read" (object ["path" .= path])
    writeAt tools path = callTool tools "fs_write" (object ["path" .= path, "content" .= ("x" :: Text)])
    editAt tools path = callTool tools "fs_edit" (object ["path" .= path, "old" .= ("o" :: Text), "new" .= ("n" :: Text)])
    globAt tools path = callTool tools "fs_glob" (object ["pattern" .= ("*" :: Text), "path" .= path])
    grepAt tools path = callTool tools "fs_grep" (object ["pattern" .= ("x" :: Text), "path" .= path])

rootReachable :: Assertion
rootReachable = withSandbox exercise
 where
  exercise root = do
    tools <- workTools Nothing root
    readRoot <- callTool tools "fs_read" (object ["path" .= ("." :: Text)])
    listRoot <- callTool tools "fs_list" (object ["path" .= ("." :: Text)])
    globRoot <- callTool tools "fs_glob" (object ["pattern" .= ("**/*.txt" :: Text), "path" .= ("." :: Text)])
    grepRoot <- callTool tools "fs_grep" (object ["pattern" .= ("fine" :: Text), "path" .= ("." :: Text)])
    toolOutcomeError readRoot @?= True
    assertBool "reading a directory is not an escape" (toolOutcomeContent readRoot /= "path escapes the work directory")
    toolOutcomeError listRoot @?= False
    assertBool "lists the sandbox" (Text.isInfixOf "sub/" (toolOutcomeContent listRoot))
    toolOutcomeError globRoot @?= False
    toolOutcomeContent globRoot @?= "sub/ok.txt"
    toolOutcomeError grepRoot @?= False
    toolOutcomeContent grepRoot @?= "sub/ok.txt:1:fine"

symlinkEscape :: Assertion
symlinkEscape = withSandbox exercise
 where
  exercise root = do
    tools <- workTools Nothing root
    traverse_ (fmap assertEscape . readAt tools) ["linkfile.txt", "chain.txt", "linkdir/secret.txt"]
    traverse_ (fmap assertEscape . writeAt tools) ["linkfile.txt", "linkdir/evil.txt"]
    traverse_ (fmap assertEscape . editAt tools) ["linkfile.txt", "chain.txt"]
    secret <- TextIO.readFile (outside "secret.txt")
    secret @?= "TOP-SECRET\n"
    evilExists <- doesFileExist (outside "evil.txt")
    assertBool "nothing is written outside" (not evilExists)
   where
    outside name = takeDirectory root ++ "/outside/" ++ name
    readAt tools path = callTool tools "fs_read" (object ["path" .= (path :: Text)])
    writeAt tools path = callTool tools "fs_write" (object ["path" .= (path :: Text), "content" .= ("x" :: Text)])
    editAt tools path = callTool tools "fs_edit" (object ["path" .= (path :: Text), "old" .= ("o" :: Text), "new" .= ("n" :: Text)])

symlinkInternal :: Assertion
symlinkInternal = withSandbox exercise
 where
  exercise root = do
    tools <- workTools Nothing root
    readInner <- readAt tools "inner/ok.txt"
    writeInner <- writeAt tools "inner/new.txt"
    edited <- editInner tools
    afterWrite <- TextIO.readFile (root ++ "/sub/ok.txt")
    landed <- doesFileExist (root ++ "/sub/new.txt")
    toolOutcomeError readInner @?= False
    toolOutcomeContent readInner @?= "fine\n"
    toolOutcomeError writeInner @?= False
    landed @?= True
    toolOutcomeError edited @?= False
    afterWrite @?= "great\n"
   where
    readAt tools path = callTool tools "fs_read" (object ["path" .= (path :: Text)])
    writeAt tools path = callTool tools "fs_write" (object ["path" .= (path :: Text), "content" .= ("brand new\n" :: Text)])
    editInner tools = callTool tools "fs_edit" (object ["path" .= ("inner/ok.txt" :: Text), "old" .= ("fine" :: Text), "new" .= ("great" :: Text)])

walkerSymlinks :: Assertion
walkerSymlinks = withSandbox exercise
 where
  exercise root =
    workTools Nothing root >>= \tools ->
      timeout 5000000 (probe tools) >>= maybe (assertFailure "the walker hung on a symlink cycle") verify
   where
    probe tools =
      (,,)
        <$> callTool tools "fs_glob" (object ["pattern" .= ("**/*.txt" :: Text)])
        <*> callTool tools "fs_grep" (object ["pattern" .= ("TOP-SECRET" :: Text)])
        <*> callTool tools "fs_grep" (object ["pattern" .= ("fine" :: Text)])
    verify (names, leak, hits) =
      sequence_
        [ toolOutcomeContent names @?= "sub/ok.txt",
          toolOutcomeContent leak @?= "",
          toolOutcomeContent hits @?= "sub/ok.txt:1:fine"
        ]

gatedModel :: MVar () -> Model
gatedModel release =
  fakeModel $ \_ emit -> readMVar release *> emit (ModelTextDelta "ok") $> Stop

concurrentRuns :: Assertion
concurrentRuns = withWorkDir $ \dir -> do
  store <- newTranscriptStore dir
  runs <- newRunRegistry
  release <- newEmptyMVar
  histories <- newIORef []
  chunksA <- newIORef []
  chunksB <- newIORef []
  doneA <- newEmptyMVar
  doneB <- newEmptyMVar
  base <- testRuntime (gatedModel release) [] Parallel
  let runtime = base {runtimeRuns = Just runs, runtimeHooks = transcriptHooks store <> afterSpy histories}
      app = application Nothing Nothing Nothing (Just runs) Nothing (const (pure runtime))
  _ <- forkIO (streamInput app inputA chunksA doneA)
  _ <- forkIO (streamInput app inputB chunksB doneB)
  bothStarted <- waitUntil ((&&) <$> streamBegan chunksA <*> streamBegan chunksB)
  unless bothStarted (assertFailure "both runs never started")
  steered <- steerRun runs "run-a" (ChatUser "probe")
  steered @?= True
  cancelled <- cancelRun runs "run-a"
  cancelled @?= True
  _ <- timeout 5000000 (takeMVar doneA) >>= maybe (assertFailure "cancelled run did not finish") pure
  putMVar release ()
  _ <- timeout 5000000 (takeMVar doneB) >>= maybe (assertFailure "surviving run did not finish") pure
  lateCancel <- runSession (srequest (cancelRequest "run-b")) app
  eventsA <- decodeChunks chunksA
  eventsB <- decodeChunks chunksB
  saved <- transcriptLoad store "thread"
  captured <- readIORef histories
  simpleStatus lateCancel @?= status404
  length [() | Custom "run.cancelled" _ <- eventsA] @?= 1
  [() | Custom "run.cancelled" _ <- eventsB] @?= []
  [run | RunStarted _ run _ <- eventsA] @?= ["run-a"]
  [run | RunStarted _ run _ <- eventsB] @?= ["run-b"]
  [run | RunFinished _ run _ <- eventsA] @?= ["run-a"]
  [run | RunFinished _ run _ <- eventsB] @?= ["run-b"]
  [delta | TextMessageContent _ delta <- eventsB] @?= ["ok"]
  eventType (last eventsA) @?= "RUN_FINISHED"
  eventType (last eventsB) @?= "RUN_FINISHED"
  length captured @?= 2
  assertBool "transcript is one whole history, not torn" (saved `elem` fmap Just captured)
 where
  inputA = (sampleInput []) {runId = "run-a", runMessages = [User (UserMessage "user-a" (UserText "hello-a") Nothing)]}
  inputB = (sampleInput []) {runId = "run-b", runMessages = [User (UserMessage "user-b" (UserText "hello-b") Nothing)]}

duplicateRunIdRace :: Assertion
duplicateRunIdRace = do
  runs <- newRunRegistry
  gate <- newEmptyMVar
  chunksA <- newIORef []
  chunksB <- newIORef []
  doneA <- newEmptyMVar
  doneB <- newEmptyMVar
  base <- testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel
  let runtime = base {runtimeRuns = Just runs}
      app = application Nothing Nothing Nothing (Just runs) Nothing (const (pure runtime))
  _ <- forkIO (streamInput app same chunksA doneA)
  firstStarted <- waitUntil (streamBegan chunksA)
  unless firstStarted (assertFailure "first run never started")
  _ <- forkIO (streamInput app same chunksB doneB)
  duplicateStarted <- waitUntil (streamBegan chunksB)
  unless duplicateStarted (assertFailure "duplicate run never started")
  cancelled <- cancelRun runs "run"
  cancelled @?= True
  _ <- timeout 5000000 (takeMVar doneB) >>= maybe (assertFailure "cancelled duplicate did not finish") pure
  putMVar gate ()
  _ <- timeout 5000000 (takeMVar doneA) >>= maybe (assertFailure "first run did not finish") pure
  lateCancel <- runSession (srequest (cancelRequest "run")) app
  eventsA <- decodeChunks chunksA
  eventsB <- decodeChunks chunksB
  simpleStatus lateCancel @?= status404
  [() | Custom "run.cancelled" _ <- eventsA] @?= []
  length [() | Custom "run.cancelled" _ <- eventsB] @?= 1
  eventType (last eventsA) @?= "RUN_FINISHED"
  eventType (last eventsB) @?= "RUN_FINISHED"
 where
  same = sampleInput []

killReaps :: Assertion
killReaps = withWorkDir exercise
 where
  exercise dir = do
    registry <- newBackgroundRegistry
    let tools = backgroundTools registry dir
    started <- callTool tools "shell_bg" (object ["command" .= ("sleep 500" :: Text)])
    taskId <- taskIdOf started
    entry <- lookupBackground registry taskId
    case entry of
      Nothing -> assertFailure "task missing from the registry"
      Just task -> do
        killed <- callTool tools "shell_kill" (object ["taskId" .= taskId])
        result <- outcomeValue killed
        reaped <- waitUntil (isJust <$> getProcessExitCode (backgroundProcess task))
        registered <- lookupBackground registry taskId
        parseMaybe (withObject "kill" (.: "killed")) result @?= Just True
        assertBool "the process is reaped, no zombie" reaped
        assertBool "the registry drops the task" (isNothing registered)

externalKill :: Assertion
externalKill = withWorkDir exercise
 where
  exercise dir = do
    registry <- newBackgroundRegistry
    let tools = backgroundTools registry dir
    started <- callTool tools "shell_bg" (object ["command" .= ("sleep 500" :: Text)])
    (taskId, pid) <- (,) <$> taskIdOf started <*> pidOf started
    entry <- lookupBackground registry taskId
    case entry of
      Nothing -> assertFailure "task missing from the registry"
      Just task -> do
        shellTools <- workTools Nothing dir
        sigkill <- callTool shellTools "shell" (object ["command" .= ("kill -9 " <> Text.pack (show pid) :: Text)])
        polled <- callTool tools "shell_output" (object ["taskId" .= taskId, "waitSeconds" .= (5 :: Int)])
        (running, exitCode, _, _) <- pollOf polled
        reaped <- waitUntil (isJust <$> getProcessExitCode (backgroundProcess task))
        registered <- lookupBackground registry taskId
        cleanup <- callTool tools "shell_kill" (object ["taskId" .= taskId])
        result <- outcomeValue cleanup
        assertBool "sigkill lands" (Text.isPrefixOf "exit 0" (toolOutcomeContent sigkill))
        running @?= False
        assertBool "the exit is reported, never a hang" (isJust exitCode)
        assertBool "the watcher reaps the corpse" reaped
        assertBool "a dead task lingers until shell_kill reaps it" (isJust registered)
        parseMaybe (withObject "kill" (.: "killed")) result @?= Just True

deadEntryNeverJams :: Assertion
deadEntryNeverJams = withWorkDir exercise
 where
  exercise dir = do
    registry <- newBackgroundRegistry
    exerciseWith registry (backgroundTools registry dir)
  exerciseWith _registry tools = do
    first <- callTool tools "shell_bg" (object ["command" .= ("true" :: Text)])
    firstId <- taskIdOf first
    polledFirst <- callTool tools "shell_output" (object ["taskId" .= firstId, "waitSeconds" .= (5 :: Int)])
    second <- callTool tools "shell_bg" (object ["command" .= ("echo second" :: Text)])
    secondId <- taskIdOf second
    polledSecond <- callTool tools "shell_output" (object ["taskId" .= secondId, "waitSeconds" .= (5 :: Int)])
    (_, firstExit, _, _) <- pollOf polledFirst
    (running, exitCode, output, _) <- pollOf polledSecond
    (firstKilled, secondKilled) <- (,) <$> reap tools firstId <*> reap tools secondId
    assertBool "the first task died on its own" (isJust firstExit)
    assertBool "task ids are distinct" (firstId /= secondId)
    running @?= False
    exitCode @?= Just 0
    output @?= "second\n"
    firstKilled @?= Just True
    secondKilled @?= Just True
  reap tools taskId =
    callTool tools "shell_kill" (object ["taskId" .= taskId])
      >>= fmap (parseMaybe (withObject "kill" (.: "killed"))) . outcomeValue

sseSpecimen :: ByteString
sseSpecimen =
  ByteString.concat
    [ ": comment line\r\n",
      "data: {\"a\":1}\r\n",
      "\r\n",
      "data: one\n",
      "data: two\n",
      "\n",
      ": mid comment\n",
      "event: ping\n",
      "data: [DONE]\n",
      "\n",
      "\n",
      "data: tail"
    ]
sseExpected :: [ByteString]
sseExpected = ["{\"a\":1}", "one\ntwo", "[DONE]", "tail"]
sseCollect :: [ByteString] -> [ByteString]
sseCollect chunks = payloads <> trailing
 where
  (decoder, payloads) = foldl feed (emptySseDecoder, []) chunks
  feed (current, acc) chunk = (next, acc <> emitted)
   where
    (next, emitted) = feedSse current chunk
  (_, trailing) = finishSse decoder

sseSpecimenRobust :: Assertion
sseSpecimenRobust =
  sequence_
    [ sseCollect [sseSpecimen] @?= sseExpected,
      sseCollect (replicate 5 "" <> [sseSpecimen]) @?= sseExpected,
      sseCollect ["data: tail"] @?= ["tail"],
      sseCollect ["data: cr-tail\r"] @?= ["cr-tail"]
    ]
    *> traverse_
      ( \point ->
          sseCollect [ByteString.take point sseSpecimen, ByteString.drop point sseSpecimen] @?= sseExpected
      )
      [0 .. ByteString.length sseSpecimen]
