module Yuki.N.ServerTest
  ( serverTests,
    briefOverHttp,
    factsOverHttp,
    artifactsOverHttp,
    journalOverHttp,
    summaryOverHttp,
    traceOverHttp,
    replayOverHttp,
    capabilityDegradation,
    inspectionMissing,
    serverEvents,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor (($>))
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Types
import Network.Wai (Application, pathInfo, queryString, requestHeaders, requestMethod)
import Network.Wai.Test
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Artifact
import Yuki.N.Facts
import Yuki.N.Inspect
import Yuki.N.Journal
import Yuki.N.Memory
import Yuki.N.Model
import Yuki.N.Provider.OpenAI
import Yuki.N.Server
import Yuki.N.TestSupport

serverTests :: TestTree
serverTests =
  testGroup
    "HTTP server"
    [ testCase "serves AG-UI events as SSE" serverEvents,
      testCase "serves the thread brief, 404 when the thread is unknown" briefOverHttp,
      testCase "lists facts" factsOverHttp,
      testCase "lists artifacts and serves raw content" artifactsOverHttp,
      testCase "lists journal runs and filters entries by run" journalOverHttp,
      testCase "serves a run summary and 404s unknown runs" summaryOverHttp,
      testCase "serves an aggregated run trace" traceOverHttp,
      testCase "replays a journaled run over HTTP" replayOverHttp,
      testCase "degrades per capability" capabilityDegradation,
      testCase "inspection routes 404 without an Inspection" inspectionMissing
    ]
inspectionFixture :: IO (Application, Text, Int)
inspectionFixture = do
  threads <- newMemoryThreadStore
  facts <- newMemoryFactStore
  artifacts <- newMemoryArtifactStore
  tmp <- getTemporaryDirectory
  identifier <- newId
  let dir = tmp ++ "/" ++ Text.unpack identifier
  createDirectoryIfMissing True dir
  (journal, readEntries) <- newMemoryJournal
  seed threads facts artifacts dir (journal, readEntries)
 where
  seed threads facts artifacts dir (journal, readEntries) = do
    threadSaveEpisode threads "thread" (Episode "run-0" "earlier" 1700000000)
    _ <- factAdd facts "the deploy target is fly.io" FactProject "run-0"
    _ <- artifactSave artifacts "big" bigContent
    base <- testRuntime echoModel [echoTool] Parallel
    events <- collectEvents base {runtimeJournal = Just journal} (journaledInput "run-1")
    _ <- collectEvents base {runtimeJournal = Just journal} (journaledInput "run-2")
    recorded <- readEntries
    LazyByteString.writeFile (journalFilePath dir) (renderJournal recorded)
    pure
      ( application Nothing (Just (inspection threads facts artifacts dir)) Nothing Nothing (const (pure base)),
        artifactIdFor bigContent,
        length events
      )
  renderJournal = LazyByteString.concat . fmap ((<> "\n") . encode)
  inspection threads facts artifacts dir =
    newInspection (Just (threads, facts)) (Just artifacts) (Just (journalFilePath dir)) Nothing
journaledInput :: Text -> RunAgentInput
journaledInput run = (sampleInput [tool "echo"]) {runId = run}
replayRequest :: LazyByteString.ByteString -> SRequest
replayRequest body =
  SRequest
    { simpleRequest =
        defaultRequest
          { requestMethod = methodPost,
            pathInfo = ["replay"],
            requestHeaders = [(hContentType, "application/json")]
          },
      simpleRequestBody = body
    }

briefOverHttp :: Assertion
briefOverHttp = do
  (app, _, _) <- inspectionFixture
  found <- runSession (request (httpGet ["memory", "threads", "thread"])) app
  unknown <- runSession (request (httpGet ["memory", "threads", "unknown"])) app
  simpleStatus found @?= status200
  simpleStatus unknown @?= status404
  either assertFailure ((@?= "earlier") . briefRollingSummary) (eitherDecode (simpleBody found))

factsOverHttp :: Assertion
factsOverHttp = do
  (app, _, _) <- inspectionFixture
  response <- runSession (request (httpGet ["memory", "facts"])) app
  simpleStatus response @?= status200
  either
    assertFailure
    ((@?= ["the deploy target is fly.io"]) . fmap factContent)
    (eitherDecode (simpleBody response))

artifactsOverHttp :: Assertion
artifactsOverHttp = do
  (app, identifier, _) <- inspectionFixture
  listed <- runSession (request (httpGet ["artifacts"])) app
  fetched <- runSession (request (httpGet ["artifacts", identifier])) app
  missing <- runSession (request (httpGet ["artifacts", "art-missing"])) app
  simpleStatus listed @?= status200
  either assertFailure (metasMatch identifier) (eitherDecode (simpleBody listed))
  simpleStatus fetched @?= status200
  lookup hContentType (simpleHeaders fetched) @?= Just "text/plain; charset=utf-8"
  simpleBody fetched @?= LazyByteString.fromStrict (TextEncoding.encodeUtf8 bigContent)
  simpleStatus missing @?= status404
 where
  metasMatch identifier metas =
    fmap (\meta -> (artifactMetaId meta, artifactMetaToolName meta, artifactMetaChars meta)) metas
      @?= [(identifier, "big", Text.length bigContent)]

journalOverHttp :: Assertion
journalOverHttp = do
  (app, _, _) <- inspectionFixture
  runs <- runSession (request (httpGet ["journal", "runs"])) app
  everything <- runSession (request (httpGet ["journal"])) app
  matching <- runSession (request filtered) app
  simpleStatus runs @?= status200
  either assertFailure (@?= ["run-1", "run-2"]) (eitherDecode (simpleBody runs) :: Either String [Text])
  simpleStatus everything @?= status200
  simpleStatus matching @?= status200
  verify
    (eitherDecode (simpleBody everything) :: Either String [Entry])
    (eitherDecode (simpleBody matching) :: Either String [Entry])
 where
  filtered = (httpGet ["journal"]) {queryString = [("run", Just "run-1")]}
  verify allDecoded matchingDecoded = case (allDecoded, matchingDecoded) of
    (Right allEntries, Right matchingEntries) ->
      sequence_
        [ assertBool "filter is not empty" (not (null matchingEntries)),
          assertBool
            "filter keeps only the wanted run"
            (all ((== Just "run-1") . listToMaybe . entryScope) matchingEntries),
          assertBool "journal holds more than one run" (length allEntries > length matchingEntries)
        ]
    _ -> assertFailure "journal responses must decode"

summaryOverHttp :: Assertion
summaryOverHttp = do
  (app, _, _) <- inspectionFixture
  found <- runSession (request (httpGet ["journal", "runs", "run-1", "summary"])) app
  unknown <- runSession (request (httpGet ["journal", "runs", "missing", "summary"])) app
  simpleStatus found @?= status200
  simpleStatus unknown @?= status404
  either assertFailure (@?= ("run-1", "finished", 2, 1)) (decodeSummary (simpleBody found))
 where
  decodeSummary :: LazyByteString.ByteString -> Either String (Text, Text, Int, Int)
  decodeSummary body =
    eitherDecode body
      >>= parseEither
        ( withObject "summary" $ \fields ->
            (,,,)
              <$> fields .: "runId"
              <*> fields .: "status"
              <*> fields .: "turns"
              <*> fields .: "toolCalls"
        )

traceOverHttp :: Assertion
traceOverHttp = do
  (app, _, _) <- inspectionFixture
  found <- runSession (request (httpGet ["journal", "runs", "run-1", "trace"])) app
  unknown <- runSession (request (httpGet ["journal", "runs", "missing", "trace"])) app
  simpleStatus found @?= status200
  simpleStatus unknown @?= status404
  either assertFailure (assertBool "trace includes causal steps" . (> 2)) (decodeSteps (simpleBody found))
 where
  decodeSteps :: LazyByteString.ByteString -> Either String Int
  decodeSteps body =
    eitherDecode body
      >>= parseEither
        (withObject "trace" (\fields -> length <$> (fields .: "steps" :: Parser [Value])))

replayOverHttp :: Assertion
replayOverHttp = do
  (app, _, eventCount) <- inspectionFixture
  explicit <- runSession (srequest (replayRequest (encode (object ["runId" .= ("run-1" :: Text)])))) app
  latest <- runSession (srequest (replayRequest "")) app
  simpleStatus explicit @?= status200
  either assertFailure (verifyReport eventCount "run-1") (decodeReport (simpleBody explicit))
  simpleStatus latest @?= status200
  either assertFailure (verifyReport eventCount "run-2") (decodeReport (simpleBody latest))
 where
  verifyReport expected run (reportRun, events, divergence) =
    sequence_ [reportRun @?= run, events @?= expected, divergence @?= Nothing]

decodeReport :: LazyByteString.ByteString -> Either String (Text, Int, Maybe Value)
decodeReport body =
  eitherDecode body
    >>= parseEither (withObject "report" (\fields -> (,,) <$> fields .: "runId" <*> fields .: "events" <*> fields .:? "divergence"))

capabilityDegradation :: Assertion
capabilityDegradation = do
  artifacts <- newMemoryArtifactStore
  let partial = newInspection Nothing (Just artifacts) Nothing Nothing
  base <- testRuntime echoModel [echoTool] Parallel
  listed <- runSession (request (httpGet ["artifacts"])) (application Nothing (Just partial) Nothing Nothing (const (pure base)))
  facts <- runSession (request (httpGet ["memory", "facts"])) (application Nothing (Just partial) Nothing Nothing (const (pure base)))
  simpleStatus listed @?= status200
  simpleStatus facts @?= status404

inspectionMissing :: Assertion
inspectionMissing = do
  base <- testRuntime echoModel [echoTool] Parallel
  facts <- runSession (request (httpGet ["memory", "facts"])) (application Nothing Nothing Nothing Nothing (const (pure base)))
  replay <- runSession (srequest (replayRequest "")) (application Nothing Nothing Nothing Nothing (const (pure base)))
  simpleStatus facts @?= status404
  simpleStatus replay @?= status404

serverEvents :: Assertion
serverEvents =
  testRuntime
    (fakeModel (\_ emit -> emit (ModelTextDelta "hello") $> Stop))
    []
    Parallel
    >>= run
 where
  run runtime = runSession agentRequest (application Nothing Nothing Nothing Nothing (const (pure runtime))) >>= verify
  agentRequest =
    srequest
      SRequest
        { simpleRequest =
            defaultRequest
              { requestMethod = methodPost,
                pathInfo = ["agent"],
                requestHeaders = [(hContentType, "application/json")]
              },
          simpleRequestBody = encode (sampleInput [])
        }
  verify response =
    let (decoder, payloads) = feedSse emptySseDecoder . LazyByteString.toStrict $ simpleBody response
        (_, trailing) = finishSse decoder
     in sequence_
          [ simpleStatus response @?= status200,
            lookup hContentType (simpleHeaders response) @?= Just "text/event-stream; charset=utf-8"
          ]
          *> (traverse decodeEventType (payloads <> trailing) >>= (@?= expected))
  expected =
    [ "RUN_STARTED",
      "STEP_STARTED",
      "TEXT_MESSAGE_START",
      "TEXT_MESSAGE_CONTENT",
      "TEXT_MESSAGE_END",
      "STEP_FINISHED",
      "RUN_FINISHED"
    ]

decodeEventType :: ByteString -> IO Text
decodeEventType payload =
  either
    (\message -> assertFailure message $> "")
    pure
    (eitherDecodeStrict' payload >>= parseEither (withObject "event" (.: "type")))
