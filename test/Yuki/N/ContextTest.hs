-- | 上下文治理与拼接测试
--
-- 覆盖：token 估算、压缩锚点/因果对、工件附件、overflow 重试、压缩后工具循环；context splice 目标选择、stub 幂等与配置解析。
-- 边界：覆盖 Yuki.N.Context 与 splice 相关契约。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.ContextTest
  ( spliceTests,
    countsChars,
    keepsRecent,
    targetGuards,
    inertWithoutStore,
    inertBelowThreshold,
    stubsAgedOnce,
    spliceReplay,
    spliceConfigParse,
    contextTests,
    contextTokenEstimate,
    compactsDialogue,
    compactionUserAnchor,
    keepsToolCausality,
    contextArtifact,
    contextJournalReplay,
    contextOverflowRetry,
    toolAfterCompaction,
    estimateAppendMonotonic,
    estimateMessageFloor,
    estimateTextPositive,
  )
where

import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Exception (throwIO)
import Control.Monad ()
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Bool ()
import Data.ByteString ()
import Data.Foldable ()
import Data.Functor (($>))
import Data.IORef
import Data.List ()
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
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
import Test.QuickCheck
  ( Gen,
    Property,
    elements,
    forAll,
    listOf,
    suchThat,
  )
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck (testProperty)
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Artifact
import Yuki.N.Background ()
import Yuki.N.Config
import Yuki.N.Context
import Yuki.N.Journal
import Yuki.N.Memory.LongTerm ()
import Yuki.N.Model
import Yuki.N.Provider.OpenAI ()
import Yuki.N.Replay
import Yuki.N.TestSupport
import Yuki.N.Transcript

spliceTests :: TestTree
spliceTests =
  testGroup
    "context splice"
    [ testCase "counts characters across message kinds" countsChars,
      testCase "targets only results older than the most recent keep" keepsRecent,
      testCase "skips stubs and small results when targeting" targetGuards,
      testCase "leaves history verbatim without an artifact store" inertWithoutStore,
      testCase "leaves history verbatim below the character threshold" inertBelowThreshold,
      testCase "stubs aged results once each, keeps originals fetchable and reports savings" stubsAgedOnce,
      testCase "replays a journaled run with a splice without divergence" spliceReplay,
      testCase "splice env vars default, accept valid and reject invalid" spliceConfigParse
    ]
bigA, bigB, bigC, bigD :: Text
bigA = Text.replicate 30 "alpha-0123"
bigB = Text.replicate 30 "beta-98765"
bigC = Text.replicate 30 "gamma-0123"
bigD = Text.replicate 30 "delta-9876"

-- | 规格：historyChars 跨 system/user/assistant/tool 各消息类型统计字符数。
-- 背景：字符预算是拼接与压缩的输入；统计错误会让阈值判断整体偏移。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
countsChars :: Assertion
countsChars =
  historyChars
    [ ChatSystem (Text.replicate 4 "s"),
      ChatUser (Text.replicate 8 "u"),
      ChatAssistant
        ( AssistantTurn
            "m"
            (Just (Text.replicate 4 "b"))
            (Just (Text.replicate 4 "r"))
            [ModelToolCall "c" "echo" (Text.replicate 8 "a")]
        ),
      ChatToolResult "c" (Text.replicate 16 "t")
    ]
    @?= 4 + 8 + 4 + 4 + 8 + 16

-- | 规格：spliceTargets 只选中最旧 keep 数之外的结果作为拼接目标。
-- 背景：最近的 keep 数结果必须保持内联可用；误伤近期结果会降低工具上下文可用性。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
keepsRecent :: Assertion
keepsRecent =
  spliceTargets 2 history @?= [(1, "c-1", bigA), (2, "c-2", bigB)]
 where
  history =
    [ ChatUser "u",
      ChatToolResult "c-1" bigA,
      ChatToolResult "c-2" bigB,
      ChatToolResult "c-3" bigC,
      ChatToolResult "c-4" bigD
    ]

