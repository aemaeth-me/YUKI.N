module Yuki.N.ToolsTest
  ( workToolTests,
    sandboxEscape,
    writeEditRead,
    readKeepsMediumContent,
    paginatedRead,
    editFailures,
    staleEdit,
    listEntries,
    listSymlinks,
    pathCompletion,
    globSearch,
    grepSearch,
    grepLiteral,
    searchSandbox,
    shellCaptures,
    shellStops,
    shellTimeoutHint,
    shellArtifact,
    shellStreams,
    backgroundLifecycle,
    backgroundStdinFeed,
    backgroundKill,
    backgroundSpawnRace,
    backgroundThreadIsolation,
    backgroundRetention,
    backgroundShutdown,
    backgroundAcrossRuntimeFor,
    planTests,
    schemaSanity,
    planSet,
    planUpdate,
    planClear,
    planReplay,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (throwIO)
import Control.Monad (replicateM, (>=>))
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>))
import Data.IORef
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types
import Network.Wai (Application, pathInfo, requestHeaders, requestMethod)
import Network.Wai.Test
import System.Directory (createDirectoryIfMissing)
import System.Process (getProcessExitCode)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Artifact
import Yuki.N.Background
import Yuki.N.Journal
import Yuki.N.Model
import Yuki.N.Replay
import Yuki.N.Server
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig
import Yuki.N.Tools

callToolContext :: ToolContext -> [BackendTool] -> Text -> Value -> IO ToolOutcome
callToolContext context tools name arguments =
  maybe (assertFailure ("missing tool: " <> Text.unpack name)) pure (find (named . backendToolSpec) tools)
    >>= \backend -> runBackendTool backend context arguments
 where
  named = (== name) . toolName
callAs :: Text -> [BackendTool] -> Text -> Value -> IO ToolOutcome
callAs threadId =
  callToolContext (ToolContext "run" threadId "call" (const (pure ())) Nothing "")

workToolTests :: TestTree
workToolTests =
  testGroup
    "work tools"
    [ testCase "sandbox rejects dotdot and absolute escapes" sandboxEscape,
      testCase "write then edit then read with diff outcomes" writeEditRead,
      testCase "fs_read keeps medium files in one result" readKeepsMediumContent,
      testCase "fs_read pages a window, clamps and rejects out-of-bounds offsets" paginatedRead,
      testCase "fs_edit fails on missing and ambiguous old text" editFailures,
      testCase "fs_edit demands a fresh read and fs_write records the stamp" staleEdit,
      testCase "fs_list sorts, marks directories and caps depth at two" listEntries,
      testCase "fs_list and config tree render symlinks without following them" listSymlinks,
      testCase "local path completion stays inside cwd and omits symlinks" pathCompletion,
      testCase "fs_glob matches **, ?, caps at 200 and skips noise directories" globSearch,
      testCase "fs_grep hits literal text with line numbers and include filter" grepSearch,
      testCase "fs_grep treats regex metacharacters literally" grepLiteral,
      testCase "fs_glob and fs_grep reject sandbox escapes" searchSandbox,
      testCase "shell captures exit code and merged output" shellCaptures,
      testCase "shell stops at the timeout" shellStops,
      testCase "shell timeout hints at shell_bg" shellTimeoutHint,
      testCase "large shell output lands in an artifact with guidance" shellArtifact,
      testCase "shell streams stdout and stderr chunks while running" shellStreams,
      testCase "background task starts, runs, and is polled to completion" backgroundLifecycle,
      testCase "background stdin feeds cat and closes on eof" backgroundStdinFeed,
      testCase "shell_kill terminates the process group and reaps the task" backgroundKill,
      testCase "concurrent background spawns all register and reap" backgroundSpawnRace,
      testCase "background tasks are visible only to their owning thread" backgroundThreadIsolation,
      testCase "completed retention is bounded without evicting running tasks" backgroundRetention,
      testCase "thread archive and service shutdown reap their owned processes" backgroundShutdown,
      testCase "fresh runtimes manage one task across three later user turns" backgroundAcrossRuntimeFor
    ]

sandboxEscape :: Assertion
sandboxEscape = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    relative <- callTool tools "fs_read" (object ["path" .= ("../../../../etc/passwd" :: Text)])
    absolute <- callTool tools "fs_read" (object ["path" .= ("/etc/passwd" :: Text)])
    written <- callTool tools "fs_write" (object ["path" .= ("../escape.txt" :: Text), "content" .= ("x" :: Text)])
    toolOutcomeError relative @?= True
    toolOutcomeError absolute @?= True
    toolOutcomeError written @?= True
    toolOutcomeContent relative @?= "path escapes the work directory"
    toolOutcomeContent absolute @?= "path escapes the work directory"
    toolOutcomeContent written @?= "path escapes the work directory"

