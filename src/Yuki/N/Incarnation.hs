module Yuki.N.Incarnation
  ( Incarnation (..),
    IncarnationStatus (..),
    IncarnationStore (..),
    PromptLayer (..),
    PromptRevision (..),
    PromptStatus (..),
    defaultIncarnation,
    freshIncarnationId,
    newIncarnationStore,
    newMemoryIncarnationStore,
    slugIncarnation,
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
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import Yuki.N.AtomicFile (atomicEncodeFile)
import Yuki.N.Blob (sha256)

data IncarnationStatus = IncarnationActive | IncarnationArchived
  deriving stock (Eq, Show)

instance ToJSON IncarnationStatus where
  toJSON IncarnationActive = String "active"
  toJSON IncarnationArchived = String "archived"

instance FromJSON IncarnationStatus where
  parseJSON = withText "IncarnationStatus" $ \case
    "active" -> pure IncarnationActive
    "archived" -> pure IncarnationArchived
    value -> fail ("unknown incarnation status: " <> Text.unpack value)

data Incarnation = Incarnation
  { incarnationId :: Text,
    incarnationName :: Text,
    incarnationDirection :: Text,
    incarnationPromptRevision :: Maybe Text,
    incarnationImpressionModel :: Maybe Text,
    incarnationRevision :: Int,
    incarnationStatus :: IncarnationStatus,
    incarnationCreated :: Integer,
    incarnationUpdated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON Incarnation where
  toJSON incarnation =
    object
      [ "id" .= incarnationId incarnation,
        "name" .= incarnationName incarnation,
        "direction" .= incarnationDirection incarnation,
        "promptRevision" .= incarnationPromptRevision incarnation,
        "impressionModel" .= incarnationImpressionModel incarnation,
        "revision" .= incarnationRevision incarnation,
        "status" .= incarnationStatus incarnation,
        "created" .= incarnationCreated incarnation,
        "updated" .= incarnationUpdated incarnation
      ]

instance FromJSON Incarnation where
  parseJSON = withObject "Incarnation" $ \fields ->
    Incarnation
      <$> fields .: "id"
      <*> fields .: "name"
      <*> fields .: "direction"
      <*> fields .:? "promptRevision"
      <*> fields .:? "impressionModel"
      <*> fields .:? "revision" .!= 1
      <*> fields .:? "status" .!= IncarnationActive
      <*> fields .: "created"
      <*> fields .: "updated"

data PromptLayer
  = RootConstitution
  | IncarnationCharter
  deriving stock (Eq, Show)

instance ToJSON PromptLayer where
  toJSON =
    String . \case
      RootConstitution -> "root"
      IncarnationCharter -> "charter"

instance FromJSON PromptLayer where
  parseJSON = withText "PromptLayer" $ \case
    "root" -> pure RootConstitution
    "charter" -> pure IncarnationCharter
    value -> fail ("unknown prompt layer: " <> Text.unpack value)

data PromptStatus = PromptDraft | PromptActive | PromptRetired
  deriving stock (Eq, Show)

instance ToJSON PromptStatus where
  toJSON =
    String . \case
      PromptDraft -> "draft"
      PromptActive -> "active"
      PromptRetired -> "retired"

instance FromJSON PromptStatus where
  parseJSON = withText "PromptStatus" $ \case
    "draft" -> pure PromptDraft
    "active" -> pure PromptActive
    "retired" -> pure PromptRetired
    value -> fail ("unknown prompt status: " <> Text.unpack value)

data PromptRevision = PromptRevision
  { promptRevisionId :: Text,
    promptIncarnationId :: Maybe Text,
    promptLayer :: PromptLayer,
    promptSourceIntent :: Text,
    promptContent :: Text,
    promptGeneratorRevision :: Text,
    promptModelInvocationRef :: Maybe Text,
    promptParentRevision :: Maybe Text,
    promptOrdinal :: Int,
    promptStatus :: PromptStatus,
    promptEffectiveHash :: Text,
    promptCreated :: Integer
  }
  deriving stock (Eq, Show)

instance ToJSON PromptRevision where
  toJSON prompt =
    object
      [ "id" .= promptRevisionId prompt,
        "incarnationId" .= promptIncarnationId prompt,
        "layer" .= promptLayer prompt,
        "sourceIntent" .= promptSourceIntent prompt,
        "content" .= promptContent prompt,
        "generatorRevision" .= promptGeneratorRevision prompt,
        "modelInvocationRef" .= promptModelInvocationRef prompt,
        "parentRevision" .= promptParentRevision prompt,
        "ordinal" .= promptOrdinal prompt,
        "status" .= promptStatus prompt,
        "effectiveHash" .= promptEffectiveHash prompt,
        "created" .= promptCreated prompt
      ]

instance FromJSON PromptRevision where
  parseJSON = withObject "PromptRevision" $ \fields ->
    PromptRevision
      <$> fields .: "id"
      <*> fields .:? "incarnationId"
      <*> fields .: "layer"
      <*> fields .: "sourceIntent"
      <*> fields .: "content"
      <*> fields .: "generatorRevision"
      <*> fields .:? "modelInvocationRef"
      <*> fields .:? "parentRevision"
      <*> fields .:? "ordinal" .!= 1
      <*> fields .:? "status" .!= PromptDraft
      <*> fields .: "effectiveHash"
      <*> fields .: "created"

data IncarnationStore = IncarnationStore
  { incarnationList :: IO [Incarnation],
    incarnationRead :: Text -> IO (Maybe Incarnation),
    incarnationCreate :: Text -> Text -> Text -> Maybe Text -> IO (Either Text Incarnation),
    incarnationUpdate :: Text -> Int -> Text -> Text -> Maybe Text -> IO (Either Text Incarnation),
    incarnationArchive :: Text -> Int -> IO (Either Text Incarnation),
    incarnationRestore :: Text -> Int -> IO (Either Text Incarnation),
    incarnationDelete :: Text -> Int -> IO (Either Text Incarnation),
    promptAppend :: Maybe Text -> PromptLayer -> Text -> Text -> Text -> Maybe Text -> Maybe Text -> PromptStatus -> IO PromptRevision,
    promptRead :: Text -> IO (Maybe PromptRevision),
    promptList :: Maybe Text -> IO [PromptRevision],
    promptActivate :: Text -> Int -> Text -> IO (Either Text Incarnation),
    promptActivateRoot :: Int -> Text -> IO (Either Text PromptRevision)
  }

data IncarnationState = IncarnationState
  { stateIncarnations :: Map Text Incarnation,
    statePrompts :: Map Text PromptRevision
  }

instance ToJSON IncarnationState where
  toJSON state =
    object
      [ "incarnations" .= stateIncarnations state,
        "prompts" .= statePrompts state
      ]

instance FromJSON IncarnationState where
  parseJSON = withObject "IncarnationState" $ \fields ->
    IncarnationState
      <$> fields .:? "incarnations" .!= Map.empty
      <*> fields .:? "prompts" .!= Map.empty

emptyState :: IncarnationState
emptyState = IncarnationState Map.empty Map.empty

defaultIncarnation :: Integer -> Incarnation
defaultIncarnation now =
  Incarnation
    { incarnationId = "yuki",
      incarnationName = "Yuki",
      incarnationDirection = "面向通用个人工作的 YUKI；保持清醒、主动使用能力，并让长期连续性来自记忆而非 transcript。",
      incarnationPromptRevision = Nothing,
      incarnationImpressionModel = Nothing,
      incarnationRevision = 1,
      incarnationStatus = IncarnationActive,
      incarnationCreated = now,
      incarnationUpdated = now
    }

newIncarnationStore :: FilePath -> IO (Either Text IncarnationStore)
newIncarnationStore dir =
  createDirectoryIfMissing True dir
    *> loadState (statePath dir)
    >>= traverse (initialize (atomicEncodeFile (statePath dir)))

newMemoryIncarnationStore :: IO IncarnationStore
newMemoryIncarnationStore = initialize (const (pure ())) emptyState

initialize :: (IncarnationState -> IO ()) -> IncarnationState -> IO IncarnationStore
initialize persist initial =
  getPOSIXTime >>= \now ->
    let seeded =
          bool
            initial
            initial {stateIncarnations = Map.singleton "yuki" (defaultIncarnation (round now))}
            (Map.null (stateIncarnations initial))
     in persist seeded *> newMVar seeded <&> mkStore persist

mkStore :: (IncarnationState -> IO ()) -> MVar IncarnationState -> IncarnationStore
mkStore persist lock =
  IncarnationStore
    { incarnationList = Map.elems . stateIncarnations <$> readMVar lock,
      incarnationRead = \identifier -> Map.lookup identifier . stateIncarnations <$> readMVar lock,
      incarnationCreate = create,
      incarnationUpdate = update,
      incarnationArchive = archive,
      incarnationRestore = restore,
      incarnationDelete = delete,
      promptAppend = appendPrompt,
      promptRead = \identifier -> Map.lookup identifier . statePrompts <$> readMVar lock,
      promptList = \owner ->
        sortOn promptOrdinal
          . filter ((== owner) . promptIncarnationId)
          . Map.elems
          . statePrompts
          <$> readMVar lock,
      promptActivate = activate,
      promptActivateRoot = activateRoot
    }
 where
  create identifier name direction model
    | not (validId identifier) = pure (Left "invalid incarnation id")
    | Text.null (Text.strip name) = pure (Left "incarnation name must not be empty")
    | Text.null (Text.strip direction) = pure (Left "incarnation direction must not be empty")
    | otherwise =
        getPOSIXTime >>= \now ->
          modifyMVar lock $ \state ->
            case Map.lookup identifier (stateIncarnations state) of
              Just _ -> pure (state, Left ("incarnation already exists: " <> identifier))
              Nothing ->
                let stamp = round now
                    incarnation =
                      Incarnation identifier (Text.take 80 (Text.strip name)) (Text.strip direction) Nothing model 1 IncarnationActive stamp stamp
                    changed = state {stateIncarnations = Map.insert identifier incarnation (stateIncarnations state)}
                 in persist changed $> (changed, Right incarnation)
  update identifier expected name direction model
    | Text.null (Text.strip name) = pure (Left "incarnation name must not be empty")
    | Text.null (Text.strip direction) = pure (Left "incarnation direction must not be empty")
    | otherwise =
        mutate identifier expected requireActive $ \now incarnation ->
          incarnation
            { incarnationName = Text.take 80 (Text.strip name),
              incarnationDirection = Text.strip direction,
              incarnationImpressionModel = model,
              incarnationRevision = expected + 1,
              incarnationUpdated = now
            }
  archive "yuki" _ = pure (Left "default incarnation yuki cannot be archived")
  archive identifier expected =
    mutate identifier expected requireActive $ \now incarnation ->
      incarnation
        { incarnationStatus = IncarnationArchived,
          incarnationRevision = expected + 1,
          incarnationUpdated = now
        }
  restore identifier expected =
    mutate identifier expected requireArchived $ \now incarnation ->
      incarnation
        { incarnationStatus = IncarnationActive,
          incarnationRevision = expected + 1,
          incarnationUpdated = now
        }
  delete "yuki" _ = pure (Left "default incarnation yuki cannot be deleted")
  delete identifier expected =
    modifyMVar lock $ \state ->
      case Map.lookup identifier (stateIncarnations state) of
        Nothing -> pure (state, Left ("unknown incarnation: " <> identifier))
        Just incarnation
          | incarnationRevision incarnation /= expected ->
              pure (state, Left (stale expected (incarnationRevision incarnation)))
          | incarnationStatus incarnation /= IncarnationArchived ->
              pure (state, Left ("incarnation is not archived: " <> identifier))
          | otherwise ->
              let kept = filter ((/= Just identifier) . promptIncarnationId) (Map.elems (statePrompts state))
                  changed =
                    state
                      { stateIncarnations = Map.delete identifier (stateIncarnations state),
                        statePrompts = Map.fromList [(promptRevisionId prompt, prompt) | prompt <- kept]
                      }
               in persist changed $> (changed, Right incarnation)
  mutate identifier expected allowed change =
    getPOSIXTime >>= \now ->
      modifyMVar lock $ \state ->
        case Map.lookup identifier (stateIncarnations state) of
          Nothing -> pure (state, Left ("unknown incarnation: " <> identifier))
          Just incarnation
            | incarnationRevision incarnation /= expected ->
                pure (state, Left (stale expected (incarnationRevision incarnation)))
            | Just failure <- allowed incarnation ->
                pure (state, Left failure)
            | otherwise ->
                let changedIncarnation = change (round now) incarnation
                    changed = state {stateIncarnations = Map.insert identifier changedIncarnation (stateIncarnations state)}
                 in persist changed $> (changed, Right changedIncarnation)
  appendPrompt owner layer source content generator invocation parent status =
    getPOSIXTime >>= \now ->
      modifyMVar lock $ \state ->
        let related =
              filter
                (\candidate -> promptIncarnationId candidate == owner && promptLayer candidate == layer)
                (Map.elems (statePrompts state))
            ordinal = maximum (0 : fmap promptOrdinal related) + 1
            digest = sha256 (TextEncoding.encodeUtf8 (Text.intercalate "\NUL" [fromMaybe "root" owner, Text.pack (show layer), Text.pack (show ordinal), content]))
            identifier = "prompt-" <> Text.take 24 digest
            prompt =
              PromptRevision identifier owner layer source content generator invocation parent ordinal status digest (round now)
            changed = state {statePrompts = Map.insert identifier prompt (statePrompts state)}
         in persist changed $> (changed, prompt)
  activate incarnationId' expected promptId =
    modifyMVar lock $ \state ->
      case (Map.lookup incarnationId' (stateIncarnations state), Map.lookup promptId (statePrompts state)) of
        (Nothing, _) -> pure (state, Left ("unknown incarnation: " <> incarnationId'))
        (_, Nothing) -> pure (state, Left ("unknown prompt revision: " <> promptId))
        (Just incarnation, Just prompt)
          | incarnationRevision incarnation /= expected ->
              pure (state, Left (stale expected (incarnationRevision incarnation)))
          | incarnationStatus incarnation /= IncarnationActive ->
              pure (state, Left ("incarnation is archived: " <> incarnationId'))
          | promptIncarnationId prompt /= Just incarnationId' ->
              pure (state, Left "prompt revision belongs to another incarnation")
          | otherwise ->
              getPOSIXTime >>= \now ->
                let activated = incarnation {incarnationPromptRevision = Just promptId, incarnationRevision = expected + 1, incarnationUpdated = round now}
                    prompts =
                      Map.map
                        ( \candidate ->
                            if promptIncarnationId candidate == Just incarnationId' && promptLayer candidate == promptLayer prompt
                              then candidate {promptStatus = bool PromptRetired PromptActive (promptRevisionId candidate == promptId)}
                              else candidate
                        )
                        (statePrompts state)
                    changed =
                      state
                        { stateIncarnations = Map.insert incarnationId' activated (stateIncarnations state),
                          statePrompts = prompts
                        }
                 in persist changed $> (changed, Right activated)
  activateRoot expected promptId =
    modifyMVar lock $ \state ->
      let roots =
            filter
              ( (&&)
                  <$> ((== Nothing) . promptIncarnationId)
                  <*> ((== RootConstitution) . promptLayer)
              )
              (Map.elems (statePrompts state))
          active =
            listToMaybe
              . reverse
              . sortOn promptOrdinal
              . filter ((== PromptActive) . promptStatus)
              $ roots
          actual = maybe 0 promptOrdinal active
       in case Map.lookup promptId (statePrompts state) of
            Nothing -> pure (state, Left ("unknown prompt revision: " <> promptId))
            Just prompt
              | actual /= expected ->
                  pure
                    ( state,
                      Left
                        ( "stale root prompt ordinal: expected "
                            <> Text.pack (show expected)
                            <> ", actual "
                            <> Text.pack (show actual)
                        )
                    )
              | isJust (promptIncarnationId prompt) ->
                  pure (state, Left "prompt revision belongs to an incarnation")
              | promptLayer prompt /= RootConstitution ->
                  pure (state, Left "prompt revision is not a Root Constitution")
              | otherwise ->
                  let prompts =
                        Map.map
                          ( \candidate ->
                              if isNothing (promptIncarnationId candidate) && promptLayer candidate == RootConstitution
                                then candidate {promptStatus = bool PromptRetired PromptActive (promptRevisionId candidate == promptId)}
                                else candidate
                          )
                          (statePrompts state)
                      activated = fromMaybe prompt (Map.lookup promptId prompts)
                      changed = state {statePrompts = prompts}
                   in persist changed $> (changed, Right activated)
  requireActive incarnation
    | incarnationStatus incarnation == IncarnationActive = Nothing
    | otherwise = Just ("incarnation is already archived: " <> incarnationId incarnation)
  requireArchived incarnation
    | incarnationStatus incarnation == IncarnationArchived = Nothing
    | otherwise = Just ("incarnation is already active: " <> incarnationId incarnation)

validId :: Text -> Bool
validId identifier =
  not (Text.null identifier)
    && Text.length identifier <= 80
    && Text.all (\character -> character == '-' || character == '_' || character == '.' || asciiAlphaNum character) identifier
 where
  asciiAlphaNum character =
    isAsciiLower character
      || isAsciiUpper character
      || isDigit character

slugIncarnation :: Text -> Text
slugIncarnation name =
  bool slug ("yuki-" <> Text.pack (show (abs (hashName name)))) (Text.null slug)
 where
  slug =
    Text.take 80
      . Text.intercalate "-"
      . filter (not . Text.null)
      . Text.split (== '-')
      . Text.map (\character -> bool '-' character (asciiAlphaNum character))
      . Text.toLower
      $ name
  asciiAlphaNum character = isAsciiLower character || isDigit character
  hashName = Text.foldl' (\acc character -> acc * 31 + fromEnum character) 0

freshIncarnationId :: IncarnationStore -> Text -> IO Text
freshIncarnationId store name =
  firstFree (candidates (slugIncarnation name))
 where
  candidates base = base : [base <> "-" <> Text.pack (show n) | n <- [2 .. 99]]
  firstFree [] = pure (slugIncarnation name <> "-x")
  firstFree (candidate : rest) =
    incarnationRead store candidate >>= maybe (pure candidate) (const (firstFree rest))

stale :: Int -> Int -> Text
stale expected actual =
  "stale incarnation revision: expected "
    <> Text.pack (show expected)
    <> ", actual "
    <> Text.pack (show actual)

loadState :: FilePath -> IO (Either Text IncarnationState)
loadState path =
  (try (eitherDecodeFileStrict path) :: IO (Either IOException (Either String IncarnationState)))
    <&> \case
      Left failure
        | isDoesNotExistError failure -> Right emptyState
        | otherwise -> Left ("cannot read incarnation store: " <> Text.pack (displayException failure))
      Right (Left failure) -> Left ("invalid incarnation store: " <> Text.pack failure)
      Right (Right state) -> Right state

statePath :: FilePath -> FilePath
statePath dir = dir </> "incarnations.json"
