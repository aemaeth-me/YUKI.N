module Yuki.N.Sessions
  ( ImportRequest (..),
    SessionBundle (..),
    SessionKind (..),
    SessionMeta (..),
    SessionService (..),
    SessionStore (..),
    archiveSession,
    deleteIncarnationSessions,
    exportSession,
    forkSession,
    homeThreadId,
    importSession,
    migrateSessionOwners,
    newSessionStore,
    restoreSession,
    sessionIsHome,
    validThreadId,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar
import Control.Exception (IOException, displayException, try)
import Data.Aeson
import Data.Bool (bool)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Functor (($>), (<&>))
import Data.List (find, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectoryIfMissing)
import System.IO (stderr)
import System.IO.Error (isDoesNotExistError)
import Yuki.N.AtomicFile (atomicEncodeFile)
import Yuki.N.Model
import Yuki.N.ThreadConfig (ThreadConfig (..), ThreadConfigStore (..))
import Yuki.N.Transcript (TranscriptStore (..))

data SessionKind = SessionHome | SessionTask
  deriving stock (Eq, Show)

data SessionMeta = SessionMeta
  { sessionId :: Text,
    sessionTitle :: Text,
    sessionIncarnationId :: Text,
    sessionCreated :: Integer,
    sessionUpdated :: Integer,
    sessionArchived :: Bool,
    sessionParent :: Maybe Text,
    sessionForkNode :: Maybe Text,
    sessionKind :: SessionKind
  }
  deriving stock (Eq, Show)

instance ToJSON SessionMeta where
  toJSON meta =
    object
      [ "id" .= sessionId meta,
        "title" .= sessionTitle meta,
        "incarnationId" .= sessionIncarnationId meta,
        "created" .= sessionCreated meta,
        "updated" .= sessionUpdated meta,
        "archived" .= sessionArchived meta,
        "parent" .= sessionParent meta,
        "forkNode" .= sessionForkNode meta,
        "kind" .= sessionKind meta
      ]

instance FromJSON SessionMeta where
  parseJSON = withObject "SessionMeta" $ \fields ->
    SessionMeta
      <$> fields .: "id"
      <*> fields .: "title"
      <*> fields .:? "incarnationId" .!= ""
      <*> fields .: "created"
      <*> fields .: "updated"
      <*> fields .:? "archived" .!= False
      <*> fields .:? "parent"
      <*> fields .:? "forkNode"
      <*> fields .:? "kind" .!= SessionTask

instance ToJSON SessionKind where
  toJSON SessionHome = String "home"
  toJSON SessionTask = String "task"

instance FromJSON SessionKind where
  parseJSON = withText "SessionKind" $ \case
    "home" -> pure SessionHome
    "task" -> pure SessionTask
    value -> fail ("unknown session kind: " <> Text.unpack value)

data SessionStore = SessionStore
  { listSessions :: Bool -> IO [SessionMeta],
    findSession :: Text -> IO (Maybe SessionMeta),
    ensureSession :: Text -> Maybe Text -> Text -> IO SessionMeta,
    ensureHomeSession :: Text -> Maybe Text -> IO SessionMeta,
    createSession :: Text -> Maybe Text -> Text -> Maybe Text -> Maybe Text -> IO (Either Text SessionMeta),
    claimSessionOwner :: Text -> Text -> IO (Either Text SessionMeta),
    renameSession :: Text -> Text -> IO (Either Text SessionMeta),
    setSessionArchived :: Text -> Bool -> IO (Either Text SessionMeta),
    deleteSessionsFor :: Text -> IO [SessionMeta]
  }

data SessionService = SessionService
  { serviceSessions :: SessionStore,
    serviceTranscripts :: TranscriptStore,
    serviceConfigs :: ThreadConfigStore,
    serviceArchiveThread :: Text -> IO ()
  }

data SessionBundle = SessionBundle
  { bundleVersion :: Int,
    bundleMeta :: SessionMeta,
    bundleConfig :: ThreadConfig,
    bundleTranscript :: [ChatMessage]
  }
  deriving stock (Eq, Show)

instance ToJSON SessionBundle where
  toJSON bundle =
    object
      [ "version" .= bundleVersion bundle,
        "meta" .= bundleMeta bundle,
        "config" .= bundleConfig bundle,
        "transcript" .= bundleTranscript bundle
      ]

instance FromJSON SessionBundle where
  parseJSON = withObject "SessionBundle" $ \fields ->
    SessionBundle
      <$> fields .: "version"
      <*> fields .: "meta"
      <*> fields .: "config"
      <*> fields .: "transcript"

data ImportRequest = ImportRequest
  { importBundle :: SessionBundle,
    importTargetId :: Maybe Text,
    importTitle :: Maybe Text
  }
  deriving stock (Eq, Show)

instance FromJSON ImportRequest where
  parseJSON = withObject "ImportRequest" $ \fields ->
    ImportRequest
      <$> fields .: "bundle"
      <*> fields .:? "threadId"
      <*> fields .:? "title"

newSessionStore :: FilePath -> IO SessionStore
newSessionStore dir =
  createDirectoryIfMissing True path
    *> loadIndex index
    >>= newMVar
    <&> store
 where
  path = sessionsPath dir
  index = indexPath dir
  store lock =
    SessionStore
      { listSessions = \includeArchived ->
          sortOn (Down . sessionUpdated)
            . filter (bool (not . sessionArchived) (const True) includeArchived)
            . Map.elems
            <$> readMVar lock,
        findSession = \threadId -> Map.lookup threadId <$> readMVar lock,
        ensureSession = ensure lock index SessionTask,
        ensureHomeSession = ensureHome lock index,
        createSession = create lock index,
        claimSessionOwner = claim lock index,
        renameSession = rename lock index,
        setSessionArchived = archive lock index,
        deleteSessionsFor = deleteForIncarnation lock index
      }

ensure :: MVar (Map Text SessionMeta) -> FilePath -> SessionKind -> Text -> Maybe Text -> Text -> IO SessionMeta
ensure lock path kind threadId title rawOwner =
  getPOSIXTime >>= \now ->
    modifyMVar lock $ \sessions ->
      let stamp = round now
          owner = cleanOwner rawOwner
          meta =
            maybe
              (SessionMeta threadId (cleanTitle threadId title) owner stamp stamp False Nothing Nothing kind)
              ( \current ->
                  current
                    { sessionIncarnationId = bool (sessionIncarnationId current) owner (Text.null (Text.strip (sessionIncarnationId current))),
                      sessionUpdated = stamp,
                      sessionTitle = refreshedTitle current,
                      sessionKind = bool (sessionKind current) SessionHome (kind == SessionHome)
                    }
              )
              (Map.lookup threadId sessions)
          updated = Map.insert threadId meta sessions
       in persist path updated $> (updated, meta)
 where
  refreshedTitle current
    | sessionTitle current == threadId = cleanTitle threadId title
    | otherwise = sessionTitle current

ensureHome :: MVar (Map Text SessionMeta) -> FilePath -> Text -> Maybe Text -> IO SessionMeta
ensureHome lock path incarnation rawName =
  ensure lock path SessionHome (homeThreadId incarnation) (Just fallback) incarnation
 where
  fallback = fromMaybe incarnation (nonBlank =<< rawName)

deleteForIncarnation :: MVar (Map Text SessionMeta) -> FilePath -> Text -> IO [SessionMeta]
deleteForIncarnation lock path incarnation =
  modifyMVar lock $ \sessions ->
    let removed =
          [ meta
          | meta <- Map.elems sessions,
            sessionIncarnationId meta == incarnation
          ]
        kept = Map.filter ((/= incarnation) . sessionIncarnationId) sessions
        updated = kept
     in persist path updated $> (updated, removed)

create :: MVar (Map Text SessionMeta) -> FilePath -> Text -> Maybe Text -> Text -> Maybe Text -> Maybe Text -> IO (Either Text SessionMeta)
create lock path threadId title rawOwner parent node
  | not (validThreadId threadId) = pure (Left "invalid thread id")
  | isHomeThreadId threadId = pure (Left ("reserved thread id: " <> threadId))
  | Text.null owner = pure (Left "incarnation id must not be empty")
  | otherwise =
      getPOSIXTime >>= \now ->
        modifyMVar lock $ \sessions ->
          case Map.lookup threadId sessions of
            Just _ -> pure (sessions, Left ("thread already exists: " <> threadId))
            Nothing ->
              let stamp = round now
                  meta = SessionMeta threadId (cleanTitle threadId title) owner stamp stamp False parent node SessionTask
                  updated = Map.insert threadId meta sessions
               in persist path updated $> (updated, Right meta)
 where
  owner = Text.strip rawOwner

claim :: MVar (Map Text SessionMeta) -> FilePath -> Text -> Text -> IO (Either Text SessionMeta)
claim lock path threadId rawOwner
  | Text.null owner = pure (Left "incarnation id must not be empty")
  | otherwise =
      modifyMVar lock $ \sessions ->
        case Map.lookup threadId sessions of
          Nothing -> pure (sessions, Left ("unknown thread: " <> threadId))
          Just current
            | Text.null (Text.strip (sessionIncarnationId current)) ->
                let changed = current {sessionIncarnationId = owner}
                    updated = Map.insert threadId changed sessions
                 in persist path updated $> (updated, Right changed)
            | sessionIncarnationId current == owner -> pure (sessions, Right current)
            | otherwise ->
                pure
                  ( sessions,
                    Left
                      ( "thread incarnation is immutable: "
                          <> sessionIncarnationId current
                      )
                  )
 where
  owner = Text.strip rawOwner

rename :: MVar (Map Text SessionMeta) -> FilePath -> Text -> Text -> IO (Either Text SessionMeta)
rename lock path threadId title
  | Text.null clean = pure (Left "title must not be empty")
  | otherwise = update lock path threadId (\now meta -> meta {sessionTitle = clean, sessionUpdated = now})
 where
  clean = Text.take 120 (Text.strip title)

archive :: MVar (Map Text SessionMeta) -> FilePath -> Text -> Bool -> IO (Either Text SessionMeta)
archive lock path threadId archived =
  update lock path threadId (\now meta -> meta {sessionArchived = archived, sessionUpdated = now})

update :: MVar (Map Text SessionMeta) -> FilePath -> Text -> (Integer -> SessionMeta -> SessionMeta) -> IO (Either Text SessionMeta)
update lock path threadId change =
  getPOSIXTime >>= \now ->
    modifyMVar lock $ \sessions ->
      case Map.lookup threadId sessions of
        Nothing -> pure (sessions, Left ("unknown thread: " <> threadId))
        Just current ->
          let meta = change (round now) current
              updated = Map.insert threadId meta sessions
           in persist path updated $> (updated, Right meta)

persist :: FilePath -> Map Text SessionMeta -> IO ()
persist path = atomicEncodeFile path . Map.elems

loadIndex :: FilePath -> IO (Map Text SessionMeta)
loadIndex path =
  (try (eitherDecodeFileStrict path) :: IO (Either IOException (Either String [SessionMeta]))) >>= \case
    Left failure
      | isDoesNotExistError failure -> pure Map.empty
      | otherwise -> warn (displayException failure)
    Right (Left failure) -> warn failure
    Right (Right sessions) -> pure (Map.fromList [(sessionId meta, meta) | meta <- sessions])
 where
  warn failure =
    Map.empty
      <$ TextIO.hPutStrLn stderr ("YUKI.N sessions index: " <> Text.pack failure)

migrateSessionOwners :: SessionStore -> ThreadConfigStore -> IO (Either Text ())
migrateSessionOwners sessions configs =
  listSessions sessions True >>= migrateAll
 where
  migrateAll [] = pure (Right ())
  migrateAll (meta : rest) =
    threadConfigRead configs identifier >>= \config ->
      let owner =
            bool
              (sessionIncarnationId meta)
              (fromMaybe "yuki" (nonBlank =<< configIncarnationId config))
              (Text.null (Text.strip (sessionIncarnationId meta)))
       in claimSessionOwner sessions identifier owner >>= \case
            Left failure -> pure (Left failure)
            Right claimed ->
              canonicalize claimed config *> migrateAll rest
   where
    identifier = sessionId meta
    canonicalize claimed config =
      bool
        (pure ())
        (threadConfigWrite configs identifier (config {configIncarnationId = Just (sessionIncarnationId claimed)}))
        (configIncarnationId config /= Just (sessionIncarnationId claimed))

archiveSession :: SessionService -> Text -> IO (Either Text SessionMeta)
archiveSession service threadId =
  setSessionArchived (serviceSessions service) threadId True >>= \result ->
    result <$ either (const (pure ())) (const (serviceArchiveThread service threadId)) result

deleteIncarnationSessions :: SessionService -> Text -> IO ()
deleteIncarnationSessions service incarnation =
  deleteSessionsFor (serviceSessions service) incarnation >>= mapM_ cleanup
 where
  cleanup meta = do
    transcriptDelete (serviceTranscripts service) (sessionId meta)
    threadConfigDelete (serviceConfigs service) (sessionId meta)

restoreSession :: SessionService -> Text -> IO (Either Text SessionMeta)
restoreSession service threadId = setSessionArchived (serviceSessions service) threadId False

exportSession :: SessionService -> Text -> IO (Maybe SessionBundle)
exportSession service threadId =
  findSession (serviceSessions service) threadId >>= traverse bundle
 where
  bundle meta =
    SessionBundle 1 meta
      <$> threadConfigRead (serviceConfigs service) threadId
      <*> (fromMaybe [] <$> transcriptLoad (serviceTranscripts service) threadId)

forkSession :: SessionService -> Text -> Text -> Maybe Text -> Maybe Text -> IO (Either Text SessionMeta)
forkSession service source target node title
  | not (validThreadId target) = pure (Left "invalid target thread id")
  | otherwise =
      findSession (serviceSessions service) target >>= maybe fork (const (pure (Left ("thread already exists: " <> target))))
 where
  fork =
    findSession (serviceSessions service) source >>= \case
      Nothing -> pure (Left ("unknown thread: " <> source))
      Just sourceMeta ->
        transcriptLoad (serviceTranscripts service) source >>= \case
          Nothing -> pure (Left ("source transcript not found: " <> source))
          Just transcript ->
            either (pure . Left) (materialize sourceMeta) (prefixAt node transcript)
  materialize sourceMeta prefix =
    threadConfigRead (serviceConfigs service) source >>= \config ->
      let owner = sessionOwner sourceMeta
          copied = config {configIncarnationId = Just owner}
       in createSession (serviceSessions service) target title owner (Just source) node >>= \case
            Left failure -> pure (Left failure)
            Right created ->
              transcriptSave (serviceTranscripts service) target prefix
                *> threadConfigWrite (serviceConfigs service) target copied
                $> Right created

importSession :: SessionService -> ImportRequest -> IO (Either Text SessionMeta)
importSession service request
  | bundleVersion bundle /= 1 = pure (Left "unsupported session bundle version")
  | not (validThreadId target) = pure (Left "invalid target thread id")
  | otherwise =
      findSession (serviceSessions service) target >>= maybe materialize (const (pure (Left ("thread already exists: " <> target))))
 where
  bundle = importBundle request
  sourceMeta = bundleMeta bundle
  target = fromMaybe (sessionId sourceMeta) (importTargetId request)
  title = importTitle request <|> Just (sessionTitle sourceMeta)
  owner =
    fromMaybe
      "yuki"
      ( nonBlank (sessionIncarnationId sourceMeta)
          <|> (nonBlank =<< configIncarnationId (bundleConfig bundle))
      )
  config = (bundleConfig bundle) {configIncarnationId = Just owner}
  materialize =
    createSession (serviceSessions service) target title owner (sessionParent sourceMeta) (sessionForkNode sourceMeta) >>= \case
      Left failure -> pure (Left failure)
      Right created ->
        transcriptSave (serviceTranscripts service) target (bundleTranscript bundle)
          *> threadConfigWrite (serviceConfigs service) target config
          $> Right created

prefixAt :: Maybe Text -> [ChatMessage] -> Either Text [ChatMessage]
prefixAt Nothing messages = Right messages
prefixAt (Just node) messages =
  maybe (Left ("history node not found: " <> node)) (Right . flip take messages . (+ 1)) found
 where
  found =
    fst
      <$> find
        (\(index, message) -> node `elem` messageIds index message)
        (zip [0 ..] messages)
  messageIds index = \case
    ChatAssistant turn -> [turnMessageId turn, auto index <> "-reasoning"]
    _ -> [auto index]
  auto index = "tr-" <> Text.pack (show (index :: Int))

validThreadId :: Text -> Bool
validThreadId threadId =
  not (Text.null threadId)
    && Text.length threadId <= 128
    && Text.all safe threadId
 where
  safe char = isAsciiLower char || isAsciiUpper char || isDigit char || char `elem` ("-._" :: String)

cleanTitle :: Text -> Maybe Text -> Text
cleanTitle threadId = maybe threadId clean
 where
  clean title = bool (Text.take 120 (Text.strip title)) threadId (Text.null (Text.strip title))

cleanOwner :: Text -> Text
cleanOwner = fromMaybe "yuki" . nonBlank

sessionOwner :: SessionMeta -> Text
sessionOwner = cleanOwner . sessionIncarnationId

sessionIsHome :: SessionMeta -> Bool
sessionIsHome = (== SessionHome) . sessionKind

homeThreadId :: Text -> Text
homeThreadId incarnationId = "home-" <> incarnationId

isHomeThreadId :: Text -> Bool
isHomeThreadId = ("home-" `Text.isPrefixOf`)

nonBlank :: Text -> Maybe Text
nonBlank value
  | Text.null clean = Nothing
  | otherwise = Just clean
 where
  clean = Text.strip value

sessionsPath :: FilePath -> FilePath
sessionsPath dir = dir ++ "/sessions"

indexPath :: FilePath -> FilePath
indexPath dir = sessionsPath dir ++ "/index.json"
