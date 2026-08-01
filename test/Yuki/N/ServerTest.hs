-- | HTTP 服务测试
--
-- 覆盖：SSE agent 流、brief/facts/artifacts/journal/summary/trace/replay 端点、能力降级与 Inspection 缺失。
-- 边界：覆盖 Yuki.N.Server 与 Yuki.N.Inspect 的路由；真实 socket 见 E2E。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
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

import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Exception ()
import Control.Monad ()
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Bool ()
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable ()
import Data.Functor (($>))
import Data.IORef ()
import Data.List ()
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS ()
import Network.HTTP.Types
import Network.Wai (Application, pathInfo, queryString, requestHeaders, requestMethod)
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.Exit ()
import System.FilePath ()
import System.Process ()
import System.Timeout ()
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.AGUI.Event ()
import Yuki.N.AGUI.Types
import Yuki.N.Agent
import Yuki.N.Artifact
import Yuki.N.Background ()
import Yuki.N.Facts
import Yuki.N.Inspect
import Yuki.N.Journal
import Yuki.N.Memory
import Yuki.N.Model
import Yuki.N.Provider.OpenAI
import Yuki.N.Replay ()
import Yuki.N.Server
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig ()
import Yuki.N.Transcript ()

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
inspectionFixture =
  newMemoryThreadStore >>= \threads ->
    newMemoryFactStore >>= \facts ->
      newMemoryArtifactStore >>= \artifacts ->
        getTemporaryDirectory >>= \tmp ->
          newId >>= \identifier ->
            let dir = tmp ++ "/" ++ Text.unpack identifier
             in createDirectoryIfMissing True dir *> newMemoryJournal >>= seed threads facts artifacts dir
 where
  seed threads facts artifacts dir (journal, readEntries) =
    threadSaveEpisode threads "thread" (Episode "run-0" "earlier" 1700000000)
      *> factAdd facts "the deploy target is fly.io" FactProject "run-0"
      *> artifactSave artifacts "big" bigContent
      *> testRuntime echoModel [echoTool] Parallel
      >>= \base ->
        collectEvents base {runtimeJournal = Just journal} (journaledInput "run-1")
          >>= \events ->
            collectEvents base {runtimeJournal = Just journal} (journaledInput "run-2")
              *> (readEntries >>= LazyByteString.writeFile (journalFilePath dir) . renderJournal)
              *> pure
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

-- | 规格：GET /memory/threads/:id 返回线程 brief，未知线程 404。
-- 背景：brief 端点是记忆视图的数据源；404 语义错误会让前端显示错误状态。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
briefOverHttp :: Assertion
briefOverHttp =
  inspectionFixture >>= \(app, _, _) ->
    runSession (request (httpGet ["memory", "threads", "thread"])) app >>= \found ->
      runSession (request (httpGet ["memory", "threads", "unknown"])) app >>= \unknown ->
        sequence_
          [ simpleStatus found @?= status200,
            simpleStatus unknown @?= status404,
            either assertFailure ((@?= "earlier") . briefRollingSummary) (eitherDecode (simpleBody found))
          ]

-- | 规格：GET /memory/facts 列出事实内容。
-- 背景：事实端点是记忆界面的数据源；形状错误会让界面解析失败。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
factsOverHttp :: Assertion
factsOverHttp =
  inspectionFixture >>= \(app, _, _) ->
    runSession (request (httpGet ["memory", "facts"])) app >>= \response ->
      sequence_
        [ simpleStatus response @?= status200,
          either
            assertFailure
            ((@?= ["the deploy target is fly.io"]) . fmap factContent)
            (eitherDecode (simpleBody response))
        ]

-- | 规格：GET /artifacts 列出工件元数据，GET /artifacts/:id 返回原始内容（text/plain），缺失 404。
-- 背景：工件读写端点是 stub 回源通道；content-type 或 404 错误会让前端取回失败。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
artifactsOverHttp :: Assertion
artifactsOverHttp =
  inspectionFixture >>= \(app, identifier, _) ->
    runSession (request (httpGet ["artifacts"])) app >>= \listed ->
      runSession (request (httpGet ["artifacts", identifier])) app >>= \fetched ->
        runSession (request (httpGet ["artifacts", "art-missing"])) app >>= \missing ->
          sequence_
            [ simpleStatus listed @?= status200,
              either assertFailure (metasMatch identifier) (eitherDecode (simpleBody listed)),
              simpleStatus fetched @?= status200,
              lookup hContentType (simpleHeaders fetched) @?= Just "text/plain; charset=utf-8",
              simpleBody fetched @?= LazyByteString.fromStrict (TextEncoding.encodeUtf8 bigContent),
              simpleStatus missing @?= status404
            ]
 where
  metasMatch identifier metas =
    fmap (\meta -> (artifactMetaId meta, artifactMetaToolName meta, artifactMetaChars meta)) metas
      @?= [(identifier, "big", Text.length bigContent)]

