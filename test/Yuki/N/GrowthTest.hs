module Yuki.N.GrowthTest
  ( growthTests,
    journalRetention,
    journalInspectionCache,
    artifactRetention,
  )
where

import Data.Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Maybe (fromMaybe, listToMaybe)
import Network.HTTP.Types
import Network.Wai.Test
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Artifact
import Yuki.N.Inspect
import Yuki.N.Journal
import Yuki.N.Server
import Yuki.N.TestSupport

growthTests :: TestTree
growthTests =
  testGroup
    "bounded local state"
    [ testCase "journal keeps complete recent runs and preserves sequence across compaction" journalRetention,
      testCase "live journal inspection uses the in-memory index" journalInspectionCache,
      testCase "artifact retention removes old objects and compacts the index" artifactRetention
    ]

journalRetention :: Assertion
journalRetention = withWorkDir $ \dir -> do
  journal <- newFileJournalWithLimit 2 dir
  traverse_ (recordRun journal) ["run-1", "run-2", "run-3"]
  entries <- journalSnapshot journal
  verify [2, 3, 4, 5] ["run-2", "run-3"] entries
  reopened <- newFileJournalWithLimit 2 dir
  recordRun reopened "run-4"
  entries' <- journalSnapshot reopened
  verify [4, 5, 6, 7] ["run-3", "run-4"] entries'
 where
  settings = RunSettings 8 Parallel "" 1 Nothing Nothing Nothing
  recordRun journal run =
    let input = (sampleInput []) {runId = run}
        scoped = subJournal run journal
     in recordMaybe (Just scoped) (RunBegin input settings)
          *> recordMaybe (Just scoped) (IdEntry ("id-" <> run))
  verify seqs runs entries =
    sequence_
      [ fmap entrySeq entries @?= seqs,
        [runId input | Entry _ scope _ (RunBegin input _) <- entries, length scope == 1] @?= runs
      ]

journalInspectionCache :: Assertion
journalInspectionCache = withWorkDir $ \dir -> do
  journal <- newFileJournal dir
  recordMaybe (Just journal) (IdEntry "cached")
  base <- testRuntime okModel [] Parallel
  let path = journalFilePath dir
      inspection = withLiveJournal journal (newInspection Nothing (Just path) Nothing)
      app = application Nothing (Just inspection) Nothing Nothing Nothing Nothing (const (pure base))
  LazyByteString.writeFile path "{broken"
  response <- runSession (request (httpGet ["journal"])) app
  simpleStatus response @?= status200
  either assertFailure (\entries -> fmap entryKind entries @?= [IdEntry "cached"]) (eitherDecode (simpleBody response))

artifactRetention :: Assertion
artifactRetention = withWorkDir $ \dir -> do
  store <- newArtifactStoreWithLimit 2 dir
  identifiers <- traverse (artifactSave store "tool") ["first", "second", "third"]
  listed <- artifactList store
  oldest <- artifactFetch store (fromMaybe "" (listToMaybe identifiers))
  reopened <- newArtifactStoreWithLimit 2 dir
  afterRestart <- artifactList reopened
  length listed @?= 2
  oldest @?= Nothing
  length afterRestart @?= 2
  bytes <- LazyByteString.readFile (dir ++ "/index.jsonl")
  length (filter (not . LazyByteString.null) (LazyByteString.split 10 bytes)) @?= 2
