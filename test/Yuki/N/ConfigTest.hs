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

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Config
import Yuki.N.Provider.OpenAI
import Yuki.N.TestSupport

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

customRequiresConfiguration :: Assertion
customRequiresConfiguration =
  either
    (const (pure ()))
    (const (assertFailure "custom provider should need explicit configuration"))
    (resolveSettings (Map.fromList [("YUKI_PROVIDER", "custom"), ("YUKI_API_KEY", "secret")]))

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
