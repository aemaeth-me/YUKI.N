-- | 全局配置解析测试
--
-- 覆盖：默认值、未知 provider 要求、sub-agent 深度、重试次数与上下文摘要下限。
-- 边界：覆盖 Yuki.N.Config 的 resolveSettings；线程级配置见 ThreadConfigTest。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
--   - 2026-08-01: 补充端口/max/context token 与 dialect/thinking 组合边界的回归覆盖。
module Yuki.N.ConfigTest
  ( configTests,
    configBoundaryTests,
    deepSeekDefaults,
    customRequiresConfiguration,
    subAgentDepthConfig,
    providerRetriesConfig,
    contextSummaryConfig,
    portBoundaryConfig,
    maxTokensBoundaryConfig,
    contextTokensBoundaryConfig,
    dialectThinkingBoundaryConfig,
  )
where

import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Exception ()
import Control.Monad ()
import Data.Aeson ()
import Data.Aeson.Types ()
import Data.Bool ()
import Data.ByteString ()
import Data.Foldable ()
import Data.Functor ()
import Data.IORef ()
import Data.List ()
import Data.Map.Strict qualified as Map
import Data.Maybe ()
import Data.Text ()
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
import Yuki.N.Config
import Yuki.N.Provider.OpenAI
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig ()

configTests :: TestTree
configTests =
  testGroup
    "configuration"
    [ testCase "defaults to a proxy-safe local port and DeepSeek V4 Flash" deepSeekDefaults,
      testCase "requires model and URL for unknown providers" customRequiresConfiguration,
      testCase "sub-agent depth defaults to one, accepts zero, rejects bad values" subAgentDepthConfig,
      testCase "provider retries default to three, accept zero, reject bad values" providerRetriesConfig,
      testCase "context summary config enforces the real algorithmic floor" contextSummaryConfig
    ]

-- | 规格：零配置默认：deepseek provider、18080 端口、V4 Flash 模型、High 思考、1M 上下文。
-- 背景：默认值是零配置体验的契约；默认漂移会让既有部署行为突变。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
deepSeekDefaults :: Assertion
deepSeekDefaults =
  either
    (assertFailure . Text.unpack)
    verify
    (resolveSettings (Map.singleton "DEEPSEEK_API_KEY" "secret"))
 where
  verify settings =
    let provider = settingsProvider settings
     in sequence_
          [ openAIProvider provider @?= "deepseek",
            settingsPort settings @?= 18080,
            openAIModelName provider @?= "deepseek-v4-flash",
            openAIBaseUrl provider @?= "https://api.deepseek.com",
            openAIDialect provider @?= DeepSeek,
            openAIThinking provider @?= ThinkingEnabled High,
            openAIContextTokens provider @?= Just 1000000,
            settingsContextReserveTokens settings @?= 16384
          ]

-- | 规格：未知 provider 必须显式配置模型与 URL，否则解析失败。
-- 背景：自动补全未知 provider 会产生猜测连接；显式失败让用户感知配置缺口。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
customRequiresConfiguration :: Assertion
customRequiresConfiguration =
  either
    (const (pure ()))
    (const (assertFailure "custom provider should need explicit configuration"))
    (resolveSettings (Map.fromList [("YUKI_PROVIDER", "custom"), ("YUKI_API_KEY", "secret")]))

-- | 规格：YUKI_SUBAGENT_DEPTH 默认 1，接受 0 与正数，拒绝负数与非数字。
-- 背景：深度配置直接影响递归边界；错误接受会把坏值带进运行时。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
subAgentDepthConfig :: Assertion
subAgentDepthConfig =
  sequence_
    [ depthOf [] >>= (@?= 1),
      depthOf [("YUKI_SUBAGENT_DEPTH", "0")] >>= (@?= 0),
      depthOf [("YUKI_SUBAGENT_DEPTH", "3")] >>= (@?= 3),
      rejected "-1",
      rejected "two"
    ]
 where
  depthOf extra =
    either (assertFailure . Text.unpack) (pure . settingsSubAgentDepth) (resolveSettings (env extra))
  env extra = Map.fromList (("DEEPSEEK_API_KEY", "secret") : extra)
  rejected value =
    either
      (const (pure ()))
      (const (assertFailure ("YUKI_SUBAGENT_DEPTH=" <> value <> " should be rejected")))
      (resolveSettings (env [("YUKI_SUBAGENT_DEPTH", value)]))