-- | 规格：stub 结果与小结果不进入拼接目标。
-- 背景：重复拼接 stub 或小结果会浪费预算或产生嵌套引用；守卫失败会破坏工件语义。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
targetGuards :: Assertion
targetGuards =
  spliceTargets 0 history @?= [(2, "c-3", bigA)]
 where
  history =
    [ ChatToolResult "c-1" (artifactStub (artifactIdFor bigB) "big" bigB),
      ChatToolResult "c-2" "tiny",
      ChatToolResult "c-3" bigA
    ]

agedModel :: IORef Int -> IORef [ChatMessage] -> Model
agedModel turns captured =
  fakeModel $ \modelRequest emit ->
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next))
      >>= turn modelRequest emit
 where
  turn _ emit 1 = emit (ModelToolCallDelta 0 (Just "call-a") (Just "biga") "{}") $> ToolUse
  turn _ emit 2 = emit (ModelToolCallDelta 0 (Just "call-b") (Just "bigb") "{}") $> ToolUse
  turn _ emit 3 = emit (ModelToolCallDelta 0 (Just "call-c") (Just "bigc") "{}") $> ToolUse
  turn modelRequest emit 4 =
    writeIORef captured (requestMessages modelRequest) *> emit (ModelTextDelta "done") $> Stop
  turn _ _ _ = throwIO (ProviderFailure "unexpected model turn")
agedFixture :: Maybe ArtifactStore -> Maybe SpliceConfig -> (Runtime -> IO Runtime) -> IO ([Event], [ChatMessage])
agedFixture store splice configure =
  newIORef (0 :: Int) >>= \turns ->
    newIORef [] >>= \captured ->
      testRuntime (agedModel turns captured) [staticTool "biga" bigA, staticTool "bigb" bigB, staticTool "bigc" bigC] Sequential
        >>= \base ->
          configure base {runtimeArtifactStore = store, runtimeSplice = splice}
            >>= \runtime ->
              collectEvents runtime (sampleInput [])
                >>= \events -> (,) events <$> readIORef captured
spliceEvents :: [Event] -> [Value]
spliceEvents events = [value | Custom "context.splice" value <- events]

-- | 规格：没有工件存储时拼接完全不介入，历史逐字保留。
-- 背景：可选的拼接能力必须优雅降级；无存储时改动历史会让重放分歧。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
inertWithoutStore :: Assertion
inertWithoutStore =
  agedFixture Nothing (Just (SpliceConfig 400 1)) pure >>= \(events, messages) ->
    sequence_
      [ [content | ChatToolResult _ content <- messages] @?= [bigA, bigB, bigC],
        spliceEvents events @?= []
      ]

-- | 规格：历史低于字符阈值时拼接不介入。
-- 背景：阈值是拼接的开关；阈值内触发会产生无谓的 stub 噪音。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
inertBelowThreshold :: Assertion
inertBelowThreshold =
  newMemoryArtifactStore >>= \store ->
    agedFixture (Just store) (Just (SpliceConfig 200000 1)) pure >>= \(events, messages) ->
      sequence_
        [ [content | ChatToolResult _ content <- messages] @?= [bigA, bigB, bigC],
          spliceEvents events @?= []
        ]

-- | 规格：aged 结果被 stub 化一次（绝不重复 stub），原件可从工件存储取回，并上报 savedChars/keep。
-- 背景：stub 幂等性与原件可恢复性是拼接的两个硬约束；违反任一都会造成上下文不可逆丢失。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
stubsAgedOnce :: Assertion
stubsAgedOnce =
  newMemoryArtifactStore >>= \store ->
    agedFixture (Just store) (Just (SpliceConfig 400 1)) pure >>= \(events, messages) ->
      case [content | ChatToolResult _ content <- messages] of
        [aged, middle, recent] ->
          sequence_
            [ aged @?= stubA,
              middle @?= stubB,
              recent @?= bigC,
              assertBool "a stub is never re-stubbed" (Text.isInfixOf "tool=biga" aged)
            ]
            *> (artifactFetch store (artifactIdFor bigA) >>= (@?= Just bigA))
            *> (artifactFetch store (artifactIdFor bigB) >>= (@?= Just bigB))
            *> verifyEvents events
        other -> assertFailure ("unexpected tool results: " <> show (length other))
 where
  stubA = artifactStub (artifactIdFor bigA) "biga" bigA
  stubB = artifactStub (artifactIdFor bigB) "bigb" bigB
  verifyEvents events =
    case spliceEvents events of
      [first, second] ->
        sequence_
          [ parseMaybe (withObject "splice" (.: "stubbed")) first @?= Just (1 :: Int),
            parseMaybe (withObject "splice" (.: "savedChars")) first @?= Just (Text.length bigA - Text.length stubA),
            parseMaybe (withObject "splice" (.: "keep")) first @?= Just (1 :: Int),
            parseMaybe (withObject "splice" (.: "stubbed")) second @?= Just (1 :: Int),
            parseMaybe (withObject "splice" (.: "savedChars")) second @?= Just (Text.length bigB - Text.length stubB)
          ]
      other -> assertFailure ("expected two context.splice events, got " <> show (length other))

