module Yuki.N.Experience
  ( ExperienceCursor (..),
    ExperienceDraft (..),
    ExperienceEvent (..),
    ExperienceStore (..),
    newExperienceStore,
    newMemoryExperienceStore,
  )
where

import Control.Concurrent.MVar
import Control.Exception (IOException, displayException, try)
import Control.Monad (forM_, void)
import Data.Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor (($>), (<&>))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO (IOMode (AppendMode, WriteMode), hFlush, withFile)
import System.IO.Error (isDoesNotExistError)
import Yuki.N.Blob (sha256)

data ExperienceCursor = ExperienceCursor
  { cursorStreamId :: Text,
    cursorSeq :: Int
  }
  deriving stock (Eq, Show)

instance ToJSON ExperienceCursor where
  toJSON cursor = object ["streamId" .= cursorStreamId cursor, "seq" .= cursorSeq cursor]

instance FromJSON ExperienceCursor where
  parseJSON = withObject "ExperienceCursor" $ \fields ->
    ExperienceCursor <$> fields .: "streamId" <*> fields .: "seq"

data ExperienceDraft = ExperienceDraft
  { draftIncarnationId :: Text,
    draftOperationId :: Text,
    draftActorId :: Text,
    draftIntentId :: Maybe Text,
    draftTaskId :: Maybe Text,
    draftRunId :: Maybe Text,
    draftDelegationId :: Maybe Text,
    draftCausationId :: Maybe Text,
    draftKind :: Text,
    draftPayloadRef :: Text,
    draftPayloadHash :: Text
  }
  deriving stock (Eq, Show)

