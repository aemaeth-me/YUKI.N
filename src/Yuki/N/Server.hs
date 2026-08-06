module Yuki.N.Server
  ( ConfigView (..),
    application,
    runServer,
  )
where

import Control.Monad (join, (>=>))
import Data.Aeson (FromJSON (..), ToJSON, Value, eitherDecode, encode, object, toJSON, withObject, (.:), (.:?), (.=))
import Data.Bool (bool)
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor ((<&>))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.String (fromString)
import Data.Text (Text, unpack)
import Data.Text qualified as TextValue
import Data.Text.Encoding qualified as Text
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import System.Directory (doesDirectoryExist)
import Text.Read (readMaybe)
import Yuki.N.AGUI.Event (Event)
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent (BackendTool (..), Runtime (..), runAgent, runtimeContextWindow)
import Yuki.N.Artifact (ArtifactStore (..))
import Yuki.N.Config (Settings (..))
import Yuki.N.Context (ContextConfig (..), contextBudget, contextWindow, estimateToolsTokens)
import Yuki.N.Sessions
import Yuki.N.ThreadConfig (ThreadConfig (..), ThreadConfigStore (..), cwdPath, resolveThreadConfig)
import Yuki.N.Tools (completePaths, listTree)
import Yuki.N.Transcript (TranscriptStore (..), renderTranscript, toAguiMessages)

data ConfigView = ConfigView
  { configViewGlobal :: Value,
    configViewStore :: ThreadConfigStore,
    configViewDefaults :: ThreadConfig,
    configViewModels :: IO (Either Text [Text]),
    configViewProviders :: IO [Value]
  }

data CreateSessionRequest = CreateSessionRequest Text (Maybe Text) (Maybe Text)

instance FromJSON CreateSessionRequest where
  parseJSON = withObject "CreateSessionRequest" $ \fields ->
    CreateSessionRequest
      <$> fields .: "threadId"
      <*> fields .:? "title"
      <*> fields .:? "incarnationId"

newtype RenameSessionRequest = RenameSessionRequest Text

instance FromJSON RenameSessionRequest where
  parseJSON = withObject "RenameSessionRequest" $ \fields -> RenameSessionRequest <$> fields .: "title"

data ForkSessionRequest = ForkSessionRequest Text (Maybe Text) (Maybe Text)

instance FromJSON ForkSessionRequest where
  parseJSON = withObject "ForkSessionRequest" $ \fields ->
    ForkSessionRequest
      <$> fields .: "threadId"
      <*> fields .:? "title"
      <*> fields .:? "messageId"

newtype PathRequest = PathRequest Text

instance FromJSON PathRequest where
  parseJSON = withObject "PathRequest" $ \fields -> PathRequest <$> fields .: "prefix"