writeEditRead :: Assertion
writeEditRead = withWorkDir $ \dir -> do
  tools <- workTools Nothing dir
  written <- callTool tools "fs_write" (object ["path" .= ("sub/notes.txt" :: Text), "content" .= ("alpha\nbeta\n" :: Text)])
  edited <- callTool tools "fs_edit" (object ["path" .= ("sub/notes.txt" :: Text), "old" .= ("beta" :: Text), "new" .= ("gamma" :: Text)])
  readBack <- callTool tools "fs_read" (object ["path" .= ("sub/notes.txt" :: Text)])
  toolOutcomeError written @?= False
  toolOutcomeContent written
    @?= Text.unlines ["--- a/sub/notes.txt", "+++ b/sub/notes.txt", "@@ -1,0 +1,2 @@", "+alpha", "+beta"]
  toolOutcomeContent edited
    @?= Text.unlines ["--- a/sub/notes.txt", "+++ b/sub/notes.txt", "@@ -1,2 +1,2 @@", " alpha", "-beta", "+gamma"]
  toolOutcomeError readBack @?= False
  toolOutcomeContent readBack @?= "alpha\ngamma\n"

readKeepsMediumContent :: Assertion
readKeepsMediumContent = withWorkDir exercise
 where
  exercise dir = do
    store <- newMemoryArtifactStore
    tools <- workTools (Just store) dir
    let content = Text.replicate 1000 "x"
    TextIO.writeFile (dir ++ "/medium.txt") content
    outcome <- callTool tools "fs_read" (object ["path" .= ("medium.txt" :: Text)])
    toolOutcomeError outcome @?= False
    toolOutcomeContent outcome @?= content

paginatedRead :: Assertion
paginatedRead = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    TextIO.writeFile (dir ++ "/f.txt") "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"
    window <- callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "offset" .= (3 :: Int), "limit" .= (4 :: Int)])
    headOnly <- callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "limit" .= (2 :: Int)])
    tailOnly <- callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "offset" .= (8 :: Int)])
    clamped <- callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "offset" .= (0 :: Int), "limit" .= (2 :: Int)])
    outOfBounds <- callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "offset" .= (11 :: Int)])
    toolOutcomeError window @?= False
    toolOutcomeContent window @?= "l3\nl4\nl5\nl6\n(lines 3-6 of 10)"
    toolOutcomeContent headOnly @?= "l1\nl2\n(lines 1-2 of 10)"
    toolOutcomeContent tailOnly @?= "l8\nl9\nl10\n(lines 8-10 of 10)"
    toolOutcomeContent clamped @?= "l1\nl2\n(lines 1-2 of 10)"
    toolOutcomeError outOfBounds @?= True
    toolOutcomeContent outOfBounds @?= "offset 11 exceeds f.txt line count 10"

editFailures :: Assertion
editFailures = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    TextIO.writeFile (dir ++ "/dup.txt") "dup dup here"
    _ <- callTool tools "fs_read" (object ["path" .= ("dup.txt" :: Text)])
    missing <- callTool tools "fs_edit" (object ["path" .= ("dup.txt" :: Text), "old" .= ("absent" :: Text), "new" .= ("x" :: Text)])
    ambiguous <- callTool tools "fs_edit" (object ["path" .= ("dup.txt" :: Text), "old" .= ("dup" :: Text), "new" .= ("x" :: Text)])
    toolOutcomeError missing @?= True
    assertBool "missing explains" (Text.isInfixOf "old text not found in dup.txt" (toolOutcomeContent missing))
    toolOutcomeError ambiguous @?= True
    assertBool "ambiguous explains" (Text.isInfixOf "old text occurs 2 times in dup.txt" (toolOutcomeContent ambiguous))

staleEdit :: Assertion
staleEdit = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    TextIO.writeFile (dir ++ "/s.txt") "aaa\n"
    unread <- editAt tools "s.txt" "aaa" "bbb"
    _ <- readAt tools "s.txt"
    fresh <- editAt tools "s.txt" "aaa" "bbb"
    TextIO.writeFile (dir ++ "/s.txt") "cccc\n"
    stale <- editAt tools "s.txt" "bbb" "x"
    _ <- readAt tools "s.txt"
    reread <- editAt tools "s.txt" "cccc" "dddd"
    _ <- writeAt tools "w.txt" "fresh\n"
    afterWrite <- editAt tools "w.txt" "fresh" "done"
    finalContent <- TextIO.readFile (dir ++ "/s.txt")
    toolOutcomeError unread @?= True
    toolOutcomeContent unread @?= "read the file before editing"
    toolOutcomeError fresh @?= False
    toolOutcomeError stale @?= True
    toolOutcomeContent stale @?= "file changed since last read; re-read it"
    toolOutcomeError reread @?= False
    toolOutcomeError afterWrite @?= False
    finalContent @?= "dddd\n"
  readAt tools path = callTool tools "fs_read" (object ["path" .= (path :: Text)])
  writeAt tools path content = callTool tools "fs_write" (object ["path" .= (path :: Text), "content" .= (content :: Text)])
  editAt tools path old new = callTool tools "fs_edit" (object ["path" .= (path :: Text), "old" .= (old :: Text), "new" .= (new :: Text)])