-- | 规格：带拼接的 journaled 运行可无分歧重放，journal 记录 stub 请求与拼接配置。
-- 背景：重放必须重建同样的 stub 视图；否则重放上下文与真实执行不一致。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
spliceReplay :: Assertion
spliceReplay =
  newMemoryArtifactStore >>= \store ->
    newMemoryJournal >>= \(journal, readEntries) ->
      agedFixture (Just store) (Just (SpliceConfig 400 1)) (wire journal) >>= \(events, _) ->
        readEntries >>= \recorded ->
          replayEntries defaultHooks Nothing recorded >>= \report ->
            sequence_
              [ fmap reportDivergence report @?= Right Nothing,
                fmap reportEvents report @?= Right (length events),
                assertBool "journaled request carries a stub" (any stubbed recorded),
                assertBool "journaled settings carry the splice config" (any configured recorded)
              ]
 where
  wire journal runtime = pure runtime {runtimeJournal = Just journal}
  stubbed (Entry _ _ _ (ModelRequestEntry recorded)) = any stubbedMessage (requestMessages recorded)
  stubbed _ = False
  stubbedMessage (ChatToolResult _ content) = isArtifactStub content
  stubbedMessage _ = False
  configured (Entry _ _ _ (RunBegin _ settings)) = runSettingsSplice settings == Just (SpliceConfig 400 1)
  configured _ = False

-- | 规格：YUKI_SPLICE_CHARS/KEEP 默认值、合法值解析与非法值拒绝符合契约。
-- 背景：配置解析是环境输入的守门员；错误接受会把坏配置带入运行时。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
spliceConfigParse :: Assertion
spliceConfigParse =
  sequence_
    [ spliceOf [] >>= (@?= (200000, 4)),
      spliceOf [("YUKI_SPLICE_CHARS", "5000"), ("YUKI_SPLICE_KEEP", "0")] >>= (@?= (5000, 0)),
      spliceOf [("YUKI_SPLICE_CHARS", "100"), ("YUKI_SPLICE_KEEP", "12")] >>= (@?= (100, 12)),
      rejected ("YUKI_SPLICE_CHARS", "0"),
      rejected ("YUKI_SPLICE_CHARS", "many"),
      rejected ("YUKI_SPLICE_KEEP", "-1"),
      rejected ("YUKI_SPLICE_KEEP", "few")
    ]
 where
  spliceOf extra =
    either
      (assertFailure . Text.unpack)
      (pure . ((,) <$> settingsSpliceChars <*> settingsSpliceKeep))
      (resolveSettings (env extra))
  env extra = Map.fromList (("DEEPSEEK_API_KEY", "secret") : extra)
  rejected (key, value) =
    either
      (const (pure ()))
      (const (assertFailure (key ++ "=" ++ value ++ " should be rejected")))
      (resolveSettings (env [(key, value)]))

contextTests :: TestTree
contextTests =
  testGroup
    "context governance"
    [ testCase "estimates ASCII and CJK tokens conservatively" contextTokenEstimate,
      testCase "compacts old dialogue within the model budget" compactsDialogue,
      testCase "anchors an assistant-only suffix with the latest user request" compactionUserAnchor,
      testCase "keeps a tool call and result as one causal unit" keepsToolCausality,
      testCase "keeps the full dropped payload addressable as an artifact" contextArtifact,
      testCase "persists the summary and compaction boundary, then replays cleanly" contextJournalReplay,
      testCase "recognizes overflow and retries once with an emergency compaction" contextOverflowRetry,
      testCase "continues calling tools after compacting an oversized result" toolAfterCompaction,
      testProperty "appending a message never lowers the estimate" estimateAppendMonotonic,
      testProperty "message estimates respect the per-message floor" estimateMessageFloor,
      testProperty "text estimates are always positive" estimateTextPositive
    ]

