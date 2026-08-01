module Yuki.N.Cognition.MemoryTest
  ( cognitionLongTermTest,
    cognitionImpression,
    cognitionImpressionAcrossTasks,
    cognitionImpressionFailure,
    cognitionImpressionClosure,
    cognitionImpressionProposalGuard,
    cognitionImpressionEvidenceGuard,
    cognitionImpressionDiagnosticGuard,
    cognitionImpressionFalseMigration,
    cognitionMemoryTests,
  )
where

import Data.Aeson
import Data.Functor (($>))
import Data.IORef
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Cognition
import Yuki.N.Experience
import Yuki.N.Memory.Impression
import Yuki.N.Memory.LongTerm
import Yuki.N.Model
import Yuki.N.TestSupport

cognitionLongTermTest :: Assertion
cognitionLongTermTest = withWorkDir $ \dir -> do
  store <- newLongTermStore dir >>= expectTextRight
  memory <-
    longTermRemember
      store
      (RememberRequest "yuki" MemoryPrivate "preference" "琥珀色是这个分身的参考色" ["琥珀", "color"] ["experience/1"])
      >>= expectTextRight
  own <- longTermCatalog store "yuki" 10
  other <- longTermCatalog store "other" 10
  _ <- longTermGrep store (GrepRequest "yuki" "琥珀" Nothing 8) >>= expectTextRight
  _ <- longTermRead store (ReadRequest "yuki" (longMemoryId memory) Nothing) >>= expectTextRight
  reopened <- newLongTermStore dir >>= expectTextRight
  receipts <- longTermReceipts reopened "yuki"
  fmap memoryCatalogId own @?= [longMemoryId memory]
  other @?= []
  length receipts @?= 2
  sort (fmap memoryReadReceiptAction receipts) @?= ["grep", "read"]

cognitionImpression :: Assertion
cognitionImpression = do
  longTerm <- newMemoryLongTermStore
  memory <-
    longTermRemember
      longTerm
      (RememberRequest "yuki" MemoryPrivate "preference" "secret amber memory content" ["amber"] ["source"])
      >>= expectTextRight
  impressions <- newMemoryImpressionStore
  catalog <- longTermCatalog longTerm "yuki" 8
  activation <-
    activateImpression
      [impressionCueModel (longMemoryId memory)]
      Nothing
      impressions
      "yuki"
      (ImpressionScope "task" "run" "intent")
      "pick a color"
      [longMemoryId memory]
      (jsonText catalog)
      >>= expectTextRight
  let injected = impressionActivationInjectedText activation
  assertBool "cue is explicitly non-factual" ("non-factual" `Text.isInfixOf` injected)
  assertBool "cue tells the agent to grep" ("memory_grep" `Text.isInfixOf` injected)
  assertBool "long-term content is not injected" (not ("secret amber memory content" `Text.isInfixOf` injected))

cognitionImpressionAcrossTasks :: Assertion
cognitionImpressionAcrossTasks = withWorkDir $ \dir -> do
  cognition <- newCognition dir [impressionCueWithoutMemoryModel] Nothing >>= expectTextRight
  incarnation <- ensureIncarnation cognition "yuki"
  let hooks = cognitionHooks cognition incarnation
      first = impressionInput "task-a" "run-a" "intent-a" "first direction"
      second = impressionInput "task-b" "run-b" "intent-b" "second direction"
      activate input = transformContext hooks input [ChatUser (latestUser input)]
  firstContext <- activate first
  secondContext <- activate second
  _ <- activate second
  activations <- impressionActivations (cognitionImpressions cognition) "yuki"
  fmap impressionActivationTaskId activations @?= ["task-a", "task-b"]
  fmap impressionActivationRunId activations @?= ["run-a", "run-b"]
  fmap impressionActivationIntentId activations @?= ["intent-a", "intent-b"]
  fmap impressionActivationError activations @?= [Nothing, Nothing]
  assertBool "first task received an impression cue" (any impressionCue firstContext)
  assertBool "second task received an impression cue" (any impressionCue secondContext)
 where
  latestUser input =
    fromMaybe "" . listToMaybe . reverse $
      [text | User message <- runMessages input, Right text <- [userText (userContent message)]]
  impressionCue (ChatSystem content) = "non-factual" `Text.isInfixOf` content
  impressionCue _ = False

