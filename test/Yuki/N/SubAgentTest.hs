-- | 子代理委派测试
--
-- 覆盖：委派闭环、深度耗尽、能力描述、cwd 继承与 sub_agent 注册条件。
-- 边界：不覆盖子代理内部工具集（见 ToolsTest）。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.SubAgentTest
  ( subAgentTests,
    capabilityDescription,
    inheritedShell,
    registration,
    delegation,
    depthExhausted
  )
where
import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Exception ()
import Control.Monad ()
import Data.Aeson
import Data.Bool ()
import Data.ByteString ()
import Data.Foldable ()
import Data.IORef ()
import Data.List ()
import qualified Data.Map.Strict as Map
import Data.Maybe ()
import Data.Text (Text)
import qualified Data.Text as Text
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types ()
import Network.Wai ()
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test ()
import System.Directory ()
import System.Exit ()
import System.FilePath ()
import System.Process ()
import System.Timeout ()
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Agent
import Yuki.N.Model
import Yuki.N.Journal
import Yuki.N.Replay
import Yuki.N.ThreadConfig
import Yuki.N.Provider.OpenAI ()
import Yuki.N.AGUI.Types
import Yuki.N.AGUI.Event
import Yuki.N.Tools ()
import Yuki.N.SubAgent
import Yuki.N.TestSupport
import Data.Functor (($>))
import Data.Aeson.Types (parseMaybe)


subAgentTests :: TestTree
subAgentTests =
  testGroup
    "sub-agents"
    [ testCase "delegates to a scoped sub-run and replays cleanly" delegation,
      testCase "refuses delegation at depth zero" depthExhausted,
      testCase "advertises the child's exact inherited tools" capabilityDescription,
      testCase "a resolved cwd lets the child execute a local shell request" inheritedShell,
      testCase "resolveRuntime registers sub_agent only above depth zero" registration
    ]
-- | 规格：sub_agent 工具描述列举子代继承的确切工具（shell、fs_read）且不包含自身。
-- 背景：子代理能力描述是模型决策是否委派的依据；漏列或自我引用会误导模型。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
capabilityDescription :: Assertion
capabilityDescription =
  testRuntime okModel [staticTool "shell" "ok", staticTool "fs_read" "ok"] Parallel
    >>= \base ->
      case Map.lookup "sub_agent" (runtimeTools (registerSubAgent base)) of
        Nothing -> assertFailure "missing sub_agent"
        Just backend ->
          let description = toolDescription (backendToolSpec backend)
           in sequence_
                [ assertBool "description names shell" ("shell" `Text.isInfixOf` description),
                  assertBool "description names fs_read" ("fs_read" `Text.isInfixOf` description),
                  assertBool "description excludes itself" (not ("sub_agent" `Text.isInfixOf` description))
                ]
-- | 规格：已解析 cwd 的子代理可执行本地 shell 请求，父代收到子回答并暴露嵌套 shell 事件。
-- 背景：委派必须继承工作目录等环境；否则子代理与父代行为不一致。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
inheritedShell :: Assertion
inheritedShell =
  withWorkDir $ \dir ->
    newTlsManager >>= \manager ->
      testRuntime subShellModel [] Sequential >>= \base ->
        resolveRuntime
          manager
          testProvider
          Nothing
          base
          (emptyThreadConfig {configCwd = CwdPath dir})
          Map.empty
          Map.empty
          >>= \runtime ->
            collectEvents runtime (sampleInput [])
              >>= \events ->
                sequence_
                  [ assertBool "parent receives the child answer" (any childAnswer events),
                    assertBool "nested event exposes the shell call" (any nestedShell events)
                  ]
childAnswer :: Event -> Bool
childAnswer (ToolCallResult _ "call-delegate" content) = "child-ok" `Text.isInfixOf` content
childAnswer _ = False
nestedShell :: Event -> Bool
nestedShell (Custom "agent.sub" value) =
  parseMaybe
    ( withObject "agent.sub" $ \fields ->
        fields .: "event"
          >>= withObject
            "event"
            (\event -> (,) <$> event .: "type" <*> event .:? "toolCallName")
    )
    value
    == Just ("TOOL_CALL_START" :: Text, Just ("shell" :: Text))