application :: Maybe Text -> Maybe SessionService -> Maybe ConfigView -> Maybe ArtifactStore -> (Text -> IO Runtime) -> Application
application cors sessions configs artifacts runtimeFor request respond =
  route (requestMethod request) (pathInfo request)
 where
  route "POST" ["agent"] = handleAgent
  route "OPTIONS" _ =
    respond (responseLBS status204 (corsHeaders cors <> preflightHeaders) "")
  route "GET" ["config"] = withConfig (respond . ok . configViewGlobal)
  route "GET" ["providers"] = withConfig (\view -> configViewProviders view >>= respond . ok)
  route "GET" ["models"] = withConfig (\view -> configViewModels view >>= respond . either failed ok)
  route "GET" ["config", "threads", threadId] =
    withConfig (\view -> threadConfigRead (configViewStore view) threadId >>= respond . ok)
  route "GET" ["config", "threads", threadId, "capabilities"] =
    runtimeFor threadId >>= respond . ok . Map.keys . runtimeTools
  route "GET" ["config", "threads", threadId, "context"] =
    runtimeFor threadId >>= respond . ok . renderContextPolicy
  route "PUT" ["config", "threads", threadId] = withConfig (saveConfig threadId)
  route "GET" ["config", "threads", threadId, "tree"] = withConfig (tree threadId)
  route "POST" ["config", "threads", threadId, "paths"] = withConfig (paths threadId)
  route "GET" ["threads"] = withSessions sessionList
  route "POST" ["threads"] = withSessions createThread
  route "POST" ["threads", "import"] = withSessions importThread
  route "PATCH" ["threads", threadId] = withSessions (renameThread threadId)
  route "POST" ["threads", threadId, "archive"] = withSessions (archiveThread threadId)
  route "POST" ["threads", threadId, "restore"] = withSessions (restoreThread threadId)
  route "POST" ["threads", threadId, "fork"] = withSessions (forkThread threadId)
  route "GET" ["threads", threadId, "export"] = withSessions (exportThread threadId)
  route "GET" ["threads", threadId, "transcript"] = withSessions (threadTranscript threadId)
  route "GET" ["artifacts"] = withStore (fmap ok . artifactList)
  route "GET" ["artifacts", identifier] = withStore (artifact identifier)
  route _ ["agent"] =
    respond (jsonResponse cors status405 [("Allow", "POST, OPTIONS")] (message "method not allowed"))
  route _ _ = notFound
  notFound = respond (jsonResponse cors status404 [] (message "not found"))
  withStore use = maybe notFound (use >=> respond) artifacts
  withSessions use = maybe notFound use sessions
  withConfig use = maybe notFound use configs
  withBody :: (FromJSON body) => Text -> (body -> IO ResponseReceived) -> IO ResponseReceived
  withBody label use =
    strictRequestBody request
      >>= either (respond . bad . (label <>) . fromString) use . eitherDecode
  sessionList service =
    listSessions (serviceSessions service) includeArchived
      >>= respond . ok . filter (matches (kindQuery request))
   where
    matches (Just "home") = sessionIsHome
    matches (Just "task") = not . sessionIsHome
    matches _ = const True
    kindQuery = fmap Text.decodeUtf8 . join . lookup "kind" . queryString
  createThread service =
    withBody "invalid create request: " $ \(CreateSessionRequest threadId title requestedOwner) ->
      let owner = fromMaybe "yuki" (nonBlankText =<< requestedOwner)
       in createSession (serviceSessions service) threadId title owner Nothing Nothing
            >>= either (respond . sessionError) (respond . ok)
  renameThread threadId service =
    withBody "invalid rename request: " $ \(RenameSessionRequest title) ->
      renameSession (serviceSessions service) threadId title >>= sessionResult
  homeGuard service threadId continue =
    findSession (serviceSessions service) threadId >>= homeGate continue
   where
    homeGate _ (Just meta)
      | sessionIsHome meta =
          respond (jsonResponse cors status400 [] (message "home_session_immutable"))
    homeGate continue' _ = continue'
  archiveThread threadId service = homeGuard service threadId (archiveSession service threadId >>= sessionResult)
  restoreThread threadId service =
    homeGuard service threadId (restoreSession service threadId >>= sessionResult)
  forkThread source service =
    homeGuard service source $
      withBody "invalid fork request: " $ \(ForkSessionRequest target title node) ->
        forkSession service source target node title >>= sessionResult
  exportThread threadId service =
    exportSession service threadId >>= respond . maybe (missing "thread not found") ok
  importThread service =
    withBody "invalid import request: " $ \incoming ->
      homeGuard service (importTarget incoming) (importSession service incoming >>= sessionResult)
   where
    importTarget incoming = fromMaybe (sessionId (bundleMeta (importBundle incoming))) (importTargetId incoming)
  threadTranscript threadId service =
    findSession (serviceSessions service) threadId >>= transcriptSession service threadId
   where
    transcriptSession service' threadId' = \case
      Nothing -> transcriptLoad (serviceTranscripts service') threadId' >>= transcriptMissing service' threadId'
      Just _ -> transcriptLoad (serviceTranscripts service') threadId' >>= respond . ok . renderTranscript threadId' . fromMaybe []
    transcriptMissing service' threadId' = \case
      Nothing -> respond (missing "thread not found")
      Just messages ->
        (taskOwnerFor service' threadId' >>= ensureSession (serviceSessions service') threadId' Nothing)
          *> respond (ok (renderTranscript threadId' messages))
  sessionResult = either (respond . sessionError) (respond . ok)
  sessionError errorText
    | "unknown thread:" `TextValue.isPrefixOf` errorText = missing errorText
    | "not found:" `TextValue.isInfixOf` errorText = missing errorText
    | "already exists:" `TextValue.isInfixOf` errorText =
        jsonResponse cors status409 [] (message errorText)
    | otherwise = bad errorText
  saveConfig threadId view =
    strictRequestBody request
      >>= either (respond . bad . ("invalid ThreadConfig: " <>) . fromString) check . eitherDecode
   where
    check config =
      validateConfig config >>= either (respond . bad) (const (persist config))
    persist config =
      threadConfigWrite (configViewStore view) threadId config
        *> respond (responseLBS status204 (corsHeaders cors) "")
  tree threadId view =
    threadConfigRead (configViewStore view) threadId
      >>= maybe notFound listing . cwdPath . configCwd . flip resolveThreadConfig (configViewDefaults view)
   where
    listing dir = listTree dir (treeDepth (queryString request)) >>= respond . ok
  paths threadId view =
    withBody "invalid path completion request: " $ \(PathRequest prefix) ->
      threadConfigRead (configViewStore view) threadId
        >>= maybe
          (respond (ok (object ["prefix" .= prefix, "paths" .= ([] :: [Text])])))
          (completeFor prefix)
          . cwdPath
          . configCwd
          . flip resolveThreadConfig (configViewDefaults view)
   where
    completeFor prefix dir =
      completePaths dir prefix >>= respond . ok . completed prefix
    completed prefix matches =
      object ["prefix" .= prefix, "paths" .= matches]
  artifact identifier store = maybe (missing "artifact not found") plain <$> artifactFetch store identifier
  ok :: (ToJSON a) => a -> Response
  ok = jsonResponse cors status200 [] . toJSON
  missing text = jsonResponse cors status404 [] (message text)
  bad text = jsonResponse cors status400 [] (message text)
  failed text = jsonResponse cors status500 [] (message text)
  plain content =
    responseLBS
      status200
      (corsHeaders cors <> plainHeaders)
      (LazyByteString.fromStrict (Text.encodeUtf8 content))
  handleAgent = strictRequestBody request >>= either invalid stream . eitherDecode
  invalid parseError =
    respond (jsonResponse cors status400 [] (object ["error" .= ("invalid RunAgentInput: " <> parseError)]))
  stream input
    | not (validThreadId (AGUI.runThreadId input)) = respond (bad "invalid thread id")
    | otherwise = maybe (streamRun input) prepare sessions
   where
    prepare service =
      taskOwnerFor service (AGUI.runThreadId input)
        >>= ensureSession (serviceSessions service) (AGUI.runThreadId input) (latestUserTitle input)
        >>= gate . sessionArchived
     where
      gate False = transcriptInput service input >>= streamRun
      gate True = respond (conflict "thread is archived")
    streamRun accepted =
      runtimeFor (AGUI.runThreadId accepted)
        >>= respond
          . responseStream status200 (corsHeaders cors <> streamHeaders)
          . streamFor accepted
     where
      streamFor accepted' runtime write flush =
        runAgent runtime accepted' (\event -> write (encodeEvent event) *> flush)
  conflict text = jsonResponse cors status409 [] (message text)
  includeArchived = join (lookup "archived" (queryString request)) == Just "true"

latestUserTitle :: AGUI.RunAgentInput -> Maybe Text
latestUserTitle input =
  listToMaybe
    ( reverse
        [ TextValue.take 80 title
        | AGUI.User userMessage <- AGUI.runMessages input,
          Right raw <- [AGUI.userText (AGUI.userContent userMessage)],
          let title = TextValue.unwords (TextValue.words raw),
          not (TextValue.null title)
        ]
    )

taskOwnerFor :: SessionService -> Text -> IO Text
taskOwnerFor service threadId =
  maybe (pure "yuki") (pure . sessionOwnerId)
    =<< findSession (serviceSessions service) threadId

sessionOwnerId :: SessionMeta -> Text
sessionOwnerId = fromMaybe "yuki" . nonBlankText . sessionIncarnationId

nonBlankText :: Text -> Maybe Text
nonBlankText value
  | TextValue.null clean = Nothing
  | otherwise = Just clean
 where
  clean = TextValue.strip value

transcriptInput :: SessionService -> AGUI.RunAgentInput -> IO AGUI.RunAgentInput
transcriptInput service input =
  transcriptLoad (serviceTranscripts service) (AGUI.runThreadId input) <&> transcriptInputFromHistory input
 where
  transcriptInputFromHistory input' = \case
    Nothing -> input'
    Just [] -> input'
    Just history ->
      input'
        { AGUI.runMessages =
            appendLatestUser (toAguiMessages history) (latestUserMessage input')
        }

appendLatestUser :: [AGUI.Message] -> Maybe AGUI.Message -> [AGUI.Message]
appendLatestUser history Nothing = history
appendLatestUser history (Just nextMessage)
  | sameUser (listToMaybe (reverse history)) nextMessage = history
  | otherwise = history <> [nextMessage]
 where
  sameUser (Just (AGUI.User left)) (AGUI.User right) =
    AGUI.userId left == AGUI.userId right
      || AGUI.userContent left == AGUI.userContent right
  sameUser _ _ = False

latestUserMessage :: AGUI.RunAgentInput -> Maybe AGUI.Message
latestUserMessage =
  listToMaybe
    . reverse
    . filter user
    . AGUI.runMessages
 where
  user AGUI.User {} = True
  user _ = False

treeDepth :: Query -> Int
treeDepth = clamp . fromMaybe 2 . parse
 where
  parse = (readMaybe . unpack . Text.decodeUtf8 =<<) . join . lookup "depth"
  clamp = max 1 . min 8

validateCwd :: ThreadConfig -> IO (Either Text ())
validateCwd = maybe (pure (Right ())) check . cwdPath . configCwd
 where
  check dir = bool (Left ("not a directory: " <> fromString dir)) (Right ()) <$> doesDirectoryExist dir

validateConfig :: ThreadConfig -> IO (Either Text ())
validateConfig config = validateCwd config <&> (>> validateContextConfig config)

validateContextConfig :: ThreadConfig -> Either Text ()
validateContextConfig config =
  sequence_
    [ optional "contextReserveTokens" (> 0) (configContextReserveTokens config),
      optional "contextKeepUnits" (> 0) (configContextKeepUnits config),
      optional "contextSummaryTokens" (>= 96) (configContextSummaryTokens config)
    ]
 where
  optional name valid =
    maybe
      (Right ())
      (\value -> bool (Left (name <> " 超出允许范围")) (Right ()) (valid value))

renderContextPolicy :: Runtime -> Value
renderContextPolicy runtime =
  maybe
    (object ["enabled" .= False])
    configured
    (runtimeContext runtime)
 where
  tools = backendToolSpec <$> Map.elems (runtimeTools runtime)
  configured config =
    object
      [ "enabled" .= True,
        "windowTokens" .= contextWindow config (runtimeContextWindow runtime),
        "reserveTokens" .= contextReserveTokens config,
        "toolTokens" .= estimateToolsTokens tools,
        "budgetTokens" .= contextBudget config (runtimeContextWindow runtime) tools,
        "keepUnits" .= contextKeepUnits config,
        "summaryTokens" .= contextSummaryTokens config
      ]

runServer :: Settings -> Maybe SessionService -> Maybe ConfigView -> Maybe ArtifactStore -> (Text -> IO Runtime) -> IO ()
runServer settings sessions configs artifacts runtimeFor =
  runSettings
    ( setPort (settingsPort settings)
        . setHost (fromString (settingsHost settings))
        $ defaultSettings
    )
    (application (settingsCorsOrigin settings) sessions configs artifacts runtimeFor)

encodeEvent :: Event -> Builder.Builder
encodeEvent event =
  Builder.byteString "data: "
    <> Builder.lazyByteString (encode event)
    <> Builder.byteString "\n\n"

jsonResponse :: Maybe Text -> Status -> ResponseHeaders -> Value -> Response
jsonResponse cors status headers value =
  responseLBS
    status
    (corsHeaders cors <> [(hContentType, "application/json; charset=utf-8")] <> headers)
    (encode value)

message :: Text -> Value
message text = object ["error" .= text]

streamHeaders :: ResponseHeaders
streamHeaders =
  [ (hContentType, "text/event-stream; charset=utf-8"),
    (hCacheControl, "no-cache"),
    ("X-Accel-Buffering", "no")
  ]

plainHeaders :: ResponseHeaders
plainHeaders = [(hContentType, "text/plain; charset=utf-8")]

preflightHeaders :: ResponseHeaders
preflightHeaders =
  [ ("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, OPTIONS"),
    ("Access-Control-Allow-Headers", "Content-Type, Authorization"),
    ("Access-Control-Max-Age", "86400")
  ]

corsHeaders :: Maybe Text -> ResponseHeaders
corsHeaders = \case
  Nothing -> []
  Just origin ->
    [ ("Access-Control-Allow-Origin", Text.encodeUtf8 origin),
      (hVary, "Origin")
    ]
