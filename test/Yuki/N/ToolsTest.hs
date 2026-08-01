-- | 工作工具测试
--
-- 覆盖：diff、fs 读写/编辑/列表/补全/glob/grep、shell 捕获/超时/工件/流式、后台任务生命周期与 plan 工具。
-- 边界：覆盖 Yuki.N.Tools、Yuki.N.Diff、Yuki.N.Background；沙箱对抗场景见 AdversarialTest。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.ToolsTest
  ( workToolTests,
    diffMiddle,
    diffEnds,
    diffAll,
    diffSame,
    sandboxEscape,
    writeEditRead,
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

import Control.Applicative ()
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (throwIO)
import Control.Monad ((>=>))
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Bool ()
import Data.ByteString ()
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
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types
import Network.Wai (Application, pathInfo, requestHeaders, requestMethod)
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test
import System.Directory (createDirectoryIfMissing)
import System.Exit ()
import System.FilePath ()
import System.Process (getProcessExitCode)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Artifact
import Yuki.N.Background
import Yuki.N.Diff
import Yuki.N.Journal
import Yuki.N.Model
import Yuki.N.Provider.OpenAI ()
import Yuki.N.Replay
import Yuki.N.Server
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig
import Yuki.N.Tools
import Yuki.N.Transcript ()

callToolContext :: ToolContext -> [BackendTool] -> Text -> Value -> IO ToolOutcome
callToolContext context tools name arguments =
  maybe (assertFailure ("missing tool: " <> Text.unpack name)) pure (find (named . backendToolSpec) tools)
    >>= \backend -> runBackendTool backend context arguments
 where
  named = (== name) . toolName
callAs :: Text -> [BackendTool] -> Text -> Value -> IO ToolOutcome
callAs threadId =
  callToolContext (ToolContext "run" threadId "call" (const (pure ())) Nothing)

workToolTests :: TestTree
workToolTests =
  testGroup
    "work tools"
    [ testCase "diff rewrites the middle with three lines of context" diffMiddle,
      testCase "diff splits far-apart changes into two hunks" diffEnds,
      testCase "diff replaces everything" diffAll,
      testCase "diff of identical files is empty" diffSame,
      testCase "sandbox rejects dotdot and absolute escapes" sandboxEscape,
      testCase "write then edit then read with diff outcomes" writeEditRead,
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

-- | 规格：unified diff 对中部修改生成三行上下文的单 hunk。
-- 背景：diff 是 fs_edit 反馈的核心；hunk 边界错误会让模型误读变更范围。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
diffMiddle :: Assertion
diffMiddle =
  unified "f.txt" (numbered "l5") (numbered "X") @?= Text.unlines expected
 where
  numbered replacement = Text.unlines (["l1", "l2", "l3", "l4", replacement, "l6", "l7", "l8", "l9", "l10"] :: [Text])
  expected =
    [ "--- a/f.txt",
      "+++ b/f.txt",
      "@@ -2,7 +2,7 @@",
      " l2",
      " l3",
      " l4",
      "-l5",
      "+X",
      " l6",
      " l7",
      " l8"
    ]

-- | 规格：相距较远的修改拆为两个 hunk。
-- 背景：hunk 合并错误会让模型把不相关变更当成相邻修改。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
diffEnds :: Assertion
diffEnds =
  unified "f.txt" (numbered "l1" "l10") (numbered "X" "Y") @?= Text.unlines expected
 where
  numbered head' last' = Text.unlines ([head', "l2", "l3", "l4", "l5", "l6", "l7", "l8", "l9", last'] :: [Text])
  expected =
    [ "--- a/f.txt",
      "+++ b/f.txt",
      "@@ -1,4 +1,4 @@",
      "-l1",
      "+X",
      " l2",
      " l3",
      " l4",
      "@@ -7,4 +7,4 @@",
      " l7",
      " l8",
      " l9",
      "-l10",
      "+Y"
    ]

-- | 规格：整体替换生成全量 diff。
-- 背景：全量替换是 diff 的最简形态；错误会破坏编辑工具的基本契约。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
diffAll :: Assertion
diffAll =
  unified "f.txt" "a\nb\n" "x\ny\nz\n"
    @?= Text.unlines ["--- a/f.txt", "+++ b/f.txt", "@@ -1,2 +1,3 @@", "-a", "-b", "+x", "+y", "+z"]

-- | 规格：相同文件产生空 diff。
-- 背景：空 diff 是幂等性的体现；误报差异会让模型以为发生了变更。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
diffSame :: Assertion
diffSame = unified "f.txt" "same\nfile\n" "same\nfile\n" @?= ""

-- | 规格：fs 工具拒绝 dotdot 与绝对路径逃逸，返回统一说明。
-- 背景：沙箱是安全边界；逃逸会把任意文件读写暴露给模型。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
sandboxEscape :: Assertion
sandboxEscape = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      callTool tools "fs_read" (object ["path" .= ("../../../../etc/passwd" :: Text)]) >>= \relative ->
        callTool tools "fs_read" (object ["path" .= ("/etc/passwd" :: Text)]) >>= \absolute ->
          callTool tools "fs_write" (object ["path" .= ("../escape.txt" :: Text), "content" .= ("x" :: Text)]) >>= \written ->
            sequence_
              [ toolOutcomeError relative @?= True,
                toolOutcomeError absolute @?= True,
                toolOutcomeError written @?= True,
                toolOutcomeContent relative @?= "path escapes the work directory",
                toolOutcomeContent absolute @?= "path escapes the work directory",
                toolOutcomeContent written @?= "path escapes the work directory"
              ]

-- | 规格：fs_write 生成新增 diff、fs_edit 生成替换 diff、fs_read 取回最终内容。
-- 背景：读写编辑闭环是文件工具的基础工作流；diff 错位会让模型误判文件状态。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
writeEditRead :: Assertion
writeEditRead = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      callTool tools "fs_write" (object ["path" .= ("sub/notes.txt" :: Text), "content" .= ("alpha\nbeta\n" :: Text)]) >>= \written ->
        callTool tools "fs_edit" (object ["path" .= ("sub/notes.txt" :: Text), "old" .= ("beta" :: Text), "new" .= ("gamma" :: Text)]) >>= \edited ->
          callTool tools "fs_read" (object ["path" .= ("sub/notes.txt" :: Text)]) >>= \readBack ->
            sequence_
              [ toolOutcomeError written @?= False,
                toolOutcomeContent written
                  @?= Text.unlines ["--- a/sub/notes.txt", "+++ b/sub/notes.txt", "@@ -1,0 +1,2 @@", "+alpha", "+beta"],
                toolOutcomeContent edited
                  @?= Text.unlines ["--- a/sub/notes.txt", "+++ b/sub/notes.txt", "@@ -1,2 +1,2 @@", " alpha", "-beta", "+gamma"],
                toolOutcomeError readBack @?= False,
                toolOutcomeContent readBack @?= "alpha\ngamma\n"
              ]

-- | 规格：fs_read 分页显示行范围、钳制越界 limit、拒绝越界 offset。
-- 背景：大文件必须分页；offset/limit 语义错误会让模型读到错误窗口。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
paginatedRead :: Assertion
paginatedRead = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      TextIO.writeFile (dir ++ "/f.txt") "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"
        *> callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "offset" .= (3 :: Int), "limit" .= (4 :: Int)])
        >>= \window ->
          callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "limit" .= (2 :: Int)]) >>= \headOnly ->
            callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "offset" .= (8 :: Int)]) >>= \tailOnly ->
              callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "offset" .= (0 :: Int), "limit" .= (2 :: Int)]) >>= \clamped ->
                callTool tools "fs_read" (object ["path" .= ("f.txt" :: Text), "offset" .= (11 :: Int)]) >>= \outOfBounds ->
                  sequence_
                    [ toolOutcomeError window @?= False,
                      toolOutcomeContent window @?= "l3\nl4\nl5\nl6\n(lines 3-6 of 10)",
                      toolOutcomeContent headOnly @?= "l1\nl2\n(lines 1-2 of 10)",
                      toolOutcomeContent tailOnly @?= "l8\nl9\nl10\n(lines 8-10 of 10)",
                      toolOutcomeContent clamped @?= "l1\nl2\n(lines 1-2 of 10)",
                      toolOutcomeError outOfBounds @?= True,
                      toolOutcomeContent outOfBounds @?= "offset 11 exceeds f.txt line count 10"
                    ]

