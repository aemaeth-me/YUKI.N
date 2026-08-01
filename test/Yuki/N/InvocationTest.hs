-- | 模型调用（invokeModel）边界测试
--
-- 覆盖：成功路径、输出字符上限、超时、provider 失败、空模型链、模型内重试与跨模型回退。
-- 边界：全部使用内存假模型，不经过真实网络（见 E2E）。
-- 变更记录：
--   - 2026-08-01: 新增 Invocation 关键分支的回归覆盖。
module Yuki.N.InvocationTest
  ( invocationTests,
    invocationSuccess,
    invocationOutputLimit,
    invocationTimeout,
    invocationProviderFailure,
    invocationChainExhausted,
    invocationRetriesWithinModel,
    invocationFallsBackAcrossModels
  )
where
import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Data.Functor (($>))
import Data.IORef
import qualified Data.Text as Text
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Invocation
import Yuki.N.Model
import Yuki.N.TestSupport (fakeModel)


invocationTests :: TestTree
invocationTests =
  testGroup
    "invocation"
    [ testCase "streams deltas into the result text with finish and provider identity" invocationSuccess,
      testCase "fails when output exceeds the character budget" invocationOutputLimit,
      testCase "fails when the model exceeds the timeout budget" invocationTimeout,
      testCase "surfaces provider failures as Left with the provider message" invocationProviderFailure,
      testCase "fails with a clear message when the model chain is empty" invocationChainExhausted,
      testCase "retries the same model up to the attempts budget before failing over" invocationRetriesWithinModel,
      testCase "falls back to the next model after the first exhausts its attempts" invocationFallsBackAcrossModels
    ]
-- | 规格：单模型流式输出被累积进结果文本，携带 finish 原因与 provider/model 身份。
-- 背景：invokeModel 是 cognition 内部调用的统一入口；文本拼接与身份字段错误会让上层（睡眠/提示词生成）失真。
-- 变更记录：- 2026-08-01: 补充 Invocation 成功路径的回归覆盖。
invocationSuccess :: Assertion
invocationSuccess =
  invokeModel spec >>= \result ->
    case result of
      Left failure -> assertFailure ("unexpected failure: " <> Text.unpack failure)
      Right invocation ->
        sequence_
          [ invocationResultText invocation @?= "hello world",
            invocationResultFinish invocation @?= Stop,
            invocationResultProvider invocation @?= "fake",
            invocationResultModel invocation @?= "fake",
            invocationResultAttempts invocation @?= 1,
            invocationResultKind invocation @?= "test"
          ]
  where
    spec =
      InvocationSpec
        { invocationId = "inv-1",
          invocationKind = "test",
          invocationPromptRevision = "revision-1",
          invocationModels = [fakeModel (\_ emit -> emit (ModelTextDelta "hello ") *> emit (ModelTextDelta "world") $> Stop)],
          invocationMessages = [ChatUser "hi"],
          invocationAttemptsPerModel = 1,
          invocationOutputChars = 1000,
          invocationTimeoutMs = 1000,
          invocationJournal = Nothing
        }
-- | 规格：累计输出超过 invocationOutputChars 时以 Left 失败且不返回部分结果。
-- 背景：输出预算保护是长文本失控的本地防线；静默截断会让上层拿到残缺内容。
-- 变更记录：- 2026-08-01: 补充输出字符上限分支的回归覆盖。
invocationOutputLimit :: Assertion
invocationOutputLimit =
  invokeModel spec >>= \result ->
    case result of
      Right _ -> assertFailure "output limit should fail the invocation"
      Left failure -> failure @?= "model invocation exceeded output budget"
  where
    spec =
      InvocationSpec
        { invocationId = "inv-2",
          invocationKind = "test",
          invocationPromptRevision = "revision-1",
          invocationModels = [fakeModel (\_ emit -> emit (ModelTextDelta "0123456789") $> Stop)],
          invocationMessages = [],
          invocationAttemptsPerModel = 1,
          invocationOutputChars = 5,
          invocationTimeoutMs = 1000,
          invocationJournal = Nothing
        }
-- | 规格：模型超过 invocationTimeoutMs 毫秒仍未结束时以 Left "model invocation timed out" 失败。
-- 背景：超时保护防止上游挂起占用整个运行时；缺失会让单次调用无限阻塞。
-- 变更记录：- 2026-08-01: 补充超时分支的回归覆盖。
invocationTimeout :: Assertion
invocationTimeout =
  invokeModel spec >>= \result ->
    case result of
      Right _ -> assertFailure "timeout should fail the invocation"
      Left failure -> failure @?= "model invocation timed out"
  where
    spec =
      InvocationSpec
        { invocationId = "inv-3",
          invocationKind = "test",
          invocationPromptRevision = "revision-1",
          invocationModels = [fakeModel (\_ _ -> threadDelay 200000 $> Stop)],
          invocationMessages = [],
          invocationAttemptsPerModel = 1,
          invocationOutputChars = 1000,
          invocationTimeoutMs = 2,
          invocationJournal = Nothing
        }
