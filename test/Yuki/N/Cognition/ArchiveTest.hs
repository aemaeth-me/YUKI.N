-- | 分身认知 · 任务档案测试
--
-- 覆盖：档案持久化、grep/因果读取、hooks 捕获原始证据与档案 HTTP 端点。
-- 边界：覆盖 Yuki.N.Memory.Archive。
-- 变更记录：
--   - 2026-08-01: 从集中式 test/Main.hs 拆出；测试语义、标题、数量与组顺序保持原样。
module Yuki.N.Cognition.ArchiveTest
  ( cognitionTaskArchivePersistence,
    cognitionTaskArchiveRetrieval,
    cognitionTaskArchiveHooks,
    cognitionTaskArchiveHttp,
    cognitionTaskArchiveTests
  )
where
import Control.Applicative ()
import Control.Concurrent ()
import Control.Concurrent.MVar ()
import Control.Monad ((>=>))
import Data.Aeson
import Data.Aeson.Types ()
import Data.Bool ()
import Data.ByteString ()
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Foldable ()
import Data.Functor ()
import Data.IORef ()
import Data.Maybe ()
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Network.HTTP.Client ()
import Network.HTTP.Client.TLS ()
import Network.HTTP.Types
import Network.Wai ()
import Network.Wai.Handler.Warp ()
import Network.Wai.Internal ()
import Network.Wai.Test
import System.Directory ()
import System.Exit ()
import System.FilePath ()
import System.Process ()
import System.Timeout ()
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Cognition
import Yuki.N.Memory.Archive
import Yuki.N.Blob
import Yuki.N.Agent
import Yuki.N.Model
import Yuki.N.Server
import Yuki.N.AGUI.Types
import Yuki.N.AGUI.Event
import Yuki.N.Background ()
import Yuki.N.Provider.OpenAI ()
import Yuki.N.Inspect
import Yuki.N.TestSupport
import Data.List (sort)
import Control.Exception (throwIO)


-- | 规格：任务档案跨重启持久化：运行/条目不可变追加，重复与改写被拒绝。
-- 背景：档案不可变是审计前提；可改写会破坏证据链。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionTaskArchivePersistence :: Assertion
cognitionTaskArchivePersistence =
  withWorkDir $ \dir ->
    newBlobStore dir >>= withTextRight (newTaskArchiveStore dir >=> withTextRight (exercise dir))
  where
    task = "archived-task"
    user = entry "user-1" ArchiveUser "Keep the complete tool evidence." Nothing Nothing Nothing
    result = entry "call-1/result" ArchiveToolResult fullResult (Just "call-1") (Just "call-1") (Just "inspect")
    reasoning = entry "turn-1/reasoning" ArchiveReasoning "I should inspect the source first." (Just "turn-1") Nothing Nothing
    answer = entry "turn-1/assistant" ArchiveAssistant "The source confirms the result." (Just "turn-1") Nothing Nothing
    call = entry "call-1/call" ArchiveToolCall (jsonText (ModelToolCall "call-1" "inspect" "{\"path\":\"source\"}")) (Just "turn-1") (Just "call-1") (Just "inspect")
    fullResult = "complete-tool-result-sentinel\n" <> Text.replicate 900 "e"
    running =
      ArchiveRunDraft "art" task "run-1" (Just "intent-1") "running" Nothing [user, result]
    completed =
      ArchiveRunDraft "art" task "run-1" (Just "intent-1") "completed" Nothing [user, reasoning, answer, call, result]
    rewritten = completed {archiveRunDraftStatus = "failed", archiveRunDraftFailure = Just "late rewrite"}
    exercise dir store =
      taskArchiveAppend store running >>= withTextRight (\_ ->
        taskArchiveAppend store completed >>= withTextRight (\sealed ->
          taskArchiveAppend store completed >>= withTextRight (\repeated ->
            taskArchiveAppend store rewritten >>= \rewrite ->
              newBlobStore dir >>= withTextRight (newTaskArchiveStore dir >=> withTextRight (verify sealed repeated rewrite)))))
    verify sealed repeated rewrite reopened =
      taskArchiveRuns reopened "art" (Just task) >>= \runs ->
        taskArchiveTasks reopened "art" 20 >>= \catalog ->
          case archiveRunEntryIds sealed of
            _ : resultId : _ ->
              taskArchiveRead reopened (ArchiveReadRequest "art" resultId 0 0 0 20000)
                >>= withTextRight
                  ( \window ->
                      sequence_
                        [ repeated @?= sealed,
                          assertLeft rewrite,
                          fmap archiveRunStatus runs @?= ["completed"],
                          fmap archiveTaskId catalog @?= [task],
                          fmap archiveTaskRunCount catalog @?= [1],
                          fmap archiveTaskEntryCount catalog @?= [5],
                          fmap archiveSliceSeq (archiveReadResultEntries window) @?= [2 .. 5],
                          fmap archiveSliceContent
                            (filter ((== ArchiveToolResult) . archiveSliceKind) (archiveReadResultEntries window))
                            @?= [fullResult]
                        ]
                  )
            _ -> assertFailure "persisted Task archive did not retain its entry identities"
    entry source kind content parent callId toolName =
      ArchiveEntryDraft source kind content parent callId toolName