-- | 规格：fs_edit 对缺失文本与歧义文本给出可诊断的错误。
-- 背景：编辑失败必须可解释；含糊错误会让模型盲目重试。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
editFailures :: Assertion
editFailures = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      TextIO.writeFile (dir ++ "/dup.txt") "dup dup here"
        *> callTool tools "fs_read" (object ["path" .= ("dup.txt" :: Text)])
        *> callTool tools "fs_edit" (object ["path" .= ("dup.txt" :: Text), "old" .= ("absent" :: Text), "new" .= ("x" :: Text)])
        >>= \missing ->
          callTool tools "fs_edit" (object ["path" .= ("dup.txt" :: Text), "old" .= ("dup" :: Text), "new" .= ("x" :: Text)]) >>= \ambiguous ->
            sequence_
              [ toolOutcomeError missing @?= True,
                assertBool "missing explains" (Text.isInfixOf "old text not found in dup.txt" (toolOutcomeContent missing)),
                toolOutcomeError ambiguous @?= True,
                assertBool "ambiguous explains" (Text.isInfixOf "old text occurs 2 times in dup.txt" (toolOutcomeContent ambiguous))
              ]

-- | 规格：fs_edit 要求新鲜读取，文件被外部修改后必须重新读取。
-- 背景：陈旧编辑会覆盖外部变更；stamp 机制是并发安全的关键。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
staleEdit :: Assertion
staleEdit = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      TextIO.writeFile (dir ++ "/s.txt") "aaa\n"
        *> editAt tools "s.txt" "aaa" "bbb"
        >>= \unread ->
          readAt tools "s.txt"
            *> editAt tools "s.txt" "aaa" "bbb"
            >>= \fresh ->
              TextIO.writeFile (dir ++ "/s.txt") "cccc\n"
                *> editAt tools "s.txt" "bbb" "x"
                >>= \stale ->
                  readAt tools "s.txt"
                    *> editAt tools "s.txt" "cccc" "dddd"
                    >>= \reread ->
                      writeAt tools "w.txt" "fresh\n"
                        *> editAt tools "w.txt" "fresh" "done"
                        >>= \afterWrite ->
                          TextIO.readFile (dir ++ "/s.txt") >>= \finalContent ->
                            sequence_
                              [ toolOutcomeError unread @?= True,
                                toolOutcomeContent unread @?= "read the file before editing",
                                toolOutcomeError fresh @?= False,
                                toolOutcomeError stale @?= True,
                                toolOutcomeContent stale @?= "file changed since last read; re-read it",
                                toolOutcomeError reread @?= False,
                                toolOutcomeError afterWrite @?= False,
                                finalContent @?= "dddd\n"
                              ]
  readAt tools path = callTool tools "fs_read" (object ["path" .= (path :: Text)])
  writeAt tools path content = callTool tools "fs_write" (object ["path" .= (path :: Text), "content" .= (content :: Text)])
  editAt tools path old new = callTool tools "fs_edit" (object ["path" .= (path :: Text), "old" .= (old :: Text), "new" .= (new :: Text)])

