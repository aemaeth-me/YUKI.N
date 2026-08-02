module Yuki.N.DispatchTest
  ( dispatchTests,
  )
where

import Control.Exception (throwIO)
import Data.Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Types
import Network.Wai (queryString)
import Network.Wai.Test
import System.Directory (doesFileExist)
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Cognition (Cognition (..), newCognition)
import Yuki.N.Dispatch
import Yuki.N.Incarnation
import Yuki.N.Inspect
import Yuki.N.Invocation
import Yuki.N.Model
import Yuki.N.Server
import Yuki.N.Sessions
import Yuki.N.TestSupport
import Yuki.N.ThreadConfig
import Yuki.N.Transcript

dispatchTests :: TestTree
dispatchTests =
  testGroup
    "dispatch"
    [ testCase "dispatch draft roundtrips through JSON" dispatchJsonRoundtrip,
      testCase "store lifecycle persists drafts and enforces draft-only transitions" dispatchStoreLifecycle,
      testCase "generation falls back to GeneratedFallback when the invocation fails" dispatchFallbackGeneration,
      testCase "generation parses lenient model JSON into a GeneratedModel draft" dispatchModelGeneration,
      testCase "confirm materializes thread, config and first transcript message" dispatchConfirmSuccess,
      testCase "confirm rolls back created artifacts when transcript append fails" dispatchConfirmRollback,
      testCase "dispatch routes enforce draft-only patch, confirm and cancel" dispatchRoutes
    ]

sampleDraft :: DispatchDraft
sampleDraft =
  DispatchDraft
    "dsp-1"
    "art"
    DispatchUser
    "raw input"
    "Title"
    "Prompt"
    emptyThreadConfig {configSystemPrompt = Just "snapshot"}
    (GeneratedModel "inv-1")
    Draft
    Nothing
    Nothing
    10
    11
    Nothing

dispatchJsonRoundtrip :: Assertion
dispatchJsonRoundtrip = do
  roundtrip sampleDraft
  roundtrip sampleDraft {dispatchSource = DispatchAgent "run-1" "call-1", dispatchGeneration = GeneratedAgent}
  roundtrip sampleDraft {dispatchStatus = Dispatched, dispatchCreatedThreadId = Just "thread-1", dispatchDispatchedAt = Just 12}
  roundtrip sampleDraft {dispatchStatus = Cancelled, dispatchError = Just "boom", dispatchGeneration = GeneratedFallback}
 where
  roundtrip draft = eitherDecode (encode draft) @?= Right draft

dispatchStoreLifecycle :: Assertion
dispatchStoreLifecycle = withWorkDir $ \dir -> do
  store <- newDispatchStore dir
  draft <- createDispatch store (newDraft "art" GeneratedFallback)
  assertBool "dsp- prefix" ("dsp-" `Text.isPrefixOf` dispatchId draft)
  dispatchStatus draft @?= Draft
  found <- getDispatch store (dispatchId draft)
  fmap dispatchTitle found @?= Just "Title"
  drafts <- listDispatches store "art" (Just Draft)
  length drafts @?= 1
  dispatched <- listDispatches store "art" (Just Dispatched)
  dispatched @?= []
  others <- listDispatches store "other" Nothing
  others @?= []
  patched <-
    patchDispatch store (dispatchId draft) (DispatchPatch (Just "Renamed") (Just "New prompt") (Just emptyThreadConfig {configModel = Just "m"}))
      >>= expectTextRight
  dispatchTitle patched @?= "Renamed"
  dispatchPrompt patched @?= "New prompt"
  configModel (dispatchConfig patched) @?= Just "m"
  reopened <- newDispatchStore dir
  stored <- getDispatch reopened (dispatchId draft)
  fmap dispatchPrompt stored @?= Just "New prompt"
  cancelled <- markDispatchCancelled reopened (dispatchId draft) >>= expectTextRight
  dispatchStatus cancelled @?= Cancelled
  assertLeft =<< patchDispatch reopened (dispatchId draft) (DispatchPatch (Just "x") Nothing Nothing)
  assertLeft =<< markDispatchCancelled reopened (dispatchId draft)
  assertLeft =<< markDispatchError reopened (dispatchId draft) "late error"
  assertLeft =<< patchDispatch reopened "dsp-absent" (DispatchPatch Nothing Nothing Nothing)
  next <- createDispatch reopened (newDraft "art" GeneratedFallback)
  sent <- markDispatchDispatched reopened (dispatchId next) "thread-1" >>= expectTextRight
  dispatchStatus sent @?= Dispatched
  dispatchCreatedThreadId sent @?= Just "thread-1"
  assertBool "dispatchedAt recorded" (maybe False (> 0) (dispatchDispatchedAt sent))
  assertLeft =<< markDispatchDispatched reopened (dispatchId next) "thread-2"
 where
  newDraft incarnation = NewDispatch DispatchUser incarnation "input" "Title" "Prompt" emptyThreadConfig