data ExperienceEvent = ExperienceEvent
  { experienceEventId :: Text,
    experienceIncarnationId :: Text,
    experienceOperationId :: Text,
    experienceActorId :: Text,
    experienceIntentId :: Maybe Text,
    experienceTaskId :: Maybe Text,
    experienceRunId :: Maybe Text,
    experienceDelegationId :: Maybe Text,
    experienceStreamId :: Text,
    experienceSeq :: Int,
    experienceCausationId :: Maybe Text,
    experienceKind :: Text,
    experiencePayloadRef :: Text,
    experiencePayloadHash :: Text,
    experienceOccurredAt :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON ExperienceEvent where
  toJSON event =
    object
      [ "eventId" .= experienceEventId event,
        "incarnationId" .= experienceIncarnationId event,
        "operationId" .= experienceOperationId event,
        "actorId" .= experienceActorId event,
        "intentId" .= experienceIntentId event,
        "taskId" .= experienceTaskId event,
        "runId" .= experienceRunId event,
        "delegationId" .= experienceDelegationId event,
        "streamId" .= experienceStreamId event,
        "seq" .= experienceSeq event,
        "causationId" .= experienceCausationId event,
        "kind" .= experienceKind event,
        "payloadRef" .= experiencePayloadRef event,
        "payloadHash" .= experiencePayloadHash event,
        "occurredAt" .= experienceOccurredAt event
      ]

instance FromJSON ExperienceEvent where
  parseJSON = withObject "ExperienceEvent" $ \fields ->
    ExperienceEvent
      <$> fields .: "eventId"
      <*> fields .: "incarnationId"
      <*> fields .: "operationId"
      <*> fields .: "actorId"
      <*> fields .:? "intentId"
      <*> fields .:? "taskId"
      <*> fields .:? "runId"
      <*> fields .:? "delegationId"
      <*> fields .: "streamId"
      <*> fields .: "seq"
      <*> fields .:? "causationId"
      <*> fields .: "kind"
      <*> fields .: "payloadRef"
      <*> fields .: "payloadHash"
      <*> fields .: "occurredAt"

data ExperienceStore = ExperienceStore
  { experienceAppend :: Maybe ExperienceCursor -> ExperienceDraft -> IO (Either Text ExperienceEvent),
    experienceReadAfter :: Text -> Int -> IO [ExperienceEvent],
    experienceEvents :: Text -> IO [ExperienceEvent],
    experienceHead :: Text -> IO ExperienceCursor,
    experienceDelete :: Text -> IO ()
  }

data ExperienceState = ExperienceState
  { stateEvents :: Map Text [ExperienceEvent],
    stateHeads :: Map Text Int
  }

emptyState :: ExperienceState
emptyState = ExperienceState Map.empty Map.empty

newExperienceStore :: FilePath -> IO (Either Text ExperienceStore)
newExperienceStore dir =
  createDirectoryIfMissing True (eventsDir dir)
    *> loadEvents path
    >>= traverse (fmap (mkStore (appendEventFile path) (rewriteEvents path)) . newMVar)
 where
  path = eventsPath dir

newMemoryExperienceStore :: IO ExperienceStore
newMemoryExperienceStore = newMVar emptyState <&> mkStore (const (pure ())) (const (pure ()))

mkStore :: (ExperienceEvent -> IO ()) -> (ExperienceState -> IO ()) -> MVar ExperienceState -> ExperienceStore
mkStore persist rewrite lock =
  ExperienceStore
    { experienceAppend = append,
      experienceReadAfter = \incarnation seqNo ->
        filter ((> seqNo) . experienceSeq)
          . Map.findWithDefault [] incarnation
          . stateEvents
          <$> readMVar lock,
      experienceEvents = \incarnation ->
        Map.findWithDefault [] incarnation . stateEvents <$> readMVar lock,
      experienceHead = \incarnation ->
        ExperienceCursor (streamId incarnation)
          . Map.findWithDefault 0 incarnation
          . stateHeads
          <$> readMVar lock,
      experienceDelete = \incarnation ->
        void
          ( modifyMVar
              lock
              ( \state ->
                  let changed =
                        state
                          { stateEvents = Map.delete incarnation (stateEvents state),
                            stateHeads = Map.delete incarnation (stateHeads state)
                          }
                   in rewrite changed $> (changed, ())
              )
          )
    }
 where
  append expected draft =
    getPOSIXTime >>= \now ->
      modifyMVar lock $ \state ->
        let incarnation = draftIncarnationId draft
            headSeq = Map.findWithDefault 0 incarnation (stateHeads state)
         in case stale incarnation headSeq expected of
              Just failure -> pure (state, Left failure)
              Nothing ->
                let next = headSeq + 1
                    event = materialize next (round now) draft
                    updated =
                      state
                        { stateEvents = Map.insertWith (flip (<>)) incarnation [event] (stateEvents state),
                          stateHeads = Map.insert incarnation next (stateHeads state)
                        }
                 in persist event $> (updated, Right event)

stale :: Text -> Int -> Maybe ExperienceCursor -> Maybe Text
stale _ _ Nothing = Nothing
stale incarnation current (Just expected)
  | cursorStreamId expected /= streamId incarnation =
      Just ("experience stream mismatch: expected " <> streamId incarnation)
  | cursorSeq expected /= current =
      Just
        ( "stale experience cursor: expected "
            <> Text.pack (show current)
            <> ", got "
            <> Text.pack (show (cursorSeq expected))
        )
  | otherwise = Nothing

materialize :: Int -> Integer -> ExperienceDraft -> ExperienceEvent
materialize seqNo now draft =
  ExperienceEvent
    { experienceEventId =
        "event-"
          <> sha256
            ( LazyByteString.toStrict
                ( encode
                    ( object
                        [ "stream" .= stream,
                          "seq" .= seqNo,
                          "kind" .= draftKind draft,
                          "payload" .= draftPayloadHash draft
                        ]
                    )
                )
            ),
      experienceIncarnationId = incarnation,
      experienceOperationId = draftOperationId draft,
      experienceActorId = draftActorId draft,
      experienceIntentId = draftIntentId draft,
      experienceTaskId = draftTaskId draft,
      experienceRunId = draftRunId draft,
      experienceDelegationId = draftDelegationId draft,
      experienceStreamId = stream,
      experienceSeq = seqNo,
      experienceCausationId = draftCausationId draft,
      experienceKind = draftKind draft,
      experiencePayloadRef = draftPayloadRef draft,
      experiencePayloadHash = draftPayloadHash draft,
      experienceOccurredAt = now
    }
 where
  incarnation = draftIncarnationId draft
  stream = streamId incarnation

streamId :: Text -> Text
streamId = ("experience/" <>)

appendEventFile :: FilePath -> ExperienceEvent -> IO ()
appendEventFile path event =
  withFile path AppendMode $ \handle ->
    LazyByteString.hPutStr handle (encode event <> "\n") *> hFlush handle

rewriteEvents :: FilePath -> ExperienceState -> IO ()
rewriteEvents path state =
  withFile path WriteMode $ \handle ->
    forM_ events $ \event ->
      LazyByteString.hPutStr handle (encode event <> "\n")
 where
  events = concat (Map.elems (stateEvents state))

loadEvents :: FilePath -> IO (Either Text ExperienceState)
loadEvents path =
  (try (LazyByteString.readFile path) :: IO (Either IOException LazyByteString.ByteString))
    <&> either absent parse
 where
  absent failure
    | isDoesNotExistError failure = Right emptyState
    | otherwise = Left ("cannot read experience stream: " <> Text.pack (displayException failure))

parse :: LazyByteString.ByteString -> Either Text ExperienceState
parse bytes =
  traverse decodeLine numbered >>= validate
 where
  numbered =
    filter
      (not . LazyByteString.null . snd)
      (zip [1 :: Int ..] (LazyByteString.split 10 bytes))
  decodeLine (lineNo, line) =
    either
      (Left . (\failure -> "invalid experience event at line " <> Text.pack (show lineNo) <> ": " <> Text.pack failure))
      Right
      (eitherDecode line)
  validate events =
    foldl' insert (Right emptyState) (sortOn (\event -> (experienceStreamId event, experienceSeq event)) events)
  insert (Left failure) _ = Left failure
  insert (Right state) event
    | experienceStreamId event /= streamId incarnation =
        Left ("experience stream/id mismatch at " <> experienceEventId event)
    | experienceSeq event /= expected =
        Left
          ( "non-contiguous experience stream "
              <> experienceStreamId event
              <> ": expected "
              <> Text.pack (show expected)
              <> ", got "
              <> Text.pack (show (experienceSeq event))
          )
    | otherwise =
        Right
          state
            { stateEvents = Map.insertWith (flip (<>)) incarnation [event] (stateEvents state),
              stateHeads = Map.insert incarnation (experienceSeq event) (stateHeads state)
            }
   where
    incarnation = experienceIncarnationId event
    expected = Map.findWithDefault 0 incarnation (stateHeads state) + 1

eventsDir :: FilePath -> FilePath
eventsDir dir = dir </> "events"

eventsPath :: FilePath -> FilePath
eventsPath dir = eventsDir dir </> "events.jsonl"
