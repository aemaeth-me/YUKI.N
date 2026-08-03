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
  try @IOException (LazyByteString.appendFile path (line <> "\n"))
    >>= either logAppendError (const (pure ()))
 where
  logAppendError exception =
    TextIO.hPutStrLn stderr ("yuki.telemetry: append failed: " <> Text.pack (displayException exception))

recordDelivery :: Ledger -> Telemetry -> DeliveryRecord -> IO ()
recordDelivery ledger telemetry record =
  liftA2 stamp (telemetryClock telemetry) (hashUnique <$> newUnique)
    >>= quietly . persist
 where
  stamp now unique =
    record
      { deliveryId = "dlv-" <> Text.pack (show (seconds now)) <> "-" <> Text.pack (show unique),
        deliveryAt = seconds now
      }
  persist stamped =
    appendDelivery ledger stamped *> publish telemetry (FrameDelivery stamped)

recordFsChange :: Ledger -> Telemetry -> FsChangeRecord -> IO ()
recordFsChange ledger telemetry record =
  liftA2 stamp (telemetryClock telemetry) (hashUnique <$> newUnique)
    >>= quietly . persist
 where
  stamp now unique =
    record
      { fsChangeId = "fsc-" <> Text.pack (show (seconds now)) <> "-" <> Text.pack (show unique),
        fsChangeAt = seconds now
      }
  persist stamped =
    appendFsChange ledger stamped *> publish telemetry (FrameFsChange stamped)

quietly :: IO () -> IO ()
quietly action =
  try @SomeException action >>= either rethrowAsync (const (pure ()))
 where
  rethrowAsync exception =
    maybe
      (TextIO.hPutStrLn stderr ("yuki.telemetry: " <> Text.pack (displayException exception)))
      throwIO
      (fromException exception :: Maybe SomeAsyncException)

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
  try @IOException (LazyByteString.readFile path)
    >>= either (const (pure [])) (pure . splitLines)
 where
  splitLines = filter (not . LazyByteString.null) . LazyByteString.split 10

enrichFromGit :: Ledger -> Telemetry -> Int -> Text -> Text -> Text -> Maybe FilePath -> IO ()
enrichFromGit ledger telemetry timeoutSeconds incarnation runId threadId cwd =
  quietly (maybe (pure ()) enrich cwd)
 where
  enrich dir =
    gitSucceeds dir ["rev-parse", "--is-inside-work-tree"] >>= flip when (collect dir)
  collect dir =
    liftA2
      (,)
      (parsePorcelain <$> gitLines dir ["status", "--porcelain"])
      (statPairs <$> gitLines dir ["diff", "--stat", "HEAD"])
      >>= recordChanged
  recordChanged (changed, stats) =
    fsChangesFor ledger incarnation (Just threadId) (Just runId) 200 Nothing
      >>= recordMissing . Set.fromList . fmap fsChangePath
   where
    recordMissing known =
      traverse_ (appendChanged stats known) changed
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
    maybe False isExitSuccess <$> timed (readProcessWithExitCode "git" ("-C" : dir : args) "")
  gitLines dir args =
    maybe [] exitOutput <$> timed (readProcessWithExitCode "git" ("-C" : dir : args) "")
  timed = timeout (timeoutSeconds * 1000000)
  isExitSuccess (ExitSuccess, _, _) = True
  isExitSuccess _ = False
  exitOutput (ExitSuccess, output, _) = Text.lines (Text.pack output)
  exitOutput _ = []

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