listEntries :: Assertion
listEntries = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    createDirectoryIfMissing True (dir ++ "/src/deep")
    TextIO.writeFile (dir ++ "/b.txt") "b"
    TextIO.writeFile (dir ++ "/src/a.txt") "a"
    TextIO.writeFile (dir ++ "/src/deep/x.txt") "x"
    outcome <- callTool tools "fs_list" (object [])
    toolOutcomeError outcome @?= False
    toolOutcomeContent outcome @?= Text.intercalate "\n" ["b.txt", "src/", "  a.txt", "  deep/"]

listSymlinks :: Assertion
listSymlinks = withSandbox $ \root -> do
  tools <- workTools Nothing root
  listed <- callTool tools "fs_list" (object [])
  explicit <- callTool tools "fs_list" (object ["path" .= ("inner" :: Text)])
  tree <- listTree root 8
  let renderedTree = Text.intercalate "\n" tree
  toolOutcomeError listed @?= False
  assertBool "external directory symlink is a leaf" ("linkdir@" `Text.isInfixOf` toolOutcomeContent listed)
  assertBool "internal directory symlink is a leaf" ("inner@" `Text.isInfixOf` toolOutcomeContent listed)
  assertBool "cycle symlink is a leaf" ("up@" `Text.isInfixOf` toolOutcomeContent listed)
  assertBool "external content never appears" (not ("TOP-SECRET" `Text.isInfixOf` toolOutcomeContent listed))
  toolOutcomeError explicit @?= True
  toolOutcomeContent explicit @?= "refusing to list through a symbolic link"
  assertBool "config tree marks external symlink" ("linkdir@" `Text.isInfixOf` renderedTree)
  assertBool "config tree marks internal symlink" ("inner@" `Text.isInfixOf` renderedTree)
  assertBool "config tree does not expand the cycle" (length (filter (Text.isInfixOf "up@") tree) == 1)

pathCompletion :: Assertion
pathCompletion = withSandbox $ \root -> do
  top <- completePaths root ""
  nested <- completePaths root "sub/"
  escaped <- completePaths root "../"
  assertBool "offers real directories" ("sub/" `elem` top)
  assertBool "omits external symlinks" ("linkdir/" `notElem` top)
  assertBool "omits file symlinks" ("linkfile.txt" `notElem` top)
  nested @?= ["sub/ok.txt"]
  escaped @?= []

globSearch :: Assertion
globSearch = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    createDirectoryIfMissing True (dir ++ "/src/N")
    createDirectoryIfMissing True (dir ++ "/node_modules/pkg")
    createDirectoryIfMissing True (dir ++ "/.hidden")
    createDirectoryIfMissing True (dir ++ "/caps")
    TextIO.writeFile (dir ++ "/x.hs") "top"
    TextIO.writeFile (dir ++ "/src/N/x.hs") "nested"
    TextIO.writeFile (dir ++ "/node_modules/pkg/x.hs") "dep"
    TextIO.writeFile (dir ++ "/.hidden/x.hs") "hidden"
    traverse_ (\name -> TextIO.writeFile (dir ++ "/caps/" ++ name) "cap") capNames
    nested <- callTool tools "fs_glob" (object ["pattern" .= ("**/x.hs" :: Text)])
    single <- callTool tools "fs_glob" (object ["pattern" .= ("src/?/x.hs" :: Text)])
    capped <- callTool tools "fs_glob" (object ["pattern" .= ("caps/*.txt" :: Text)])
    toolOutcomeError nested @?= False
    toolOutcomeContent nested @?= "src/N/x.hs\nx.hs"
    toolOutcomeContent single @?= "src/N/x.hs"
    toolOutcomeContent capped @?= expectedCaps
  capNames = ["cap-" <> replicate (3 - length s) '0' <> s <> ".txt" | i <- [0 .. 204 :: Int], let s = show i]
  expectedCaps = Text.intercalate "\n" (fmap (Text.pack . ("caps/" ++)) (take 200 capNames)) <> "\n... 5 more"

