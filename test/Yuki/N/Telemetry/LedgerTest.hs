module Yuki.N.Telemetry.LedgerTest
  ( ledgerTests,
  )
where

import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Functor (($>))
import Data.IORef
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Network.HTTP.Client.TLS (newTlsManager)
import System.Directory (createDirectoryIfMissing, removeFile)
import System.FilePath ((</>))
import System.Process (callProcess)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Agent
import Yuki.N.Runs (RunKind (..))
import Yuki.N.Telemetry
import Yuki.N.Telemetry.Ledger
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig

ledgerTests :: TestTree
ledgerTests =
  testGroup
    "telemetry ledger"
    [ testCase "deliveries append and query with filters, limit and cursor" deliveriesRoundTrip,
      testCase "fs changes append and query with run filter" fsChangesRoundTrip,
      testCase "fs write tools record created, modified and deleted changes" fsToolInterception,
      testCase "failed fs write records nothing" failedFsWrite,
      testCase "git enrichment records shell changes inside a repository" gitEnrichment,
      testCase "git enrichment stays silent outside a repository" gitEnrichmentOutside,
      testCase "unwritable ledger never breaks tool calls" failOpenLedger
    ]

deliveriesRoundTrip :: Assertion
deliveriesRoundTrip = withWorkDir $ \dir -> do
  ledger <- newLedger dir
  ticks <- newIORef (0 :: Integer)
  telemetry <- newTelemetryWithClock (readIORef ticks)
  let append delta thread kind =
        writeIORef ticks (delta * 1000000)
          *> recordDelivery
            ledger
            telemetry
            DeliveryRecord
              { deliveryId = "",
                deliveryRunId = "run-" <> thread,
                deliveryThreadId = thread,
                deliveryIncarnation = "yuki",
                deliveryRunKind = RunTask,
                deliveryKind = kind,
                deliveryTitle = "title-" <> thread,
                deliveryRef = "ref-" <> thread,
                deliveryBytes = Nothing,
                deliveryAt = 0
              }
  append 1 "t1" DeliveryAnswer
  append 2 "t1" DeliveryArtifact
  append 3 "t1" DeliveryFileWrite
  append 4 "t2" DeliveryAnswer
  appendDelivery
    ledger
    DeliveryRecord
      { deliveryId = "dlv-x",
        deliveryRunId = "run-t3",
        deliveryThreadId = "t3",
        deliveryIncarnation = "other",
        deliveryRunKind = RunTask,
        deliveryKind = DeliveryAnswer,
        deliveryTitle = "title-other",
        deliveryRef = "ref-other",
        deliveryBytes = Nothing,
        deliveryAt = 5
      }
  allYuki <- deliveriesFor ledger "yuki" Nothing 200 Nothing
  fmap deliveryThreadId allYuki @?= ["t2", "t1", "t1", "t1"]
  fmap deliveryAt allYuki @?= [4, 3, 2, 1]
  t1Only <- deliveriesFor ledger "yuki" (Just "t1") 200 Nothing
  fmap deliveryThreadId t1Only @?= ["t1", "t1", "t1"]
  capped <- deliveriesFor ledger "yuki" Nothing 2 Nothing
  fmap deliveryAt capped @?= [4, 3]
  beforeCursor <- deliveriesFor ledger "yuki" Nothing 200 (Just 3)
  fmap deliveryAt beforeCursor @?= [2, 1]
  beforeCapped <- deliveriesFor ledger "yuki" Nothing 1 (Just 3)
  fmap deliveryAt beforeCapped @?= [2]
  otherIncarnation <- deliveriesFor ledger "other" Nothing 200 Nothing
  fmap deliveryThreadId otherIncarnation @?= ["t3"]

