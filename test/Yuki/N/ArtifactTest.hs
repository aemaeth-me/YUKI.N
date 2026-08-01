-- | 工件存储测试
--
-- 覆盖：重复大结果 stub 化、小结果内联、预览、引导去重、回源读取与重放。
-- 边界：覆盖 Yuki.N.Artifact 契约；保留策略见 GrowthTest。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.ArtifactTest
  ( artifactTests,
    elidesDuplicate,
    keepsSmall,
    artifactPreview,
    guidedArtifactOnce,
    readsBack,
    replaysClean
  )
where
import Control.Exception (throwIO)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import Data.Functor (($>))
import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Monad ()
import Data.Aeson
import Data.Aeson.Types ()
import Data.Bool ()
import Data.ByteString ()
import Data.Foldable ()
import Data.IORef
import Data.List ()
import Data.Maybe ()
import Data.Text (Text)
import qualified Data.Text as Text
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS ()
import Network.HTTP.Types ()
import Network.Wai ()
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test ()
import System.Exit ()
import System.FilePath ()
import System.Process ()
import System.Timeout ()
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Artifact
import Yuki.N.Agent
import Yuki.N.Model
import Yuki.N.Journal
import Yuki.N.Replay
import Yuki.N.AGUI.Types ()
import Yuki.N.AGUI.Event
import Yuki.N.Background ()
import Yuki.N.TestSupport


artifactTests :: TestTree
artifactTests =
  testGroup
    "artifacts"
    [ testCase "elides a duplicate large tool result as a reference stub" elidesDuplicate,
      testCase "keeps small duplicate results inline" keepsSmall,
      testCase "lists a human preview and accepts legacy metadata" artifactPreview,
      testCase "does not store a tool-produced artifact guidance twice" guidedArtifactOnce,
      testCase "reads back a stored artifact in full" readsBack,
      testCase "replays a journaled run with duplicates without divergence" replaysClean
    ]
withArtifactStore :: (ArtifactStore -> Assertion) -> Assertion
withArtifactStore action =
  getTemporaryDirectory >>= \tmp ->
    newId >>= \identifier ->
      let dir = tmp ++ "/" ++ Text.unpack identifier
       in createDirectoryIfMissing True dir *> newArtifactStore dir >>= action
dupCalls :: Text -> IORef Int -> IORef [ChatMessage] -> Model
dupCalls name turns captured =
  fakeModel $ \modelRequest emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next))
      >>= turn modelRequest emit
  where
    turn _ emit 1 =
      emit (ModelToolCallDelta 0 (Just "call-a") (Just name) "{}")
        *> emit (ModelToolCallDelta 1 (Just "call-b") (Just name) "{}")
        $> ToolUse
    turn modelRequest emit 2 =
      writeIORef captured (requestMessages modelRequest) *> emit (ModelTextDelta "done") $> Stop
    turn _ _ _ = throwIO (ProviderFailure "unexpected model turn")
-- | 规格：大体积重复工具结果被替换为引用 stub，原值保留在事件流。
-- 背景：重复大结果会成倍消耗上下文；stub 必须可辨识、可回源，事件流仍保留完整值。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
elidesDuplicate :: Assertion
elidesDuplicate =
  withArtifactStore $ \store ->
    newIORef (0 :: Int) >>= \turns ->
      newIORef [] >>= \captured ->
        testRuntime (dupCalls "big" turns captured) [staticTool "big" bigContent] Sequential >>= \base ->
          collectEvents base {runtimeArtifactStore = Just store} (sampleInput []) >>= \events ->
            readIORef captured >>= verify events
  where
    verify events messages =
      case [content | ChatToolResult _ content <- messages] of
        [first, second] ->
          sequence_
            [ first @?= bigContent,
              assertBool "second result is a reference stub" (isArtifactStub second),
              assertBool "stub names the artifact" (Text.isInfixOf (artifactIdFor bigContent) second),
              assertBool "stub keeps an excerpt" (Text.isInfixOf (Text.take 200 bigContent) second),
              [content | ToolCallResult _ _ content <- events] @?= [bigContent, bigContent]
            ]
        other -> assertFailure ("unexpected tool results: " <> show (length other))