nestedShell _ = False
-- | 规格：resolveRuntime 只在深度 >0 时注册 sub_agent 工具。
-- 背景：深度 0 的子代理不应再委派；注册失控会造成无限递归。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
registration :: Assertion
registration =
  newTlsManager >>= \manager ->
    testRuntime okModel [] Parallel >>= \base ->
      let resolved depth = resolveRuntime manager testProvider Nothing base {runtimeDepth = depth} emptyThreadConfig Map.empty Map.empty
       in (,,) <$> resolved 1 <*> resolved 2 <*> resolved 0 >>= \(one, two, zero) ->
            sequence_
              [ assertBool "depth one registers" (Map.member "sub_agent" (runtimeTools one)),
                assertBool "deeper still registers" (Map.member "sub_agent" (runtimeTools two)),
                assertBool "depth zero omits" (Map.notMember "sub_agent" (runtimeTools zero)),
                runtimeDepth one @?= 1
              ]
-- | 规格：委派到受限子运行并 journal 嵌套 scope，可无分歧重放。
-- 背景：委派是核心能力；scope 嵌套记录错误会让重放与审计无法还原层次。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
delegation :: Assertion
delegation =
  newMemoryJournal >>= \(journal, readEntries) ->
    delegateRuntime journal 1 >>= \runtime ->
      collectEvents runtime (sampleInput [])
        >>= \events ->
          readEntries
            >>= \recorded ->
              replayEntries defaultHooks Nothing recorded
                >>= \report ->
                  sequence_
                    [ [content | ToolCallResult _ "call-delegate" content <- events] @?= ["sub result"],
                      assertBool "sub-run events are scoped" (any isSubEvent events),
                      assertBool "journal nests the sub-run scope" (any ((== 2) . length . entryScope) recorded),
                      fmap reportDivergence report @?= Right Nothing
                    ]
-- | 规格：深度 0 时委派被拒绝且返回说明性结果，不产生子运行事件。
-- 背景：深度耗尽必须优雅失败而非崩溃或死循环。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
depthExhausted :: Assertion
depthExhausted =
  newMemoryJournal >>= \(journal, _) ->
    delegateRuntime journal 0 >>= \runtime ->
      collectEvents runtime (sampleInput [])
        >>= \events ->
          sequence_
            [ [content | ToolCallResult _ "call-delegate" content <- events] @?= ["delegation depth exhausted"],
              assertBool "no sub-run events" (all (not . isSubEvent) events)
            ]
isSubEvent :: Event -> Bool
isSubEvent (Custom "agent.sub" _) = True
isSubEvent _ = False
subShellModel :: Model
subShellModel =
  fakeModel $ \request emit ->
    case lastMessage request of
      Just (ChatToolResult "call-delegate" _) -> emit (ModelTextDelta "parent done") $> Stop
      Just (ChatToolResult "call-shell" content) -> emit (ModelTextDelta content) $> Stop
      Just (ChatUser "run local shell") ->
        emit (ModelToolCallDelta 0 (Just "call-shell") (Just "shell") "{\"command\":\"printf child-ok\"}")
          $> ToolUse
      _ ->
        emit (ModelToolCallDelta 0 (Just "call-delegate") (Just "sub_agent") "{\"prompt\":\"run local shell\"}")
          $> ToolUse
delegateRuntime :: Journal -> Int -> IO Runtime
delegateRuntime journal depth =
  testRuntime subAgentModel [] Parallel >>= \base ->
    let tools = Map.fromList [("delegate", subAgentTool "delegate" "run a sub-agent" runtime)]
        runtime = base {runtimeJournal = Just journal, runtimeTools = tools, runtimeDepth = depth}
     in pure runtime
subAgentModel :: Model
subAgentModel =
  fakeModel $ \request emit ->
    case lastMessage request of
      Just (ChatToolResult {}) -> emit (ModelTextDelta "parent done") $> Stop
      Just (ChatUser "sub task") -> emit (ModelTextDelta "sub result") $> Stop
      _ ->
        emit (ModelToolCallDelta 0 (Just "call-delegate") (Just "delegate") "{\"prompt\":\"sub task\"}")
          $> ToolUse
