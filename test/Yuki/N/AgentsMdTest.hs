module Yuki.N.AgentsMdTest
  ( agentsMdTests,
    nestedAgentsMd,
    absentAgentsMd,
    unreadableAgentsMd,
    cappedAgentsMd,
    appendShape,
    resolveAgentsMd,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Network.HTTP.Client.TLS (newTlsManager)
import System.Directory (createDirectoryIfMissing, emptyPermissions, getPermissions, setPermissions)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Agent
import Yuki.N.AgentsMd
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig

agentsMdTests :: TestTree
agentsMdTests =
  testGroup
    "AGENTS.md"
    [ testCase "collects nested files root-first with path headers" nestedAgentsMd,
      testCase "yields empty without any AGENTS.md" absentAgentsMd,
      testCase "skips unreadable files without failing" unreadableAgentsMd,
      testCase "caps the total at 32KB with a truncation note" cappedAgentsMd,
      testCase "appendAgentsMd joins with two blank lines only when both sides exist" appendShape,
      testCase "resolve appends the section when a cwd resolves, never without" resolveAgentsMd
    ]

nestedAgentsMd :: Assertion
nestedAgentsMd = withWorkDir $ \root -> do
  let leaf = root ++ "/leaf"
      expected = Text.intercalate "\n\n" [sectionOf root "root rules", sectionOf leaf "leaf rules"]
  createDirectoryIfMissing True leaf
  writeFile (root ++ "/AGENTS.md") "root rules"
  writeFile (leaf ++ "/AGENTS.md") "leaf rules"
  section <- agentsMdSection (Just leaf)
  assertBool "root-first with path headers" (Text.isInfixOf expected section)
 where
  sectionOf dir body = "# " <> Text.pack (dir ++ "/AGENTS.md") <> "\n\n" <> body

absentAgentsMd :: Assertion
absentAgentsMd =
  (agentsMdSection Nothing >>= (@?= ""))
    *> withWorkDir (\dir -> agentsMdSection (Just dir) >>= (@?= ""))

unreadableAgentsMd :: Assertion
unreadableAgentsMd = withWorkDir $ \root -> do
  let leaf = root ++ "/leaf"
      blocked = leaf ++ "/AGENTS.md"
  createDirectoryIfMissing True leaf
  writeFile (root ++ "/AGENTS.md") "root rules"
  writeFile blocked "hidden"
  original <- getPermissions blocked
  setPermissions blocked emptyPermissions
  section <- agentsMdSection (Just leaf)
  verify section
  setPermissions blocked original
 where
  verify section =
    sequence_
      [ assertBool "keeps the readable file" (Text.isInfixOf "root rules" section),
        assertBool "skips the unreadable file" (not (Text.isInfixOf "hidden" section))
      ]

cappedAgentsMd :: Assertion
cappedAgentsMd =
  withWorkDir $ \root ->
    writeFile (root ++ "/AGENTS.md") (replicate 40000 'x')
      *> (agentsMdSection (Just root) >>= (@?= expected root))
 where
  expected root = Text.take 32768 full <> "\n# AGENTS.md sections truncated at 32768 characters"
   where
    full = "# " <> Text.pack (root ++ "/AGENTS.md") <> "\n\n" <> Text.replicate 40000 "x"

appendShape :: Assertion
appendShape =
  sequence_
    [ appendAgentsMd "" "prompt" @?= "prompt",
      appendAgentsMd "section" "" @?= "section",
      appendAgentsMd "section" "prompt" @?= "prompt\n\n\nsection"
    ]

resolveAgentsMd :: Assertion
resolveAgentsMd = withWorkDir $ \root -> do
  manager <- newTlsManager
  base <- testRuntime okModel [] Parallel
  writeFile (root ++ "/AGENTS.md") "project rules"
  withCwd <- inject manager base (emptyThreadConfig {configCwd = CwdPath root})
  withSession <- inject manager base (emptyThreadConfig {configCwd = CwdPath root, configSystemPrompt = Just "session"})
  withoutCwd <- inject manager base emptyThreadConfig
  runtimeSystemPrompt withCwd @?= "base prompt\n\n\n# " <> Text.pack (root ++ "/AGENTS.md") <> "\n\nproject rules"
  runtimeSystemPrompt withSession @?= "session\n\n\n# " <> Text.pack (root ++ "/AGENTS.md") <> "\n\nproject rules"
  runtimeSystemPrompt withoutCwd @?= "base prompt"
 where
  inject manager base config = do
    resolved <-
      resolveRuntime manager testProvider Nothing base {runtimeSystemPrompt = "base prompt"} config Map.empty Map.empty
    section <- agentsMdSection (cwdPath (configCwd config))
    pure (resolved {runtimeSystemPrompt = appendAgentsMd section (runtimeSystemPrompt resolved)})
