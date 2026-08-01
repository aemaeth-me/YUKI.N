-- | token 解剖报告测试
--
-- 覆盖：跨请求聚合 token 类别与空 journal 零报告。
-- 边界：覆盖 Yuki.N.Anatomy。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.AnatomyTest
  ( anatomyTests,
    aggregates,
    emptyJournal,
  )
where

import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Exception ()
import Control.Monad ()
import Data.Aeson
import Data.Aeson.Types ()
import Data.Bool ()
import Data.ByteString ()
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable ()
import Data.Functor ()
import Data.IORef ()
import Data.List ()
import Data.Maybe ()
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS ()
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
import Yuki.N.AGUI.Types
import Yuki.N.Agent ()
import Yuki.N.Anatomy
import Yuki.N.Journal
import Yuki.N.Model
import Yuki.N.TestSupport ()

anatomyTests :: TestTree
anatomyTests =
  testGroup
    "token anatomy"
    [ testCase "aggregates categories across model requests" aggregates,
      testCase "treats an empty journal as zero" emptyJournal
    ]

-- | 规格：anatomyEntries 跨多个模型请求聚合 token 类别，并区分总览与最近请求。
-- 背景：token 解剖是成本与上下文预算诊断的输入；聚合错误会误导优化决策。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
aggregates :: Assertion
aggregates =
  anatomyEntries specimen
    @?= AnatomyReport
      2
      (Anatomy 8 (2 * specimenSize) 20 36 8 32)
      (Just (Anatomy 4 specimenSize 12 24 4 16))

-- | 规格：空 journal 的解剖报告为零值。
-- 背景：空输入必须得到确定的零报告；否则诊断视图出现幽灵数据。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
emptyJournal :: Assertion
emptyJournal = anatomyEntries [] @?= AnatomyReport 0 mempty Nothing

specimen :: [Entry]
specimen =
  [ Entry 1 ["run"] Nothing (ModelRequestEntry firstRequest),
    Entry 2 ["run"] Nothing (ModelEventEntry (ModelTextDelta "noise")),
    Entry 3 ["run"] Nothing (ModelRequestEntry secondRequest)
  ]
specimenSize :: Int
specimenSize = fromIntegral (LazyByteString.length (encode [specimenSpec]))
specimenSpec :: ToolSpec
specimenSpec = ToolSpec "echo" "echo" (object ["type" .= ("object" :: Text)])
firstRequest :: ModelRequest
firstRequest =
  ModelRequest
    [ ChatSystem (Text.replicate 4 "s"),
      ChatUser (Text.replicate 8 "u"),
      ChatAssistant
        ( AssistantTurn
            "m1"
            (Just (Text.replicate 4 "b"))
            (Just (Text.replicate 4 "r"))
            [ModelToolCall "c1" "echo" (Text.replicate 8 "a")]
        ),
      ChatToolResult "c1" (Text.replicate 16 "t")
    ]
    [specimenSpec]
secondRequest :: ModelRequest
secondRequest =
  ModelRequest
    ( requestMessages firstRequest
        <> [ ChatAssistant (AssistantTurn "m2" (Just (Text.replicate 12 "b")) Nothing []),
             ChatUser (Text.replicate 4 "u")
           ]
    )
    [specimenSpec]