-- | 规格：ASCII/CJK token 估算保守（4 字符/1 token 的粒度），且 overflow 识别只命中上下文超限。
-- 背景：估算过低会突破模型窗口，过高会浪费上下文；overflow 误判会把普通失败当超限重试。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
contextTokenEstimate :: Assertion
contextTokenEstimate =
  sequence_
    [ estimateTextTokens "abc" @?= 1,
      estimateTextTokens "abcdef" @?= 2,
      estimateTextTokens "你好a" @?= 3,
      assertBool "overflow code recognized" (isContextOverflow (ProviderFailure "HTTP 400 context_length_exceeded")),
      assertBool "ordinary failure is not overflow" (not (isContextOverflow (ProviderFailure "connection reset")))
    ]

-- | 规格：追加任意消息后消息总估算不下降，且至少增加每条消息的 4 token 固定开销。
-- 背景：估算单调性是预算比较的前提；下降会导致压缩决策来回抖动。
-- 变更记录：- 2026-08-01: 补充 Context token 估算追加单调性的属性覆盖。
estimateAppendMonotonic :: Property
estimateAppendMonotonic =
  forAll genMessages $ \messages ->
    forAll genMessage $ \extra ->
      estimateMessagesTokens (messages <> [extra]) >= estimateMessagesTokens messages + 4

-- | 规格：任意消息序列的估算不小于 4 乘以消息数。
-- 背景：每条消息的 4 token 固定开销是压缩预算公式的组成部分；下界失效会让预算失真。
-- 变更记录：- 2026-08-01: 补充 Context token 估算下界的属性覆盖。
estimateMessageFloor :: Property
estimateMessageFloor =
  forAll genMessages $ \messages ->
    estimateMessagesTokens messages >= 4 * length messages

-- | 规格：任意文本的估算至少为 1 token。
-- 背景：空文本也必须占用最小开销，避免零 token 消息破坏压缩算术。
-- 变更记录：- 2026-08-01: 补充 Context 文本估算正值的属性覆盖。
estimateTextPositive :: Property
estimateTextPositive =
  forAll genText $ \text ->
    estimateTextTokens text >= 1

-- | 受控消息生成器：混合各消息类型，序列长度受限以防拖慢属性测试。
genMessages :: Gen [ChatMessage]
genMessages =
  listOf genMessage `suchThat` ((<= 6) . length)

genMessage :: Gen ChatMessage
genMessage =
  elements
    [ ChatSystem "system",
      ChatUser "你好",
      ChatUser "hello world",
      ChatAssistant (AssistantTurn "m" (Just "text") Nothing []),
      ChatAssistant (AssistantTurn "m" Nothing (Just "reasoning") []),
      ChatAssistant (AssistantTurn "m" Nothing Nothing [ModelToolCall "c" "tool" "{\"k\":1}"]),
      ChatToolResult "c" "result"
    ]

genText :: Gen Text
genText =
  suchThat
    (Text.pack <$> listOf (elements ['a' .. 'z']))
    ((<= 12) . Text.length)

-- | 规格：compactMessages 在预算内压缩旧对话、保留 system/最新 assistant 与摘要。
-- 背景：压缩是长会话不崩的支柱；丢用户意图或留超预算请求都会让后续轮次失效。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
compactsDialogue :: Assertion
compactsDialogue =
  requireCompaction (compactMessages contextConfig (Just 512) [] contextConversation) $ \compaction ->
    let compacted = compactionMessages compaction
     in sequence_
          [ assertBool "old dialogue was dropped" (not (null (compactionDropped compaction))),
            assertBool "users are summarized" (any isUser (compactionDropped compaction)),
            assertBool "assistants are summarized" (any isAssistant (compactionDropped compaction)),
            take 1 compacted @?= [ChatSystem "local rules"],
            assertBool "summary is present" (any isContextSummary compacted),
            assertBool "latest assistant remains" (any latestAssistant compacted),
            assertBool "request fits its model budget" (estimateMessagesTokens compacted <= compactionBudgetTokens compaction)
          ]
 where
  isUser ChatUser {} = True
  isUser _ = False
  isAssistant ChatAssistant {} = True
  isAssistant _ = False
  latestAssistant (ChatAssistant turn) = turnMessageId turn == "message-12"
  latestAssistant _ = False