-- | 规格：小体积重复结果保持内联，不产生 stub。
-- 背景：内联/引用阈值必须一致；小结果 stub 化会无谓增加读取成本。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
keepsSmall :: Assertion
keepsSmall =
  withArtifactStore $ \store ->
    newIORef (0 :: Int) >>= \turns ->
      newIORef [] >>= \captured ->
        testRuntime (dupCalls "small" turns captured) [staticTool "small" "tiny result"] Sequential >>= \base ->
          collectEvents base {runtimeArtifactStore = Just store} (sampleInput [])
            *> readIORef captured
            >>= \messages ->
              [content | ChatToolResult _ content <- messages] @?= ["tiny result", "tiny result"]
-- | 规格：工件列表提供空白归一化的预览并兼容旧版元数据 JSON。
-- 背景：列表预览是前端与旧数据的兼容契约；解析失败会让历史工件不可见。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
artifactPreview :: Assertion
artifactPreview =
  newMemoryArtifactStore >>= \store ->
    artifactSave store "shell" "alpha\n\n beta\tgamma"
      *> artifactList store
      >>= \case
        [meta] ->
          sequence_
            [ artifactMetaPreview meta @?= "alpha beta gamma",
              eitherDecode
                "{\"id\":\"art-legacy\",\"toolName\":\"shell\",\"chars\":3,\"time\":1}"
                @?= Right (ArtifactMeta "art-legacy" "shell" "" 3 1)
            ]
        metas -> assertFailure ("expected one artifact, got " <> show (length metas))
-- | 规格：已存储工件的引导文本不会被二次存储。
-- 背景：工具输出中引用既有工件时重复落盘会污染存储并撑爆保留限额。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
guidedArtifactOnce :: Assertion
guidedArtifactOnce =
  newMemoryArtifactStore >>= \store ->
    artifactSave store "shell" bigContent >>= \identifier ->
      newIORef (0 :: Int) >>= \turns ->
        newIORef [] >>= \captured ->
          let guided =
                Text.take 220 bigContent
                  <> "\n[artifact "
                  <> identifier
                  <> ": full shell output; call artifact_read]"
           in testRuntime (dupCalls "shell" turns captured) [staticTool "shell" guided] Sequential
                >>= \base ->
                  collectEvents base {runtimeArtifactStore = Just store} (sampleInput [])
                    *> artifactList store
                    >>= \metas ->
                      sequence_
                        [ length metas @?= 1,
                          fmap artifactMetaId metas @?= [identifier]
                        ]
-- | 规格：artifact_read 能取回完整存储内容供模型消费。
-- 背景：回源读取是 stub 闭环的另一半；取不回原值等于数据丢失。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
readsBack :: Assertion
readsBack =
  withArtifactStore $ \store ->
    artifactSave store "big" bigContent >>= \identifier ->
      newIORef [] >>= \captured ->
        testRuntime (readBackModel identifier captured) [artifactReadTool store] Sequential >>= \base ->
          collectEvents base {runtimeArtifactStore = Just store} (sampleInput [])
            *> readIORef captured
            >>= \messages ->
              [content | ChatToolResult _ content <- messages] @?= [bigContent]
readBackModel :: Text -> IORef [ChatMessage] -> Model
readBackModel identifier captured =
  fakeModel $ \modelRequest emit ->
    case lastMessage modelRequest of
      Just (ChatToolResult {}) ->
        writeIORef captured (requestMessages modelRequest) *> emit (ModelTextDelta "done") $> Stop
      _ ->
        emit (ModelToolCallDelta 0 (Just "call-read") (Just artifactReadToolName) ("{\"id\":\"" <> identifier <> "\"}"))
          $> ToolUse
-- | 规格：带重复工件的 journaled 运行可无分歧重放。
-- 背景：重放必须复现同样的 stub/原值布局；否则重放上下文与真实执行不一致。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
replaysClean :: Assertion
replaysClean =
  withArtifactStore $ \store ->
    newMemoryJournal >>= \(journal, readEntries) ->
      newIORef (0 :: Int) >>= \turns ->
        newIORef [] >>= \captured ->
          testRuntime (dupCalls "big" turns captured) [staticTool "big" bigContent] Sequential >>= \base ->
            collectEvents base {runtimeJournal = Just journal, runtimeArtifactStore = Just store} (sampleInput [])
              >>= \events ->
                readEntries >>= \recorded ->
                  replayEntries defaultHooks Nothing recorded >>= \report ->
                    sequence_
                      [ fmap reportDivergence report @?= Right Nothing,
                        fmap reportEvents report @?= Right (length events)
                      ]