-- | 规格：档案 grep 支持大小写/种类过滤/分页/因果窗口读取，命中带行号与偏移。
-- 背景：检索是档案价值所在；过滤与分页错误会让证据不可定位。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionTaskArchiveRetrieval :: Assertion
cognitionTaskArchiveRetrieval =
  newMemoryBlobStore >>= \blobs ->
    newMemoryTaskArchiveStore blobs >>= \store ->
      taskArchiveAppend store primary >>= withTextRight (\_ ->
        taskArchiveAppend store secondary >>= withTextRight (\_ ->
          taskArchiveAppend store otherRun >>= withTextRight (\_ ->
            verify store)))
  where
    task = "task-a"
    turn = "turn-a"
    callA = "call-a"
    callB = "call-b"
    primary =
      ArchiveRunDraft
        "art"
        task
        "run-a"
        Nothing
        "completed"
        Nothing
        [ entry "user-a" ArchiveUser "第一行\nAlpha NEEDLE beta\nrepeat repeat repeat\n第三行" Nothing Nothing Nothing,
          entry "reasoning-a" ArchiveReasoning (padded "secret-reasoning") (Just turn) Nothing Nothing,
          entry "assistant-a" ArchiveAssistant (padded "answer-without-query") (Just turn) Nothing Nothing,
          entry "call-a/call" ArchiveToolCall (padded "call-a-input") (Just turn) (Just callA) (Just "shell"),
          entry "call-b/call" ArchiveToolCall (padded "call-b-input") (Just turn) (Just callB) (Just "second"),
          entry "call-memory/call" ArchiveToolCall "{\"query\":\"recursive-noise\"}" (Just turn) (Just "call-memory") (Just "memory_grep"),
          entry "call-a/result" ArchiveToolResult (padded "tool-A-evidence" <> "\n[artifact art-source-a: full shell output]") (Just callA) (Just callA) (Just "shell"),
          entry "call-b/result" ArchiveToolResult (padded "tool-B-evidence") (Just callB) (Just callB) (Just "second"),
          entry "call-memory/result" ArchiveToolResult "{\"hits\":[{\"excerpt\":\"recursive-noise\"}],\"scannedEntries\":8}" (Just "call-memory") (Just "call-memory") (Just "memory_grep")
        ]
    secondary =
      ArchiveRunDraft "art" "task-b" "run-b" Nothing "completed" Nothing
        [entry "user-b" ArchiveUser "Needle in another archived Task." Nothing Nothing Nothing]
    otherRun =
      ArchiveRunDraft "other" "task-c" "run-c" Nothing "completed" Nothing
        [entry "user-c" ArchiveUser "NEEDLE must remain isolated." Nothing Nothing Nothing]
    verify store =
      search store (ArchiveGrepRequest "art" "needle" (Just task) [] False 20 0 False Nothing) >>= \insensitive ->
        search store (ArchiveGrepRequest "art" "needle" (Just task) [] True 20 0 False Nothing) >>= \sensitive ->
          search store (ArchiveGrepRequest "art" "secret-reasoning" Nothing [] False 20 0 False Nothing) >>= \defaultReasoning ->
            search store (ArchiveGrepRequest "art" "secret-reasoning" Nothing [ArchiveReasoning] False 20 0 False Nothing) >>= \explicitReasoning ->
              search store (ArchiveGrepRequest "art" "needle" Nothing [] False 20 0 False Nothing) >>= \allOwn ->
                search store (ArchiveGrepRequest "art" "needle" Nothing [] False 20 0 False (Just task)) >>= \excluded ->
                  search store (ArchiveGrepRequest "art" "tool-A-evidence" (Just task) [] False 20 0 False Nothing) >>= \anchorSearch ->
                  search store (ArchiveGrepRequest "art" "repeat" (Just task) [] True 20 0 False Nothing) >>= \repeated ->
                    search store (ArchiveGrepRequest "art" "needle" Nothing [] False 1 0 False Nothing) >>= \firstPage ->
                      search store (ArchiveGrepRequest "art" "needle" Nothing [] False 1 1 False Nothing) >>= \secondPage ->
                        search store (ArchiveGrepRequest "art" "recursive-noise" (Just task) [] True 20 0 False Nothing) >>= \processHidden ->
                          search store (ArchiveGrepRequest "art" "recursive-noise" (Just task) [] True 20 0 True Nothing) >>= \processShown ->
                            taskArchiveTasks store "art" 20 >>= \catalog ->
                              case archiveGrepResultHits anchorSearch of
                                [anchor] ->
                                  taskArchiveRead store (ArchiveReadRequest "art" (archiveHitEntryId anchor) 0 0 (archiveHitMatchOffset anchor) 256)
                                    >>= withTextRight (verifyWindow store insensitive sensitive defaultReasoning explicitReasoning allOwn excluded repeated firstPage secondPage processHidden processShown catalog anchor)
                                hits -> assertFailure ("unexpected Task archive anchor hits: " <> show (length hits))
    verifyWindow store insensitive sensitive defaultReasoning explicitReasoning allOwn excluded repeated firstPage secondPage processHidden processShown catalog anchor window =
      taskArchiveRead store (ArchiveReadRequest "art" (archiveHitEntryId anchor) 0 0 (archiveHitMatchOffset anchor) 1)
        >>= withTextRight
          ( \tiny ->
              taskArchiveRead store (ArchiveReadRequest "other" (archiveHitEntryId anchor) 0 0 0 256) >>= \foreignRead ->
                let entries = archiveReadResultEntries window
                    tinyEntries = archiveReadResultEntries tiny
                 in sequence_
                      [ fmap archiveHitLineNumber (archiveGrepResultHits insensitive) @?= [2],
                        fmap archiveHitMatchOffset (archiveGrepResultHits insensitive) @?= [10],
                        archiveGrepResultHits sensitive @?= [],
                        archiveGrepResultHits defaultReasoning @?= [],
                        fmap archiveHitKind (archiveGrepResultHits explicitReasoning) @?= [ArchiveReasoning],
                        sort (fmap archiveHitTaskId (archiveGrepResultHits allOwn)) @?= [task, "task-b"],
                        sort (fmap archiveHitTaskId (archiveGrepResultHits excluded)) @?= ["task-b"],
                        fmap archiveHitEntryMatchIndex (archiveGrepResultHits repeated) @?= [1, 2, 3],
                        fmap archiveHitEntryMatchCount (archiveGrepResultHits repeated) @?= [3, 3, 3],
                        archiveGrepResultTotalHits firstPage @?= 2,
                        archiveGrepResultReturnedHits firstPage @?= 1,
                        archiveGrepResultNextOffset firstPage @?= Just 1,
                        archiveGrepResultHasMore firstPage @?= True,
                        archiveGrepResultNextOffset secondPage @?= Nothing,
                        archiveGrepResultHasMore secondPage @?= False,
                        archiveGrepResultHits processHidden @?= [],
                        fmap archiveHitEvidenceClass (archiveGrepResultHits processShown) @?= ["process", "process"],
                        archiveHitSourceCompleteness anchor @?= "artifact-backed",
                        archiveHitArtifactIds anchor @?= ["art-source-a"],
                        sort (fmap archiveTaskId catalog) @?= [task, "task-b"],
                        fmap archiveSliceKind entries
                          @?= [ ArchiveReasoning,
                                ArchiveAssistant,
                                ArchiveToolCall,
                                ArchiveToolCall,
                                ArchiveToolCall,
                                ArchiveToolResult,
                                ArchiveToolResult,
                                ArchiveToolResult
                              ],
                        assertBool "causal read exceeded its global character budget" (sum (fmap (Text.length . archiveSliceContent) entries) <= 256),
                        assertBool "anchor text was not centered into the bounded read" ("tool-A-evidence" `Text.isInfixOf` archiveSliceContent (entries !! 5)),
                        sum (fmap (Text.length . archiveSliceContent) tinyEntries) @?= 1,
                        Text.length (archiveSliceContent (tinyEntries !! 5)) @?= 1,
                        assertLeft foreignRead
                      ]
          )
    search store grepRequest =
      taskArchiveGrep store grepRequest >>= either (throwIO . userError . Text.unpack) pure
    padded label = label <> ":" <> Text.replicate 500 "x"
    entry source kind content parent callId toolName =
      ArchiveEntryDraft source kind content parent callId toolName
