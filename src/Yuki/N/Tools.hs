module Yuki.N.Tools (workTools, backgroundTools, completePaths, listTree) where

import Control.Concurrent.Async (waitCatch, withAsync)
import Control.Exception (IOException, displayException, try)
import Data.Aeson
  ( FromJSON (..),
    Result (..),
    ToJSON,
    Value,
    encode,
    fromJSON,
    object,
    withObject,
    withText,
    (.:),
    (.:?),
    (.=),
  )
import Data.Bool (bool)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>), (<&>))
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf, sort, tails)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import System.Directory
  ( canonicalizePath,
    createDirectoryIfMissing,
    doesDirectoryExist,
    getFileSize,
    getModificationTime,
    listDirectory,
    pathIsSymbolicLink,
  )
import System.Exit (ExitCode (..))
import System.FilePath
  ( addTrailingPathSeparator,
    dropTrailingPathSeparator,
    hasTrailingPathSeparator,
    isDrive,
    joinPath,
    splitDirectories,
    takeDirectory,
    takeFileName,
    (</>),
  )
import System.IO (Handle)
import System.Process
import System.Timeout (timeout)
import Yuki.N.AGUI.Event (Event (Custom))
import Yuki.N.AGUI.Types (ToolSpec (..))
import Yuki.N.Agent (BackendTool (..), ToolContext (..), ToolOutcome (..), newId)
import Yuki.N.Artifact (ArtifactStore (..), stubThreshold)
import Yuki.N.Background
  ( BackgroundRegistry,
    BackgroundSnapshot (..),
    feedBackground,
    killBackground,
    snapshotBackground,
    spawnBackground,
  )
import Yuki.N.Diff (unified)

workTools :: Maybe ArtifactStore -> FilePath -> IO [BackendTool]
workTools store root =
  (,) <$> newIORef Map.empty <*> newIORef [] <&> \(ledger, plan) ->
    [ textTool
        ( spec
            "fs_read"
            "read a file at a path relative to the work directory; offset (1-based) and limit select a line window"
            (object ["path" .= stringSchema, "offset" .= integerSchema, "limit" .= integerSchema])
            ["path"]
        )
        (runRead store ledger root),
      textTool
        ( spec
            "fs_write"
            "write a file, creating parent directories as needed"
            (object ["path" .= stringSchema, "content" .= stringSchema])
            ["path", "content"]
        )
        (runWrite store ledger root),
      textTool
        ( spec
            "fs_edit"
            "replace a unique occurrence of old text with new text; requires a prior fs_read or fs_write of the file"
            (object ["path" .= stringSchema, "old" .= stringSchema, "new" .= stringSchema])
            ["path", "old", "new"]
        )
        (runEdit store ledger root),
      textTool
        ( spec
            "fs_list"
            "list directory entries up to depth two, directories end with /"
            (object ["path" .= stringSchema])
            []
        )
        (runList root),
      textTool
        ( spec
            "fs_glob"
            "find files by glob pattern (*, **, ?), paths relative to the search root"
            (object ["pattern" .= stringSchema, "path" .= stringSchema])
            ["pattern"]
        )
        (runGlob store root),
      textTool
        ( spec
            "fs_grep"
            "search files for a literal substring, one path:line:content per match"
            (object ["pattern" .= stringSchema, "path" .= stringSchema, "include" .= stringSchema])
            ["pattern"]
        )
        (runGrep store root),
      contextTool
        ( spec
            "plan"
            "track your own progress on a longer task: set replaces the plan with pending items, update marks one item pending/doing/done, clear empties the plan"
            ( object
                [ "action" .= enumSchema ["set", "update", "clear"],
                  "items" .= arraySchema itemSchema,
                  "id" .= stringSchema,
                  "status" .= enumSchema ["pending", "doing", "done"]
                ]
            )
            ["action"]
        )
        (\context -> runPlan context plan),
      contextTool
        ( spec
            "shell"
            "run a command with sh -c in the work directory"
            (object ["command" .= stringSchema, "timeoutSeconds" .= integerSchema])
            ["command"]
        )
        (\context -> runShell context store root)
    ]