fsChangesRoundTrip :: Assertion
fsChangesRoundTrip = withWorkDir $ \dir -> do
  ledger <- newLedger dir
  ticks <- newIORef (0 :: Integer)
  telemetry <- newTelemetryWithClock (readIORef ticks)
  let append delta run thread path =
        writeIORef ticks (delta * 1000000)
          *> recordFsChange
            ledger
            telemetry
            FsChangeRecord
              { fsChangeId = "",
                fsChangeRunId = run,
                fsChangeThreadId = thread,
                fsChangeIncarnation = "yuki",
                fsChangePath = path,
                fsChangeOp = FsCreated,
                fsChangeOrigin = OriginGit,
                fsChangeDiff = Nothing,
                fsChangeStat = Just "1 +",
                fsChangeAt = 0
              }
  append 1 "r1" "t1" "a.txt"
  append 2 "r2" "t1" "b.txt"
  append 3 "r1" "t2" "c.txt"
  byRun <- fsChangesFor ledger "yuki" (Just "t1") (Just "r1") 200 Nothing
  fmap fsChangePath byRun @?= ["a.txt"]
  byThread <- fsChangesFor ledger "yuki" (Just "t1") Nothing 200 Nothing
  fmap fsChangePath byThread @?= ["b.txt", "a.txt"]
  allChanges <- fsChangesFor ledger "yuki" Nothing Nothing 200 Nothing
  fmap fsChangePath allChanges @?= ["c.txt", "b.txt", "a.txt"]

fsToolInterception :: Assertion
fsToolInterception = withWorkDir $ \dir -> do
  (runtime, telemetry, ledger) <- wiredRuntime dir
  writeTool <- lookupTool runtime "fs_write"
  let context = ToolContext "run-1" "thread-1" "call-1" (const (pure ())) Nothing "yuki"
  created <- runBackendTool writeTool context (object ["path" .= ("a.txt" :: Text), "content" .= ("hello world" :: Text)])
  toolOutcomeError created @?= False
  modified <- runBackendTool writeTool context (object ["path" .= ("a.txt" :: Text), "content" .= ("hello world\nmore" :: Text)])
  toolOutcomeError modified @?= False
  let wrappedDelete = fsInterceptor telemetry ledger 8192 dir RunTask (deleteTool dir)
  deleted <- runBackendTool wrappedDelete context (object ["path" .= ("a.txt" :: Text)])
  toolOutcomeError deleted @?= False
  changes <- fsChangesFor ledger "yuki" Nothing Nothing 200 Nothing
  fmap fsChangePath changes @?= ["a.txt", "a.txt", "a.txt"]
  sort (fmap fsChangeOp changes) @?= [FsCreated, FsModified, FsDeleted]
  sort (fmap fsChangeOrigin changes) @?= [OriginTool "fs_delete" "call-1", OriginTool "fs_write" "call-1", OriginTool "fs_write" "call-1"]
  assertBool "diffs are present and carry content" (all (maybe False (Text.isInfixOf "hello world") . fsChangeDiff) changes)
  deliveries <- deliveriesFor ledger "yuki" Nothing 200 Nothing
  fmap deliveryKind deliveries @?= [DeliveryFileWrite, DeliveryFileWrite, DeliveryFileWrite]
  fmap deliveryRunKind deliveries @?= [RunTask, RunTask, RunTask]

failedFsWrite :: Assertion
failedFsWrite = withWorkDir $ \dir -> do
  (runtime, _, ledger) <- wiredRuntime dir
  writeTool <- lookupTool runtime "fs_write"
  let context = ToolContext "run-1" "thread-1" "call-1" (const (pure ())) Nothing "yuki"
  fine <- runBackendTool writeTool context (object ["path" .= ("x.txt" :: Text), "content" .= ("x" :: Text)])
  toolOutcomeError fine @?= False
  escaped <- runBackendTool writeTool context (object ["path" .= ("../esc.txt" :: Text), "content" .= ("y" :: Text)])
  toolOutcomeError escaped @?= True
  changes <- fsChangesFor ledger "yuki" Nothing Nothing 200 Nothing
  fmap fsChangePath changes @?= ["x.txt"]