dispatchFallbackGeneration :: Assertion
dispatchFallbackGeneration = do
  (title, prompt, generation) <- generateDraft failing [okModel] 20 Nothing art input
  title @?= "Build the report pipeline"
  prompt @?= input
  generation @?= GeneratedFallback
  (emptyTitle, _, _) <- generateDraft failing [] 20 Nothing art input
  emptyTitle @?= "Build the report pipeline"
 where
  failing _ = pure (Left "boom")
  input = "  Build the report pipeline\nwith quarterly numbers"

dispatchModelGeneration :: Assertion
dispatchModelGeneration = do
  (title, prompt, generation) <- generateDraft invoke [okModel] 20 Nothing art "ignored"
  title @?= "Drafted title"
  prompt @?= "Drafted prompt"
  assertModel generation
  (fallbackTitle, fallbackPrompt, fallbackGeneration) <- generateDraft garbage [okModel] 20 Nothing art "raw request"
  fallbackTitle @?= "raw request"
  fallbackPrompt @?= "raw request"
  fallbackGeneration @?= GeneratedFallback
 where
  invoke spec =
    pure
      ( Right
          ( InvocationResult
              (invocationId spec)
              "dispatch.draft"
              "dispatch-draft-generator/v1"
              "fake"
              "fake"
              1
              "```json\n{\"title\": \"Drafted title\", \"prompt\": \"Drafted prompt\"}\n```"
              Stop
          )
      )
  garbage spec =
    pure
      ( Right
          (InvocationResult (invocationId spec) "dispatch.draft" "rev" "fake" "fake" 1 "not json at all" Stop)
      )
  assertModel (GeneratedModel identifier) = assertBool "invocation id" ("dsp-" `Text.isPrefixOf` identifier)
  assertModel other = assertFailure ("expected GeneratedModel, got " <> show other)

art :: Incarnation
art =
  (defaultIncarnation 0)
    { incarnationId = "art",
      incarnationName = "Art",
      incarnationDirection = "draw"
    }

dispatchConfirmSuccess :: Assertion
dispatchConfirmSuccess = withWorkDir $ \dir -> do
  dispatches <- newDispatchStore dir
  service <- sessionServiceAt dir (const (pure ()))
  incarnations <- newMemoryIncarnationStore
  _ <- incarnationCreate incarnations "art" "Art" "draw" Nothing >>= expectTextRight
  draft <-
    createDispatch
      dispatches
      (NewDispatch DispatchUser "art" "input" "Mission" "Do the thing" emptyThreadConfig {configSystemPrompt = Just "snapshot"} GeneratedFallback)
  outcome <- confirmDraft dispatches service incarnations (pure "thread-9") (dispatchId draft)
  outcome @?= ConfirmOk "thread-9"
  meta <- findSession (serviceSessions service) "thread-9"
  fmap sessionTitle meta @?= Just "Mission"
  fmap sessionIncarnationId meta @?= Just "art"
  fmap sessionKind meta @?= Just SessionTask
  config <- threadConfigRead (serviceConfigs service) "thread-9"
  configSystemPrompt config @?= Just "snapshot"
  transcript <- transcriptLoad (serviceTranscripts service) "thread-9"
  transcript @?= Just [ChatUser "Do the thing"]
  updated <- getDispatch dispatches (dispatchId draft)
  fmap dispatchStatus updated @?= Just Dispatched
  fmap dispatchCreatedThreadId updated @?= Just (Just "thread-9")
  again <- confirmDraft dispatches service incarnations (pure "thread-10") (dispatchId draft)
  assertConflict again
 where
  assertConflict (ConfirmConflict _) = pure ()
  assertConflict other = assertFailure ("expected ConfirmConflict, got " <> show other)