-- | 规格：assistant-only 后缀压缩时以最新 user 请求为锚，压缩后仍不超预算。
-- 背景：没有 user 锚点时压缩会把最新用户指令一并丢弃；锚点缺失即对话失去方向。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
compactionUserAnchor :: Assertion
compactionUserAnchor =
  requireCompaction (compactToBudget contextConfig {contextKeepUnits = 1} 256 history) $ \compaction ->
    case dropWhile systemMessage (compactionMessages compaction) of
      ChatUser anchor : ChatAssistant {} : _ ->
        sequence_
          [ assertBool "anchor keeps the latest user intent" ("send this request" `Text.isInfixOf` anchor),
            assertBool "anchored request remains within budget" (compactionAfterTokens compaction <= compactionBudgetTokens compaction)
          ]
      suffix -> assertFailure ("expected user/assistant suffix, got " <> show suffix)
 where
  history =
    [ ChatSystem "local rules",
      ChatUser ("send this request " <> Text.replicate 300 "u"),
      ChatAssistant (AssistantTurn "latest" (Just (Text.replicate 600 "a")) Nothing [])
    ]
  systemMessage ChatSystem {} = True
  systemMessage _ = False

-- | 规格：工具调用与结果作为因果单元整体保留，超限结果裁剪到预算内。
-- 背景：拆散 call/result 会让模型看到悬空调用；超限结果不裁剪会再次触发 overflow。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
keepsToolCausality :: Assertion
keepsToolCausality =
  requireCompaction (compactMessages contextConfig {contextKeepUnits = 1} (Just 512) [] history) $ \compaction ->
    sequence_
      [ assertBool "call/result pair survives together" (causalPair "call-big" "big" (compactionMessages compaction)),
        assertBool "oversized result is clipped to budget" (estimateMessagesTokens (compactionMessages compaction) <= compactionBudgetTokens compaction)
      ]
 where
  history =
    contextConversation
      <> [ ChatAssistant (AssistantTurn "tool-message" Nothing Nothing [ModelToolCall "call-big" "big" "{}"]),
           ChatToolResult "call-big" (Text.replicate 1200 "result")
         ]

-- | 规格：压缩时把完整丢弃 payload 挂载为工件并在摘要中指明，且附件不超预算。
-- 背景：用户需要能取回被压缩的原文；摘要只留指针会让内容不可恢复。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
contextArtifact :: Assertion
contextArtifact =
  requireCompaction (compactMessages contextConfig (Just 512) [] contextConversation) $ \initial ->
    let attached = attachCompactionArtifact "artifact-123" initial
     in sequence_
          [ assertBool "summary points to full payload" (Text.isInfixOf "artifact artifact-123" (compactionSummary attached)),
            assertBool "artifact attachment stays in budget" (compactionAfterTokens attached <= compactionBudgetTokens attached),
            assertBool "full payload is not reduced to the summary" (Text.length (compactionPayload attached) > Text.length (compactionSummary attached))
          ]

