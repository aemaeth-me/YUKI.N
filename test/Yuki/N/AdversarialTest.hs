-- | 对抗与并发压力测试
--
-- 覆盖：沙箱逃逸族、符号链接、遍历器环、并发运行隔离、重复 runId 竞态、后台泄漏与 SSE 任意切分解码。
-- 边界：覆盖跨模块的对抗契约；SSE 切分属 provider 解码器的稳健性。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
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
    binarySplits,
    randomSplits,
    emptyChunks,
  )
where

import Control.Applicative ()
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception ()
import Control.Monad ()
import Data.Aeson
import Data.Aeson.Types (parseEither, parseMaybe)
import Data.Bool (bool)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>))
import Data.IORef
import Data.List (nub, sort, unfoldr)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Network.HTTP.Client.TLS ()
import Network.HTTP.Types
import Network.Wai ()
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
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
import Yuki.N.ThreadConfig ()
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
        [ testCase "every binary split reproduces the one-shot decode" binarySplits,
          testCase "200 pseudo-random n-ary splits reproduce the one-shot decode" randomSplits,
          testCase "empty chunks and an unterminated tail" emptyChunks
        ]
    ]
assertEscape :: ToolOutcome -> Assertion
assertEscape outcome =
  sequence_
    [ toolOutcomeError outcome @?= True,
      toolOutcomeContent outcome @?= "path escapes the work directory"
    ]

-- | 规格：dotdot/嵌套 dotdot/绝对路径逃逸被每个 fs 工具一致拒绝。
-- 背景：多个逃逸变体必须被所有入口一致拦截；单入口漏检就是可利用的沙箱洞。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
escapeFamily :: Assertion
escapeFamily = withSandbox exercise
 where
  exercise root =
    workTools Nothing root >>= \tools ->
      traverse_ (fmap assertEscape . readAt tools) fileEscapes
        *> traverse_ (fmap assertEscape . writeAt tools) fileEscapes
        *> traverse_ (fmap assertEscape . editAt tools) fileEscapes
        *> traverse_ (fmap assertEscape . globAt tools) dirEscapes
        *> traverse_ (fmap assertEscape . grepAt tools) dirEscapes
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

-- | 规格：工作目录本身可读、可列、可 glob、可 grep，读目录报非逃逸错误。
-- 背景：安全不能以功能瘫痪为代价；沙箱内操作必须保持可用。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
rootReachable :: Assertion
rootReachable = withSandbox exercise
 where
  exercise root =
    workTools Nothing root >>= \tools ->
      callTool tools "fs_read" (object ["path" .= ("." :: Text)]) >>= \readRoot ->
        callTool tools "fs_list" (object ["path" .= ("." :: Text)]) >>= \listRoot ->
          callTool tools "fs_glob" (object ["pattern" .= ("**/*.txt" :: Text), "path" .= ("." :: Text)]) >>= \globRoot ->
            callTool tools "fs_grep" (object ["pattern" .= ("fine" :: Text), "path" .= ("." :: Text)]) >>= \grepRoot ->
              sequence_
                [ toolOutcomeError readRoot @?= True,
                  assertBool "reading a directory is not an escape" (toolOutcomeContent readRoot /= "path escapes the work directory"),
                  toolOutcomeError listRoot @?= False,
                  assertBool "lists the sandbox" (Text.isInfixOf "sub/" (toolOutcomeContent listRoot)),
                  toolOutcomeError globRoot @?= False,
                  toolOutcomeContent globRoot @?= "sub/ok.txt",
                  toolOutcomeError grepRoot @?= False,
                  toolOutcomeContent grepRoot @?= "sub/ok.txt:1:fine"
                ]

-- | 规格：指向外部文件/链式/目录的符号链接在读写编辑下全部被拒，外部不被写。
-- 背景：符号链接是经典逃逸向量；链式链接与目录链接都必须被拦截。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
symlinkEscape :: Assertion
symlinkEscape = withSandbox exercise
 where
  exercise root =
    workTools Nothing root >>= \tools ->
      traverse_ (fmap assertEscape . readAt tools) ["linkfile.txt", "chain.txt", "linkdir/secret.txt"]
        *> traverse_ (fmap assertEscape . writeAt tools) ["linkfile.txt", "linkdir/evil.txt"]
        *> traverse_ (fmap assertEscape . editAt tools) ["linkfile.txt", "chain.txt"]
        *> (TextIO.readFile (outside "secret.txt") >>= (@?= "TOP-SECRET\n"))
        *> (doesFileExist (outside "evil.txt") >>= assertBool "nothing is written outside" . not)
   where
    outside name = takeDirectory root ++ "/outside/" ++ name
    readAt tools path = callTool tools "fs_read" (object ["path" .= (path :: Text)])
    writeAt tools path = callTool tools "fs_write" (object ["path" .= (path :: Text), "content" .= ("x" :: Text)])
    editAt tools path = callTool tools "fs_edit" (object ["path" .= (path :: Text), "old" .= ("o" :: Text), "new" .= ("n" :: Text)])

