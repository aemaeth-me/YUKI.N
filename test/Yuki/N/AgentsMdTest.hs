-- | AGENTS.md 注入测试
--
-- 覆盖：嵌套收集、缺失/不可读/超限处理、拼接形状与 cwd 解析注入。
-- 边界：覆盖 Yuki.N.AgentsMd。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.AgentsMdTest
  ( agentsMdTests,
    nestedAgentsMd,
    absentAgentsMd,
    unreadableAgentsMd,
    cappedAgentsMd,
    appendShape,
    resolveAgentsMd
  )
where
import System.Directory (createDirectoryIfMissing, emptyPermissions, getPermissions, setPermissions)
import Data.Functor ((<&>))
import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Exception ()
import Control.Monad ()
import Data.Aeson ()
import Data.Bool ()
import Data.ByteString ()
import Data.Foldable ()
import Data.List ()
import qualified Data.Map.Strict as Map
import Data.Text ()
import qualified Data.Text as Text
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types ()
import Network.Wai.Test ()
import System.Exit ()
import System.FilePath ()
import System.Process ()
import System.Timeout ()
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AgentsMd
import Yuki.N.ThreadConfig
import Yuki.N.Agent
import Yuki.N.Model ()
import Yuki.N.Provider.OpenAI ()
import Yuki.N.AGUI.Types ()
import Yuki.N.AGUI.Event ()
import Yuki.N.Background ()
import Yuki.N.TestSupport


agentsMdTests :: TestTree
agentsMdTests =
  testGroup
    "AGENTS.md"
    [ testCase "collects nested files root-first with path headers" nestedAgentsMd,
      testCase "yields empty without any AGENTS.md" absentAgentsMd,
      testCase "skips unreadable files without failing" unreadableAgentsMd,
      testCase "caps the total at 32KB with a truncation note" cappedAgentsMd,
      testCase "appendAgentsMd joins with two blank lines only when both sides exist" appendShape,
      testCase "resolve appends the section when a cwd resolves, never without" resolveAgentsMd
    ]
-- | 规格：agentsMdSection 根优先收集嵌套 AGENTS.md 并带路径标题。
-- 背景：项目规则分层是 AGENTS.md 协议的核心；顺序错误会让规则覆盖关系颠倒。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
nestedAgentsMd :: Assertion
nestedAgentsMd =
  withWorkDir $ \root ->
    let leaf = root ++ "/leaf"
        expected = Text.intercalate "\n\n" [sectionOf root "root rules", sectionOf leaf "leaf rules"]
     in createDirectoryIfMissing True leaf
          *> writeFile (root ++ "/AGENTS.md") "root rules"
          *> writeFile (leaf ++ "/AGENTS.md") "leaf rules"
          *> (agentsMdSection (Just leaf) >>= assertBool "root-first with path headers" . Text.isInfixOf expected)
  where
    sectionOf dir body = "# " <> Text.pack (dir ++ "/AGENTS.md") <> "\n\n" <> body
-- | 规格：无 AGENTS.md 时返回空。
-- 背景：可选文件缺失必须无副作用；报错会让未配置项目不可用。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
absentAgentsMd :: Assertion
absentAgentsMd =
  (agentsMdSection Nothing >>= (@?= ""))
    *> withWorkDir (\dir -> agentsMdSection (Just dir) >>= (@?= ""))
-- | 规格：不可读的 AGENTS.md 被跳过而不失败。
-- 背景：权限受限文件是常态；失败会让整个运行时不可用。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
unreadableAgentsMd :: Assertion
unreadableAgentsMd =
  withWorkDir $ \root ->
    let leaf = root ++ "/leaf"
        blocked = leaf ++ "/AGENTS.md"
     in createDirectoryIfMissing True leaf
          *> writeFile (root ++ "/AGENTS.md") "root rules"
          *> writeFile blocked "hidden"
          *> getPermissions blocked
          >>= \original ->
            setPermissions blocked emptyPermissions
              *> (agentsMdSection (Just leaf) >>= verify)
              *> setPermissions blocked original
  where
    verify section =
      sequence_
        [ assertBool "keeps the readable file" (Text.isInfixOf "root rules" section),
          assertBool "skips the unreadable file" (not (Text.isInfixOf "hidden" section))
        ]
-- | 规格：总内容被限制在 32KB 并附截断说明。
-- 背景：超长规则会挤爆上下文；截断说明让模型知道信息有界。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cappedAgentsMd :: Assertion
cappedAgentsMd =
  withWorkDir $ \root ->
    writeFile (root ++ "/AGENTS.md") (replicate 40000 'x')
      *> (agentsMdSection (Just root) >>= (@?= expected root))
  where
    expected root = Text.take 32768 full <> "\n# AGENTS.md sections truncated at 32768 characters"
      where
        full = "# " <> Text.pack (root ++ "/AGENTS.md") <> "\n\n" <> Text.replicate 40000 "x"
-- | 规格：appendAgentsMd 只在两侧都非空时以两个空行连接。
-- 背景：连接形状影响规则可读性；多余空行会让提示尾部异常。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
appendShape :: Assertion
appendShape =
  sequence_
    [ appendAgentsMd "" "prompt" @?= "prompt",
      appendAgentsMd "section" "" @?= "section",
      appendAgentsMd "section" "prompt" @?= "prompt\n\n\nsection"
    ]
-- | 规格：cwd 解析成功时附加 AGENTS.md 段，否则保持原提示。
-- 背景：规则注入必须与 cwd 绑定；无 cwd 注入会让全局提示被污染。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
resolveAgentsMd :: Assertion
resolveAgentsMd =
  withWorkDir $ \root ->
    newTlsManager >>= \manager ->
      testRuntime okModel [] Parallel >>= \base ->
        writeFile (root ++ "/AGENTS.md") "project rules"
          *> ( (,,) <$> inject manager base (emptyThreadConfig {configCwd = CwdPath root})
                <*> inject manager base (emptyThreadConfig {configCwd = CwdPath root, configSystemPrompt = Just "session"})
                <*> inject manager base emptyThreadConfig
             )
          >>= \(withCwd, withSession, withoutCwd) ->
            sequence_
              [ runtimeSystemPrompt withCwd @?= "base prompt\n\n\n# " <> Text.pack (root ++ "/AGENTS.md") <> "\n\nproject rules",
                runtimeSystemPrompt withSession @?= "session\n\n\n# " <> Text.pack (root ++ "/AGENTS.md") <> "\n\nproject rules",
                runtimeSystemPrompt withoutCwd @?= "base prompt"
              ]
  where
    inject manager base config =
      resolveRuntime manager testProvider Nothing base {runtimeSystemPrompt = "base prompt"} config Map.empty Map.empty >>= \resolved ->
        agentsMdSection (cwdPath (configCwd config)) <&> \section ->
          resolved {runtimeSystemPrompt = appendAgentsMd section (runtimeSystemPrompt resolved)}
