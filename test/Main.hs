module Main (main) where

import E2E (e2eTests)
import Golden (goldenTests)
import Test.Tasty
import Yuki.N.AGUITest
import Yuki.N.ActivityTest
import Yuki.N.AdversarialTest
import Yuki.N.AgentTest
import Yuki.N.AgentsMdTest
import Yuki.N.AnatomyTest
import Yuki.N.ArtifactTest
import Yuki.N.Cognition.ArchiveTest
import Yuki.N.Cognition.LifecycleTest
import Yuki.N.Cognition.MemoryTest
import Yuki.N.Cognition.SleepTest
import Yuki.N.CognitionTest
import Yuki.N.ConfigTest
import Yuki.N.ContextTest
import Yuki.N.DiffTest
import Yuki.N.DispatchTest
import Yuki.N.DispatchToolTest
import Yuki.N.FactsTest
import Yuki.N.GrowthTest
import Yuki.N.InvocationTest
import Yuki.N.JournalTest
import Yuki.N.MemoryTest
import Yuki.N.Provider.OpenAITest
import Yuki.N.ProvidersTest
import Yuki.N.RunsTest
import Yuki.N.ServerCognitionTest
import Yuki.N.ServerTest
import Yuki.N.SessionTest
import Yuki.N.SubAgentTest
import Yuki.N.Telemetry.LedgerTest
import Yuki.N.TelemetryTest
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
        telemetryTests,
        activityTests,
        ledgerTests,
        steeringTests,
        retryTests,
        fallbackTests,
        spliceTests,
        contextTests,
        subAgentTests,
        hooksTests,
        machineTests,
        auditTests,
        artifactTests,
        anatomyTests,
        memoryTests,
        cognitionTests,
        cognitionTaskArchiveTests,
        cognitionMemoryTests,
        cognitionLifecycleTests,
        cognitionSleepTests,
        factsTests,
        serverTests,
        serverCognitionTests,
        configTests,
        configBoundaryTests,
        workToolTests,
        planTests,
        adversarialTests,
        threadConfigTests,
        agentsMdTests,
        sessionTests,
        growthTests,
        transcriptTests,
        invocationTests,
        diffTests,
        dispatchTests,
        dispatchToolTests,
        e2eTests,
        goldenTests
      ]