-- | 规格：带压缩的 journaled 运行可无分歧重放，记录边界、窗口与工件，且事件解释压缩阈值公式。
-- 背景：压缩事件与 journal 记录是审计和前端展示的依据；边界记录错误会让重放与展示失真。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
contextJournalReplay :: Assertion
contextJournalReplay =
  newIORef [] >>= \captured ->
    newMemoryJournal >>= \(journal, readEntries) ->
      newMemoryArtifactStore >>= \artifacts ->
        testRuntime (capturingContextModel captured) [] Sequential >>= \base ->
          collectEvents
            base
              { runtimeJournal = Just journal,
                runtimeArtifactStore = Just artifacts,
                runtimeContext = Just contextConfig,
                runtimeSystemPrompt = "local rules"
              }
            (conversationInput (drop 1 contextConversation))
            >>= \events ->
              readEntries >>= \entries ->
                readIORef captured >>= \messages ->
                  artifactList artifacts >>= \stored ->
                    replayEntries defaultHooks Nothing entries >>= \report ->
                      sequence_
                        [ assertBool "model sees persisted summary" (any isContextSummary messages),
                          assertBool "frontend transcript retains summary" (any summaryMessage (toAguiMessages messages)),
                          assertBool "frontend sees the impending compaction" (any statusWillCompact events),
                          assertBool "status explains the exact trigger formula" (any statusExplained events),
                          assertBool "event exposes the compaction boundary" (not (null (contextCompactEvents events))),
                          assertBool "journal stores the normal boundary" (any normalBoundary entries),
                          assertBool "journal stores the effective context window" (any configuredWindow entries),
                          assertBool "full dropped context is stored locally" (any ((== "context_compaction") . artifactMetaToolName) stored),
                          fmap reportDivergence report @?= Right Nothing
                        ]
 where
  summaryMessage (Developer message) = developerName message == Just "context-summary"
  summaryMessage _ = False
  normalBoundary (Entry _ _ _ (ContextCompactEntry _ before afterTokens budget dropped False summary)) =
    before > afterTokens && afterTokens <= budget && dropped > 0 && Text.isPrefixOf contextSummaryMarker summary
  normalBoundary _ = False
  configuredWindow (Entry _ _ _ (RunBegin _ settings)) = runSettingsContextTokens settings == Just 512
  configuredWindow _ = False
  statusWillCompact (Custom "context.status" value) =
    fromMaybe False (parseMaybe (withObject "context.status" (.: "willCompact")) value)
  statusWillCompact _ = False
  statusExplained (Custom "context.status" value) =
    fromMaybe
      False
      ( (\window reserve tools budget -> budget == max 256 (window - reserve - tools))
          <$> (parseMaybe (withObject "context.status" (.: "windowTokens")) value :: Maybe Int)
          <*> (parseMaybe (withObject "context.status" (.: "reserveTokens")) value :: Maybe Int)
          <*> (parseMaybe (withObject "context.status" (.: "toolTokens")) value :: Maybe Int)
          <*> (parseMaybe (withObject "context.status" (.: "budgetTokens")) value :: Maybe Int)
      )
  statusExplained _ = False

capturingContextModel :: IORef [ChatMessage] -> Model
capturingContextModel captured =
  ( fakeModel
      (\request emit -> writeIORef captured (requestMessages request) *> emit (ModelTextDelta "done") $> Stop)
  )
    { modelContextTokens = Just 512
    }

-- | 规格：context overflow 识别后以紧急压缩重试一次，绕过普通退避，标记 emergency。
-- 背景：overflow 是明确的预算信号；按普通重试背退会拖慢恢复，不重试则对话直接失败。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
contextOverflowRetry :: Assertion
contextOverflowRetry =
  newIORef (0 :: Int) >>= \calls ->
    newIORef [] >>= \requests ->
      newMemoryJournal >>= \(journal, readEntries) ->
        testRuntime (overflowContextModel calls requests) [] Sequential >>= \base ->
          collectEvents
            base
              { runtimeJournal = Just journal,
                runtimeContext = Just contextConfig,
                runtimeProviderRetries = 3,
                runtimeSystemPrompt = "local rules"
              }
            (conversationInput (take 10 (drop 1 contextConversation)))
            >>= \events ->
              readIORef requests >>= \seen ->
                readEntries >>= \entries ->
                  replayEntries defaultHooks Nothing entries >>= \report ->
                    verifyOverflow seen events entries report

verifyOverflow :: [ModelRequest] -> [Event] -> [Entry] -> Either Text ReplayReport -> Assertion
verifyOverflow [first, second] events entries report =
  sequence_
    [ assertBool "first request is above emergency budget" (estimateMessagesTokens (requestMessages first) > 256),
      assertBool "retry request is emergency-sized" (estimateMessagesTokens (requestMessages second) <= 256),
      length (contextCompactEvents events) @?= 1,
      assertBool "compaction is marked emergency" (all emergencyEvent (contextCompactEvents events)),
      assertBool "overflow bypasses ordinary backoff" (all (not . providerRetry) events),
      length (filter emergencyBoundary entries) @?= 1,
      fmap reportDivergence report @?= Right Nothing
    ]