grepSearch :: Assertion
grepSearch = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    TextIO.writeFile (dir ++ "/a.txt") "one\ntwo needle\nthree needle\n"
    TextIO.writeFile (dir ++ "/b.hs") "needle in hs\n"
    TextIO.writeFile (dir ++ "/b.txt") "needle in txt\n"
    plain <- callTool tools "fs_grep" (object ["pattern" .= ("needle" :: Text)])
    hsOnly <- callTool tools "fs_grep" (object ["pattern" .= ("needle" :: Text), "include" .= ("*.hs" :: Text)])
    toolOutcomeError plain @?= False
    toolOutcomeContent plain
      @?= Text.intercalate "\n" ["a.txt:2:two needle", "a.txt:3:three needle", "b.hs:1:needle in hs", "b.txt:1:needle in txt"]
    toolOutcomeContent hsOnly @?= "b.hs:1:needle in hs"

grepLiteral :: Assertion
grepLiteral = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    TextIO.writeFile (dir ++ "/c.txt") "axb\nliteral .* here\n"
    outcome <- callTool tools "fs_grep" (object ["pattern" .= (".*" :: Text)])
    toolOutcomeError outcome @?= False
    toolOutcomeContent outcome @?= "c.txt:2:literal .* here"

searchSandbox :: Assertion
searchSandbox = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    globbed <- callTool tools "fs_glob" (object ["pattern" .= ("*" :: Text), "path" .= ("../" :: Text)])
    grepped <- callTool tools "fs_grep" (object ["pattern" .= ("x" :: Text), "path" .= ("../" :: Text)])
    toolOutcomeError globbed @?= True
    toolOutcomeError grepped @?= True
    toolOutcomeContent globbed @?= "path escapes the work directory"
    toolOutcomeContent grepped @?= "path escapes the work directory"

shellCaptures :: Assertion
shellCaptures = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    outcome <- callTool tools "shell" (object ["command" .= ("echo out; echo err >&2; exit 3" :: Text)])
    toolOutcomeError outcome @?= False
    toolOutcomeContent outcome @?= "exit 3\nout\nerr\n"

shellStops :: Assertion
shellStops = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    outcome <- callTool tools "shell" (object ["command" .= ("echo before; sleep 30; echo after" :: Text), "timeoutSeconds" .= (1 :: Int)])
    assertBool "timeout reported" ("exit timeout" `Text.isPrefixOf` toolOutcomeContent outcome)
    assertBool "partial output kept" (Text.isInfixOf "before" (toolOutcomeContent outcome))
    assertBool "killed before completion" (not (Text.isInfixOf "after" (toolOutcomeContent outcome)))

shellTimeoutHint :: Assertion
shellTimeoutHint = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    outcome <- callTool tools "shell" (object ["command" .= ("printf before; sleep 30" :: Text), "timeoutSeconds" .= (1 :: Int)])
    toolOutcomeContent outcome
      @?= "exit timeout\nbefore\nhint: use shell_bg for long-running tasks, then shell_output to poll\n"

shellArtifact :: Assertion
shellArtifact = withWorkDir exercise
 where
  exercise dir = do
    store <- newMemoryArtifactStore
    tools <- workTools (Just store) dir
    outcome <- callTool tools "shell" (object ["command" .= bigCommand])
    metas <- artifactList store
    toolOutcomeError outcome @?= False
    assertBool "head kept" ("exit 0\nline-0" `Text.isPrefixOf` toolOutcomeContent outcome)
    assertBool "tail kept" (Text.isInfixOf "line-39" (toolOutcomeContent outcome))
    assertBool "guidance names the artifact" (Text.isInfixOf "[artifact art-" (toolOutcomeContent outcome))
    assertBool "guidance points at artifact_read" (Text.isInfixOf "artifact_read" (toolOutcomeContent outcome))
    fmap artifactMetaToolName metas @?= ["shell"]
  bigCommand =
    "i=0; while [ $i -lt 40 ]; do echo line-$i-xxxxxxxxxxxx; i=$((i+1)); done" :: Text