-- | 规格：cognition hooks 捕获完整工具结果与接受后的用户输入，而非投影 stub。
-- 背景：档案必须存原始证据；只存投影会让事后调查失去细节。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionTaskArchiveHooks :: Assertion
cognitionTaskArchiveHooks =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\cognition ->
      ensureIncarnation cognition "yuki" >>= \incarnation ->
        let hooks = cognitionHooks cognition incarnation
            input =
              (sampleInput [])
                { runThreadId = "raw-hook-task",
                  runId = "raw-hook-run",
                  runMessages = [User (UserMessage "intent-raw" (UserText accepted) Nothing)]
                }
            call = ModelToolCall "raw-call" "inspect" "{\"path\":\"large\"}"
            finalMessages =
              [ ChatUser accepted,
                ChatAssistant (AssistantTurn "raw-turn" (Just "I inspected it.") Nothing [call]),
                ChatToolResult "raw-call" projected
              ]
         in observeEvent hooks input (RunStarted "raw-hook-task" "raw-hook-run" Nothing)
              *> observeEvent hooks input (ToolCallResult "raw-tool-message" "raw-call" completeResult)
              *> afterRunOutcome hooks input RunSucceeded finalMessages
              *> taskArchiveGrep
                (cognitionArchive cognition)
                (ArchiveGrepRequest "yuki" "complete-result-sentinel" (Just "raw-hook-task") [] True 20 0 False Nothing)
              >>= withTextRight
                ( \full ->
                    taskArchiveGrep
                      (cognitionArchive cognition)
                      (ArchiveGrepRequest "yuki" "projected-result-stub" (Just "raw-hook-task") [] True 20 0 False Nothing)
                      >>= withTextRight
                        ( \stub ->
                            taskArchiveGrep
                              (cognitionArchive cognition)
                              (ArchiveGrepRequest "yuki" accepted (Just "raw-hook-task") [] True 20 0 False Nothing)
                              >>= withTextRight
                                ( \user ->
                                    taskArchiveRuns (cognitionArchive cognition) "yuki" (Just "raw-hook-task") >>= \runs ->
                                      sequence_
                                        [ fmap archiveHitKind (archiveGrepResultHits full) @?= [ArchiveToolResult],
                                          archiveGrepResultHits stub @?= [],
                                          fmap archiveHitKind (archiveGrepResultHits user) @?= [ArchiveUser],
                                          fmap archiveRunStatus runs @?= ["completed"]
                                        ]
                                )
                        )
                ))
  where
    accepted = "accepted-input-sentinel"
    completeResult = "complete-result-sentinel\n" <> Text.replicate 2000 "原"
    projected = "projected-result-stub"
