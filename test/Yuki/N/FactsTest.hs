-- | 事实库测试
--
-- 覆盖：记忆化去重、检索槽、坏 JSON 静默、预算/冷却、文件往返、归档/作废/遗留行与重放。
-- 边界：覆盖 Yuki.N.Facts；保留策略见 GrowthTest。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.FactsTest
  ( factsTests,
    memorizeDedup,
    retrievalSlot,
    badJsonSilent,
    budgetCapped,
    cooldownThrottles,
    fileRoundTrip,
    retrievalReplay,
    archiveStale,
    invalidateByContent,
    watcherInvalidates,
    legacyLine,
    invalidateReplay
  )
where
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import Data.Functor (($>))
import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Exception ()
import Control.Monad ()
import Data.Aeson
import Data.Aeson.Types ()
import Data.Bool ()
import Data.ByteString ()
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Foldable (traverse_)
import Data.IORef
import Data.List ()
import Data.Maybe ()
import Data.Text ()
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
import Yuki.N.Facts
import Yuki.N.Memory
import Yuki.N.Agent
import Yuki.N.Model
import Yuki.N.Journal
import Yuki.N.Replay
import Yuki.N.AGUI.Types ()
import Yuki.N.AGUI.Event ()
import Yuki.N.Background ()
import Yuki.N.ThreadConfig ()
import Yuki.N.TestSupport


factsTests :: TestTree
factsTests =
  testGroup
    "facts"
    [ testCase "memorizes watcher facts, drops malformed entries and dedupes by content" memorizeDedup,
      testCase "materializes a retrieval slot after the briefing and touches hits" retrievalSlot,
      testCase "stays inert on an unparseable watcher decision" badJsonSilent,
      testCase "caps retrievals at three per run" budgetCapped,
      testCase "cools a repeated query down for five watcher rounds" cooldownThrottles,
      testCase "persists facts as jsonl across restarts" fileRoundTrip,
      testCase "replays a journaled run with a retrieval slot without divergence" retrievalReplay,
      testCase "archives old untouched facts, hiding them from search but not the list" archiveStale,
      testCase "invalidates a fact by content and reports a miss" invalidateByContent,
      testCase "voids a fact named by a watcher invalidate decision" watcherInvalidates,
      testCase "parses fact lines written before archived and void existed" legacyLine,
      testCase "replays a journaled run with an invalidate decision without divergence" invalidateReplay
    ]
slotMarked :: ChatMessage -> Bool
slotMarked (ChatSystem text) = candidatesMarker `Text.isInfixOf` text
slotMarked _ = False
invalidateWatcher :: Model
invalidateWatcher =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          "{\"summary\":\"s\",\"memorize\":[],\"retrieve\":null,\"invalidate\":[\
          \{\"content\":\"the deploy target is fly.io\",\"reason\":\"moved to railway\"},\
          \{\"content\":42}]}"
      )
      $> Stop
-- | 规格：watcher 记忆决策落库：重复内容去重、坏条目丢弃、检索关闭。
-- 背景：事实库是轻量记忆层；重复与坏条目会让检索结果失真。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
memorizeDedup :: Assertion
memorizeDedup =
  newMemoryFactStore >>= \facts ->
    newMemoryThreadStore >>= \threads ->
      newMemoryState >>= \state ->
        transformContext (memoryHooks memorizeWatcher threads facts Nothing state) (sampleInput []) [ChatUser "hi"]
          *> factList facts
          >>= \case
            [fact] ->
              sequence_
                [ factContent fact @?= "uses ghcup for the toolchain",
                  factKind fact @?= FactProject,
                  factSource fact @?= "run",
                  factId fact @?= factIdFor "uses ghcup for the toolchain"
                ]
            other -> assertFailure ("unexpected facts: " <> show (length other))
  where
    memorizeWatcher =
      fakeModel $ \_ emit ->
        emit
          ( ModelTextDelta
              "{\"summary\":\"s\",\"memorize\":[\
              \{\"content\":\"uses ghcup for the toolchain\",\"kind\":\"project\",\"reason\":\"setup\"},\
              \{\"content\":\"uses ghcup for the toolchain\",\"kind\":\"project\",\"reason\":\"setup\"},\
              \{\"content\":\"bogus entry\",\"kind\":\"nonsense\",\"reason\":\"bad\"}],\
              \\"retrieve\":null}"
          )
          $> Stop