backgroundTools :: BackgroundRegistry -> FilePath -> [BackendTool]
backgroundTools registry root =
  [ contextJsonTool
      ( spec
          "shell_bg"
          "start a background command with sh -c in the work directory; returns the task id and pid"
          (object ["command" .= stringSchema])
          ["command"]
      )
      (\context -> startBackground registry (toolContextThreadId context) root),
    contextJsonTool
      ( spec
          "shell_output"
          "poll a background task for its status and buffered output tail"
          (object ["taskId" .= stringSchema, "waitSeconds" .= integerSchema])
          ["taskId"]
      )
      (\context -> pollBackgroundTask registry (toolContextThreadId context)),
    contextJsonTool
      ( spec
          "shell_stdin"
          "write text to a background task's stdin, optionally closing it"
          (object ["taskId" .= stringSchema, "text" .= stringSchema, "eof" .= boolSchema])
          ["taskId", "text"]
      )
      (\context -> feedTask registry (toolContextThreadId context)),
    contextJsonTool
      ( spec
          "shell_kill"
          "terminate a background task's process group and reap it"
          (object ["taskId" .= stringSchema])
          ["taskId"]
      )
      (\context -> killTask registry (toolContextThreadId context))
  ]

spec :: Text -> Text -> Value -> [Text] -> ToolSpec
spec name description properties required =
  ToolSpec
    name
    description
    ( object
        [ "type" .= ("object" :: Text),
          "properties" .= properties,
          "required" .= required,
          "additionalProperties" .= False
        ]
    )

stringSchema :: Value
stringSchema = object ["type" .= ("string" :: Text)]

integerSchema :: Value
integerSchema = object ["type" .= ("integer" :: Text)]

boolSchema :: Value
boolSchema = object ["type" .= ("boolean" :: Text)]

enumSchema :: [Text] -> Value
enumSchema values = object ["type" .= ("string" :: Text), "enum" .= values]

arraySchema :: Value -> Value
arraySchema items = object ["type" .= ("array" :: Text), "items" .= items]

itemSchema :: Value
itemSchema =
  object
    [ "type" .= ("object" :: Text),
      "properties" .= object ["id" .= stringSchema, "title" .= stringSchema],
      "required" .= (["id", "title"] :: [Text]),
      "additionalProperties" .= False
    ]

textTool :: (FromJSON input) => ToolSpec -> (input -> IO (Either Text Text)) -> BackendTool
textTool toolSpec execute = contextTool toolSpec (const execute)

contextTool :: (FromJSON input) => ToolSpec -> (ToolContext -> input -> IO (Either Text Text)) -> BackendTool
contextTool toolSpec execute = BackendTool toolSpec decode
 where
  decode context arguments = case fromJSON arguments of
    Error message -> pure (failure ("invalid tool arguments: " <> Text.pack message))
    Success input -> execute context input <&> either failure success

contextJsonTool :: (FromJSON input, ToJSON output) => ToolSpec -> (ToolContext -> input -> IO (Either Text output)) -> BackendTool
contextJsonTool toolSpec execute = BackendTool toolSpec decode
 where
  decode context arguments = case fromJSON arguments of
    Error message -> pure (failure ("invalid tool arguments: " <> Text.pack message))
    Success input ->
      execute context input
        <&> either failure (success . TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode)

failure :: Text -> ToolOutcome
failure content = ToolOutcome content True False

success :: Text -> ToolOutcome
success content = ToolOutcome content False False

data FsRead = FsRead FilePath (Maybe Int) (Maybe Int)

instance FromJSON FsRead where
  parseJSON = withObject "FsRead" $ \fields -> FsRead <$> fields .: "path" <*> fields .:? "offset" <*> fields .:? "limit"

