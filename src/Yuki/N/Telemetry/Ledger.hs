module Yuki.N.Telemetry.Ledger
  ( Ledger (..),
    appendDelivery,
    appendFsChange,
    deliveriesFor,
    enrichFromGit,
    fsChangesFor,
    newLedger,
    quietly,
    recordDelivery,
    recordFsChange,
  )
where

import Control.Applicative (liftA3)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception
  ( IOException,
    SomeAsyncException,
    SomeException,
    displayException,
    fromException,
    throwIO,
    try,
  )
import Control.Monad (when)
import Data.Aeson (eitherDecodeStrict', encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor ((<&>))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Unique (hashUnique, newUnique)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (stderr)
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Yuki.N.Telemetry

newLedger :: FilePath -> IO Ledger
newLedger dir =
  (try @IOException (createDirectoryIfMissing True dir) >>= either logDirErr (const (pure ())))
    *> liftA3 Ledger (pure (dir </> "deliveries.jsonl")) (pure (dir </> "fs-changes.jsonl")) (newMVar ())
 where
  logDirErr = TextIO.hPutStrLn stderr . ("yuki.telemetry: cannot create ledger dir: " <>) . Text.pack . displayException

appendDelivery :: Ledger -> DeliveryRecord -> IO ()
appendDelivery ledger record =
  withMVar (ledgerLock ledger) (const (appendLine (ledgerDeliveriesFile ledger) (encode record)))

appendFsChange :: Ledger -> FsChangeRecord -> IO ()
appendFsChange ledger record =
  withMVar (ledgerLock ledger) (const (appendLine (ledgerFsChangesFile ledger) (encode record)))

appendLine :: FilePath -> LazyByteString.ByteString -> IO ()
appendLine path line =
  try @IOException (LazyByteString.appendFile path (line <> "\n")) >>= \case
    Left exception -> TextIO.hPutStrLn stderr ("yuki.telemetry: append failed: " <> Text.pack (displayException exception))
    Right () -> pure ()

recordDelivery :: Ledger -> Telemetry -> DeliveryRecord -> IO ()
recordDelivery ledger telemetry record =
  liftA2 (,) (telemetryClock telemetry) (hashUnique <$> newUnique) >>= \(now, unique) ->
    let stamped =
          record
            { deliveryId = "dlv-" <> Text.pack (show (seconds now)) <> "-" <> Text.pack (show unique),
              deliveryAt = seconds now
            }
     in quietly (appendDelivery ledger stamped *> publish telemetry (FrameDelivery stamped))

recordFsChange :: Ledger -> Telemetry -> FsChangeRecord -> IO ()
recordFsChange ledger telemetry record =
  liftA2 (,) (telemetryClock telemetry) (hashUnique <$> newUnique) >>= \(now, unique) ->
    let stamped =
          record
            { fsChangeId = "fsc-" <> Text.pack (show (seconds now)) <> "-" <> Text.pack (show unique),
              fsChangeAt = seconds now
            }
     in quietly (appendFsChange ledger stamped *> publish telemetry (FrameFsChange stamped))

quietly :: IO () -> IO ()
quietly action =
  try @SomeException action >>= \case
    Left exception ->
      maybe
        (TextIO.hPutStrLn stderr ("yuki.telemetry: " <> Text.pack (displayException exception)))
        throwIO
        (fromException exception :: Maybe SomeAsyncException)
    Right () -> pure ()

deliveriesFor :: Ledger -> Text -> Maybe Text -> Int -> Maybe Integer -> IO [DeliveryRecord]
deliveriesFor ledger incarnation threadId limit before =
  records <$> readLines (ledgerDeliveriesFile ledger)
 where
  records =
    take (min 200 limit)
      . sortOn (Down . deliveryAt)
      . filter matches
      . mapMaybe decode
  matches record =
    deliveryIncarnation record == incarnation
      && maybe True (== deliveryThreadId record) threadId
      && maybe True (\cursor -> deliveryAt record < cursor) before
  decode = either (const Nothing) Just . eitherDecodeStrict' . LazyByteString.toStrict

fsChangesFor :: Ledger -> Text -> Maybe Text -> Maybe Text -> Int -> Maybe Integer -> IO [FsChangeRecord]
fsChangesFor ledger incarnation threadId runId limit before =
  records <$> readLines (ledgerFsChangesFile ledger)
 where
  records =
    take (min 200 limit)
      . sortOn (Down . fsChangeAt)
      . filter matches
      . mapMaybe decode
  matches record =
    fsChangeIncarnation record == incarnation
      && maybe True (== fsChangeThreadId record) threadId
      && maybe True (== fsChangeRunId record) runId
      && maybe True (\cursor -> fsChangeAt record < cursor) before
  decode = either (const Nothing) Just . eitherDecodeStrict' . LazyByteString.toStrict

readLines :: FilePath -> IO [LazyByteString.ByteString]
readLines path =
  try @IOException (LazyByteString.readFile path) >>= \case
    Left _ -> pure []
    Right bytes -> pure (filter (not . LazyByteString.null) (LazyByteString.split 10 bytes))

enrichFromGit :: Ledger -> Telemetry -> Int -> Text -> Text -> Text -> Maybe FilePath -> IO ()
enrichFromGit ledger telemetry timeoutSeconds incarnation runId threadId cwd =
  quietly (maybe (pure ()) enrich cwd)
 where
  enrich dir =
    gitSucceeds dir ["rev-parse", "--is-inside-work-tree"] >>= \inside ->
      when inside (collect dir)
  collect dir =
    liftA2 (,) (parsePorcelain <$> gitLines dir ["status", "--porcelain"]) (statPairs <$> gitLines dir ["diff", "--stat", "HEAD"])
      >>= \(changed, stats) ->
        fsChangesFor ledger incarnation (Just threadId) (Just runId) 200 Nothing
          >>= (\known -> traverse_ (appendChanged stats known) changed) . Set.fromList . fmap fsChangePath
  appendChanged stats known (path, op) =
    when (Set.notMember path known) (recordFsChange ledger telemetry (gitRecord stats path op))
  gitRecord stats path op =
    FsChangeRecord
      { fsChangeId = "",
        fsChangeRunId = runId,
        fsChangeThreadId = threadId,
        fsChangeIncarnation = incarnation,
        fsChangePath = path,
        fsChangeOp = op,
        fsChangeOrigin = OriginGit,
        fsChangeDiff = Nothing,
        fsChangeStat = Map.lookup path stats,
        fsChangeAt = 0
      }
  gitSucceeds dir args =
    timed (readProcessWithExitCode "git" ("-C" : dir : args) "") <&> \case
      Nothing -> False
      Just (ExitSuccess, _, _) -> True
      Just _ -> False
  gitLines dir args =
    timed (readProcessWithExitCode "git" ("-C" : dir : args) "") <&> \case
      Nothing -> []
      Just (ExitSuccess, output, _) -> Text.lines (Text.pack output)
      Just _ -> []
  timed = timeout (timeoutSeconds * 1000000)

parsePorcelain :: [Text] -> [(Text, FsChangeOp)]
parsePorcelain = mapMaybe parseLine
 where
  parseLine line
    | Text.null path = Nothing
    | otherwise = Just (path, opOf line)
   where
    path = changedPath line

changedPath :: Text -> Text
changedPath line
  | Text.null rest = raw
  | otherwise = Text.strip (Text.drop 3 rest)
 where
  raw = Text.drop 3 line
  (_, rest) = Text.breakOn " -> " raw

opOf :: Text -> FsChangeOp
opOf line
  | "??" `Text.isPrefixOf` line = FsCreated
  | "D" `Text.isInfixOf` status = FsDeleted
  | "A" `Text.isInfixOf` status = FsCreated
  | "R" `Text.isInfixOf` status = FsCreated
  | otherwise = FsModified
 where
  status = Text.take 2 line

statPairs :: [Text] -> Map Text Text
statPairs = Map.fromList . mapMaybe pair . filter (Text.isInfixOf "|")
 where
  pair line
    | Text.null path = Nothing
    | otherwise = Just (path, Text.strip line)
   where
    path = Text.strip (fst (Text.breakOn "|" line))