-- | 规格：任务档案目录、搜索与锚定读取经 HTTP 端点为前端提供。
-- 背景：HTTP 路由是档案的对外接口；路由与形状错误会让界面不可用。
-- 变更记录：- 2026-08-01: 从集中式测试套件迁移并建立回归文档基线。
cognitionTaskArchiveHttp :: Assertion
cognitionTaskArchiveHttp =
  withWorkDir $ \dir ->
    newCognition dir [] Nothing >>= withTextRight (\cognition ->
      testRuntime okModel [] Parallel >>= \runtime ->
        taskArchiveAppend
          (cognitionArchive cognition)
          ( ArchiveRunDraft
              "yuki"
              "route-task"
              "route-run"
              Nothing
              "completed"
              Nothing
              [ArchiveEntryDraft "route-user" ArchiveUser "route-memory-sentinel" Nothing Nothing Nothing]
          )
          >>= withTextRight
            ( \stored ->
                case archiveRunEntryIds stored of
                  [entryId] ->
                    let app = application Nothing (Just (withCognition cognition emptyInspection)) Nothing Nothing (const (pure runtime))
                     in runSession (request (httpGet ["incarnations", "yuki", "task-records"])) app >>= \catalog ->
                          runSession
                            ( srequest
                                ( jsonRequest
                                    methodPost
                                    ["incarnations", "yuki", "task-records", "search"]
                                    ( object
                                        [ "query" .= ("route-memory-sentinel" :: Text),
                                          "caseSensitive" .= True,
                                          "limit" .= (20 :: Int)
                                        ]
                                    )
                                )
                            )
                            app
                            >>= \searched ->
                              runSession (request (httpGet ["incarnations", "yuki", "task-records", entryId])) app >>= \readBack ->
                                runSession (request (httpGet ["incarnations", "yuki", "task-records", "missing-entry"])) app >>= \missingEntry ->
                                  sequence_
                                    [ simpleStatus catalog @?= status200,
                                      simpleStatus searched @?= status200,
                                      simpleStatus readBack @?= status200,
                                      simpleStatus missingEntry @?= status404,
                                      responseContains "route-task" catalog,
                                      responseContains "\"mode\":\"fixed\"" searched,
                                      responseContains "route-memory-sentinel" searched,
                                      responseContains "route-memory-sentinel" readBack
                                    ]
                  identifiers -> assertFailure ("unexpected Task archive entry count: " <> show (length identifiers))
            ))
  where
    responseContains needle =
      assertBool
        ("response body does not contain " <> needle)
        . ByteString.isInfixOf (TextEncoding.encodeUtf8 (Text.pack needle))
        . LazyByteString.toStrict
        . simpleBody
cognitionTaskArchiveTests :: TestTree
cognitionTaskArchiveTests =
  testGroup
    "incarnation cognition task archive"
    [
      testCase "persists immutable structured Task archives across restart" cognitionTaskArchivePersistence,
      testCase "greps Task archives and reads causal windows" cognitionTaskArchiveRetrieval,
      testCase "captures accepted input and full tool results before projection" cognitionTaskArchiveHooks,
      testCase "serves Task archive catalog, grep and anchored read endpoints" cognitionTaskArchiveHttp
    ]