-- | 规格：provider 抛出 ProviderFailure 时失败消息原样透传为 Left。
-- 背景：provider 错误语义（限流/鉴权/上下文过长）由上层据此决策；消息丢失会破坏重试与降级判断。
-- 变更记录：- 2026-08-01: 补充 provider 失败分支的回归覆盖。
invocationProviderFailure :: Assertion
invocationProviderFailure =
  invokeModel spec >>= \result ->
    case result of
      Right _ -> assertFailure "provider failure should surface as Left"
      Left failure -> failure @?= "boom"
  where
    spec =
      InvocationSpec
        { invocationId = "inv-4",
          invocationKind = "test",
          invocationPromptRevision = "revision-1",
          invocationModels = [fakeModel (\_ _ -> throwIO (ProviderFailure "boom"))],
          invocationMessages = [],
          invocationAttemptsPerModel = 1,
          invocationOutputChars = 1000,
          invocationTimeoutMs = 1000,
          invocationJournal = Nothing
        }
-- | 规格：空模型链直接失败并给出可诊断消息，而不是空转。
-- 背景：cognition 可能因配置缺失而没有任何可用模型；错误必须显式可见。
-- 变更记录：- 2026-08-01: 补充空模型链分支的回归覆盖。
invocationChainExhausted :: Assertion
invocationChainExhausted =
  invokeModel spec >>= \result ->
    case result of
      Right _ -> assertFailure "empty chain should fail the invocation"
      Left failure -> failure @?= "model chain exhausted"
  where
    spec =
      InvocationSpec
        { invocationId = "inv-5",
          invocationKind = "test",
          invocationPromptRevision = "revision-1",
          invocationModels = [],
          invocationMessages = [],
          invocationAttemptsPerModel = 1,
          invocationOutputChars = 1000,
          invocationTimeoutMs = 1000,
          invocationJournal = Nothing
        }
-- | 规格：同一模型在 attempts 预算内失败后重试，成功时 attempts 记录实际尝试序数。
-- 背景：瞬时限流/网络抖动应在同一模型上自动重试；attempts 序数是审计与回放的关键字段。
-- 变更记录：- 2026-08-01: 补充模型内重试分支的回归覆盖。
invocationRetriesWithinModel :: Assertion
invocationRetriesWithinModel =
  newIORef (0 :: Int) >>= \counter ->
    let flaky =
          fakeModel $ \_ emit -> do
            attempt <- atomicModifyIORef' counter (\n -> (n + 1, n + 1))
            if attempt < 3
              then throwIO (ProviderFailure "flaky")
              else emit (ModelTextDelta "ok") $> Stop
        spec =
          InvocationSpec
            { invocationId = "inv-6",
              invocationKind = "test",
              invocationPromptRevision = "revision-1",
              invocationModels = [flaky],
              invocationMessages = [],
              invocationAttemptsPerModel = 3,
              invocationOutputChars = 1000,
              invocationTimeoutMs = 1000,
              invocationJournal = Nothing
            }
     in invokeModel spec >>= \result ->
          case result of
            Left failure -> assertFailure ("retries should recover: " <> Text.unpack failure)
            Right invocation ->
              sequence_
                [ invocationResultText invocation @?= "ok",
                  invocationResultAttempts invocation @?= 3
                ]
-- | 规格：首个模型耗尽 attempts 后回退到下一个模型，成功结果携带回退模型的身份。
-- 背景：多 provider 链是主备降级的实现路径；回退身份错误会让审计把成功归功于错误供应商。
-- 变更记录：- 2026-08-01: 补充跨模型回退分支的回归覆盖。
invocationFallsBackAcrossModels :: Assertion
invocationFallsBackAcrossModels =
  let primary = Model "primary" "p-1" Nothing (\_ _ -> throwIO (ProviderFailure "down")) (const (error "unused"))
      secondary = fakeModel (\_ emit -> emit (ModelTextDelta "recovered") $> Stop)
      spec =
        InvocationSpec
          { invocationId = "inv-7",
            invocationKind = "test",
            invocationPromptRevision = "revision-1",
            invocationModels = [primary, secondary],
            invocationMessages = [],
            invocationAttemptsPerModel = 1,
            invocationOutputChars = 1000,
            invocationTimeoutMs = 1000,
            invocationJournal = Nothing
          }
   in invokeModel spec >>= \result ->
        case result of
          Left failure -> assertFailure ("fallback should recover: " <> Text.unpack failure)
          Right invocation ->
            sequence_
              [ invocationResultText invocation @?= "recovered",
                invocationResultModel invocation @?= "fake",
                invocationResultAttempts invocation @?= 2
              ]
