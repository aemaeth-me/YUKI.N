module Yuki.N.SubAgentTest
  ( subAgentTests,
    capabilityDescription,
    inheritedShell,
    registration,
    delegation,
    depthExhausted,
  )
where

import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Functor (($>))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Client.TLS (newTlsManager)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Journal
import Yuki.N.Model
import Yuki.N.Replay
import Yuki.N.SubAgent
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig

subAgentTests :: TestTree
subAgentTests =
  testGroup
    "sub-agents"
    [ testCase "delegates to a scoped sub-run and replays cleanly" delegation,
      testCase "refuses delegation at depth zero" depthExhausted,
      testCase "advertises the child's exact inherited tools" capabilityDescription,
      testCase "a resolved cwd lets the child execute a local shell request" inheritedShell,
      testCase "resolveRuntime registers sub_agent only above depth zero" registration
    ]

capabilityDescription :: Assertion
capabilityDescription =
  testRuntime okModel [staticTool "shell" "ok", staticTool "fs_read" "ok"] Parallel
    >>= \base ->
      case Map.lookup "sub_agent" (runtimeTools (registerSubAgent base)) of
        Nothing -> assertFailure "missing sub_agent"
        Just backend ->
          let description = toolDescription (backendToolSpec backend)
           in sequence_
                [ assertBool "description names shell" ("shell" `Text.isInfixOf` description),
                  assertBool "description names fs_read" ("fs_read" `Text.isInfixOf` description),
                  assertBool "description excludes itself" (not ("sub_agent" `Text.isInfixOf` description))
                ]

inheritedShell :: Assertion
inheritedShell = withWorkDir $ \dir -> do
  manager <- newTlsManager
  base <- testRuntime subShellModel [] Sequential
  runtime <-
    resolveRuntime
      manager
      testProvider
      Nothing
      base
      (emptyThreadConfig {configCwd = CwdPath dir})
      Map.empty
      Map.empty
  events <- collectEvents runtime (sampleInput [])
  assertBool "parent receives the child answer" (any childAnswer events)
  assertBool "nested event exposes the shell call" (any nestedShell events)

childAnswer :: Event -> Bool
childAnswer (ToolCallResult _ "call-delegate" content) = "child-ok" `Text.isInfixOf` content
childAnswer _ = False
nestedShell :: Event -> Bool
nestedShell (Custom "agent.sub" value) =
  parseMaybe
    ( withObject "agent.sub" $ \fields ->
        fields .: "event"
          >>= withObject
            "event"
            (\event -> (,) <$> event .: "type" <*> event .:? "toolCallName")
    )
    value
    == Just ("TOOL_CALL_START" :: Text, Just ("shell" :: Text))
nestedShell _ = False

registration :: Assertion
registration = do
  manager <- newTlsManager
  base <- testRuntime okModel [] Parallel
  let resolved depth = resolveRuntime manager testProvider Nothing base {runtimeDepth = depth} emptyThreadConfig Map.empty Map.empty
  one <- resolved 1
  two <- resolved 2
  zero <- resolved 0
  assertBool "depth one registers" (Map.member "sub_agent" (runtimeTools one))
  assertBool "deeper still registers" (Map.member "sub_agent" (runtimeTools two))
  assertBool "depth zero omits" (Map.notMember "sub_agent" (runtimeTools zero))
  runtimeDepth one @?= 1

delegation :: Assertion
delegation = do
  (journal, readEntries) <- newMemoryJournal
  runtime <- delegateRuntime journal 1
  events <- collectEvents runtime (sampleInput [])
  recorded <- readEntries
  report <- replayEntries defaultHooks Nothing recorded
  [content | ToolCallResult _ "call-delegate" content <- events] @?= ["sub result"]
  assertBool "sub-run events are scoped" (any isSubEvent events)
  assertBool "journal nests the sub-run scope" (any ((== 2) . length . entryScope) recorded)
  fmap reportDivergence report @?= Right Nothing

depthExhausted :: Assertion
depthExhausted = do
  (journal, _) <- newMemoryJournal
  runtime <- delegateRuntime journal 0
  events <- collectEvents runtime (sampleInput [])
  [content | ToolCallResult _ "call-delegate" content <- events] @?= ["delegation depth exhausted"]
  assertBool "no sub-run events" (not (any isSubEvent events))

isSubEvent :: Event -> Bool
isSubEvent (Custom "agent.sub" _) = True
isSubEvent _ = False
subShellModel :: Model
subShellModel =
  fakeModel $ \request emit ->
    case lastMessage request of
      Just (ChatToolResult "call-delegate" _) -> emit (ModelTextDelta "parent done") $> Stop
      Just (ChatToolResult "call-shell" content) -> emit (ModelTextDelta content) $> Stop
      Just (ChatUser "run local shell") ->
        emit (ModelToolCallDelta 0 (Just "call-shell") (Just "shell") "{\"command\":\"printf child-ok\"}")
          $> ToolUse
      _ ->
        emit (ModelToolCallDelta 0 (Just "call-delegate") (Just "sub_agent") "{\"prompt\":\"run local shell\"}")
          $> ToolUse
delegateRuntime :: Journal -> Int -> IO Runtime
delegateRuntime journal depth =
  testRuntime subAgentModel [] Parallel >>= \base ->
    let tools = Map.fromList [("delegate", subAgentTool "delegate" "run a sub-agent" runtime)]
        runtime = base {runtimeJournal = Just journal, runtimeTools = tools, runtimeDepth = depth}
     in pure runtime
subAgentModel :: Model
subAgentModel =
  fakeModel $ \request emit ->
    case lastMessage request of
      Just (ChatToolResult {}) -> emit (ModelTextDelta "parent done") $> Stop
      Just (ChatUser "sub task") -> emit (ModelTextDelta "sub result") $> Stop
      _ ->
        emit (ModelToolCallDelta 0 (Just "call-delegate") (Just "delegate") "{\"prompt\":\"sub task\"}")
          $> ToolUse