-- | 规格：YUKI_PROVIDER_RETRIES 默认 3，接受 0，拒绝负数与非数字。
-- 背景：重试配置影响失败路径成本；错误接受会让用户以为重试已配置。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
providerRetriesConfig :: Assertion
providerRetriesConfig =
  sequence_
    [ retriesOf [] >>= (@?= 3),
      retriesOf [("YUKI_PROVIDER_RETRIES", "0")] >>= (@?= 0),
      retriesOf [("YUKI_PROVIDER_RETRIES", "7")] >>= (@?= 7),
      rejected "-1",
      rejected "two"
    ]
 where
  retriesOf extra =
    either (assertFailure . Text.unpack) (pure . settingsProviderRetries) (resolveSettings (env extra))
  env extra = Map.fromList (("DEEPSEEK_API_KEY", "secret") : extra)
  rejected value =
    either
      (const (pure ()))
      (const (assertFailure ("YUKI_PROVIDER_RETRIES=" <> value <> " should be rejected")))
      (resolveSettings (env [("YUKI_PROVIDER_RETRIES", value)]))

-- | 规格：YUKI_CONTEXT_SUMMARY_TOKENS 强制算法下限 96。
-- 背景：摘要 token 下限是压缩正确性的硬约束；低于下限会破坏压缩预算公式。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
contextSummaryConfig :: Assertion
contextSummaryConfig =
  sequence_
    [ summaryOf "96" >>= (@?= 96),
      summaryOf "2048" >>= (@?= 2048),
      rejected "95",
      rejected "0"
    ]
 where
  env value = Map.fromList [("DEEPSEEK_API_KEY", "secret"), ("YUKI_CONTEXT_SUMMARY_TOKENS", value)]
  summaryOf value =
    either (assertFailure . Text.unpack) (pure . settingsContextSummaryTokens) (resolveSettings (env value))
  rejected value =
    either
      (const (pure ()))
      (const (assertFailure ("YUKI_CONTEXT_SUMMARY_TOKENS=" <> value <> " should be rejected")))
      (resolveSettings (env value))

configBoundaryTests :: TestTree
configBoundaryTests =
  testGroup
    "configuration boundaries"
    [ testCase "port accepts 1..65535 and rejects 0/65536/negative/non-numeric" portBoundaryConfig,
      testCase "max tokens accepts positive values and rejects zero/negative/non-numeric" maxTokensBoundaryConfig,
      testCase "context tokens default to 1M and reject non-positive values" contextTokensBoundaryConfig,
      testCase "dialect/thinking combinations and reasoning effort values are validated" dialectThinkingBoundaryConfig
    ]

-- | 规格：YUKI_PORT 接受 1..65535，拒绝 0、65536、负数与非数字。
-- 背景：端口越界会静默绑定失败或占用非法端口；解析边界是部署安全的契约。
-- 变更记录：- 2026-08-01: 补充端口边界回归覆盖。
portBoundaryConfig :: Assertion
portBoundaryConfig =
  sequence_
    [ portOf "0" >>= assertLeft,
      portOf "1" >>= (@?= Right 1),
      portOf "65535" >>= (@?= Right 65535),
      portOf "65536" >>= assertLeft,
      portOf "-1" >>= assertLeft,
      portOf "abc" >>= assertLeft
    ]
 where
  portOf value =
    pure (fmap settingsPort (resolveSettings (env [("YUKI_PORT", value)])))
  env extra = Map.fromList (("DEEPSEEK_API_KEY", "secret") : extra)

