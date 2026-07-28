module Yuki.N.Anatomy
  ( Anatomy (..),
    AnatomyReport (..),
    anatomyEntries,
    anatomyFile,
    renderAnatomy,
  )
where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Yuki.N.Journal (Entry (..), EntryKind (..))
import Yuki.N.Model
import Yuki.N.Replay (readJournal)

data Anatomy = Anatomy
  { anatomySystem :: Int,
    anatomyToolDefs :: Int,
    anatomyUser :: Int,
    anatomyBody :: Int,
    anatomyReasoning :: Int,
    anatomyToolResults :: Int
  }
  deriving stock (Eq, Show)

instance Semigroup Anatomy where
  Anatomy a b c d e f <> Anatomy a' b' c' d' e' f' =
    Anatomy (a + a') (b + b') (c + c') (d + d') (e + e') (f + f')

instance Monoid Anatomy where
  mempty = Anatomy 0 0 0 0 0 0

data AnatomyReport = AnatomyReport
  { reportRequests :: Int,
    reportTotals :: Anatomy,
    reportWindow :: Maybe Anatomy
  }
  deriving stock (Eq, Show)

anatomyEntries :: [Entry] -> AnatomyReport
anatomyEntries entries =
  AnatomyReport (length anatomies) (mconcat anatomies) (listToMaybe (reverse anatomies))
  where
    anatomies = [dissect request | Entry _ _ _ (ModelRequestEntry request) <- entries]

anatomyFile :: FilePath -> IO (Either Text AnatomyReport)
anatomyFile = fmap (fmap anatomyEntries) . readJournal

dissect :: ModelRequest -> Anatomy
dissect (ModelRequest messages tools) =
  foldMap message messages <> mempty {anatomyToolDefs = serialized tools}
  where
    message = \case
      ChatSystem content -> system content
      ChatUser content -> user content
      ChatAssistant turn -> assistant turn
      ChatToolResult _ content -> toolResult content
    assistant (AssistantTurn _ text reasoning calls) =
      foldMap body text
        <> foldMap body (modelToolArguments <$> calls)
        <> foldMap reasoningOf reasoning
    system content = mempty {anatomySystem = Text.length content}
    user content = mempty {anatomyUser = Text.length content}
    body content = mempty {anatomyBody = Text.length content}
    reasoningOf content = mempty {anatomyReasoning = Text.length content}
    toolResult content = mempty {anatomyToolResults = Text.length content}
    serialized = fromIntegral . LazyByteString.length . encode

renderAnatomy :: AnatomyReport -> Text
renderAnatomy (AnatomyReport requests totals window) =
  Text.intercalate "\n" $
    [ "token anatomy (estimate: chars/4)",
      "requests: " <> shown requests,
      "",
      columns "category" "cum.tokens" "share" "window.tokens",
      rule
    ]
      <> fmap row categories
      <> [ rule,
           columns "total" (tokens totalChars) (share totalChars) (tokens windowChars),
           "window = last request (current context water level)"
         ]
  where
    row (label, get) =
      columns label (tokens (get totals)) (share (get totals)) (tokens (maybe 0 get window))
    columns a b c d = Text.intercalate "  " [pad 12 a, pad 10 b, pad 7 c, d]
    totalChars = anatomyTotal totals
    windowChars = maybe 0 anatomyTotal window
    share n = shown (n * 100 `div` max 1 totalChars) <> "%"
    tokens = shown . (`div` 4)
    shown = Text.pack . show
    pad width text = text <> Text.replicate (width - Text.length text) " "
    rule = Text.replicate 48 "-"

anatomyTotal :: Anatomy -> Int
anatomyTotal (Anatomy a b c d e f) = a + b + c + d + e + f

categories :: [(Text, Anatomy -> Int)]
categories =
  [ ("system", anatomySystem),
    ("tool defs", anatomyToolDefs),
    ("user", anatomyUser),
    ("model body", anatomyBody),
    ("reasoning", anatomyReasoning),
    ("tool results", anatomyToolResults)
  ]