shellStreams :: Assertion
shellStreams = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    events <- newIORef []
    outcome <- callToolContext (streaming events) tools "shell" (object ["command" .= ("echo one; sleep 0.5; echo two; sleep 0.5; echo err >&2" :: Text)])
    raw <- readIORef events
    let emitted = reverse raw
        chunks = mapMaybe (parseMaybe parseChunk) [value | Custom "shell.output" value <- emitted]
        stdout = Text.concat [delta | ("call-1", "stdout", delta) <- chunks]
        stderr = Text.concat [delta | ("call-1", "stderr", delta) <- chunks]
    assertBool "streams at least two chunks" (length chunks >= 2)
    stdout @?= "one\ntwo\n"
    stderr @?= "err\n"
    toolOutcomeContent outcome @?= "exit 0\none\ntwo\nerr\n"
   where
    streaming events = ToolContext "run" "thread" "call-1" (\event -> modifyIORef' events (event :)) Nothing ""
  parseChunk :: Value -> Parser (Text, Text, Text)
  parseChunk =
    withObject "shell.output" $ \fields ->
      (,,) <$> fields .: "callId" <*> fields .: "stream" <*> fields .: "delta"

backgroundLifecycle :: Assertion
backgroundLifecycle = withWorkDir exercise
 where
  exercise dir = do
    registry <- newBackgroundRegistry
    let tools = backgroundTools registry dir
    started <- callTool tools "shell_bg" (object ["command" .= ("sleep 1; echo done" :: Text)])
    taskId <- taskIdOf started
    early <- callTool tools "shell_output" (object ["taskId" .= taskId])
    late <- callTool tools "shell_output" (object ["taskId" .= taskId, "waitSeconds" .= (5 :: Int)])
    (earlyRunning, _, _, _) <- pollOf early
    (running, exitCode, output, truncated) <- pollOf late
    toolOutcomeError started @?= False
    earlyRunning @?= True
    running @?= False
    exitCode @?= Just 0
    assertBool "buffered output kept" ("done" `Text.isInfixOf` output)
    truncated @?= False

backgroundStdinFeed :: Assertion
backgroundStdinFeed = withWorkDir exercise
 where
  exercise dir = do
    registry <- newBackgroundRegistry
    let tools = backgroundTools registry dir
    started <- callTool tools "shell_bg" (object ["command" .= ("cat" :: Text)])
    taskId <- taskIdOf started
    fed <- callTool tools "shell_stdin" (object ["taskId" .= taskId, "text" .= ("hello\n" :: Text)])
    closed <- callTool tools "shell_stdin" (object ["taskId" .= taskId, "text" .= ("" :: Text), "eof" .= True])
    late <- callTool tools "shell_stdin" (object ["taskId" .= taskId, "text" .= ("late\n" :: Text)])
    polled <- callTool tools "shell_output" (object ["taskId" .= taskId, "waitSeconds" .= (5 :: Int)])
    (running, exitCode, output, _) <- pollOf polled
    toolOutcomeError fed @?= False
    toolOutcomeError closed @?= False
    toolOutcomeError late @?= True
    running @?= False
    exitCode @?= Just 0
    output @?= "hello\n"

backgroundKill :: Assertion
backgroundKill = withWorkDir exercise
 where
  exercise dir = do
    registry <- newBackgroundRegistry
    let tools = backgroundTools registry dir
    started <- callTool tools "shell_bg" (object ["command" .= ("sleep 30" :: Text)])
    taskId <- taskIdOf started
    early <- callTool tools "shell_output" (object ["taskId" .= taskId])
    killed <- callTool tools "shell_kill" (object ["taskId" .= taskId])
    late <- callTool tools "shell_output" (object ["taskId" .= taskId])
    (running, _, _, _) <- pollOf early
    result <- outcomeValue killed
    running @?= True
    parseMaybe (withObject "kill" (.: "killed")) result @?= Just True
    toolOutcomeError late @?= True
    assertBool "reaped task is unknown" ("unknown background task" `Text.isInfixOf` toolOutcomeContent late)

backgroundSpawnRace :: Assertion
backgroundSpawnRace = withWorkDir exercise
 where
  exercise dir = do
    registry <- newBackgroundRegistry
    slots <- replicateM 8 newEmptyMVar
    let tools = backgroundTools registry dir
    traverse_ (forkIO . spawn tools) slots
    taskIds <- timeout 10000000 (traverse takeMVar slots) >>= maybe (assertFailure "concurrent spawns did not finish") pure
    killed <- traverse (kill tools) taskIds
    count <- backgroundTaskCount registry
    killed @?= replicate 8 True
    assertBool "every spawned task is reaped, none leaks" (count == 0)
  spawn tools slot =
    callTool tools "shell_bg" (object ["command" .= ("cat" :: Text)]) >>= taskIdOf >>= putMVar slot
  kill tools taskId =
    callTool tools "shell_kill" (object ["taskId" .= taskId])
      >>= fmap ((Just True ==) . parseMaybe (withObject "kill" (.: "killed"))) . outcomeValue

backgroundThreadIsolation :: Assertion
backgroundThreadIsolation = withWorkDir exercise
 where
  exercise dir = do
    registry <- newBackgroundRegistry
    let tools = backgroundTools registry dir
    started <- callAs "thread-a" tools "shell_bg" (object ["command" .= ("cat" :: Text)])
    taskId <- taskIdOf started
    alien <- callAs "thread-b" tools "shell_output" (object ["taskId" .= taskId])
    owned <- callAs "thread-a" tools "shell_output" (object ["taskId" .= taskId])
    killed <- callAs "thread-a" tools "shell_kill" (object ["taskId" .= taskId])
    toolOutcomeError alien @?= True
    assertBool "foreign thread learns no task details" ("unknown background task" `Text.isInfixOf` toolOutcomeContent alien)
    toolOutcomeError owned @?= False
    toolOutcomeError killed @?= False

backgroundRetention :: Assertion
backgroundRetention = withWorkDir exercise
 where
  exercise dir = do
    registry <- newBackgroundRegistryWithLimit 2
    let tools = backgroundTools registry dir
    running <- callTool tools "shell_bg" (object ["command" .= ("cat" :: Text)])
    runningId <- taskIdOf running
    completed <- traverse (complete tools) [1 .. 4 :: Int]
    bounded <- waitUntil ((<= 3) <$> backgroundTaskCount registry)
    live <- lookupBackground registry runningId
    oldest <- lookupBackground registry (fromMaybe (error "no completed tasks") (listToMaybe completed))
    newest <- lookupBackground registry (fromMaybe (error "no completed tasks") (listToMaybe (reverse completed)))
    killed <- callTool tools "shell_kill" (object ["taskId" .= runningId])
    assertBool "registry converges to running plus retention limit" bounded
    assertBool "running task is never pruned" (isJust live)
    assertBool "oldest completed task is pruned" (isNothing oldest)
    assertBool "newest completed task remains inspectable" (isJust newest)
    toolOutcomeError killed @?= False
  complete tools index =
    callTool tools "shell_bg" (object ["command" .= ("printf done-" <> Text.pack (show index) :: Text)]) >>= \started ->
      taskIdOf started >>= \taskId ->
        callTool tools "shell_output" (object ["taskId" .= taskId, "waitSeconds" .= (5 :: Int)]) $> taskId

backgroundShutdown :: Assertion
backgroundShutdown = withWorkDir exercise
 where
  exercise dir = do
    registry <- newBackgroundRegistry
    let tools = backgroundTools registry dir
    first <- callAs "thread-a" tools "shell_bg" (object ["command" .= ("cat" :: Text)])
    second <- callAs "thread-b" tools "shell_bg" (object ["command" .= ("cat" :: Text)])
    firstId <- taskIdOf first
    secondId <- taskIdOf second
    found <- (,) <$> lookupBackground registry firstId <*> lookupBackground registry secondId
    case found of
      (Just firstProc, Just secondProc) -> do
        shutdownBackgroundThread registry "thread-a"
        archived <- callAs "thread-a" tools "shell_output" (object ["taskId" .= firstId])
        surviving <- callAs "thread-b" tools "shell_output" (object ["taskId" .= secondId])
        shutdownBackground registry
        reaped <- waitUntil (bothReaped firstProc secondProc)
        remaining <- backgroundTaskCount registry
        toolOutcomeError archived @?= True
        toolOutcomeError surviving @?= False
        assertBool "both process handles are reaped" reaped
        remaining @?= 0
      _ -> assertFailure "spawned tasks missing from registry"
  bothReaped first second =
    ((&&) . isJust <$> getProcessExitCode (backgroundProcess first))
      <*> (isJust <$> getProcessExitCode (backgroundProcess second))

backgroundAcrossRuntimeFor :: Assertion
backgroundAcrossRuntimeFor = withWorkDir exercise
 where
  exercise dir = do
    manager <- newTlsManager
    registry <- newBackgroundRegistry
    task <- newIORef Nothing
    observed <- newIORef Map.empty
    resolved <- newIORef (0 :: Int)
    base <- testRuntime (backgroundRoundModel task observed) [] Sequential
    let runtimeFor _ =
          modifyIORef' resolved (+ 1)
            *> resolveRuntime
              manager
              testProvider
              Nothing
              base {runtimeBackground = registry}
              (emptyThreadConfig {configCwd = CwdPath dir})
              Map.empty
              Map.empty
        app = application Nothing Nothing Nothing Nothing Nothing Nothing runtimeFor
    responses <- traverse (runBackgroundRound app) (zip [1 ..] ["start", "output", "stdin", "kill"])
    results <- readIORef observed
    resolutions <- readIORef resolved
    remaining <- backgroundTaskCount registry
    assertBool "each run returns an SSE success" (all ((== status200) . simpleStatus) responses)
    resolutions @?= 4
    assertBool "a later run can poll" (resultField "output" "running" results == Just True)
    assertBool "a third run can write stdin" (resultField "stdin" "stdinOpen" results == Just True)
    assertBool "a fourth run terminates" (resultField "kill" "killed" results == Just True)
    remaining @?= 0

backgroundRoundModel :: IORef (Maybe Text) -> IORef (Map.Map Text Value) -> Model
backgroundRoundModel task observed =
  fakeModel $ \req emit ->
    case lastMessage req of
      Just (ChatToolResult _ content) ->
        remember (roundName req) content
          *> emit (ModelTextDelta "done")
          $> Stop
      _ -> dispatch (roundName req) emit
 where
  dispatch "start" emit =
    emit (ModelToolCallDelta 0 (Just "call-start") (Just "shell_bg") "{\"command\":\"cat\"}") $> ToolUse
  dispatch name emit =
    readIORef task >>= maybe (throwIO (ProviderFailure "task id not captured")) (call name emit)
  call :: Text -> (ModelEvent -> IO ()) -> Text -> IO FinishReason
  call "output" emit taskId =
    emit (ModelToolCallDelta 0 (Just "call-output") (Just "shell_output") (jsonArgs taskId [])) $> ToolUse
  call "stdin" emit taskId =
    emit (ModelToolCallDelta 0 (Just "call-stdin") (Just "shell_stdin") (jsonArgs taskId [("text", "hello\n")])) $> ToolUse
  call "kill" emit taskId =
    emit (ModelToolCallDelta 0 (Just "call-kill") (Just "shell_kill") (jsonArgs taskId [])) $> ToolUse
  call name _ _ = throwIO (ProviderFailure ("unknown background round: " <> name))
  remember name content =
    either (throwIO . ProviderFailure . Text.pack) pure (eitherDecodeStrict' (TextEncoding.encodeUtf8 content)) >>= \value ->
      modifyIORef' observed (Map.insert name value)
        *> case name of
          "start" ->
            maybe
              (throwIO (ProviderFailure "shell_bg omitted taskId"))
              (writeIORef task . Just)
              (parseMaybe (withObject "background" (.: "taskId")) value)
          _ -> pure ()
  jsonArgs :: Text -> [(Text, Text)] -> Text
  jsonArgs taskId fields =
    TextEncoding.decodeUtf8
      . LazyByteString.toStrict
      . encode
      $ object (["taskId" .= taskId] <> [Key.fromText key .= value | (key, value) <- fields])
roundName :: ModelRequest -> Text
roundName req = fromMaybe "" (listToMaybe [text | ChatUser text <- reverse (requestMessages req)])
runBackgroundRound :: Application -> (Int, Text) -> IO SResponse
runBackgroundRound app (index, action) =
  runSession (srequest waiRequest) app
 where
  waiRequest =
    SRequest
      { simpleRequest =
          defaultRequest
            { requestMethod = methodPost,
              pathInfo = ["agent"],
              requestHeaders = [(hContentType, "application/json")]
            },
        simpleRequestBody =
          encode
            ( (sampleInput [])
                { runThreadId = "daily-thread",
                  runId = "background-run-" <> Text.pack (show index),
                  runMessages = [User (UserMessage ("user-" <> Text.pack (show index)) (UserText action) Nothing)]
                }
            )
      }
resultField :: (FromJSON value) => Text -> Text -> Map.Map Text Value -> Maybe value
resultField roundKey field results =
  Map.lookup roundKey results >>= parseMaybe (withObject "background result" (.: Key.fromText field))
planTests :: TestTree
planTests =
  testGroup
    "plan tool"
    [ testCase "set replaces the plan, renders it and announces the full state" planSet,
      testCase "update flips items one by one and rejects unknown ids" planUpdate,
      testCase "clear empties the plan and renders the empty state" planClear,
      testCase "journaled plan events replay without divergence" planReplay,
      testCase "every tool spec is structurally valid JSON Schema" schemaSanity
    ]

schemaSanity :: Assertion
schemaSanity =
  withSandbox (workTools Nothing >=> traverse_ (check . toolParameters . backendToolSpec))
 where
  check parameters =
    assertBool ("invalid schema node in: " ++ show parameters) (valid parameters)
  valid (Object fields) =
    hasType && consistent "properties" "object" && consistent "items" "array" && recurse
   where
    hasType = case KeyMap.lookup "type" fields of
      Just (String _) -> True
      _ -> False
    consistent key want =
      maybe True (const (KeyMap.lookup "type" fields == Just (String want))) (KeyMap.lookup key fields)
    recurse =
      maybe True (all (valid . snd) . KeyMap.toList) (objectOf "properties")
        && maybe True valid (KeyMap.lookup "items" fields)
    objectOf key = case KeyMap.lookup key fields of
      Just (Object inner) -> Just inner
      _ -> Nothing
  valid _ = True

callPlan :: [BackendTool] -> IORef [Event] -> Value -> IO ToolOutcome
callPlan tools events =
  callToolContext (streaming events) tools "plan"
 where
  streaming ref = ToolContext "run" "thread" "call" (\event -> modifyIORef' ref (event :)) Nothing ""
planEvent :: [(Text, Text, Text)] -> Event
planEvent items = Custom "plan" (object ["items" .= fmap item items])
 where
  item (identifier, title, status) =
    object ["id" .= identifier, "title" .= title, "status" .= status]
planSetArgs :: Value
planSetArgs =
  object
    [ "action" .= ("set" :: Text),
      "items"
        .= [ object ["id" .= ("1" :: Text), "title" .= ("scan" :: Text)],
             object ["id" .= ("2" :: Text), "title" .= ("fix" :: Text)]
           ]
    ]
planUpdateArgs :: Text -> Text -> Value
planUpdateArgs identifier status =
  object ["action" .= ("update" :: Text), "id" .= identifier, "status" .= status]

planSet :: Assertion
planSet = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    events <- newIORef []
    outcome <- callPlan tools events planSetArgs
    raw <- readIORef events
    let emitted = reverse raw
    toolOutcomeError outcome @?= False
    toolOutcomeContent outcome @?= "1. [ ] scan\n2. [ ] fix"
    emitted @?= [planEvent [("1", "scan", "pending"), ("2", "fix", "pending")]]

planUpdate :: Assertion
planUpdate = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    events <- newIORef []
    _ <- callPlan tools events planSetArgs
    doing <- callPlan tools events (planUpdateArgs "1" "doing")
    done <- callPlan tools events (planUpdateArgs "1" "done")
    second <- callPlan tools events (planUpdateArgs "2" "doing")
    unknown <- callPlan tools events (planUpdateArgs "9" "done")
    raw <- readIORef events
    let emitted = reverse raw
    toolOutcomeContent doing @?= "1. [doing] scan\n2. [ ] fix"
    toolOutcomeContent done @?= "1. [done] scan\n2. [ ] fix"
    toolOutcomeContent second @?= "1. [done] scan\n2. [doing] fix"
    toolOutcomeError unknown @?= True
    toolOutcomeContent unknown @?= "unknown plan item: 9"
    length emitted @?= 4
    last emitted @?= planEvent [("1", "scan", "done"), ("2", "fix", "doing")]

planClear :: Assertion
planClear = withWorkDir exercise
 where
  exercise dir = do
    tools <- workTools Nothing dir
    events <- newIORef []
    _ <- callPlan tools events planSetArgs
    cleared <- callPlan tools events (object ["action" .= ("clear" :: Text)])
    again <- callPlan tools events (object ["action" .= ("clear" :: Text)])
    raw <- readIORef events
    let emitted = reverse raw
    toolOutcomeError cleared @?= False
    toolOutcomeContent cleared @?= "(empty plan)"
    toolOutcomeContent again @?= "(empty plan)"
    last emitted @?= planEvent []

planReplay :: Assertion
planReplay = withWorkDir exercise
 where
  exercise dir = do
    (journal, readEntries) <- newMemoryJournal
    turns <- newIORef (0 :: Int)
    tools <- workTools Nothing dir
    base <- testRuntime (planModel turns) tools Sequential
    events <- collectEvents base {runtimeJournal = Just journal} (sampleInput [])
    recorded <- readEntries
    report <- replayEntries defaultHooks Nothing recorded
    assertBool "journal records the plan event" (any journaled recorded)
    [content | ToolCallResult _ "call-plan" content <- events] @?= ["1. [ ] scan\n2. [ ] fix"]
    fmap reportDivergence report @?= Right Nothing
    fmap reportEvents report @?= Right (length (filter (not . isPlan) events))
  journaled (Entry _ _ _ (AgentEventEntry (Custom "plan" _))) = True
  journaled _ = False
  isPlan (Custom "plan" _) = True
  isPlan _ = False

planModel :: IORef Int -> Model
planModel turns =
  fakeModel $ \_ emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next)) >>= \case
      1 -> emit (ModelToolCallDelta 0 (Just "call-plan") (Just "plan") planArgs) $> ToolUse
      _ -> emit (ModelTextDelta "planned") $> Stop
 where
  planArgs = "{\"action\":\"set\",\"items\":[{\"id\":\"1\",\"title\":\"scan\"},{\"id\":\"2\",\"title\":\"fix\"}]}"
