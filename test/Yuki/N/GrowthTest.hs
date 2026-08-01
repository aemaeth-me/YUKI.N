-- | 有界本地状态测试
--
-- 覆盖：记忆/journal/工件/事实的保留上限与重启一致性。
-- 边界：覆盖各存储的保留策略与文件压缩。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.GrowthTest
  ( growthTests,
    memoryStateBounded,
    journalRetention,
    journalInspectionCache,
    artifactRetention,
    factRetention,
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
import Data.Foldable (traverse_)
import Data.Functor ()
import Data.IORef ()
import Data.List ()
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text ()
import Data.Text qualified as Text
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS ()
import Network.HTTP.Types
import Network.Wai ()
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test
import System.Directory ()
import System.Exit ()
import System.FilePath ()
import System.Process ()
import System.Timeout ()
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event ()
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Artifact
import Yuki.N.Background ()
import Yuki.N.Facts
import Yuki.N.Inspect
import Yuki.N.Journal
import Yuki.N.Memory
import Yuki.N.Model ()
import Yuki.N.Server
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig ()

growthTests :: TestTree
growthTests =
  testGroup
    "bounded local state"
    [ testCase "run completion clears transient memory and caps thread episodes" memoryStateBounded,
      testCase "journal keeps complete recent runs and preserves sequence across compaction" journalRetention,
      testCase "live journal inspection uses the in-memory index" journalInspectionCache,
      testCase "artifact retention removes old objects and compacts the index" artifactRetention,
      testCase "fact retention caps resident state and compacts the file" factRetention
    ]

-- | 规格：80 次运行后瞬态记忆清零、cooldown 有界、线程 episode 封顶 64。
-- 背景：记忆必须按预算收敛；无界增长会让长期运行退化。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
memoryStateBounded :: Assertion
memoryStateBounded =
  newMemoryFactStore >>= \facts ->
    factAdd facts "the deploy target is fly.io" FactProject "seed"
      *> newMemoryThreadStore
      >>= \threads ->
        newMemoryState >>= \state ->
          testRuntime okModel [] Parallel >>= \base ->
            let runtime = base {runtimeHooks = memoryHooks retrieveWatcher threads facts Nothing state}
                run index =
                  collectEvents
                    runtime
                    ((sampleInput []) {runId = "bounded-" <> Text.pack (show index)})
             in traverse_ run [(1 :: Int) .. 80]
                  *> ( memoryTransientCounts state
                         >>= \(briefings, candidates, budgets, cooldowns) ->
                           threadBrief threads "thread" >>= \brief ->
                             sequence_
                               [ briefings @?= 0,
                                 candidates @?= 0,
                                 budgets @?= 0,
                                 assertBool "cooldowns remain bounded by recent queries" (cooldowns <= 1),
                                 fmap (length . briefEpisodes) brief @?= Just 64
                               ]
                     )

-- | 规格：journal 保留完整近期运行，压缩后 seq 全局单调且跨重启继续。
-- 背景：保留策略是磁盘成本的闸门；seq 断裂会破坏重放顺序。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
journalRetention :: Assertion
journalRetention =
  withWorkDir $ \dir ->
    newFileJournalWithLimit 2 dir >>= \journal ->
      traverse_ (recordRun journal) ["run-1", "run-2", "run-3"]
        *> (journalSnapshot journal >>= verify [2, 3, 4, 5] ["run-2", "run-3"])
        *> ( newFileJournalWithLimit 2 dir >>= \reopened ->
               recordRun reopened "run-4"
                 *> (journalSnapshot reopened >>= verify [4, 5, 6, 7] ["run-3", "run-4"])
           )
 where
  settings = RunSettings 8 Parallel "" 1 Nothing Nothing Nothing
  recordRun journal run =
    let input = (sampleInput []) {runId = run}
        scoped = subJournal run journal
     in recordMaybe (Just scoped) (RunBegin input settings)
          *> recordMaybe (Just scoped) (IdEntry ("id-" <> run))
  verify seqs runs entries =
    sequence_
      [ fmap entrySeq entries @?= seqs,
        [runId input | Entry _ scope _ (RunBegin input _) <- entries, length scope == 1] @?= runs
      ]

-- | 规格：journal 检查端点使用内存索引，磁盘损坏不影响读取。
-- 背景：检查路径必须稳定；磁盘尾部损坏拖垮检查界面会掩盖真实故障。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
journalInspectionCache :: Assertion
journalInspectionCache =
  withWorkDir $ \dir ->
    newFileJournal dir >>= \journal ->
      recordMaybe (Just journal) (IdEntry "cached")
        *> ( testRuntime okModel [] Parallel >>= \base ->
               let path = journalFilePath dir
                   inspection = withLiveJournal journal (newInspection Nothing Nothing (Just path) Nothing)
                   app = application Nothing (Just inspection) Nothing Nothing (const (pure base))
                in LazyByteString.writeFile path "{broken"
                     *> ( runSession (request (httpGet ["journal"])) app
                            >>= \response ->
                              sequence_
                                [ simpleStatus response @?= status200,
                                  either assertFailure (\entries -> fmap entryKind entries @?= [IdEntry "cached"]) (eitherDecode (simpleBody response))
                                ]
                        )
           )

-- | 规格：工件保留移除旧对象并压缩索引文件。
-- 背景：工件目录无界增长会耗尽磁盘；索引压缩保持重启后一致。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
artifactRetention :: Assertion
artifactRetention =
  withWorkDir $ \dir ->
    newArtifactStoreWithLimit 2 dir >>= \store ->
      traverse (artifactSave store "tool") ["first", "second", "third"] >>= \identifiers ->
        artifactList store >>= \listed ->
          artifactFetch store (fromMaybe "" (listToMaybe identifiers)) >>= \oldest ->
            newArtifactStoreWithLimit 2 dir >>= \reopened ->
              artifactList reopened >>= \afterRestart ->
                sequence_
                  [ length listed @?= 2,
                    oldest @?= Nothing,
                    length afterRestart @?= 2,
                    LazyByteString.readFile (dir ++ "/index.jsonl")
                      >>= \bytes -> length (filter (not . LazyByteString.null) (LazyByteString.split 10 bytes)) @?= 2
                  ]

-- | 规格：事实保留封顶驻留状态并压缩文件。
-- 背景：事实库无界增长会拖慢检索；文件压缩保证重启后一致。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
factRetention :: Assertion
factRetention =
  withWorkDir $ \dir ->
    newFactStoreWithLimit 2 dir >>= \store ->
      traverse_ (\content -> factAdd store content FactProject "run") ["first fact", "second fact", "third fact"]
        *> ( factList store >>= \listed ->
               newFactStoreWithLimit 2 dir >>= \reopened ->
                 factList reopened >>= \afterRestart ->
                   LazyByteString.readFile (dir ++ "/facts.jsonl") >>= \bytes ->
                     sequence_
                       [ length listed @?= 2,
                         assertBool "newest fact is retained" (any ((== "third fact") . factContent) listed),
                         length afterRestart @?= 2,
                         length (filter (not . LazyByteString.null) (LazyByteString.split 10 bytes)) @?= 2
                       ]
           )
