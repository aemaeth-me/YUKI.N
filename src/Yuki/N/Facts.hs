module Yuki.N.Facts
  ( Fact (..),
    FactKind (..),
    FactStore (..),
    factIdFor,
    factKindName,
    factRetentionLimit,
    newFactStore,
    newFactStoreWithLimit,
    newMemoryFactStore,
    newMemoryFactStoreWithLimit,
    readOnlyFactStore,
    retrievalTopK,
  )
where

import Control.Concurrent.MVar
import Control.Exception (IOException, try)
import Data.Aeson
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Functor ((<&>))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectoryIfMissing)
import Yuki.N.Artifact (fnv1a64, renderHash)
import Yuki.N.AtomicFile (atomicWriteLazy)

data FactKind = FactUser | FactProject | FactPreference | FactDecision
  deriving stock (Eq, Show)

factKindName :: FactKind -> Text
factKindName = \case
  FactUser -> "user"
  FactProject -> "project"
  FactPreference -> "preference"
  FactDecision -> "decision"

instance ToJSON FactKind where
  toJSON = String . factKindName

instance FromJSON FactKind where
  parseJSON = withText "FactKind" parse
    where
      parse = \case
        "user" -> pure FactUser
        "project" -> pure FactProject
        "preference" -> pure FactPreference
        "decision" -> pure FactDecision
        other -> fail ("unknown fact kind: " <> Text.unpack other)

data Fact = Fact
  { factId :: Text,
    factContent :: Text,
    factKind :: FactKind,
    factSource :: Text,
    factCreated :: Integer,
    factLastUsed :: Integer,
    factUseCount :: Int,
    factArchived :: Bool,
    factVoid :: Bool
  }
  deriving stock (Eq, Show)

instance ToJSON Fact where
  toJSON fact =
    object
      [ "id" .= factId fact,
        "content" .= factContent fact,
        "kind" .= factKind fact,
        "source" .= factSource fact,
        "created" .= factCreated fact,
        "lastUsed" .= factLastUsed fact,
        "useCount" .= factUseCount fact,
        "archived" .= factArchived fact,
        "void" .= factVoid fact
      ]

instance FromJSON Fact where
  parseJSON = withObject "Fact" $ \fields ->
    Fact
      <$> fields .: "id"
      <*> fields .: "content"
      <*> fields .: "kind"
      <*> fields .: "source"
      <*> fields .: "created"
      <*> fields .: "lastUsed"
      <*> fields .: "useCount"
      <*> fields .:? "archived" .!= False
      <*> fields .:? "void" .!= False

data FactStore = FactStore
  { factAdd :: Text -> FactKind -> Text -> IO Fact,
    factSearch :: Text -> IO [Fact],
    factTouch :: [Fact] -> IO (),
    factList :: IO [Fact],
    factArchiveOlderThan :: Integer -> IO Int,
    factInvalidate :: Text -> IO Bool
  }

retrievalTopK :: Int
retrievalTopK = 3

readOnlyFactStore :: FactStore -> FactStore
readOnlyFactStore store =
  store
    { factAdd = \content kind source -> pure (Fact (factIdFor content) content kind source 0 0 0 False False),
      factTouch = \_ -> pure (),
      factArchiveOlderThan = \_ -> pure 0,
      factInvalidate = \_ -> pure False
    }

factIdFor :: Text -> Text
factIdFor = ("fact-" <>) . renderHash . fnv1a64