-- | 规格：GET /journal/runs 列出运行，GET /journal 支持按 run 过滤条目。
-- 背景：journal 端点是审计界面数据源；过滤错误会泄漏其他运行数据。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
journalOverHttp :: Assertion
journalOverHttp =
  inspectionFixture >>= \(app, _, _) ->
    runSession (request (httpGet ["journal", "runs"])) app >>= \runs ->
      runSession (request (httpGet ["journal"])) app >>= \everything ->
        runSession (request filtered) app >>= \matching ->
          sequence_
            [ simpleStatus runs @?= status200,
              either assertFailure (@?= ["run-1", "run-2"]) (eitherDecode (simpleBody runs) :: Either String [Text]),
              simpleStatus everything @?= status200,
              simpleStatus matching @?= status200,
              verify
                (eitherDecode (simpleBody everything) :: Either String [Entry])
                (eitherDecode (simpleBody matching) :: Either String [Entry])
            ]
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

-- | 规格：GET /journal/runs/:id/summary 返回运行摘要，未知运行 404。
-- 背景：摘要端点是运维视图；404 与字段错误会让状态面板失真。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
summaryOverHttp :: Assertion
summaryOverHttp =
  inspectionFixture >>= \(app, _, _) ->
    runSession (request (httpGet ["journal", "runs", "run-1", "summary"])) app >>= \found ->
      runSession (request (httpGet ["journal", "runs", "missing", "summary"])) app >>= \unknown ->
        sequence_
          [ simpleStatus found @?= status200,
            simpleStatus unknown @?= status404,
            either assertFailure (@?= ("run-1", "finished", 2, 1)) (decodeSummary (simpleBody found))
          ]
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

-- | 规格：GET /journal/runs/:id/trace 返回因果步骤，未知运行 404。
-- 背景：trace 端点是排障时间线；步骤缺失会让根因不可见。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
traceOverHttp :: Assertion
traceOverHttp =
  inspectionFixture >>= \(app, _, _) ->
    runSession (request (httpGet ["journal", "runs", "run-1", "trace"])) app >>= \found ->
      runSession (request (httpGet ["journal", "runs", "missing", "trace"])) app >>= \unknown ->
        sequence_
          [ simpleStatus found @?= status200,
            simpleStatus unknown @?= status404,
            either assertFailure (assertBool "trace includes causal steps" . (> 2)) (decodeSteps (simpleBody found))
          ]
 where
  decodeSteps :: LazyByteString.ByteString -> Either String Int
  decodeSteps body =
    eitherDecode body
      >>= parseEither
        (withObject "trace" (\fields -> length <$> (fields .: "steps" :: Parser [Value])))

-- | 规格：POST /replay 支持显式 runId 与默认最新运行，均无分歧。
-- 背景：HTTP 重放是线上排障入口；最新运行语义错误会让运维重放错目标。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
replayOverHttp :: Assertion
replayOverHttp =
  inspectionFixture >>= \(app, _, eventCount) ->
    runSession (srequest (replayRequest (encode (object ["runId" .= ("run-1" :: Text)])))) app >>= \explicit ->
      runSession (srequest (replayRequest "")) app >>= \latest ->
        sequence_
          [ simpleStatus explicit @?= status200,
            either assertFailure (verifyReport eventCount "run-1") (decodeReport (simpleBody explicit)),
            simpleStatus latest @?= status200,
            either assertFailure (verifyReport eventCount "run-2") (decodeReport (simpleBody latest))
          ]
 where
  verifyReport expected run (reportRun, events, divergence) =
    sequence_ [reportRun @?= run, events @?= expected, divergence @?= Nothing]

decodeReport :: LazyByteString.ByteString -> Either String (Text, Int, Maybe Value)
decodeReport body =
  eitherDecode body
    >>= parseEither (withObject "report" (\fields -> (,,) <$> fields .: "runId" <*> fields .: "events" <*> fields .:? "divergence"))

-- | 规格：部分 Inspection 缺失时相关路由 404 而其余路由正常。
-- 背景：能力降级是可选依赖的契约；全部 500 会让服务在部分配置下不可用。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
capabilityDegradation :: Assertion
capabilityDegradation =
  newMemoryArtifactStore >>= \artifacts ->
    let partial = newInspection Nothing (Just artifacts) Nothing Nothing
     in testRuntime echoModel [echoTool] Parallel >>= \base ->
          runSession (request (httpGet ["artifacts"])) (application Nothing (Just partial) Nothing Nothing (const (pure base))) >>= \listed ->
            runSession (request (httpGet ["memory", "facts"])) (application Nothing (Just partial) Nothing Nothing (const (pure base))) >>= \facts ->
              sequence_ [simpleStatus listed @?= status200, simpleStatus facts @?= status404]

-- | 规格：无 Inspection 时记忆与重放路由 404。
-- 背景：未配置能力必须显式不可用；隐式成功会掩盖配置错误。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
inspectionMissing :: Assertion
inspectionMissing =
  testRuntime echoModel [echoTool] Parallel >>= \base ->
    runSession (request (httpGet ["memory", "facts"])) (application Nothing Nothing Nothing Nothing (const (pure base))) >>= \facts ->
      runSession (srequest (replayRequest "")) (application Nothing Nothing Nothing Nothing (const (pure base))) >>= \replay ->
        sequence_ [simpleStatus facts @?= status404, simpleStatus replay @?= status404]

-- | 规格：POST /agent 以 SSE 流式返回 AG-UI 事件，带正确的 content-type 与事件顺序。
-- 背景：SSE 契约是前端事件驱动的根基；content-type 或顺序错误会让前端断流。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
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