verifyOverflow seen _ _ _ = assertFailure ("expected two model requests, got " <> show (length seen))
overflowContextModel :: IORef Int -> IORef [ModelRequest] -> Model
overflowContextModel calls requests =
  Model "fake" "overflow-once" (Just 512) stream (const (object []))
 where
  stream request emit =
    modifyIORef' requests (<> [request])
      *> atomicModifyIORef' calls (\count -> let next = count + 1 in (next, next))
      >>= \case
        1 -> throwIO (ProviderFailure "context_length_exceeded")
        _ -> emit (ModelTextDelta "recovered") $> Stop

-- | 规格：超大工具结果触发压缩后，后续工具调用仍保持因果配对并完成执行。
-- 背景：压缩发生在工具循环中段；若压缩破坏因果链，后续工具回合全部失效。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
toolAfterCompaction :: Assertion
toolAfterCompaction =
  newIORef (0 :: Int) >>= \turns ->
    newIORef [] >>= \second ->
      newIORef [] >>= \third ->
        testRuntime
          (compactingToolModel turns second third)
          [staticTool "big" (Text.replicate 1200 "result"), staticTool "echo" "ok"]
          Sequential
          >>= \base ->
            collectEvents base {runtimeContext = Just contextConfig} (sampleInput [])
              >>= \events ->
                readIORef second >>= \afterBig ->
                  readIORef third >>= \afterEcho ->
                    sequence_
                      [ assertBool "oversized tool pair stays causal" (causalPair "call-big" "big" afterBig),
                        assertBool "first compaction leaves a summary" (any isContextSummary afterBig),
                        assertBool "a later tool call also stays causal" (causalPair "call-echo" "echo" afterEcho),
                        assertBool "tool execution completed after compaction" (any echoResult events),
                        assertBool "oversized result triggered compaction" (not (null (contextCompactEvents events)))
                      ]
 where
  echoResult (ToolCallResult _ "call-echo" "ok") = True
  echoResult _ = False

compactingToolModel :: IORef Int -> IORef [ChatMessage] -> IORef [ChatMessage] -> Model
compactingToolModel turns second third =
  Model "fake" "tool-after-compaction" (Just 512) stream (const (object []))
 where
  stream request emit =
    atomicModifyIORef' turns (\count -> let next = count + 1 in (next, next)) >>= turn request emit
  turn _ emit 1 = emit (ModelToolCallDelta 0 (Just "call-big") (Just "big") "{}") $> ToolUse
  turn request emit 2 =
    writeIORef second (requestMessages request)
      *> emit (ModelToolCallDelta 0 (Just "call-echo") (Just "echo") "{}")
      $> ToolUse
  turn request emit 3 = writeIORef third (requestMessages request) *> emit (ModelTextDelta "done") $> Stop
  turn _ _ _ = throwIO (ProviderFailure "unexpected model turn")
conversationInput :: [ChatMessage] -> RunAgentInput
conversationInput messages = (sampleInput []) {runMessages = toAguiMessages messages}
contextCompactEvents :: [Event] -> [Value]
contextCompactEvents events = [value | Custom "context.compact" value <- events]
emergencyEvent :: Value -> Bool
emergencyEvent = fromMaybe False . parseMaybe (withObject "context.compact" (.: "emergency"))
emergencyBoundary :: Entry -> Bool
emergencyBoundary (Entry _ _ _ (ContextCompactEntry _ _ _ _ _ True _)) = True
emergencyBoundary _ = False
providerRetry :: Event -> Bool
providerRetry (Custom "provider.retry" _) = True
providerRetry _ = False
causalPair :: Text -> Text -> [ChatMessage] -> Bool
causalPair callId name messages = any paired (zip messages (drop 1 messages))
 where
  paired (ChatAssistant turn, ChatToolResult resultId _) =
    resultId == callId && any (\call -> modelToolCallId call == callId && modelToolName call == name) (turnToolCalls turn)
  paired _ = False
requireCompaction :: Maybe Compaction -> (Compaction -> Assertion) -> Assertion
requireCompaction planned verify = maybe (assertFailure "expected context compaction") verify planned
