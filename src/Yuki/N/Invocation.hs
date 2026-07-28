module Yuki.N.Invocation
  ( InvocationResult (..),
    InvocationSpec (..),
    invokeModel,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Exception (Exception, throwIO, try)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as Text
import Yuki.N.Journal
import Yuki.N.Model

data InvocationSpec = InvocationSpec
  { invocationId :: Text,
    invocationKind :: Text,
    invocationPromptRevision :: Text,
    invocationModels :: [Model],
    invocationMessages :: [ChatMessage],
    invocationAttemptsPerModel :: Int,
    invocationOutputChars :: Int,
    invocationTimeoutMs :: Int,
    invocationJournal :: Maybe Journal
  }

data InvocationResult = InvocationResult
  { invocationResultId :: Text,
    invocationResultKind :: Text,
    invocationResultPromptRevision :: Text,
    invocationResultProvider :: Text,
    invocationResultModel :: Text,
    invocationResultAttempts :: Int,
    invocationResultText :: Text,
    invocationResultFinish :: FinishReason
  }
  deriving stock (Eq, Show)

data InvocationFailure
  = OutputLimitExceeded
  | InvocationTimedOut
  deriving stock (Show)

instance Exception InvocationFailure

invokeModel :: InvocationSpec -> IO (Either Text InvocationResult)
invokeModel spec =
  go 0 (invocationModels spec)
  where
    go _ [] = pure (Left "model chain exhausted")
    go spent (model : rest) =
      attempts model spent 1 >>= \case
        Right result -> pure (Right result)
        Left failure
          | null rest -> pure (Left failure)
          | otherwise -> go (spent + max 1 (invocationAttemptsPerModel spec)) rest
    attempts model spent trial =
      runAttempt model (spent + trial) >>= \case
        Right result -> pure (Right result)
        Left failure
          | trial < max 1 (invocationAttemptsPerModel spec) -> attempts model spent (trial + 1)
          | otherwise -> pure (Left failure)
    runAttempt model ordinal =
      race
        (threadDelay (max 1 (invocationTimeoutMs spec) * 1000))
        (attempt model ordinal)
        >>= \case
          Left _ -> pure (Left "model invocation timed out")
          Right result -> pure result
    attempt model ordinal =
      newIORef "" >>= \output ->
        let request = ModelRequest (invocationMessages spec) []
            journal = scopedJournal ordinal
            emit event =
              recordMaybe journal (ModelEventEntry event)
                *> case event of
                  ModelTextDelta delta ->
                    modifyIORef' output (<> delta)
                      *> readIORef output
                      >>= limit
                  _ -> pure ()
            limit text
              | Text.length text <= max 1 (invocationOutputChars spec) = pure ()
              | otherwise = throwIO OutputLimitExceeded
            execute =
              recordMaybe journal (ModelRequestEntry request)
                *> recordMaybe journal (ApiRequestEntry (modelRender model request))
                *> streamModel model request emit
                >>= \finish ->
                  recordMaybe journal (ModelFinishEntry finish)
                    *> readIORef output
                    >>= \text ->
                      pure
                        ( InvocationResult
                            (invocationId spec)
                            (invocationKind spec)
                            (invocationPromptRevision spec)
                            (modelProvider model)
                            (modelName model)
                            ordinal
                            text
                            finish
                        )
         in catchInvocation
              ( (try execute :: IO (Either ProviderFailure InvocationResult))
                  >>= either (pure . Left . providerMessage) (pure . Right)
              )
              ( \case
                  OutputLimitExceeded -> pure (Left "model invocation exceeded output budget")
                  InvocationTimedOut -> pure (Left "model invocation timed out")
              )
    scopedJournal ordinal =
      subJournal ("attempt-" <> Text.pack (show ordinal))
        . subJournal (invocationKind spec)
        . subJournal (invocationId spec)
        <$> invocationJournal spec
    providerMessage (ProviderFailure message) = message

catchInvocation :: IO value -> (InvocationFailure -> IO value) -> IO value
catchInvocation action recover =
  try action >>= either recover pure