cognitionImpressionFailure :: Assertion
cognitionImpressionFailure = withWorkDir $ \dir -> do
  cognition <- newCognition dir [] Nothing >>= expectTextRight
  incarnation <- ensureIncarnation cognition "yuki"
  let input = impressionInput "task-failed" "run-failed" "intent-failed" "unavailable profile"
  _ <- transformContext (cognitionHooks cognition incarnation) input [ChatUser "unavailable profile"]
  activations <- impressionActivations (cognitionImpressions cognition) "yuki"
  case activations of
    [activation] -> do
      impressionActivationTaskId activation @?= "task-failed"
      impressionActivationRunId activation @?= "run-failed"
      impressionActivationIntentId activation @?= "intent-failed"
      impressionActivationError activation @?= Just "model chain exhausted"
    _ -> assertFailure ("unexpected activation failure count: " <> show (length activations))

impressionInput :: Text -> Text -> Text -> Text -> RunAgentInput
impressionInput task run intent content =
  (sampleInput [])
    { runThreadId = task,
      runId = run,
      runMessages = [User (UserMessage intent (UserText content) Nothing)]
    }

cognitionImpressionClosure :: Assertion
cognitionImpressionClosure = withWorkDir $ \dir -> do
  captured <- newIORef []
  cognition <- newCognition dir [impressionConsolidationModel captured] Nothing >>= expectTextRight
  incarnation <- ensureIncarnation cognition "yuki"
  let input =
        (sampleInput [])
          { runThreadId = "closure-task",
            runId = "closure-run",
            runMessages =
              [ User
                  ( UserMessage
                      "closure-user"
                      (UserText "actual-user-payload-sentinel")
                      Nothing
                  )
              ]
          }
      messages =
        [ ChatUser "actual-user-payload-sentinel",
          ChatAssistant
            (AssistantTurn "closure-answer" (Just "actual-assistant-payload-sentinel") Nothing [])
        ]
  afterRunOutcome (cognitionHooks cognition incarnation) input RunSucceeded messages
  finished <-
    waitUntil
      ( any ((== "ImpressionConsolidationSucceeded") . experienceKind)
          <$> experienceEvents (cognitionExperiences cognition) "yuki"
      )
  requestMessages' <- readIORef captured
  state <- impressionRead (cognitionImpressions cognition) "yuki"
  revisions <- impressionRevisions (cognitionImpressions cognition) "yuki"
  let rendered =
        Text.intercalate
          "\n"
          [text | ChatUser text <- requestMessages']
      source =
        impressionRevisionExperienceRef
          <$> listToMaybe (reverse revisions)
  assertBool "consolidation completed" finished
  assertBool "closure contains the real user payload" ("actual-user-payload-sentinel" `Text.isInfixOf` rendered)
  assertBool "closure contains the real assistant payload" ("actual-assistant-payload-sentinel" `Text.isInfixOf` rendered)
  assertBool "revision carries its source experience" (maybe False (not . Text.null) source)
  impressionRevision state @?= 1

cognitionImpressionProposalGuard :: Assertion
cognitionImpressionProposalGuard =
  newMemoryImpressionStore >>= \impressions ->
    consolidateImpression
      [ungroundedProposalModel]
      Nothing
      impressions
      "yuki"
      "experience-1"
      []
      ["experience-1"]
      "{}"
      >>= assertLeft

cognitionImpressionEvidenceGuard :: Assertion
cognitionImpressionEvidenceGuard =
  newMemoryImpressionStore >>= \impressions ->
    consolidateImpression
      [impressionDecisionModel "continuity" "This direction may continue." []]
      Nothing
      impressions
      "yuki"
      "experience-1"
      []
      ["experience-1"]
      "{}"
      >>= assertLeft

cognitionImpressionDiagnosticGuard :: Assertion
cognitionImpressionDiagnosticGuard =
  newMemoryImpressionStore >>= \impressions ->
    consolidateImpression
      [impressionDecisionModel "grep lesson" "A truncated memory_grep result requires memory_read." ["experience-1"]]
      Nothing
      impressions
      "yuki"
      "experience-1"
      []
      ["experience-1"]
      "{}"
      >>= assertLeft

cognitionImpressionFalseMigration :: Assertion
cognitionImpressionFalseMigration = withWorkDir $ \dir -> do
  encodeFile (dir ++ "/impressions.json") legacy
  store <- newImpressionStore dir >>= expectTextRight
  state <- impressionRead store "yuki-8nckh0"
  revisions <- impressionRevisions store "yuki-8nckh0"
  reopened <- newImpressionStore dir >>= expectTextRight
  again <- impressionRead reopened "yuki-8nckh0"
  impressionRevision state @?= 4
  impressionItems state @?= []
  impressionRevision again @?= 4
  assertBool
    "migration records the voided impression"
    ( any
        (elem "impression-q1r2s3" . impressionRevisionVoidProposals)
        revisions
    )
 where
  legacy =
    object
      [ "states"
          .= Map.fromList
            [ ( "yuki-8nckh0" :: Text,
                object
                  [ "incarnationId" .= ("yuki-8nckh0" :: Text),
                    "revision" .= (3 :: Int),
                    "items"
                      .= [ object
                             [ "id" .= ("impression-q1r2s3" :: Text),
                               "label" .= ("GrepTruncationAwareness" :: Text),
                               "intuition" .= ("memory_grep scannedEntries hid 改天孙观为婺女观." :: Text),
                               "strength" .= (0.9 :: Double),
                               "sourceMemoryIds" .= ([] :: [Text]),
                               "sourceExperienceRefs" .= ["event-1" :: Text],
                               "updated" .= (1 :: Int)
                             ]
                         ],
                    "generatorRevision" .= ("impression-consolidation/v2" :: Text),
                    "effectiveHash" .= ("old" :: Text),
                    "updated" .= (1 :: Int)
                  ]
              )
            ],
        "activations" .= ([] :: [Value]),
        "revisions" .= ([] :: [Value])
      ]

ungroundedProposalModel :: Model
ungroundedProposalModel =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "impressions" .= ([] :: [Value]),
                    "memoryProposals"
                      .= [ object
                             [ "content" .= ("remember this without evidence" :: Text),
                               "kind" .= ("preference" :: Text),
                               "visibility" .= ("private" :: Text),
                               "sourceRefs" .= ([] :: [Text]),
                               "reason" .= ("model suggestion" :: Text)
                             ]
                         ],
                    "voidProposals" .= ([] :: [Text]),
                    "reason" .= ("proposal audit" :: Text)
                  ]
              )
          )
      )
      $> Stop