-- | 规格：沙箱内符号链接解析并正常工作。
-- 背景：内部链接是合法用法；一律拒绝会破坏常见项目布局。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
symlinkInternal :: Assertion
symlinkInternal = withSandbox exercise
 where
  exercise root =
    workTools Nothing root >>= \tools ->
      readAt tools "inner/ok.txt" >>= \readInner ->
        writeAt tools "inner/new.txt" >>= \writeInner ->
          editInner tools >>= \edited ->
            (,) <$> TextIO.readFile (root ++ "/sub/ok.txt") <*> doesFileExist (root ++ "/sub/new.txt") >>= \(afterWrite, landed) ->
              sequence_
                [ toolOutcomeError readInner @?= False,
                  toolOutcomeContent readInner @?= "fine\n",
                  toolOutcomeError writeInner @?= False,
                  landed @?= True,
                  toolOutcomeError edited @?= False,
                  afterWrite @?= "great\n"
                ]
   where
    readAt tools path = callTool tools "fs_read" (object ["path" .= (path :: Text)])
    writeAt tools path = callTool tools "fs_write" (object ["path" .= (path :: Text), "content" .= ("brand new\n" :: Text)])
    editInner tools = callTool tools "fs_edit" (object ["path" .= ("inner/ok.txt" :: Text), "old" .= ("fine" :: Text), "new" .= ("great" :: Text)])

-- | 规格：glob/grep 遍历不跨符号链接、不因环挂起、不泄漏外部内容。
-- 背景：遍历器面对环与外部链接必须终止且不泄漏；否则会挂死或泄密。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
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

-- | 规格：同一线程两个并发运行流互不串扰，取消只作用于目标运行，transcript 完整不撕裂。
-- 背景：并发隔离是服务正确性底线；事件串扰会让前端显示对方运行的数据。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
concurrentRuns :: Assertion
concurrentRuns =
  withWorkDir $ \dir ->
    newTranscriptStore dir >>= \store ->
      newRunRegistry >>= \runs ->
        newEmptyMVar >>= \release ->
          newIORef [] >>= \histories ->
            newIORef [] >>= \chunksA ->
              newIORef [] >>= \chunksB ->
                newEmptyMVar >>= \doneA ->
                  newEmptyMVar >>= \doneB ->
                    testRuntime (gatedModel release) [] Parallel >>= \base ->
                      let runtime = base {runtimeRuns = Just runs, runtimeHooks = transcriptHooks store <> afterSpy histories}
                          app = application Nothing Nothing Nothing (Just runs) (const (pure runtime))
                       in forkIO (streamInput app inputA chunksA doneA)
                            *> forkIO (streamInput app inputB chunksB doneB)
                            *> (waitUntil ((&&) <$> streamBegan chunksA <*> streamBegan chunksB) >>= bool (assertFailure "both runs never started") (pure ()))
                            *> (steerRun runs "run-a" (ChatUser "probe") >>= (@?= True))
                            *> (cancelRun runs "run-a" >>= (@?= True))
                            *> (timeout 5000000 (takeMVar doneA) >>= maybe (assertFailure "cancelled run did not finish") pure)
                            *> putMVar release ()
                            *> (timeout 5000000 (takeMVar doneB) >>= maybe (assertFailure "surviving run did not finish") pure)
                            *> runSession (srequest (cancelRequest "run-b")) app
                            >>= \lateCancel ->
                              decodeChunks chunksA >>= \eventsA ->
                                decodeChunks chunksB >>= \eventsB ->
                                  transcriptLoad store "thread" >>= \saved ->
                                    reverse <$> readIORef histories >>= \captured ->
                                      sequence_
                                        [ simpleStatus lateCancel @?= status404,
                                          length [() | Custom "run.cancelled" _ <- eventsA] @?= 1,
                                          [() | Custom "run.cancelled" _ <- eventsB] @?= [],
                                          [run | RunStarted _ run _ <- eventsA] @?= ["run-a"],
                                          [run | RunStarted _ run _ <- eventsB] @?= ["run-b"],
                                          [run | RunFinished _ run _ <- eventsA] @?= ["run-a"],
                                          [run | RunFinished _ run _ <- eventsB] @?= ["run-b"],
                                          [delta | TextMessageContent _ delta <- eventsB] @?= ["ok"],
                                          eventType (last eventsA) @?= "RUN_FINISHED",
                                          eventType (last eventsB) @?= "RUN_FINISHED",
                                          length captured @?= 2,
                                          assertBool "transcript is one whole history, not torn" (saved `elem` fmap Just captured)
                                        ]
 where
  inputA = (sampleInput []) {runId = "run-a", runMessages = [User (UserMessage "user-a" (UserText "hello-a") Nothing)]}
  inputB = (sampleInput []) {runId = "run-b", runMessages = [User (UserMessage "user-b" (UserText "hello-b") Nothing)]}