-- | 规格：fs_list 排序、标记目录并限制深度为二。
-- 背景：目录视图是模型的文件导航基础；深度失控会让输出爆炸。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
listEntries :: Assertion
listEntries = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      createDirectoryIfMissing True (dir ++ "/src/deep")
        *> TextIO.writeFile (dir ++ "/b.txt") "b"
        *> TextIO.writeFile (dir ++ "/src/a.txt") "a"
        *> TextIO.writeFile (dir ++ "/src/deep/x.txt") "x"
        *> callTool tools "fs_list" (object [])
        >>= \outcome ->
          sequence_
            [ toolOutcomeError outcome @?= False,
              toolOutcomeContent outcome @?= Text.intercalate "\n" ["b.txt", "src/", "  a.txt", "  deep/"]
            ]

-- | 规格：fs_list 与 config 树渲染符号链接为叶节点而不跟随。
-- 背景：跟随符号链接会逃逸沙箱或陷入环；叶节点渲染是安全与防环的统一答案。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
listSymlinks :: Assertion
listSymlinks =
  withSandbox $ \root ->
    workTools Nothing root >>= \tools ->
      callTool tools "fs_list" (object []) >>= \listed ->
        callTool tools "fs_list" (object ["path" .= ("inner" :: Text)]) >>= \explicit ->
          listTree root 8 >>= \tree ->
            let renderedTree = Text.intercalate "\n" tree
             in sequence_
                  [ toolOutcomeError listed @?= False,
                    assertBool "external directory symlink is a leaf" ("linkdir@" `Text.isInfixOf` toolOutcomeContent listed),
                    assertBool "internal directory symlink is a leaf" ("inner@" `Text.isInfixOf` toolOutcomeContent listed),
                    assertBool "cycle symlink is a leaf" ("up@" `Text.isInfixOf` toolOutcomeContent listed),
                    assertBool "external content never appears" (not ("TOP-SECRET" `Text.isInfixOf` toolOutcomeContent listed)),
                    toolOutcomeError explicit @?= True,
                    toolOutcomeContent explicit @?= "refusing to list through a symbolic link",
                    assertBool "config tree marks external symlink" ("linkdir@" `Text.isInfixOf` renderedTree),
                    assertBool "config tree marks internal symlink" ("inner@" `Text.isInfixOf` renderedTree),
                    assertBool "config tree does not expand the cycle" (length (filter (Text.isInfixOf "up@") tree) == 1)
                  ]

-- | 规格：路径补全限制在 cwd 内且省略符号链接。
-- 背景：补全泄漏外部路径会让模型尝试读取沙箱外文件。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
pathCompletion :: Assertion
pathCompletion =
  withSandbox $ \root ->
    completePaths root "" >>= \top ->
      completePaths root "sub/" >>= \nested ->
        completePaths root "../" >>= \escaped ->
          sequence_
            [ assertBool "offers real directories" ("sub/" `elem` top),
              assertBool "omits external symlinks" (not ("linkdir/" `elem` top)),
              assertBool "omits file symlinks" (not ("linkfile.txt" `elem` top)),
              nested @?= ["sub/ok.txt"],
              escaped @?= []
            ]