-- | 规格：briefing 之后物化检索槽（kind+content），命中更新 touch，重复变换幂等。
-- 背景：检索槽是事实注入的位置契约；槽位错误会让模型看不到检索结果。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
retrievalSlot :: Assertion
retrievalSlot =
  newMemoryFactStore >>= \facts ->
    factAdd facts "the deploy target is fly.io" FactProject "run-0"
      *> newMemoryThreadStore
      >>= \threads ->
        threadSaveEpisode threads "thread" (Episode "run-0" "earlier" 1700000000)
          *> newMemoryState
          >>= \state ->
            transformContext (memoryHooks retrieveWatcher threads facts Nothing state) (sampleInput []) [ChatUser "hi"]
              >>= \once ->
                transformContext (memoryHooks retrieveWatcher threads facts Nothing state) (sampleInput []) once
                  >>= \twice -> verify facts once twice
  where
    verify facts once twice =
      case once of
        [ChatSystem brief, ChatSystem slot, ChatUser "hi"] ->
          sequence_
            [ assertBool "briefing stays at the head" (briefingMarker `Text.isInfixOf` brief),
              assertBool "slot follows the briefing" (candidatesMarker `Text.isInfixOf` slot),
              assertBool "slot carries kind and content" (Text.isInfixOf "- project: the deploy target is fly.io" slot),
              twice @?= once
            ]
            *> touched facts
        other -> assertFailure ("unexpected context: " <> show (length other) <> " messages")
    touched facts =
      factList facts >>= \case
        [fact] ->
          sequence_
            [ factUseCount fact @?= 1,
              assertBool "lastUsed updated" (factLastUsed fact > 0)
            ]
        other -> assertFailure ("unexpected facts: " <> show (length other))
-- | 规格：watcher 输出不可解析时保持静默，不注入、不落库。
-- 背景：模型偶尔输出坏 JSON；崩溃会让主运行不可用，静默忽略是容错底线。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
badJsonSilent :: Assertion
badJsonSilent =
  newMemoryFactStore >>= \facts ->
    newMemoryThreadStore >>= \threads ->
      newMemoryState >>= \state ->
        transformContext (memoryHooks broken threads facts Nothing state) (sampleInput []) [ChatUser "hi"]
          >>= \messages ->
            factList facts
              >>= \stored ->
                sequence_
                  [ messages @?= [ChatUser "hi"],
                    stored @?= []
                  ]
  where
    broken = fakeModel (\_ emit -> emit (ModelTextDelta "{\"summary\": broken") $> Stop)
-- | 规格：每次运行最多三次事实检索。
-- 背景：检索预算防止事实层喧宾夺主；超预算会让上下文被检索噪声淹没。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
budgetCapped :: Assertion
budgetCapped =
  newMemoryFactStore >>= \facts ->
    newIORef (0 :: Int) >>= \searches ->
      newIORef (0 :: Int) >>= \calls ->
        newMemoryThreadStore >>= \threads ->
          newMemoryState >>= \state ->
            let hooks = memoryHooks (rotatingWatcher calls) threads (spySearch searches facts) Nothing state
             in traverse_ (transformContext hooks (sampleInput [])) (stagesFor 4)
                  *> (readIORef searches >>= (@?= 3))
-- | 规格：重复查询在五个 watcher 回合内被冷却。
-- 背景：冷却防止同一查询反复打库；失效会让检索次数预算被单查询耗尽。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cooldownThrottles :: Assertion
cooldownThrottles =
  newMemoryFactStore >>= \facts ->
    newIORef (0 :: Int) >>= \searches ->
      newMemoryThreadStore >>= \threads ->
        newMemoryState >>= \state ->
          let hooks = memoryHooks retrieveWatcher threads (spySearch searches facts) Nothing state
           in traverse_ (transformContext hooks (sampleInput [])) (stagesFor 7)
                *> (readIORef searches >>= (@?= 2))