-- | 规格：重复 runId 取消竞态下两流都正常结束，后注册者收到 run.cancelled。
-- 背景：重复 ID 竞态是取消实现的雷区；处理错误会让取消指向错误流。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
duplicateRunIdRace :: Assertion
duplicateRunIdRace =
  newRunRegistry >>= \runs ->
    newEmptyMVar >>= \gate ->
      newIORef [] >>= \chunksA ->
        newIORef [] >>= \chunksB ->
          newEmptyMVar >>= \doneA ->
            newEmptyMVar >>= \doneB ->
              testRuntime (fakeModel (\_ _ -> takeMVar gate $> Stop)) [] Parallel >>= \base ->
                let runtime = base {runtimeRuns = Just runs}
                    app = application Nothing Nothing Nothing (Just runs) (const (pure runtime))
                 in forkIO (streamInput app same chunksA doneA)
                      *> (waitUntil (streamBegan chunksA) >>= bool (assertFailure "first run never started") (pure ()))
                      *> forkIO (streamInput app same chunksB doneB)
                      *> (waitUntil (streamBegan chunksB) >>= bool (assertFailure "duplicate run never started") (pure ()))
                      *> (cancelRun runs "run" >>= (@?= True))
                      *> (timeout 5000000 (takeMVar doneB) >>= maybe (assertFailure "cancelled duplicate did not finish") pure)
                      *> putMVar gate ()
                      *> (timeout 5000000 (takeMVar doneA) >>= maybe (assertFailure "first run did not finish") pure)
                      *> runSession (srequest (cancelRequest "run")) app
                      >>= \lateCancel ->
                        decodeChunks chunksA >>= \eventsA ->
                          decodeChunks chunksB >>= \eventsB ->
                            sequence_
                              [ simpleStatus lateCancel @?= status404,
                                [() | Custom "run.cancelled" _ <- eventsA] @?= [],
                                length [() | Custom "run.cancelled" _ <- eventsB] @?= 1,
                                eventType (last eventsA) @?= "RUN_FINISHED",
                                eventType (last eventsB) @?= "RUN_FINISHED"
                              ]
 where
  same = sampleInput []

-- | 规格：shell_kill 回收进程（无僵尸）并从注册表移除。
-- 背景：进程回收是资源管理底线；僵尸累积会耗尽系统句柄。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
killReaps :: Assertion
killReaps = withWorkDir exercise
 where
  exercise dir =
    newBackgroundRegistry >>= \registry ->
      let tools = backgroundTools registry dir
       in callTool tools "shell_bg" (object ["command" .= ("sleep 500" :: Text)]) >>= \started ->
            taskIdOf started >>= \taskId ->
              lookupBackground registry taskId >>= \found ->
                case found of
                  Nothing -> assertFailure "task missing from the registry"
                  Just task ->
                    callTool tools "shell_kill" (object ["taskId" .= taskId]) >>= \killed ->
                      outcomeValue killed >>= \result ->
                        waitUntil (isJust <$> getProcessExitCode (backgroundProcess task)) >>= \reaped ->
                          isJust <$> lookupBackground registry taskId >>= \registered ->
                            sequence_
                              [ parseMaybe (withObject "kill" (.: "killed")) result @?= Just True,
                                assertBool "the process is reaped, no zombie" reaped,
                                assertBool "the registry drops the task" (not registered)
                              ]

-- | 规格：外部 kill 的任务被 watcher 回收，轮询报告退出且不挂起，条目保留至 shell_kill。
-- 背景：外部死亡是常态；watcher 必须回收而不挂起，条目保留便于事后查证。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
externalKill :: Assertion
externalKill = withWorkDir exercise
 where
  exercise dir =
    newBackgroundRegistry >>= \registry ->
      let tools = backgroundTools registry dir
       in callTool tools "shell_bg" (object ["command" .= ("sleep 500" :: Text)]) >>= \started ->
            (,) <$> taskIdOf started <*> pidOf started >>= \(taskId, pid) ->
              lookupBackground registry taskId >>= \found ->
                case found of
                  Nothing -> assertFailure "task missing from the registry"
                  Just task ->
                    workTools Nothing dir >>= \shellTools ->
                      callTool shellTools "shell" (object ["command" .= ("kill -9 " <> Text.pack (show pid) :: Text)]) >>= \sigkill ->
                        callTool tools "shell_output" (object ["taskId" .= taskId, "waitSeconds" .= (5 :: Int)]) >>= \polled ->
                          pollOf polled >>= \(running, exitCode, _, _) ->
                            waitUntil (isJust <$> getProcessExitCode (backgroundProcess task)) >>= \reaped ->
                              isJust <$> lookupBackground registry taskId >>= \registered ->
                                callTool tools "shell_kill" (object ["taskId" .= taskId]) >>= \cleanup ->
                                  outcomeValue cleanup >>= \result ->
                                    sequence_
                                      [ assertBool "sigkill lands" (Text.isPrefixOf "exit 0" (toolOutcomeContent sigkill)),
                                        running @?= False,
                                        assertBool "the exit is reported, never a hang" (isJust exitCode),
                                        assertBool "the watcher reaps the corpse" reaped,
                                        assertBool "a dead task lingers until shell_kill reaps it" registered,
                                        parseMaybe (withObject "kill" (.: "killed")) result @?= Just True
                                      ]