-- | 规格：fs_glob 支持 **/?、200 条上限并跳过噪音目录（node_modules/.hidden）。
-- 背景：glob 是检索入口；噪声目录与超限会让结果不可用。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
globSearch :: Assertion
globSearch = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      createDirectoryIfMissing True (dir ++ "/src/N")
        *> createDirectoryIfMissing True (dir ++ "/node_modules/pkg")
        *> createDirectoryIfMissing True (dir ++ "/.hidden")
        *> createDirectoryIfMissing True (dir ++ "/caps")
        *> TextIO.writeFile (dir ++ "/x.hs") "top"
        *> TextIO.writeFile (dir ++ "/src/N/x.hs") "nested"
        *> TextIO.writeFile (dir ++ "/node_modules/pkg/x.hs") "dep"
        *> TextIO.writeFile (dir ++ "/.hidden/x.hs") "hidden"
        *> traverse_ (\name -> TextIO.writeFile (dir ++ "/caps/" ++ name) "cap") capNames
        *> callTool tools "fs_glob" (object ["pattern" .= ("**/x.hs" :: Text)])
        >>= \nested ->
          callTool tools "fs_glob" (object ["pattern" .= ("src/?/x.hs" :: Text)]) >>= \single ->
            callTool tools "fs_glob" (object ["pattern" .= ("caps/*.txt" :: Text)]) >>= \capped ->
              sequence_
                [ toolOutcomeError nested @?= False,
                  toolOutcomeContent nested @?= "src/N/x.hs\nx.hs",
                  toolOutcomeContent single @?= "src/N/x.hs",
                  toolOutcomeContent capped @?= expectedCaps
                ]
  capNames = ["cap-" <> replicate (3 - length s) '0' <> s <> ".txt" | i <- [0 .. 204 :: Int], let s = show i]
  expectedCaps = Text.intercalate "\n" (fmap (Text.pack . ("caps/" ++)) (take 200 capNames)) <> "\n... 5 more"

-- | 规格：fs_grep 以行号命中文本并支持 include 过滤。
-- 背景：grep 是代码检索主力；include 错误会让结果范围失控。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
grepSearch :: Assertion
grepSearch = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      TextIO.writeFile (dir ++ "/a.txt") "one\ntwo needle\nthree needle\n"
        *> TextIO.writeFile (dir ++ "/b.hs") "needle in hs\n"
        *> TextIO.writeFile (dir ++ "/b.txt") "needle in txt\n"
        *> callTool tools "fs_grep" (object ["pattern" .= ("needle" :: Text)])
        >>= \plain ->
          callTool tools "fs_grep" (object ["pattern" .= ("needle" :: Text), "include" .= ("*.hs" :: Text)]) >>= \hsOnly ->
            sequence_
              [ toolOutcomeError plain @?= False,
                toolOutcomeContent plain
                  @?= Text.intercalate "\n" ["a.txt:2:two needle", "a.txt:3:three needle", "b.hs:1:needle in hs", "b.txt:1:needle in txt"],
                toolOutcomeContent hsOnly @?= "b.hs:1:needle in hs"
              ]

-- | 规格：fs_grep 把正则元字符按字面处理。
-- 背景：字面语义防止模型意外正则注入；正则语义会让常见搜索误命中。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
grepLiteral :: Assertion
grepLiteral = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      TextIO.writeFile (dir ++ "/c.txt") "axb\nliteral .* here\n"
        *> callTool tools "fs_grep" (object ["pattern" .= (".*" :: Text)])
        >>= \outcome ->
          sequence_
            [ toolOutcomeError outcome @?= False,
              toolOutcomeContent outcome @?= "c.txt:2:literal .* here"
            ]

-- | 规格：fs_glob 与 fs_grep 拒绝逃逸路径。
-- 背景：搜索工具的路径参数同样受沙箱约束；漏检会让搜索泄漏外部文件。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
searchSandbox :: Assertion
searchSandbox = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      callTool tools "fs_glob" (object ["pattern" .= ("*" :: Text), "path" .= ("../" :: Text)]) >>= \globbed ->
        callTool tools "fs_grep" (object ["pattern" .= ("x" :: Text), "path" .= ("../" :: Text)]) >>= \grepped ->
          sequence_
            [ toolOutcomeError globbed @?= True,
              toolOutcomeError grepped @?= True,
              toolOutcomeContent globbed @?= "path escapes the work directory",
              toolOutcomeContent grepped @?= "path escapes the work directory"
            ]

-- | 规格：shell 捕获退出码与合并的 stdout/stderr。
-- 背景：退出码与输出是模型判断命令成败的唯一依据；错乱会让模型误判。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
shellCaptures :: Assertion
shellCaptures = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      callTool tools "shell" (object ["command" .= ("echo out; echo err >&2; exit 3" :: Text)]) >>= \outcome ->
        sequence_
          [ toolOutcomeError outcome @?= False,
            toolOutcomeContent outcome @?= "exit 3\nout\nerr\n"
          ]