rotatingWatcher :: IORef Int -> Model
rotatingWatcher counter =
  fakeModel $ \_ emit ->
    atomicModifyIORef' counter (\count -> (count + 1, count + 1))
      >>= \count ->
        emit
          ( ModelTextDelta
              ( "{\"summary\":\"s\",\"memorize\":[],\"retrieve\":{\"query\":\"q-"
                  <> Text.pack (show count)
                  <> "\",\"reason\":\"r\"}}"
              )
          )
          $> Stop
spySearch :: IORef Int -> FactStore -> FactStore
spySearch counter store =
  store {factSearch = \query -> modifyIORef' counter (+ 1) *> factSearch store query}
stagesFor :: Int -> [[ChatMessage]]
stagesFor rounds = [take amount dialog | amount <- take rounds [1, 3 ..]]
  where
    dialog =
      concatMap
        (\index -> [ChatUser ("u-" <> Text.pack (show index)), assistantReply])
        [(1 :: Int) ..]
assistantReply :: ChatMessage
assistantReply = ChatAssistant (AssistantTurn "m" (Just "ok") Nothing [])
-- | 规格：事实以 jsonl 持久化，重启后保留内容、touch 计数与 lastUsed。
-- 背景：事实必须跨重启存活；仅内存保留等于没有事实层。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
fileRoundTrip :: Assertion
fileRoundTrip =
  getTemporaryDirectory >>= \tmp ->
    newId >>= \identifier ->
      let dir = tmp ++ "/" ++ Text.unpack identifier
       in newFactStore dir
            >>= \store ->
              factAdd store "prefers point-free style" FactPreference "run-1"
                >>= \fact ->
                  factAdd store "prefers point-free style" FactPreference "run-1"
                    *> factTouch store [fact]
                    *> newFactStore dir
                    >>= verify
  where
    verify reloaded =
      factList reloaded >>= \case
        [fact] ->
          sequence_
            [ factId fact @?= factIdFor "prefers point-free style",
              factUseCount fact @?= 1,
              assertBool "lastUsed persisted" (factLastUsed fact > 0)
            ]
        other -> assertFailure ("unexpected facts: " <> show (length other))
-- | 规格：带检索槽的 journaled 运行可无分歧重放，请求携带检索槽。
-- 背景：重放必须复现检索注入；否则重放上下文与真实执行不一致。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
retrievalReplay :: Assertion
retrievalReplay =
  newMemoryFactStore >>= \facts ->
    factAdd facts "the deploy target is fly.io" FactProject "run-0"
      *> newMemoryThreadStore
      >>= \threads ->
        newMemoryJournal
        >>= \(journal, readEntries) ->
          newMemoryState >>= \state ->
            testRuntime mainModel [] Parallel >>= \base ->
              collectEvents base {runtimeHooks = hooks facts threads journal state, runtimeJournal = Just journal} (sampleInput [])
                >>= \events ->
                  readEntries >>= \recorded ->
                  replayWithStores threads facts Nothing recorded >>= \report ->
                      sequence_
                        [ fmap reportDivergence report @?= Right Nothing,
                          fmap reportEvents report @?= Right (length events),
                          assertBool "journaled request carries the retrieval slot" (any slotted recorded)
                        ]
  where
    hooks facts threads journal state = memoryHooks retrieveWatcher threads facts (Just journal) state
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)
    slotted (Entry _ _ _ (ModelRequestEntry request)) = any slotMarked (requestMessages request)
    slotted _ = False