data FsWrite = FsWrite FilePath Text

instance FromJSON FsWrite where
  parseJSON = withObject "FsWrite" $ \fields -> FsWrite <$> fields .: "path" <*> fields .: "content"

data FsEdit = FsEdit FilePath Text Text

instance FromJSON FsEdit where
  parseJSON = withObject "FsEdit" $ \fields -> FsEdit <$> fields .: "path" <*> fields .: "old" <*> fields .: "new"

newtype FsList = FsList (Maybe FilePath)

instance FromJSON FsList where
  parseJSON = withObject "FsList" $ \fields -> FsList <$> fields .:? "path"

data FsGlob = FsGlob Text (Maybe FilePath)

instance FromJSON FsGlob where
  parseJSON = withObject "FsGlob" $ \fields -> FsGlob <$> fields .: "pattern" <*> fields .:? "path"

data FsGrep = FsGrep Text (Maybe FilePath) (Maybe Text)

instance FromJSON FsGrep where
  parseJSON = withObject "FsGrep" $ \fields -> FsGrep <$> fields .: "pattern" <*> fields .:? "path" <*> fields .:? "include"

data ShellCall = ShellCall Text (Maybe Int)

instance FromJSON ShellCall where
  parseJSON = withObject "ShellCall" $ \fields -> ShellCall <$> fields .: "command" <*> fields .:? "timeoutSeconds"

newtype ShellBg = ShellBg Text

instance FromJSON ShellBg where
  parseJSON = withObject "ShellBg" $ \fields -> ShellBg <$> fields .: "command"

data ShellOutput = ShellOutput Text (Maybe Int)

instance FromJSON ShellOutput where
  parseJSON = withObject "ShellOutput" $ \fields -> ShellOutput <$> fields .: "taskId" <*> fields .:? "waitSeconds"

data ShellStdin = ShellStdin Text Text Bool

instance FromJSON ShellStdin where
  parseJSON =
    withObject "ShellStdin" $ \fields ->
      ShellStdin <$> fields .: "taskId" <*> fields .: "text" <*> (fromMaybe False <$> fields .:? "eof")

newtype ShellKill = ShellKill Text

instance FromJSON ShellKill where
  parseJSON = withObject "ShellKill" $ \fields -> ShellKill <$> fields .: "taskId"

data PlanCall
  = PlanSet [PlanSeed]
  | PlanUpdate Text PlanStatus
  | PlanClear

instance FromJSON PlanCall where
  parseJSON = withObject "PlanCall" $ \fields ->
    fields .: "action" >>= \case
      "set" -> PlanSet <$> fields .: "items"
      "update" -> PlanUpdate <$> fields .: "id" <*> fields .: "status"
      "clear" -> pure PlanClear
      other -> fail ("unknown plan action: " <> Text.unpack other)

data PlanSeed = PlanSeed Text Text

instance FromJSON PlanSeed where
  parseJSON = withObject "PlanSeed" $ \fields -> PlanSeed <$> fields .: "id" <*> fields .: "title"

data PlanStatus = Pending | Doing | Done

instance FromJSON PlanStatus where
  parseJSON = withText "PlanStatus" $ \case
    "pending" -> pure Pending
    "doing" -> pure Doing
    "done" -> pure Done
    other -> fail ("unknown plan status: " <> Text.unpack other)

data PlanItem = PlanItem
  { planId :: Text,
    planTitle :: Text,
    planStatus :: PlanStatus
  }

runRead :: Maybe ArtifactStore -> Ledger -> FilePath -> FsRead -> IO (Either Text Text)
runRead store ledger root (FsRead path offset limit) =
  resolvePath root path >>=? readTarget
 where
  readTarget target =
    (try (TextIO.readFile target) :: IO (Either IOException Text)) >>= \case
      Left err -> pure (Left (describe err))
      Right content ->
        remember ledger target
          *> either (pure . Left) (fmap Right . presentRead store (Text.take 200)) (selected content)
  selected content
    | isJust offset || isJust limit = paginate path offset limit content
    | otherwise = Right content
  describe = (prefix <>) . Text.pack . displayException
  prefix = "cannot read " <> Text.pack path <> ": "