-- | 规格：shell 超时终止并保留部分输出。
-- 背景：失控命令必须可终止；超时不生效会让运行时被挂死。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
shellStops :: Assertion
shellStops = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      callTool tools "shell" (object ["command" .= ("echo before; sleep 30; echo after" :: Text), "timeoutSeconds" .= (1 :: Int)]) >>= \outcome ->
        sequence_
          [ assertBool "timeout reported" ("exit timeout" `Text.isPrefixOf` toolOutcomeContent outcome),
            assertBool "partial output kept" (Text.isInfixOf "before" (toolOutcomeContent outcome)),
            assertBool "killed before completion" (not (Text.isInfixOf "after" (toolOutcomeContent outcome)))
          ]

-- | 规格：shell 超时提示使用 shell_bg/shell_output 处理长任务。
-- 背景：提示引导模型使用正确工具；缺失会让模型反复撞超时。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
shellTimeoutHint :: Assertion
shellTimeoutHint = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      callTool tools "shell" (object ["command" .= ("printf before; sleep 30" :: Text), "timeoutSeconds" .= (1 :: Int)]) >>= \outcome ->
        toolOutcomeContent outcome
          @?= "exit timeout\nbefore\nhint: use shell_bg for long-running tasks, then shell_output to poll\n"

-- | 规格：大体积 shell 输出落入工件存储并给出 artifact_read 引导。
-- 背景：大输出内联会撑爆上下文；工件化是唯一可持续路径。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
shellArtifact :: Assertion
shellArtifact = withWorkDir exercise
 where
  exercise dir =
    newMemoryArtifactStore >>= \store ->
      workTools (Just store) dir >>= \tools ->
        callTool tools "shell" (object ["command" .= bigCommand]) >>= \outcome ->
          artifactList store >>= \metas ->
            sequence_
              [ toolOutcomeError outcome @?= False,
                assertBool "head kept" ("exit 0\nline-0" `Text.isPrefixOf` toolOutcomeContent outcome),
                assertBool "tail kept" (Text.isInfixOf "line-39" (toolOutcomeContent outcome)),
                assertBool "guidance names the artifact" (Text.isInfixOf "[artifact art-" (toolOutcomeContent outcome)),
                assertBool "guidance points at artifact_read" (Text.isInfixOf "artifact_read" (toolOutcomeContent outcome)),
                fmap artifactMetaToolName metas @?= ["shell"]
              ]
  bigCommand =
    "i=0; while [ $i -lt 40 ]; do echo line-$i-xxxxxxxxxxxx; i=$((i+1)); done" :: Text