-- | 规格：YUKI_MAX_TOKENS 缺省为 Nothing，接受正数，拒绝 0/负数/非数字。
-- 背景：max tokens 直接写进 provider 请求；坏值会被 provider 拒绝或意外截断输出。
-- 变更记录：- 2026-08-01: 补充 max tokens 边界回归覆盖。
maxTokensBoundaryConfig :: Assertion
maxTokensBoundaryConfig =
  sequence_
    [ maxOf [] >>= (@?= Right Nothing),
      maxOf [("YUKI_MAX_TOKENS", "1")] >>= (@?= Right (Just 1)),
      maxOf [("YUKI_MAX_TOKENS", "8192")] >>= (@?= Right (Just 8192)),
      maxOf [("YUKI_MAX_TOKENS", "0")] >>= assertLeft,
      maxOf [("YUKI_MAX_TOKENS", "-5")] >>= assertLeft,
      maxOf [("YUKI_MAX_TOKENS", "many")] >>= assertLeft
    ]
 where
  maxOf extra =
    pure (fmap (openAIMaxTokens . settingsProvider) (resolveSettings (env extra)))
  env extra = Map.fromList (("DEEPSEEK_API_KEY", "secret") : extra)

-- | 规格：YUKI_CONTEXT_TOKENS 缺省 1000000，接受正数，拒绝 0/负数/非数字。
-- 背景：上下文窗口驱动压缩与溢出判定；坏值会让压缩决策失真。
-- 变更记录：- 2026-08-01: 补充 context tokens 边界回归覆盖。
contextTokensBoundaryConfig :: Assertion
contextTokensBoundaryConfig =
  sequence_
    [ contextOf [] >>= (@?= Right (Just 1000000)),
      contextOf [("YUKI_CONTEXT_TOKENS", "2048")] >>= (@?= Right (Just 2048)),
      contextOf [("YUKI_CONTEXT_TOKENS", "0")] >>= assertLeft,
      contextOf [("YUKI_CONTEXT_TOKENS", "-1")] >>= assertLeft,
      contextOf [("YUKI_CONTEXT_TOKENS", "wide")] >>= assertLeft
    ]
 where
  contextOf extra =
    pure (fmap (openAIContextTokens . settingsProvider) (resolveSettings (env extra)))
  env extra = Map.fromList (("DEEPSEEK_API_KEY", "secret") : extra)

-- | 规格：openai-compatible + thinking=enabled 非法；deepseek 组合与 effort 取值受控。
-- 背景：思考字段按方言渲染；非法组合会让 provider 400 或静默忽略配置。
-- 变更记录：- 2026-08-01: 补充 dialect/thinking 组合与 effort 边界回归覆盖。
dialectThinkingBoundaryConfig :: Assertion
dialectThinkingBoundaryConfig =
  sequence_
    [ combo [("YUKI_API_DIALECT", "openai-compatible"), ("YUKI_THINKING", "enabled")] >>= assertLeft,
      combo [("YUKI_API_DIALECT", "deepseek"), ("YUKI_THINKING", "enabled")] >>= (@?= Right (ThinkingEnabled High)),
      combo [("YUKI_API_DIALECT", "deepseek"), ("YUKI_THINKING", "enabled"), ("YUKI_REASONING_EFFORT", "max")] >>= (@?= Right (ThinkingEnabled Max)),
      combo [("YUKI_API_DIALECT", "deepseek"), ("YUKI_THINKING", "disabled")] >>= (@?= Right ThinkingDisabled),
      combo [("YUKI_API_DIALECT", "deepseek"), ("YUKI_REASONING_EFFORT", "high")] >>= (@?= Right (ThinkingEnabled High)),
      combo [("YUKI_API_DIALECT", "deepseek"), ("YUKI_REASONING_EFFORT", "low")] >>= assertLeft,
      combo [("YUKI_API_DIALECT", "deepseek"), ("YUKI_REASONING_EFFORT", "banana")] >>= assertLeft,
      combo [("YUKI_THINKING", "sometimes")] >>= assertLeft
    ]
 where
  combo extra =
    pure (fmap (openAIThinking . settingsProvider) (resolveSettings (env extra)))
  env extra = Map.fromList (("DEEPSEEK_API_KEY", "secret") : extra)