mkFactStore :: Int -> MVar (Map Text Fact) -> (Map Text Fact -> IO ()) -> FactStore
mkFactStore limit lock persist = FactStore add search touch list archive invalidate
  where
    add content kind source =
      modifyMVar lock $ \facts ->
        case Map.lookup content facts of
          Just existing -> pure (facts, existing)
          Nothing ->
            getPOSIXTime >>= \now ->
              let fact = Fact (factIdFor content) content kind source (round now) 0 0 False False
                  updated = retainFacts limit (Just content) (Map.insert content fact facts)
               in persist updated *> pure (updated, fact)
    search query = rank query <$> list
    touch hits =
      getPOSIXTime >>= \now ->
        modifyMVar lock $ \facts ->
          let bumped = fmap (bump (round now)) hits
              updated = merge facts bumped
           in persist updated *> pure (updated, ())
    bump now fact = fact {factLastUsed = now, factUseCount = factUseCount fact + 1}
    list = Map.elems <$> readMVar lock
    archive cutoff =
      modifyMVar lock $ \facts ->
        let doomed = [fact {factArchived = True} | fact <- Map.elems facts, stale fact]
            updated = merge facts doomed
         in persist updated *> pure (updated, length doomed)
      where
        stale fact = not (factArchived fact) && factUseCount fact == 0 && factCreated fact < cutoff
    invalidate content =
      modifyMVar lock $ \facts ->
        case Map.lookup content facts of
          Nothing -> pure (facts, False)
          Just fact ->
            let voided = fact {factVoid = True}
                updated = Map.insert content voided facts
             in persist updated *> pure (updated, True)
    merge = foldl' (\facts fact -> Map.insert (factContent fact) fact facts)

rank :: Text -> [Fact] -> [Fact]
rank query = take retrievalTopK . sortOn (Down . score) . filter ((> 0) . score) . filter visible
  where
    score = Set.size . Set.intersection needles . tokens . factContent
    needles = tokens query

visible :: Fact -> Bool
visible = (&&) <$> (not . factArchived) <*> (not . factVoid)

tokens :: Text -> Set Text
tokens = Set.fromList . Text.words . Text.toLower

newFactStore :: FilePath -> IO FactStore
newFactStore = newFactStoreWithLimit factRetentionLimit

factRetentionLimit :: Int
factRetentionLimit = 4096

newFactStoreWithLimit :: Int -> FilePath -> IO FactStore
newFactStoreWithLimit requestedLimit dir =
  createDirectoryIfMissing True dir
    *> loadFacts path
    >>= \loaded ->
      let retained = retainFacts limit Nothing loaded
       in persistFacts path retained
            *> newMVar retained
            <&> \lock -> mkFactStore limit lock (persistFacts path)
  where
    limit = max 1 requestedLimit
    path = factsPath dir

newMemoryFactStore :: IO FactStore
newMemoryFactStore = newMemoryFactStoreWithLimit factRetentionLimit

newMemoryFactStoreWithLimit :: Int -> IO FactStore
newMemoryFactStoreWithLimit requestedLimit =
  newMVar Map.empty <&> \lock -> mkFactStore (max 1 requestedLimit) lock (const (pure ()))

factsPath :: FilePath -> FilePath
factsPath dir = dir ++ "/facts.jsonl"

persistFacts :: FilePath -> Map Text Fact -> IO ()
persistFacts path =
  atomicWriteLazy path
    . LazyByteString.concat
    . fmap ((<> "\n") . encode)
    . Map.elems

loadFacts :: FilePath -> IO (Map Text Fact)
loadFacts path =
  either (const Map.empty) (foldl' insert Map.empty . LazyByteString.split 10) <$> attempt
  where
    attempt = try (LazyByteString.readFile path) :: IO (Either IOException LazyByteString.ByteString)
    insert facts = maybe facts (\fact -> Map.insert (factContent fact) fact facts) . decode

retainFacts :: Int -> Maybe Text -> Map Text Fact -> Map Text Fact
retainFacts limit preferred facts =
  Map.restrictKeys facts (Set.fromList (take limit ordered))
  where
    first = maybe [] pure preferred
    ordered =
      first
        <> [ factContent fact
             | fact <- sortOn (Down . retentionKey) (Map.elems facts),
               factContent fact `notElem` first
           ]
    retentionKey fact =
      ( visible fact,
        max (factCreated fact) (factLastUsed fact),
        factUseCount fact
      )