-- | 规格：shell 运行中分块流式输出 stdout/stderr 事件，最终结果与流一致。
-- 背景：流式是长命令的实时反馈；事件与最终结果不一致会让前端状态混乱。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
shellStreams :: Assertion
shellStreams = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      newIORef [] >>= \events ->
        callToolContext (streaming events) tools "shell" (object ["command" .= ("echo one; sleep 0.5; echo two; sleep 0.5; echo err >&2" :: Text)]) >>= \outcome ->
          reverse <$> readIORef events >>= \emitted ->
            let chunks = mapMaybe (parseMaybe parseChunk) [value | Custom "shell.output" value <- emitted]
                stdout = Text.concat [delta | ("call-1", "stdout", delta) <- chunks]
                stderr = Text.concat [delta | ("call-1", "stderr", delta) <- chunks]
             in sequence_
                  [ assertBool "streams at least two chunks" (length chunks >= 2),
                    stdout @?= "one\ntwo\n",
                    stderr @?= "err\n",
                    toolOutcomeContent outcome @?= "exit 0\none\ntwo\nerr\n"
                  ]
   where
    streaming events = ToolContext "run" "thread" "call-1" (\event -> modifyIORef' events (event :)) Nothing
  parseChunk :: Value -> Parser (Text, Text, Text)
  parseChunk =
    withObject "shell.output" $ \fields ->
      (,,) <$> fields .: "callId" <*> fields .: "stream" <*> fields .: "delta"

-- | 规格：shell_bg 启动后台任务，shell_output 先报告运行中、等待后报告完成与退出码。
-- 背景：后台任务生命周期是长任务支持的基础；状态机错误会让任务不可达。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
backgroundLifecycle :: Assertion
backgroundLifecycle = withWorkDir exercise
 where
  exercise dir =
    newBackgroundRegistry >>= \registry ->
      let tools = backgroundTools registry dir
       in callTool tools "shell_bg" (object ["command" .= ("sleep 1; echo done" :: Text)]) >>= \started ->
            taskIdOf started >>= \taskId ->
              callTool tools "shell_output" (object ["taskId" .= taskId]) >>= \early ->
                callTool tools "shell_output" (object ["taskId" .= taskId, "waitSeconds" .= (5 :: Int)]) >>= \late ->
                  pollOf early >>= \(earlyRunning, _, _, _) ->
                    pollOf late >>= \(running, exitCode, output, truncated) ->
                      sequence_
                        [ toolOutcomeError started @?= False,
                          earlyRunning @?= True,
                          running @?= False,
                          exitCode @?= Just 0,
                          assertBool "buffered output kept" ("done" `Text.isInfixOf` output),
                          truncated @?= False
                        ]

-- | 规格：shell_stdin 喂入 stdin、EOF 关闭，之后写入被拒。
-- 背景：交互式命令依赖 stdin；EOF 后继续写入会挂死管道。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
backgroundStdinFeed :: Assertion
backgroundStdinFeed = withWorkDir exercise
 where
  exercise dir =
    newBackgroundRegistry >>= \registry ->
      let tools = backgroundTools registry dir
       in callTool tools "shell_bg" (object ["command" .= ("cat" :: Text)]) >>= \started ->
            taskIdOf started >>= \taskId ->
              callTool tools "shell_stdin" (object ["taskId" .= taskId, "text" .= ("hello\n" :: Text)]) >>= \fed ->
                callTool tools "shell_stdin" (object ["taskId" .= taskId, "text" .= ("" :: Text), "eof" .= True]) >>= \closed ->
                  callTool tools "shell_stdin" (object ["taskId" .= taskId, "text" .= ("late\n" :: Text)]) >>= \late ->
                    callTool tools "shell_output" (object ["taskId" .= taskId, "waitSeconds" .= (5 :: Int)]) >>= \polled ->
                      pollOf polled >>= \(running, exitCode, output, _) ->
                        sequence_
                          [ toolOutcomeError fed @?= False,
                            toolOutcomeError closed @?= False,
                            toolOutcomeError late @?= True,
                            running @?= False,
                            exitCode @?= Just 0,
                            output @?= "hello\n"
                          ]

-- | 规格：shell_kill 终止进程组并回收任务，之后轮询报未知任务。
-- 背景：杀进程组防止子进程残留；回收不彻底会泄漏资源。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
backgroundKill :: Assertion
backgroundKill = withWorkDir exercise
 where
  exercise dir =
    newBackgroundRegistry >>= \registry ->
      let tools = backgroundTools registry dir
       in callTool tools "shell_bg" (object ["command" .= ("sleep 30" :: Text)]) >>= \started ->
            taskIdOf started >>= \taskId ->
              callTool tools "shell_output" (object ["taskId" .= taskId]) >>= \early ->
                callTool tools "shell_kill" (object ["taskId" .= taskId]) >>= \killed ->
                  callTool tools "shell_output" (object ["taskId" .= taskId]) >>= \late ->
                    pollOf early >>= \(running, _, _, _) ->
                      outcomeValue killed >>= \result ->
                        sequence_
                          [ running @?= True,
                            parseMaybe (withObject "kill" (.: "killed")) result @?= Just True,
                            toolOutcomeError late @?= True,
                            assertBool "reaped task is unknown" ("unknown background task" `Text.isInfixOf` toolOutcomeContent late)
                          ]

-- | 规格：并发 spawn 全部注册并全部可回收。
-- 背景：并发注册是竞态高发点；漏注册会让任务丢失。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
backgroundSpawnRace :: Assertion
backgroundSpawnRace = withWorkDir exercise
 where
  exercise dir =
    newBackgroundRegistry >>= \registry ->
      sequence (replicate 8 newEmptyMVar) >>= \slots ->
        let tools = backgroundTools registry dir
         in traverse_ (forkIO . spawn tools) slots
              *> (timeout 10000000 (traverse takeMVar slots) >>= maybe (assertFailure "concurrent spawns did not finish") pure)
              >>= traverse (kill tools)
              >>= \killed ->
                ((== 0) <$> backgroundTaskCount registry) >>= \empty ->
                  sequence_
                    [ killed @?= replicate 8 True,
                      assertBool "every spawned task is reaped, none leaks" empty
                    ]
  spawn tools slot =
    callTool tools "shell_bg" (object ["command" .= ("cat" :: Text)]) >>= taskIdOf >>= putMVar slot
  kill tools taskId =
    callTool tools "shell_kill" (object ["taskId" .= taskId])
      >>= fmap ((Just True ==) . parseMaybe (withObject "kill" (.: "killed"))) . outcomeValue

-- | 规格：后台任务仅对所属线程可见。
-- 背景：线程隔离防止跨会话干扰；泄漏会让别的线程误操作他人任务。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
backgroundThreadIsolation :: Assertion
backgroundThreadIsolation = withWorkDir exercise
 where
  exercise dir =
    newBackgroundRegistry >>= \registry ->
      let tools = backgroundTools registry dir
       in callAs "thread-a" tools "shell_bg" (object ["command" .= ("cat" :: Text)]) >>= \started ->
            taskIdOf started >>= \taskId ->
              callAs "thread-b" tools "shell_output" (object ["taskId" .= taskId]) >>= \alien ->
                callAs "thread-a" tools "shell_output" (object ["taskId" .= taskId]) >>= \owned ->
                  callAs "thread-a" tools "shell_kill" (object ["taskId" .= taskId]) >>= \killed ->
                    sequence_
                      [ toolOutcomeError alien @?= True,
                        assertBool "foreign thread learns no task details" ("unknown background task" `Text.isInfixOf` toolOutcomeContent alien),
                        toolOutcomeError owned @?= False,
                        toolOutcomeError killed @?= False
                      ]

-- | 规格：完成态任务保留有界，运行中任务绝不被驱逐。
-- 背景：保留策略错误会丢失可查证的历史或误杀运行中任务。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
backgroundRetention :: Assertion
backgroundRetention = withWorkDir exercise
 where
  exercise dir =
    newBackgroundRegistryWithLimit 2 >>= \registry ->
      let tools = backgroundTools registry dir
       in callTool tools "shell_bg" (object ["command" .= ("cat" :: Text)]) >>= \running ->
            taskIdOf running >>= \runningId ->
              traverse (complete tools) [1 .. 4 :: Int] >>= \completed ->
                waitUntil ((<= 3) <$> backgroundTaskCount registry) >>= \bounded ->
                  lookupBackground registry runningId >>= \live ->
                    lookupBackground registry (fromMaybe (error "no completed tasks") (listToMaybe completed)) >>= \oldest ->
                      lookupBackground registry (fromMaybe (error "no completed tasks") (listToMaybe (reverse completed))) >>= \newest ->
                        callTool tools "shell_kill" (object ["taskId" .= runningId]) >>= \killed ->
                          sequence_
                            [ assertBool "registry converges to running plus retention limit" bounded,
                              assertBool "running task is never pruned" (isJust live),
                              assertBool "oldest completed task is pruned" (isNothing oldest),
                              assertBool "newest completed task remains inspectable" (isJust newest),
                              toolOutcomeError killed @?= False
                            ]
  complete tools index =
    callTool tools "shell_bg" (object ["command" .= ("printf done-" <> Text.pack (show index) :: Text)]) >>= \started ->
      taskIdOf started >>= \taskId ->
        callTool tools "shell_output" (object ["taskId" .= taskId, "waitSeconds" .= (5 :: Int)]) $> taskId

-- | 规格：线程归档与服务关闭回收各自拥有的进程。
-- 背景：关闭不回收会留下僵尸进程；回收错误会让资源耗尽。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
backgroundShutdown :: Assertion
backgroundShutdown = withWorkDir exercise
 where
  exercise dir =
    newBackgroundRegistry >>= \registry ->
      let tools = backgroundTools registry dir
       in callAs "thread-a" tools "shell_bg" (object ["command" .= ("cat" :: Text)]) >>= \first ->
            callAs "thread-b" tools "shell_bg" (object ["command" .= ("cat" :: Text)]) >>= \second ->
              (,) <$> taskIdOf first <*> taskIdOf second >>= \(firstId, secondId) ->
                (,) <$> lookupBackground registry firstId <*> lookupBackground registry secondId >>= \case
                  (Just firstProc, Just secondProc) ->
                    shutdownBackgroundThread registry "thread-a"
                      *> callAs "thread-a" tools "shell_output" (object ["taskId" .= firstId])
                      >>= \archived ->
                        callAs "thread-b" tools "shell_output" (object ["taskId" .= secondId]) >>= \surviving ->
                          shutdownBackground registry
                            *> waitUntil (bothReaped firstProc secondProc)
                            >>= \reaped ->
                              backgroundTaskCount registry >>= \remaining ->
                                sequence_
                                  [ toolOutcomeError archived @?= True,
                                    toolOutcomeError surviving @?= False,
                                    assertBool "both process handles are reaped" reaped,
                                    remaining @?= 0
                                  ]
                  _ -> assertFailure "spawned tasks missing from registry"
  bothReaped first second =
    (&&)
      <$> (isJust <$> getProcessExitCode (backgroundProcess first))
      <*> (isJust <$> getProcessExitCode (backgroundProcess second))

-- | 规格：同一后台注册表跨多次独立运行时（每次重新 resolve）任务仍可轮询/喂入/终止。
-- 背景：运行时重建是常见生命周期；注册表必须跨运行时存活。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
backgroundAcrossRuntimeFor :: Assertion
backgroundAcrossRuntimeFor = withWorkDir exercise
 where
  exercise dir =
    newTlsManager >>= \manager ->
      newBackgroundRegistry >>= \registry ->
        newIORef Nothing >>= \task ->
          newIORef Map.empty >>= \observed ->
            newIORef (0 :: Int) >>= \resolved ->
              testRuntime (backgroundRoundModel task observed) [] Sequential >>= \base ->
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
                    app = application Nothing Nothing Nothing Nothing runtimeFor
                 in traverse (runBackgroundRound app) (zip [1 ..] ["start", "output", "stdin", "kill"])
                      >>= \responses ->
                        readIORef observed >>= \results ->
                          readIORef resolved >>= \resolutions ->
                            backgroundTaskCount registry >>= \remaining ->
                              sequence_
                                [ assertBool "each run returns an SSE success" (all ((== status200) . simpleStatus) responses),
                                  resolutions @?= 4,
                                  assertBool "a later run can poll" (resultField "output" "running" results == Just True),
                                  assertBool "a third run can write stdin" (resultField "stdin" "stdinOpen" results == Just True),
                                  assertBool "a fourth run terminates" (resultField "kill" "killed" results == Just True),
                                  remaining @?= 0
                                ]

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

-- | 规格：所有工具参数 schema 都是结构合法的 JSON Schema（type 必填、items/properties 类型一致）。
-- 背景：schema 驱动 provider 的工具声明；非法 schema 会被 provider 拒绝导致工具不可用。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
schemaSanity :: Assertion
schemaSanity =
  withSandbox (workTools Nothing >=> traverse_ check . fmap (toolParameters . backendToolSpec))
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
      maybe True (all valid . fmap snd . KeyMap.toList) (objectOf "properties")
        && maybe True valid (KeyMap.lookup "items" fields)
    objectOf key = case KeyMap.lookup key fields of
      Just (Object inner) -> Just inner
      _ -> Nothing
  valid _ = True

callPlan :: [BackendTool] -> IORef [Event] -> Value -> IO ToolOutcome
callPlan tools events arguments =
  callToolContext (streaming events) tools "plan" arguments
 where
  streaming ref = ToolContext "run" "thread" "call" (\event -> modifyIORef' ref (event :)) Nothing
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

-- | 规格：plan set 替换计划、渲染并发布完整状态事件。
-- 背景：计划是长任务的执行视图；渲染与事件不一致会让前端与模型看到不同计划。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
planSet :: Assertion
planSet = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      newIORef [] >>= \events ->
        callPlan tools events planSetArgs >>= \outcome ->
          reverse <$> readIORef events >>= \emitted ->
            sequence_
              [ toolOutcomeError outcome @?= False,
                toolOutcomeContent outcome @?= "1. [ ] scan\n2. [ ] fix",
                emitted @?= [planEvent [("1", "scan", "pending"), ("2", "fix", "pending")]]
              ]

-- | 规格：plan update 逐项翻转状态并拒绝未知 id。
-- 背景：逐项更新是计划交互的核心；未知 id 静默接受会掩盖模型幻觉。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
planUpdate :: Assertion
planUpdate = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      newIORef [] >>= \events ->
        callPlan tools events planSetArgs
          *> callPlan tools events (planUpdateArgs "1" "doing")
          >>= \doing ->
            callPlan tools events (planUpdateArgs "1" "done") >>= \done ->
              callPlan tools events (planUpdateArgs "2" "doing") >>= \second ->
                callPlan tools events (planUpdateArgs "9" "done") >>= \unknown ->
                  reverse <$> readIORef events >>= \emitted ->
                    sequence_
                      [ toolOutcomeContent doing @?= "1. [doing] scan\n2. [ ] fix",
                        toolOutcomeContent done @?= "1. [done] scan\n2. [ ] fix",
                        toolOutcomeContent second @?= "1. [done] scan\n2. [doing] fix",
                        toolOutcomeError unknown @?= True,
                        toolOutcomeContent unknown @?= "unknown plan item: 9",
                        length emitted @?= 4,
                        last emitted @?= planEvent [("1", "scan", "done"), ("2", "fix", "doing")]
                      ]

-- | 规格：plan clear 清空并渲染空状态，重复 clear 幂等。
-- 背景：空状态渲染与幂等是计划终态契约。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
planClear :: Assertion
planClear = withWorkDir exercise
 where
  exercise dir =
    workTools Nothing dir >>= \tools ->
      newIORef [] >>= \events ->
        callPlan tools events planSetArgs
          *> callPlan tools events (object ["action" .= ("clear" :: Text)])
          >>= \cleared ->
            callPlan tools events (object ["action" .= ("clear" :: Text)]) >>= \again ->
              reverse <$> readIORef events >>= \emitted ->
                sequence_
                  [ toolOutcomeError cleared @?= False,
                    toolOutcomeContent cleared @?= "(empty plan)",
                    toolOutcomeContent again @?= "(empty plan)",
                    last emitted @?= planEvent []
                  ]

-- | 规格：带 plan 事件的 journaled 运行可无分歧重放。
-- 背景：重放必须复现计划事件；否则重放视图与真实执行不一致。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
planReplay :: Assertion
planReplay = withWorkDir exercise
 where
  exercise dir =
    newMemoryJournal >>= \(journal, readEntries) ->
      newIORef (0 :: Int) >>= \turns ->
        workTools Nothing dir >>= \tools ->
          testRuntime (planModel turns) tools Sequential >>= \base ->
            collectEvents base {runtimeJournal = Just journal} (sampleInput []) >>= \events ->
              readEntries >>= \recorded ->
                replayEntries defaultHooks Nothing recorded >>= \report ->
                  sequence_
                    [ assertBool "journal records the plan event" (any journaled recorded),
                      [content | ToolCallResult _ "call-plan" content <- events] @?= ["1. [ ] scan\n2. [ ] fix"],
                      fmap reportDivergence report @?= Right Nothing,
                      fmap reportEvents report @?= Right (length (filter (not . isPlan) events))
                    ]
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
