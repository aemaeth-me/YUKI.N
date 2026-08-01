-- | AGENTS.md project instructions: collected root-first, capped, appended to prompts.
module Yuki.N.AgentsMd (agentsMdSection, appendAgentsMd) where

import Control.Exception (IOException, try)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import System.FilePath (takeDirectory, (</>))

-- | Concatenate AGENTS.md files from the filesystem root down to the given
-- directory, root first, each headed by its path. Missing or unreadable
-- files are skipped; the total is capped at 32KB with a truncation note.
agentsMdSection :: Maybe FilePath -> IO Text
agentsMdSection = maybe (pure "") collect
 where
  collect dir = cap . render . catMaybes <$> traverse readOne (reverse (ancestors dir))

-- | Append the section to a system prompt, two blank lines apart; an empty
-- side leaves the other untouched.
appendAgentsMd :: Text -> Text -> Text
appendAgentsMd section prompt
  | Text.null section = prompt
  | Text.null prompt = section
  | otherwise = prompt <> "\n\n\n" <> section

ancestors :: FilePath -> [FilePath]
ancestors dir
  | parent == dir = [dir]
  | otherwise = dir : ancestors parent
 where
  parent = takeDirectory dir

readOne :: FilePath -> IO (Maybe (FilePath, Text))
readOne dir = either (const Nothing) (Just . (,) path) <$> (try (TextIO.readFile path) :: IO (Either IOException Text))
 where
  path = dir </> "AGENTS.md"

render :: [(FilePath, Text)] -> Text
render = Text.intercalate "\n\n" . fmap section . filter (not . Text.null . Text.strip . snd)
 where
  section (path, body) = "# " <> Text.pack path <> "\n\n" <> Text.stripEnd body

cap :: Text -> Text
cap text
  | Text.length text <= sizeCap = text
  | otherwise = Text.take sizeCap text <> "\n" <> note
 where
  note = "# AGENTS.md sections truncated at 32768 characters"

sizeCap :: Int
sizeCap = 32768