gitEnrichment :: Assertion
gitEnrichment = withWorkDir $ \dir -> do
  callProcess "git" ["-C", dir, "init", "-q"]
  callProcess "git" ["-C", dir, "config", "user.email", "ledger@test"]
  callProcess "git" ["-C", dir, "config", "user.name", "ledger"]
  TextIO.writeFile (dir ++ "/tracked.txt") "one\n"
  callProcess "git" ["-C", dir, "add", "."]
  callProcess "git" ["-C", dir, "commit", "-qm", "init"]
  TextIO.writeFile (dir ++ "/new.txt") "fresh\n"
  TextIO.writeFile (dir ++ "/tracked.txt") "one\ntwo\n"
  ledger <- newLedger dir
  telemetry <- newTelemetry
  writeIORef (telemetryLedger telemetry) (Just ledger)
  enrichFromGit ledger telemetry 3 "yuki" "run-1" "thread-1" (Just dir)
  changes <- fsChangesFor ledger "yuki" (Just "thread-1") (Just "run-1") 200 Nothing
  length changes @?= 2
  let byPath = Map.fromList [(fsChangePath record, record) | record <- changes]
  case Map.lookup "new.txt" byPath of
    Nothing -> assertFailure "missing untracked file record"
    Just record -> do
      fsChangeOp record @?= FsCreated
      fsChangeOrigin record @?= OriginGit
      fsChangeDiff record @?= Nothing
      fsChangeStat record @?= Nothing
  case Map.lookup "tracked.txt" byPath of
    Nothing -> assertFailure "missing tracked file record"
    Just record -> do
      fsChangeOp record @?= FsModified
      fsChangeOrigin record @?= OriginGit
      fsChangeDiff record @?= Nothing
      assertBool "stat line is stored" (maybe False (Text.isInfixOf "tracked.txt") (fsChangeStat record))

gitEnrichmentOutside :: Assertion
gitEnrichmentOutside = withWorkDir $ \dir -> do
  TextIO.writeFile (dir ++ "/loose.txt") "x\n"
  ledger <- newLedger dir
  telemetry <- newTelemetry
  enrichFromGit ledger telemetry 3 "yuki" "run-1" "thread-1" (Just dir)
  changes <- fsChangesFor ledger "yuki" Nothing Nothing 200 Nothing
  changes @?= []

failOpenLedger :: Assertion
failOpenLedger = withWorkDir $ \dir -> do
  createDirectoryIfMissing True (dir ++ "/deliveries.jsonl")
  createDirectoryIfMissing True (dir ++ "/fs-changes.jsonl")
  (runtime, _, _) <- wiredRuntime dir
  writeTool <- lookupTool runtime "fs_write"
  let context = ToolContext "run-1" "thread-1" "call-1" (const (pure ())) Nothing "yuki"
  outcome <- runBackendTool writeTool context (object ["path" .= ("ok.txt" :: Text), "content" .= ("payload" :: Text)])
  toolOutcomeError outcome @?= False
  TextIO.readFile (dir ++ "/ok.txt") >>= (@?= "payload")

wiredRuntime :: FilePath -> IO (Runtime, Telemetry, Ledger)
wiredRuntime dir = do
  telemetry <- newTelemetry
  ledger <- newLedger dir
  writeIORef (telemetryLedger telemetry) (Just ledger)
  manager <- newTlsManager
  base <- testRuntime okModel [] Parallel
  resolved <- resolveRuntime manager testProvider Nothing base {runtimeTelemetry = Just telemetry} (emptyThreadConfig {configCwd = CwdPath dir}) Map.empty Map.empty
  pure (resolved, telemetry, ledger)

lookupTool :: Runtime -> Text -> IO BackendTool
lookupTool runtime name =
  maybe (assertFailure ("missing tool: " <> Text.unpack name)) pure (Map.lookup name (runtimeTools runtime))

deleteTool :: FilePath -> BackendTool
deleteTool dir =
  BackendTool
    (tool "fs_delete")
    ( \_ arguments ->
        case parseMaybe (withObject "delete" (.: "path")) arguments of
          Nothing -> pure (ToolOutcome "missing path" True False)
          Just path -> removeFile (dir </> path) $> ToolOutcome "deleted" False False
    )