impressionDecisionModel :: Text -> Text -> [Text] -> Model
impressionDecisionModel label intuition sources =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "impressions"
                      .= [ object
                             [ "id" .= ("" :: Text),
                               "label" .= label,
                               "intuition" .= intuition,
                               "strength" .= (0.7 :: Double),
                               "sourceMemoryIds" .= ([] :: [Text]),
                               "sourceExperienceRefs" .= sources
                             ]
                         ],
                    "memoryProposals" .= ([] :: [Value]),
                    "voidProposals" .= ([] :: [Text]),
                    "reason" .= ("test" :: Text)
                  ]
              )
          )
      )
      $> Stop
impressionConsolidationModel :: IORef [ChatMessage] -> Model
impressionConsolidationModel captured =
  fakeModel $ \request emit ->
    writeIORef captured (requestMessages request)
      *> emit
        ( ModelTextDelta
            ( jsonText
                ( object
                    [ "impressions" .= ([] :: [Value]),
                      "memoryProposals" .= ([] :: [Value]),
                      "voidProposals" .= ([] :: [Text]),
                      "reason" .= ("integrated the completed experience" :: Text)
                    ]
                )
            )
        )
      $> Stop
impressionCueModel :: Text -> Model
impressionCueModel memoryId =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "cues"
                      .= [ object
                             [ "hint" .= ("A color preference may be relevant." :: Text),
                               "suggestedQuery" .= ("amber" :: Text),
                               "memoryIds" .= [memoryId],
                               "confidence" .= (0.8 :: Double),
                               "reason" .= ("intent resembles a prior preference" :: Text)
                             ]
                         ]
                  ]
              )
          )
      )
      $> Stop
impressionCueWithoutMemoryModel :: Model
impressionCueWithoutMemoryModel =
  fakeModel $ \_ emit ->
    emit
      ( ModelTextDelta
          ( jsonText
              ( object
                  [ "cues"
                      .= [ object
                             [ "hint" .= ("A prior direction may be relevant." :: Text),
                               "suggestedQuery" .= Null,
                               "memoryIds" .= ([] :: [Text]),
                               "confidence" .= (0.7 :: Double),
                               "reason" .= ("the intent resembles an established working direction" :: Text)
                             ]
                         ]
                  ]
              )
          )
      )
      $> Stop
cognitionMemoryTests :: TestTree
cognitionMemoryTests =
  testGroup
    "incarnation cognition memory"
    [ testCase "keeps long-term memory explicit, scoped and receipt-audited" cognitionLongTermTest,
      testCase "activates non-factual impressions without injecting memory content" cognitionImpression,
      testCase "activates and audits impressions across tasks" cognitionImpressionAcrossTasks,
      testCase "records impression activation failures with task scope" cognitionImpressionFailure,
      testCase "consolidates impressions from the actual experience payload closure" cognitionImpressionClosure,
      testCase "rejects ungrounded impression memory proposals" cognitionImpressionProposalGuard,
      testCase "requires current evidence for new impressions" cognitionImpressionEvidenceGuard,
      testCase "keeps tool diagnostics out of impressions" cognitionImpressionDiagnosticGuard,
      testCase "migrates the known false grep impression with provenance" cognitionImpressionFalseMigration
    ]