-- | 规格：旧而未触碰的事实被归档：搜索不可见、列表保留 archived 标记并持久化。
-- 背景：归档是保留策略的核心；误删或误显都会破坏事实层可用性。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
archiveStale :: Assertion
archiveStale =
  getTemporaryDirectory >>= \tmp ->
    newId >>= \identifier ->
      let dir = tmp ++ "/" ++ Text.unpack identifier
       in createDirectoryIfMissing True dir
            *> LazyByteString.writeFile (dir ++ "/facts.jsonl") seed
            *> newFactStore dir
            >>= exercise dir
  where
    seed = LazyByteString.intercalate "\n" (fmap encode specimens) <> "\n"
    specimens =
      [ Fact (factIdFor "legacy deploy target") "legacy deploy target" FactProject "run-0" 1000 0 0 False False,
        Fact (factIdFor "touched old detail") "touched old detail" FactProject "run-0" 1000 100 3 False False,
        Fact (factIdFor "fresh detail") "fresh detail" FactProject "run-0" 2000 0 0 False False
      ]
    exercise dir store =
      factArchiveOlderThan store 1500 >>= \count ->
        factSearch store "legacy deploy" >>= \hits ->
          factSearch store "fresh" >>= \survivors ->
            factList store >>= \listed ->
              newFactStore dir >>= \reloaded ->
                factList reloaded >>= \persisted ->
                  sequence_
                    [ count @?= 1,
                      hits @?= [],
                      length survivors @?= 1,
                      fmap factArchived listed @?= [False, True, False],
                      fmap factArchived persisted @?= [False, True, False]
                    ]
-- | 规格：按内容作废事实并报告命中/未命中，作废后搜索不可见。
-- 背景：事实修正依赖作废；作废失败会让过时事实继续误导。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
invalidateByContent :: Assertion
invalidateByContent =
  newMemoryFactStore >>= \facts ->
    factAdd facts "the deploy target is fly.io" FactProject "run-0"
      *> factInvalidate facts "the deploy target is fly.io"
      >>= \hit ->
        factInvalidate facts "no such fact" >>= \miss ->
          factSearch facts "deploy target" >>= \hits ->
            factList facts >>= \listed ->
              sequence_
                [ hit @?= True,
                  miss @?= False,
                  hits @?= [],
                  fmap factVoid listed @?= [True]
                ]
-- | 规格：watcher 的 invalidate 决策按内容作废事实，坏条目被忽略。
-- 背景：模型驱动的作废是自动纠错通道；坏条目必须被忽略而非崩溃。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
watcherInvalidates :: Assertion
watcherInvalidates =
  newMemoryFactStore >>= \facts ->
    factAdd facts "the deploy target is fly.io" FactProject "run-0"
      *> newMemoryThreadStore
      >>= \threads ->
        newMemoryState >>= \state ->
          transformContext (memoryHooks invalidateWatcher threads facts Nothing state) (sampleInput []) [ChatUser "hi"]
            *> factList facts
            >>= \listed ->
              factSearch facts "deploy target" >>= \hits ->
                sequence_
                  [ fmap factVoid listed @?= [True],
                    hits @?= []
                  ]
-- | 规格：旧版事实行（无 archived/void 字段）仍可解析且默认未归档未作废。
-- 背景：向后兼容是升级前提；旧行解析失败会让既有事实库报废。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
legacyLine :: Assertion
legacyLine =
  either assertFailure verify $
    eitherDecode
      "{\"id\":\"fact-x\",\"content\":\"old line\",\"kind\":\"user\",\"source\":\"run\",\"created\":1,\"lastUsed\":2,\"useCount\":3}"
  where
    verify fact =
      sequence_
        [ factArchived fact @?= False,
          factVoid fact @?= False,
          factUseCount fact @?= 3
        ]
-- | 规格：带作废决策的 journaled 运行可无分歧重放。
-- 背景：重放必须复现作废；否则重放侧保留已作废事实。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
invalidateReplay :: Assertion
invalidateReplay =
  newMemoryFactStore >>= \facts ->
    factAdd facts "the deploy target is fly.io" FactProject "run-0"
      *> newMemoryThreadStore
      >>= \threads ->
        newMemoryJournal >>= \(journal, readEntries) ->
          newMemoryState >>= \state ->
            testRuntime mainModel [] Parallel >>= \base ->
              collectEvents base {runtimeHooks = hooks facts threads journal state, runtimeJournal = Just journal} (sampleInput [])
                >>= \events ->
                  readEntries >>= \recorded ->
                    replayWithStores threads facts Nothing recorded >>= \report ->
                      sequence_
                        [ fmap reportDivergence report @?= Right Nothing,
                          fmap reportEvents report @?= Right (length events)
                        ]
  where
    hooks facts threads journal state = memoryHooks invalidateWatcher threads facts (Just journal) state
    mainModel = fakeModel (\_ emit -> emit (ModelTextDelta "hi") $> Stop)
