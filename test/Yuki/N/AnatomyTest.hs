module Yuki.N.AnatomyTest
  ( anatomyTests,
    aggregates,
    emptyJournal,
  )
where

import Data.Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Types
import Yuki.N.Anatomy
import Yuki.N.Journal
import Yuki.N.Model

anatomyTests :: TestTree
anatomyTests =
  testGroup
    "token anatomy"
    [ testCase "aggregates categories across model requests" aggregates,
      testCase "treats an empty journal as zero" emptyJournal
    ]

aggregates :: Assertion
aggregates =
  anatomyEntries specimen
    @?= AnatomyReport
      2
      (Anatomy 8 (2 * specimenSize) 20 36 8 32)
      (Just (Anatomy 4 specimenSize 12 24 4 16))

emptyJournal :: Assertion
emptyJournal = anatomyEntries [] @?= AnatomyReport 0 mempty Nothing

specimen :: [Entry]
specimen =
  [ Entry 1 ["run"] Nothing (ModelRequestEntry firstRequest),
    Entry 2 ["run"] Nothing (ModelEventEntry (ModelTextDelta "noise")),
    Entry 3 ["run"] Nothing (ModelRequestEntry secondRequest)
  ]
specimenSize :: Int
specimenSize = fromIntegral (LazyByteString.length (encode [specimenSpec]))
specimenSpec :: ToolSpec
specimenSpec = ToolSpec "echo" "echo" (object ["type" .= ("object" :: Text)])
firstRequest :: ModelRequest
firstRequest =
  ModelRequest
    [ ChatSystem (Text.replicate 4 "s"),
      ChatUser (Text.replicate 8 "u"),
      ChatAssistant
        ( AssistantTurn
            "m1"
            (Just (Text.replicate 4 "b"))
            (Just (Text.replicate 4 "r"))
            [ModelToolCall "c1" "echo" (Text.replicate 8 "a")]
        ),
      ChatToolResult "c1" (Text.replicate 16 "t")
    ]
    [specimenSpec]
secondRequest :: ModelRequest
secondRequest =
  ModelRequest
    ( requestMessages firstRequest
        <> [ ChatAssistant (AssistantTurn "m2" (Just (Text.replicate 12 "b")) Nothing []),
             ChatUser (Text.replicate 4 "u")
           ]
    )
    [specimenSpec]