dispatchConfirmRollback :: Assertion
dispatchConfirmRollback = withWorkDir $ \dir -> do
  dispatches <- newDispatchStore dir
  service <- sessionServiceAt dir (const (pure ()))
  incarnations <- newMemoryIncarnationStore
  _ <- incarnationCreate incarnations "art" "Art" "draw" Nothing >>= expectTextRight
  draft <- createDispatch dispatches (NewDispatch DispatchUser "art" "input" "Mission" "Do the thing" emptyThreadConfig {configSystemPrompt = Just "snapshot"} GeneratedFallback)
  let broken = (serviceTranscripts service) {transcriptSave = \_ _ -> throwIO (userError "transcript boom")}
      brokenService = service {serviceTranscripts = broken}
  outcome <- confirmDraft dispatches brokenService incarnations (pure "thread-1") (dispatchId draft)
  failure <- case outcome of
    ConfirmError err -> pure err
    other -> assertFailure ("expected ConfirmError, got " <> show other)
  assertBool "transcript failure surfaced" ("transcript boom" `Text.isInfixOf` failure)
  active <- listSessions (serviceSessions service) False
  active @?= []
  archived <- listSessions (serviceSessions service) True
  map sessionId archived @?= ["thread-1"]
  transcript <- transcriptLoad (serviceTranscripts service) "thread-1"
  transcript @?= Nothing
  configExists <- doesFileExist (dir ++ "/threads-config/thread-1.json")
  configExists @?= False
  updated <- getDispatch dispatches (dispatchId draft)
  fmap dispatchStatus updated @?= Just Draft
  fmap dispatchError updated @?= Just (Just failure)

dispatchRoutes :: Assertion
dispatchRoutes = withWorkDir $ \dir -> do
  cognitionResult <- newCognition (dir ++ "/cognition") [okModel] Nothing
  cognition <- either (assertFailure . Text.unpack) pure cognitionResult
  service <- sessionServiceAt dir (const (pure ()))
  dispatches <- newDispatchStore dir
  base <- testRuntime okModel [] Parallel
  let dispatchService =
        newDispatchService
          dispatches
          service
          (cognitionIncarnations cognition)
          (pure "route-thread")
          (\incarnation input -> generateDraft invokeModel [okModel] 20 Nothing incarnation input)
      inspection =
        withCognition
          cognition
          (withSessionService service (newInspection Nothing Nothing Nothing (Just (serviceTranscripts service))))
      app = application Nothing (Just inspection) Nothing Nothing (Just dispatchService) (const (pure base))
  created <- runSession (srequest (jsonRequest methodPost ["incarnations", "yuki", "dispatches"] (object ["input" .= ("hello world" :: Text)]))) app
  simpleStatus created @?= status202
  draft <- either assertFailure pure (eitherDecode (simpleBody created))
  dispatchStatus draft @?= Draft
  dispatchTitle draft @?= "hello world"
  dispatchGeneration draft @?= GeneratedFallback
  emptyInput <- runSession (srequest (jsonRequest methodPost ["incarnations", "yuki", "dispatches"] (object ["input" .= ("   " :: Text)]))) app
  simpleStatus emptyInput @?= status400
  listed <- runSession (request (httpGet ["incarnations", "yuki", "dispatches"])) app
  drafts <- either assertFailure pure (eitherDecode (simpleBody listed))
  length (drafts :: [DispatchDraft]) @?= 1
  badStatus <- runSession (request ((httpGet ["incarnations", "yuki", "dispatches"]) {queryString = [("status", Just "bogus")]})) app
  simpleStatus badStatus @?= status400
  cancelled <- markDispatchCancelled dispatches (dispatchId draft) >>= expectTextRight
  dispatchStatus cancelled @?= Cancelled
  patched <- runSession (srequest (jsonRequest methodPatch ["dispatches", dispatchId draft] (object ["title" .= ("x" :: Text)]))) app
  confirmed <- runSession (srequest (jsonRequest methodPost ["dispatches", dispatchId draft, "confirm"] (object []))) app
  cancelledAgain <- runSession (srequest (jsonRequest methodPost ["dispatches", dispatchId draft, "cancel"] (object []))) app
  missingDraft <- runSession (request (httpGet ["dispatches", "dsp-absent"])) app
  simpleStatus patched @?= status409
  simpleStatus confirmed @?= status409
  simpleStatus cancelledAgain @?= status409
  simpleStatus missingDraft @?= status404
