module Yuki.N.Sessions
  ( SessionMeta,
    SessionStore (..),
    newSessionStore,
    validThreadId,
  )
where

import Control.Concurrent.MVar
import Control.Exception (IOException, displayException, try)
import Data.Aeson
import Data.Bool (bool)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Functor (($>), (<&>))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectoryIfMissing)
import System.IO (stderr)
import System.IO.Error (isDoesNotExistError)
import Yuki.N.AtomicFile (atomicEncodeFile)

data SessionMeta = SessionMeta
  { sessionId :: Text,
    sessionTitle :: Text,
    sessionUpdated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON SessionMeta where
  toJSON meta =
    object
      [ "id" .= sessionId meta,
        "title" .= sessionTitle meta,
        "updated" .= sessionUpdated meta,
        "archived" .= False,
        "kind" .= ("task" :: Text)
      ]

instance FromJSON SessionMeta where
  parseJSON = withObject "SessionMeta" $ \fields ->
    SessionMeta
      <$> fields .: "id"
      <*> fields .: "title"
      <*> fields .: "updated"

data SessionStore = SessionStore
  { listSessions :: IO [SessionMeta],
    findSession :: Text -> IO (Maybe SessionMeta),
    ensureSession :: Text -> Maybe Text -> IO SessionMeta,
    createSession :: Text -> IO (Either Text SessionMeta)
  }

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
      { listSessions =
          sortOn (Down . sessionUpdated)
            . Map.elems
            <$> readMVar lock,
        findSession = \threadId -> Map.lookup threadId <$> readMVar lock,
        ensureSession = ensure lock index,
        createSession = create lock index
      }

ensure :: MVar (Map Text SessionMeta) -> FilePath -> Text -> Maybe Text -> IO SessionMeta
ensure lock path threadId title =
  getPOSIXTime >>= commit
 where
  commit now =
    modifyMVar lock $ \sessions ->
      let stamp = round now
          meta =
            maybe
              (SessionMeta threadId (cleanTitle threadId title) stamp)
              ( \current ->
                  current
                    { sessionUpdated = stamp,
                      sessionTitle = refreshedTitle current
                    }
              )
              (Map.lookup threadId sessions)
          updated = Map.insert threadId meta sessions
       in persist path updated $> (updated, meta)
  refreshedTitle current
    | sessionTitle current == threadId = cleanTitle threadId title
    | otherwise = sessionTitle current

create :: MVar (Map Text SessionMeta) -> FilePath -> Text -> IO (Either Text SessionMeta)
create lock path threadId
  | not (validThreadId threadId) = pure (Left "invalid thread id")
  | otherwise =
      getPOSIXTime >>= commit
 where
  commit now =
    modifyMVar lock $ \sessions ->
      case Map.lookup threadId sessions of
        Just _ -> pure (sessions, Left ("thread already exists: " <> threadId))
        Nothing ->
          let stamp = round now
              meta = SessionMeta threadId threadId stamp
              updated = Map.insert threadId meta sessions
           in persist path updated $> (updated, Right meta)

persist :: FilePath -> Map Text SessionMeta -> IO ()
persist path = atomicEncodeFile path . Map.elems

loadIndex :: FilePath -> IO (Map Text SessionMeta)
loadIndex path =
  (try (eitherDecodeFileStrict path) :: IO (Either IOException (Either String [SessionMeta]))) >>= fromIndex
 where
  fromIndex (Left failure)
    | isDoesNotExistError failure = pure Map.empty
    | otherwise = warn (displayException failure)
  fromIndex (Right (Left failure)) = warn failure
  fromIndex (Right (Right sessions)) = pure (Map.fromList [(sessionId meta, meta) | meta <- sessions])
  warn failure =
    Map.empty
      <$ TextIO.hPutStrLn stderr ("YUKI.N sessions index: " <> Text.pack failure)

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

sessionsPath :: FilePath -> FilePath
sessionsPath dir = dir ++ "/sessions"

indexPath :: FilePath -> FilePath
indexPath dir = sessionsPath dir ++ "/index.json"
