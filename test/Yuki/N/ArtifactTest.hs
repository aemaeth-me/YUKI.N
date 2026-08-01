module Yuki.N.ArtifactTest
  ( artifactTests,
    elidesDuplicate,
    keepsSmall,
    artifactPreview,
    guidedArtifactOnce,
    readsBack,
    replaysClean,
  )
where

import Control.Exception (throwIO)
import Data.Aeson
import Data.Functor (($>))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.Agent
import Yuki.N.Artifact
import Yuki.N.Journal
import Yuki.N.Model
import Yuki.N.Replay
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
withArtifactStore action = do
  tmp <- getTemporaryDirectory
  identifier <- newId
  let dir = tmp ++ "/" ++ Text.unpack identifier
  createDirectoryIfMissing True dir
  store <- newArtifactStore dir
  action store
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

elidesDuplicate :: Assertion
elidesDuplicate = withArtifactStore $ \store -> do
  turns <- newIORef (0 :: Int)
  captured <- newIORef []
  base <- testRuntime (dupCalls "big" turns captured) [staticTool "big" bigContent] Sequential
  events <- collectEvents base {runtimeArtifactStore = Just store} (sampleInput [])
  messages <- readIORef captured
  case [content | ChatToolResult _ content <- messages] of
    [first, second] -> do
      first @?= bigContent
      assertBool "second result is a reference stub" (isArtifactStub second)
      assertBool "stub names the artifact" (Text.isInfixOf (artifactIdFor bigContent) second)
      assertBool "stub keeps an excerpt" (Text.isInfixOf (Text.take 200 bigContent) second)
      [content | ToolCallResult _ _ content <- events] @?= [bigContent, bigContent]
    other -> assertFailure ("unexpected tool results: " <> show (length other))

keepsSmall :: Assertion
keepsSmall = withArtifactStore $ \store -> do
  turns <- newIORef (0 :: Int)
  captured <- newIORef []
  base <- testRuntime (dupCalls "small" turns captured) [staticTool "small" "tiny result"] Sequential
  _ <- collectEvents base {runtimeArtifactStore = Just store} (sampleInput [])
  messages <- readIORef captured
  [content | ChatToolResult _ content <- messages] @?= ["tiny result", "tiny result"]

artifactPreview :: Assertion
artifactPreview = do
  store <- newMemoryArtifactStore
  _ <- artifactSave store "shell" "alpha\n\n beta\tgamma"
  metas <- artifactList store
  case metas of
    [meta] -> do
      artifactMetaPreview meta @?= "alpha beta gamma"
      eitherDecode
        "{\"id\":\"art-legacy\",\"toolName\":\"shell\",\"chars\":3,\"time\":1}"
        @?= Right (ArtifactMeta "art-legacy" "shell" "" 3 1)
    other -> assertFailure ("expected one artifact, got " <> show (length other))

guidedArtifactOnce :: Assertion
guidedArtifactOnce = do
  store <- newMemoryArtifactStore
  identifier <- artifactSave store "shell" bigContent
  turns <- newIORef (0 :: Int)
  captured <- newIORef []
  let guided =
        Text.take 220 bigContent
          <> "\n[artifact "
          <> identifier
          <> ": full shell output; call artifact_read]"
  base <- testRuntime (dupCalls "shell" turns captured) [staticTool "shell" guided] Sequential
  _ <- collectEvents base {runtimeArtifactStore = Just store} (sampleInput [])
  metas <- artifactList store
  length metas @?= 1
  fmap artifactMetaId metas @?= [identifier]

readsBack :: Assertion
readsBack = withArtifactStore $ \store -> do
  identifier <- artifactSave store "big" bigContent
  captured <- newIORef []
  base <- testRuntime (readBackModel identifier captured) [artifactReadTool store] Sequential
  _ <- collectEvents base {runtimeArtifactStore = Just store} (sampleInput [])
  messages <- readIORef captured
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

replaysClean :: Assertion
replaysClean = withArtifactStore $ \store -> do
  (journal, readEntries) <- newMemoryJournal
  turns <- newIORef (0 :: Int)
  captured <- newIORef []
  base <- testRuntime (dupCalls "big" turns captured) [staticTool "big" bigContent] Sequential
  events <- collectEvents base {runtimeJournal = Just journal, runtimeArtifactStore = Just store} (sampleInput [])
  recorded <- readEntries
  report <- replayEntries defaultHooks Nothing recorded
  fmap reportDivergence report @?= Right Nothing
  fmap reportEvents report @?= Right (length events)