paginate :: FilePath -> Maybe Int -> Maybe Int -> Text -> Either Text Text
paginate path offset limit content
  | begin > total = Left ("offset " <> int begin <> " exceeds " <> Text.pack path <> " line count " <> int total)
  | otherwise = Right (Text.intercalate "\n" window <> "\n(lines " <> int begin <> "-" <> int end <> " of " <> int total <> ")")
 where
  ls = Text.lines content
  total = length ls
  begin = max 1 (fromMaybe 1 offset)
  count = max 1 (fromMaybe (total - begin + 1) limit)
  window = take count (drop (begin - 1) ls)
  end = begin + length window - 1

runWrite :: Maybe ArtifactStore -> Ledger -> FilePath -> FsWrite -> IO (Either Text Text)
runWrite store ledger root (FsWrite path content) =
  resolvePath root path >>=? write
 where
  write target =
    readMaybe target >>= \old ->
      createDirectoryIfMissing True (takeDirectory target)
        *> TextIO.writeFile target content
        *> stash store "fs_write" content
        *> remember ledger target
        $> Right (unified path (fromMaybe "" old) content)

runEdit :: Maybe ArtifactStore -> Ledger -> FilePath -> FsEdit -> IO (Either Text Text)
runEdit store ledger root (FsEdit path old new)
  | Text.null old = pure (Left "old must not be empty")
  | otherwise = resolvePath root path >>=? edit
 where
  edit target =
    readIORef ledger >>= \known ->
      stamp target >>= \current ->
        case Map.lookup target known of
          Nothing -> pure (Left "read the file before editing")
          Just recorded
            | current /= Just recorded -> pure (Left "file changed since last read; re-read it")
            | otherwise -> replace
   where
    replace =
      readMaybe target >>= maybe (pure (Left ("cannot read " <> Text.pack path))) cut
     where
      cut content = case Text.count old content of
        0 -> pure (Left ("old text not found in " <> Text.pack path))
        1 ->
          TextIO.writeFile target updated
            *> stash store "fs_edit" updated
            *> remember ledger target
            $> Right (unified path content updated)
         where
          updated = Text.replace old new content
        n -> pure (Left ("old text occurs " <> int n <> " times in " <> Text.pack path <> "; provide more context"))

type Ledger = IORef (Map.Map FilePath (Integer, Integer))

