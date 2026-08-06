module Main (main) where

import E2E (e2eTests)
import Test.Tasty
import Yuki.N.AGUITest
import Yuki.N.AdversarialTest
import Yuki.N.AgentTest
import Yuki.N.AgentsMdTest
import Yuki.N.ArtifactTest
import Yuki.N.ConfigTest
import Yuki.N.ContextTest
import Yuki.N.DiffTest
import Yuki.N.Provider.OpenAITest
import Yuki.N.ProvidersTest
import Yuki.N.RunsTest
import Yuki.N.ServerTest
import Yuki.N.SessionTest
import Yuki.N.SubAgentTest
import Yuki.N.ThreadConfigTest
import Yuki.N.ToolsTest
import Yuki.N.TranscriptTest

main :: IO ()
main =
  defaultMain $
    testGroup
      "yuki-n"
      [ protocolTests,
        eventJsonTests,
        providerTests,
        providersTests,
        providerFileTests,
        agentTests,
        terminationTests,
        steeringTests,
        retryTests,
        fallbackTests,
        spliceTests,
        contextTests,
        subAgentTests,
        hooksTests,
        machineTests,
        artifactTests,
        serverTests,
        configTests,
        configBoundaryTests,
        workToolTests,
        planTests,
        adversarialTests,
        threadConfigTests,
        agentsMdTests,
        sessionTests,
        transcriptTests,
        diffTests,
        e2eTests
      ]