-- | 规格：死亡条目不阻塞后续任务 spawn/轮询。
-- 背景：注册表条目故障必须隔离；单条目卡死会拖垮整个后台工具。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
deadEntryNeverJams :: Assertion
deadEntryNeverJams = withWorkDir exercise
 where
  exercise dir =
    newBackgroundRegistry >>= \registry ->
      exerciseWith registry (backgroundTools registry dir)
  exerciseWith _registry tools =
    callTool tools "shell_bg" (object ["command" .= ("true" :: Text)]) >>= \first ->
      taskIdOf first >>= \firstId ->
        callTool tools "shell_output" (object ["taskId" .= firstId, "waitSeconds" .= (5 :: Int)]) >>= \polledFirst ->
          callTool tools "shell_bg" (object ["command" .= ("echo second" :: Text)]) >>= \second ->
            taskIdOf second >>= \secondId ->
              callTool tools "shell_output" (object ["taskId" .= secondId, "waitSeconds" .= (5 :: Int)]) >>= \polledSecond ->
                pollOf polledFirst >>= \(_, firstExit, _, _) ->
                  pollOf polledSecond >>= \(running, exitCode, output, _) ->
                    (,) <$> reap tools firstId <*> reap tools secondId >>= \(firstKilled, secondKilled) ->
                      sequence_
                        [ assertBool "the first task died on its own" (isJust firstExit),
                          assertBool "task ids are distinct" (firstId /= secondId),
                          running @?= False,
                          exitCode @?= Just 0,
                          output @?= "second\n",
                          firstKilled @?= Just True,
                          secondKilled @?= Just True
                        ]
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

-- | 规格：SSE 字节流在每个二进制切点切分都能复现一次性解码结果。
-- 背景：任意网络分块是现实约束；切点敏感说明解码器有状态错误。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
binarySplits :: Assertion
binarySplits =
  (sseCollect [sseSpecimen] @?= sseExpected)
    *> traverse_ splitAtEvery [0 .. ByteString.length sseSpecimen]
 where
  splitAtEvery point =
    sseCollect [ByteString.take point sseSpecimen, ByteString.drop point sseSpecimen] @?= sseExpected

-- | 规格：200 组伪随机 n-ary 切分都能复现一次性解码结果。
-- 背景：随机切分覆盖单切点测不到的组合；失败说明解码器状态机存在隐蔽 bug。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
randomSplits :: Assertion
randomSplits = traverse_ check [1 .. 200]
 where
  check seed = sseCollect (chopAt (splitPoints seed) sseSpecimen) @?= sseExpected

splitPoints :: Int -> [Int]
splitPoints seed = sort (nub (take (1 + seed `mod` 7) (fmap (`mod` (size + 1)) (lcg seed))))
 where
  size = ByteString.length sseSpecimen
lcg :: Int -> [Int]
lcg seed = unfoldr step (seed * 2654435761 + 1)
 where
  step x = Just (x, (x * 1103515245 + 12345) `mod` 2147483648)
chopAt :: [Int] -> ByteString -> [ByteString]
chopAt points bytes = go 0 points bytes
 where
  go _ [] rest = [rest]
  go offset (point : rest) chunk =
    piece : go point rest remainder
   where
    (piece, remainder) = ByteString.splitAt (point - offset) chunk

-- | 规格：空块、尾块缺失 CRLF 等边界输入被正确解码。
-- 背景：空块与残缺尾帧是真实网络常态；处理错误会丢事件或挂起。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
emptyChunks :: Assertion
emptyChunks =
  sequence_
    [ sseCollect [] @?= [],
      sseCollect ["", "", ""] @?= [],
      sseCollect (replicate 5 "" <> [sseSpecimen]) @?= sseExpected,
      sseCollect ["data: tail"] @?= ["tail"],
      sseCollect ["data: cr-tail\r"] @?= ["cr-tail"]
    ]