remember :: Ledger -> FilePath -> IO ()
remember ledger target = stamp target >>= traverse_ (modifyIORef' ledger . Map.insert target)

stamp :: FilePath -> IO (Maybe (Integer, Integer))
stamp target = either (const Nothing) Just <$> (try snap :: IO (Either IOException (Integer, Integer)))
 where
  snap = ((,) . round . utcTimeToPOSIXSeconds <$> getModificationTime target) <*> getFileSize target

runList :: FilePath -> FsList -> IO (Either Text Text)
runList root (FsList path) =
  pathContainsSymlink root relative
    >>= bool (resolvePath root relative >>=? list) (pure (Left "refusing to list through a symbolic link"))
 where
  relative = fromMaybe "." path
  list target =
    doesDirectoryExist target
      >>= bool (pure (Left ("not a directory: " <> Text.pack relative))) (Right <$> listing target)

pathContainsSymlink :: FilePath -> FilePath -> IO Bool
pathContainsSymlink root = go root . filter relevant . splitDirectories
 where
  relevant part = part /= "." && part /= ""
  go _ [] = pure False
  go parent (part : rest) =
    let current = parent </> part
     in (try (pathIsSymbolicLink current) :: IO (Either IOException Bool))
          >>= either (const (pure False)) (bool (go current rest) (pure True))

listing :: FilePath -> IO Text
listing target = Text.intercalate "\n" <$> listTree target 2

listTree :: FilePath -> Int -> IO [Text]
listTree target depth =
  listDirectory target
    >>= ( \entries ->
            (<> note (length entries)) . concat
              <$> traverse (entry target depth) (take listingLimit entries)
        )
      . sort
 where
  note total = ["... " <> int (total - listingLimit) <> " more entries" | total > listingLimit]

completePaths :: FilePath -> Text -> IO [Text]
completePaths root raw
  | Text.any (`elem` ['\0', '\n', '\r']) raw = pure []
  | otherwise =
      pathContainsSymlink root directory
        >>= bool suggestions (pure [])
 where
  query = Text.unpack raw
  trailing = hasTrailingPathSeparator query
  directory
    | trailing = query
    | otherwise = takeDirectory query
  prefixName
    | trailing = ""
    | otherwise = takeFileName query
  renderedPrefix
    | directory == "." || null directory = ""
    | otherwise = addTrailingPathSeparator directory
  suggestions =
    resolvePath root directory >>= \case
      Left _ -> pure []
      Right base ->
        doesDirectoryExist base >>= bool (pure []) (entries base)
  entries base =
    (try (sort <$> listDirectory base) :: IO (Either IOException [FilePath]))
      >>= either (const (pure [])) (fmap (take 40 . concat) . traverse (candidate base) . filter (prefixName `isPrefixOf`))
  candidate base name =
    pathIsSymbolicLink (base </> name) >>= bool plain (pure [])
   where
    plain =
      doesDirectoryExist (base </> name)
        <&> \isDirectory ->
          [Text.pack (renderedPrefix <> name <> [pathSeparator | isDirectory])]
    pathSeparator = '/'

listingLimit :: Int
listingLimit = 100

entry :: FilePath -> Int -> FilePath -> IO [Text]
entry dir depth name =
  pathIsSymbolicLink full >>= bool classify (pure [packed <> "@"])
 where
  full = dir </> name
  packed = Text.pack name
  classify = doesDirectoryExist full >>= bool (pure [packed]) expand
  expand
    | isNoiseDirectory name = pure [packed <> "/"]
    | depth <= 1 = pure [packed <> "/"]
    | otherwise =
        listDirectory full
          >>= (fmap (concatMap (fmap ("  " <>))) . traverse (entry full (depth - 1)))
            . sort
          <&> (packed <> "/" :)

isNoiseDirectory :: FilePath -> Bool
isNoiseDirectory name =
  name `elem` [".git", ".hg", ".svn", "node_modules", "dist", "dist-newstyle", ".yuki-n", "elm-stuff", ".elm-home"]

runGlob :: Maybe ArtifactStore -> FilePath -> FsGlob -> IO (Either Text Text)
runGlob store root (FsGlob globPattern path) =
  withSearchRoot root path $ \target ->
    walkFiles target >>= present store "fs_glob" (clipLines matchLimit) . render . sort . filter matches
 where
  matches = matchPath (Text.splitOn "/" globPattern) . Text.splitOn "/" . Text.pack
  render hits = Text.intercalate "\n" (fmap Text.pack (take matchLimit hits) <> overflow)
   where
    overflow = ["... " <> int (length hits - matchLimit) <> " more" | length hits > matchLimit]

runGrep :: Maybe ArtifactStore -> FilePath -> FsGrep -> IO (Either Text Text)
runGrep store root (FsGrep needle path include)
  | Text.null needle = pure (Left "pattern must not be empty")
  | otherwise =
      withSearchRoot root path $ \target ->
        walkFiles target
          >>= fmap (take matchLimit . concat) . traverse (grepFile needle target) . filter wanted
          >>= present store "fs_grep" (clipLines matchLimit) . Text.intercalate "\n"
 where
  wanted file = maybe True (`matchSegment` Text.pack (takeFileName file)) include

withSearchRoot :: FilePath -> Maybe FilePath -> (FilePath -> IO Text) -> IO (Either Text Text)
withSearchRoot root path action =
  resolvePath root relative >>=? search
 where
  relative = fromMaybe "." path
  search target =
    doesDirectoryExist target
      >>= bool (pure (Left ("not a directory: " <> Text.pack relative))) (Right <$> action target)

walkFiles :: FilePath -> IO [FilePath]
walkFiles root = go ""
 where
  go dir =
    listDirectory (root </> dir)
      >>= (fmap concat . traverse (visit dir)) . sort
  visit dir name =
    pathIsSymbolicLink (root </> relative)
      >>= bool
        (doesDirectoryExist (root </> relative) >>= bool (pure [relative]) descend)
        (pure [])
   where
    relative = dir </> name
    descend
      | skippedDir name = pure []
      | otherwise = go relative

skippedDir :: FilePath -> Bool
skippedDir name = "." `isPrefixOf` name || name `elem` ["dist-newstyle", "node_modules", "dist", "elm-stuff"]

grepFile :: Text -> FilePath -> FilePath -> IO [Text]
grepFile needle root relative =
  getFileSize absolute >>= scan
 where
  absolute = root </> relative
  scan size
    | size > fileLimit = pure [Text.pack relative <> ": file exceeds 1MB, skipped"]
    | otherwise =
        (try (TextIO.readFile absolute) :: IO (Either IOException Text))
          >>= either (const (pure [])) (pure . hits)
  hits content
    | "\NUL" `Text.isInfixOf` content = []
    | otherwise =
        [ Text.pack relative <> ":" <> int n <> ":" <> line
        | (n, line) <- zip [1 ..] (Text.lines content),
          needle `Text.isInfixOf` line
        ]

matchPath :: [Text] -> [Text] -> Bool
matchPath ("**" : rest) segs = any (matchPath rest) (tails segs)
matchPath (pat : rest) (seg : segs) = matchSegment pat seg && matchPath rest segs
matchPath [] [] = True
matchPath _ _ = False

matchSegment :: Text -> Text -> Bool
matchSegment pattern segment
  | Just ('*', rest) <- parts = any (matchSegment rest) (Text.tails segment)
  | Just ('?', rest) <- parts = maybe False (matchSegment rest . snd) piece
  | Just (c, rest) <- parts = maybe False (\(s, ss) -> c == s && matchSegment rest ss) piece
  | otherwise = Text.null segment
 where
  parts = Text.uncons pattern
  piece = Text.uncons segment

clipLines :: Int -> Text -> Text
clipLines count content
  | length ls <= 2 * count = content
  | otherwise = Text.intercalate "\n" (take count ls) <> "\n...\n" <> Text.intercalate "\n" (drop (length ls - count) ls)
 where
  ls = Text.lines content

matchLimit :: Int
matchLimit = 200

fileLimit :: Integer
fileLimit = 1024 * 1024

runShell :: ToolContext -> Maybe ArtifactStore -> FilePath -> ShellCall -> IO (Either Text Text)
runShell context store root (ShellCall command timeoutSeconds) =
  runShellCommand (streamChunk context) root (clamp timeoutSeconds) (Text.unpack command)
    >>= fmap Right . present store "shell" clip
 where
  clip content = Text.take 200 content <> "\n...\n" <> Text.takeEnd 200 content

streamChunk :: ToolContext -> Text -> Text -> IO ()
streamChunk context stream delta =
  toolContextEmit
    context
    ( Custom
        "shell.output"
        ( object
            [ "callId" .= toolContextCallId context,
              "stream" .= stream,
              "delta" .= delta
            ]
        )
    )

runPlan :: ToolContext -> IORef [PlanItem] -> PlanCall -> IO (Either Text Text)
runPlan context plan call =
  atomicModifyIORef' plan (apply call) >>= traverse announce
 where
  announce items =
    toolContextEmit context (Custom "plan" (planValue items)) $> renderPlan items

apply :: PlanCall -> [PlanItem] -> ([PlanItem], Either Text [PlanItem])
apply (PlanSet seeds) _ = changed [PlanItem identifier title Pending | PlanSeed identifier title <- seeds]
apply PlanClear _ = changed []
apply (PlanUpdate wanted status) items
  | any ((== wanted) . planId) items = changed (fmap step items)
  | otherwise = (items, Left ("unknown plan item: " <> wanted))
 where
  step item = bool item item {planStatus = status} (planId item == wanted)

changed :: [PlanItem] -> ([PlanItem], Either Text [PlanItem])
changed items = (items, Right items)

renderPlan :: [PlanItem] -> Text
renderPlan [] = "(empty plan)"
renderPlan items = Text.intercalate "\n" (fmap line items)
 where
  line item = planId item <> ". [" <> marker (planStatus item) <> "] " <> planTitle item

marker :: PlanStatus -> Text
marker Pending = " "
marker status = statusName status

planValue :: [PlanItem] -> Value
planValue items = object ["items" .= fmap itemValue items]
 where
  itemValue item =
    object
      [ "id" .= planId item,
        "title" .= planTitle item,
        "status" .= statusName (planStatus item)
      ]

statusName :: PlanStatus -> Text
statusName Pending = "pending"
statusName Doing = "doing"
statusName Done = "done"

startBackground :: BackgroundRegistry -> Text -> FilePath -> ShellBg -> IO (Either Text Value)
startBackground registry threadId root (ShellBg command) =
  newId >>= \taskId ->
    spawnBackground registry threadId taskId root (Text.unpack command)
      <&> maybe (Left "failed to start background task") (\pid -> Right (object ["taskId" .= taskId, "pid" .= pid]))

pollBackgroundTask :: BackgroundRegistry -> Text -> ShellOutput -> IO (Either Text Value)
pollBackgroundTask registry threadId (ShellOutput taskId waitSeconds) =
  snapshotBackground registry threadId taskId (clampWait <$> waitSeconds) <&> fmap render
 where
  clampWait = max 0 . min 30
  render (BackgroundSnapshot running exitCode output truncated) =
    object
      ( [ "taskId" .= taskId,
          "running" .= running,
          "output" .= output,
          "truncated" .= truncated
        ]
          <> ["exitCode" .= code | Just code <- [exitCode]]
      )

feedTask :: BackgroundRegistry -> Text -> ShellStdin -> IO (Either Text Value)
feedTask registry threadId (ShellStdin taskId text eof) =
  feedBackground registry threadId taskId text eof
    <&> fmap (\open -> object ["taskId" .= taskId, "stdinOpen" .= open])

killTask :: BackgroundRegistry -> Text -> ShellKill -> IO (Either Text Value)
killTask registry threadId (ShellKill taskId) =
  killBackground registry threadId taskId
    <&> fmap (\confirmed -> object ["taskId" .= taskId, "killed" .= confirmed])

clamp :: Maybe Int -> Int
clamp = maybe 30 (max 1 . min 120)

runShellCommand :: (Text -> Text -> IO ()) -> FilePath -> Int -> String -> IO Text
runShellCommand announce root seconds command =
  createProcess sh >>= \case
    setup@(Nothing, Just out, Just err, process) ->
      newIORef "" >>= \outAcc ->
        newIORef "" >>= \errAcc ->
          withAsync (pump (announce "stdout") out outAcc) $ \outAsync ->
            withAsync (pump (announce "stderr") err errAcc) $ \errAsync ->
              raceTimeout (seconds * 1000000) (waitForProcess process)
                >>= \code ->
                  interruptProcessGroupOf process
                    *> (waitCatch outAsync *> waitCatch errAsync)
                    *> cleanupProcess setup
                    *> (renderShell <$> ((<>) <$> readIORef outAcc <*> readIORef errAcc) <*> pure code)
    setup -> cleanupProcess setup $> renderShell "" (Just 127)
 where
  sh =
    (shell command)
      { cwd = Just root,
        std_out = CreatePipe,
        std_err = CreatePipe,
        create_group = True
      }

pump :: (Text -> IO ()) -> Handle -> IORef Text -> IO ()
pump announce handle sink = loop
 where
  loop =
    TextIO.hGetChunk handle >>= \chunk ->
      bool (announce chunk *> modifyIORef' sink (<> chunk) *> loop) (pure ()) (Text.null chunk)

raceTimeout :: Int -> IO ExitCode -> IO (Maybe Int)
raceTimeout micros action =
  timeout micros action <&> \case
    Nothing -> Nothing
    Just (ExitFailure code) -> Just code
    Just ExitSuccess -> Just 0

renderShell :: Text -> Maybe Int -> Text
renderShell output Nothing =
  "exit timeout\n" <> lined output <> "hint: use shell_bg for long-running tasks, then shell_output to poll\n"
 where
  lined text
    | Text.null text || Text.isSuffixOf "\n" text = text
    | otherwise = text <> "\n"
renderShell output (Just code) = "exit " <> int code <> "\n" <> output

resolvePath :: FilePath -> FilePath -> IO (Either Text FilePath)
resolvePath root path =
  canonicalizeLenient root >>= \canonicalRoot ->
    inside canonicalRoot . squeezeDotDot <$> canonicalizeLenient (canonicalRoot </> path)
 where
  inside canonicalRoot canonical
    | canonical == canonicalRoot || prefix canonicalRoot `isPrefixOf` canonical = Right canonical
    | otherwise = Left "path escapes the work directory"
  prefix = addTrailingPathSeparator

squeezeDotDot :: FilePath -> FilePath
squeezeDotDot = joinPath . foldl step [] . splitDirectories
 where
  step parts part
    | name == "." = parts
    | name /= ".." = parts <> [part]
    | otherwise = pop parts
   where
    name = dropTrailingPathSeparator part
  pop [] = [".."]
  pop parts@[root] | isDrive root = parts
  pop parts = init parts

canonicalizeLenient :: FilePath -> IO FilePath
canonicalizeLenient path =
  (try (canonicalizePath path) :: IO (Either IOException FilePath)) >>= \case
    Right canonical -> pure canonical
    Left _
      | parent == path -> pure path
      | otherwise -> (</> takeFileName path) <$> canonicalizeLenient parent
 where
  parent = takeDirectory path

readMaybe :: FilePath -> IO (Maybe Text)
readMaybe path = either (const Nothing) Just <$> (try (TextIO.readFile path) :: IO (Either IOException Text))

stash :: Maybe ArtifactStore -> Text -> Text -> IO ()
stash store name content =
  bool (pure ()) (traverse_ (\s -> artifactSave s name content) store) (Text.length content >= stubThreshold)

present :: Maybe ArtifactStore -> Text -> (Text -> Text) -> Text -> IO Text
present store name clip content
  | Text.length content < stubThreshold = pure content
  | otherwise = maybe (pure content) (\s -> guided <$> artifactSave s name content) store
 where
  guided identifier =
    clip content
      <> "\n[artifact "
      <> identifier
      <> ": full "
      <> name
      <> " output, "
      <> int (Text.length content)
      <> " chars; call artifact_read with id \""
      <> identifier
      <> "\" for the complete text]"

presentRead :: Maybe ArtifactStore -> (Text -> Text) -> Text -> IO Text
presentRead store clip content
  | Text.length content <= readResultThreshold = pure content
  | otherwise = present store "fs_read" clip content

readResultThreshold :: Int
readResultThreshold = 16 * 1024

int :: Int -> Text
int = Text.pack . show

infixl 1 >>=?

(>>=?) :: IO (Either Text a) -> (a -> IO (Either Text b)) -> IO (Either Text b)
action >>=? next = action >>= either (pure . Left) next
