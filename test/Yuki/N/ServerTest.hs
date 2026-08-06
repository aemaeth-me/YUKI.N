module Yuki.N.ServerTest
  ( serverTests,
    artifactsOverHttp,
    capabilityDegradation,
    serverEvents,
  )
where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor (($>))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Types
import Network.Wai (Application, pathInfo, requestHeaders, requestMethod)
import Network.Wai.Test
import Test.Tasty
import Test.Tasty.HUnit
import Yuki.N.Artifact
import Yuki.N.Model
import Yuki.N.Provider.OpenAI
import Yuki.N.Server
import Yuki.N.TestSupport

serverTests :: TestTree
serverTests =
  testGroup
    "HTTP server"
    [ testCase "serves AG-UI events as SSE" serverEvents,
      testCase "lists artifacts and serves raw content" artifactsOverHttp,
      testCase "degrades per capability" capabilityDegradation
    ]
artifactsFixture :: IO (Application, Text)
artifactsFixture = do
  artifacts <- newMemoryArtifactStore
  _ <- artifactSave artifacts "big" bigContent
  base <- testRuntime echoModel [echoTool] Parallel
  pure
    ( application Nothing Nothing Nothing (Just artifacts) (const (pure base)),
      artifactIdFor bigContent
    )

artifactsOverHttp :: Assertion
artifactsOverHttp = do
  (app, identifier) <- artifactsFixture
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

capabilityDegradation :: Assertion
capabilityDegradation = do
  artifacts <- newMemoryArtifactStore
  base <- testRuntime echoModel [echoTool] Parallel
  listed <- runSession (request (httpGet ["artifacts"])) (application Nothing Nothing Nothing (Just artifacts) (const (pure base)))
  simpleStatus listed @?= status200

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
