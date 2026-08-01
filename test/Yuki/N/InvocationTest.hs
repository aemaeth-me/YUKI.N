module Yuki.N.InvocationTest
  ( invocationTests,
    invocationSuccess,
    invocationOutputLimit,
    invocationTimeout,
    invocationProviderFailure,
    invocationChainExhausted,
    invocationRetriesWithinModel,
    invocationFallsBackAcrossModels,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Data.Functor (($>))
import Data.IORef
import Data.Text qualified as Text
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

invocationSuccess :: Assertion
invocationSuccess =
  invokeModel spec >>= \case
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

invocationOutputLimit :: Assertion
invocationOutputLimit =
  invokeModel spec >>= \case
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

invocationTimeout :: Assertion
invocationTimeout =
  invokeModel spec >>= \case
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

invocationProviderFailure :: Assertion
invocationProviderFailure =
  invokeModel spec >>= \case
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

invocationChainExhausted :: Assertion
invocationChainExhausted =
  invokeModel spec >>= \case
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
     in invokeModel spec >>= \case
          Left failure -> assertFailure ("retries should recover: " <> Text.unpack failure)
          Right invocation ->
            sequence_
              [ invocationResultText invocation @?= "ok",
                invocationResultAttempts invocation @?= 3
              ]

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
   in invokeModel spec >>= \case
        Left failure -> assertFailure ("fallback should recover: " <> Text.unpack failure)
        Right invocation ->
          sequence_
            [ invocationResultText invocation @?= "recovered",
              invocationResultModel invocation @?= "fake",
              invocationResultAttempts invocation @?= 2
            ]
