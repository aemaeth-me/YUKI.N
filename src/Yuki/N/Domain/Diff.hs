module Yuki.N.Domain.Diff (unified) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text

data Line = Keep Text | Drop Text | Add Text

data Hunk = Hunk !Int !Int !Int !Int [Text]

unified :: FilePath -> Text -> Text -> Text
unified path old new
  | null hunks = ""
  | otherwise = Text.unlines (header : concatMap hunkLines hunks)
 where
  hunks = hunksOf 1 1 (match (Text.lines old) (Text.lines new))
  header = "--- a/" <> Text.pack path <> "\n+++ b/" <> Text.pack path

hunkLines :: Hunk -> [Text]
hunkLines (Hunk oldStart oldCount newStart newCount chunk) =
  ("@@ -" <> int oldStart <> "," <> int oldCount <> " +" <> int newStart <> "," <> int newCount <> " @@") : chunk

int :: Int -> Text
int = Text.pack . show

hunksOf :: Int -> Int -> [Line] -> [Hunk]
hunksOf oldLine newLine script = case span isKeep script of
  (_, []) -> []
  (keeps, changes) ->
    body
      (oldLine + skipped)
      (newLine + skipped)
      (oldLine + length keeps)
      (newLine + length keeps)
      leading
      changes
   where
    leading = drop (length keeps - 3) keeps
    skipped = length keeps - length leading

body :: Int -> Int -> Int -> Int -> [Line] -> [Line] -> [Hunk]
body oldStart newStart old new acc [] = close oldStart old newStart new acc
body oldStart newStart old new acc (Add line : rest) = body oldStart newStart old (new + 1) (acc <> [Add line]) rest
body oldStart newStart old new acc (Drop line : rest) = body oldStart newStart (old + 1) new (acc <> [Drop line]) rest
body oldStart newStart old new acc keeps@(Keep _ : _) = decide (span isKeep keeps)
 where
  decide (run, rest)
    | length run <= 6 && not (null rest) = body oldStart newStart (old + n) (new + n) (acc <> run) rest
    | otherwise =
        close oldStart (old + k) newStart (new + k) (acc <> context)
          <> hunksOf (old + k) (new + k) (drop k run <> rest)
   where
    n = length run
    context = take 3 run
    k = length context

close :: Int -> Int -> Int -> Int -> [Line] -> [Hunk]
close oldStart old newStart new acc =
  [Hunk oldStart (old - oldStart) newStart (new - newStart) (fmap render acc) | not (all isKeep acc)]

isKeep :: Line -> Bool
isKeep (Keep _) = True
isKeep _ = False

render :: Line -> Text
render (Keep line) = " " <> line
render (Drop line) = "-" <> line
render (Add line) = "+" <> line

match :: [Text] -> [Text] -> [Line]
match old new = go (index new) 1 old
 where
  go _ pos [] = [Add line | line <- drop (pos - 1) new]
  go table pos (line : rest) =
    case candidate table pos line of
      Just row -> [Add added | added <- slice pos row new] <> (Keep line : go table (row + 1) rest)
      Nothing -> Drop line : go table pos rest

candidate :: Map Text [Int] -> Int -> Text -> Maybe Int
candidate table pos line = listToMaybe . dropWhile (< pos) =<< Map.lookup line table

index :: [Text] -> Map Text [Int]
index = Map.fromListWith (flip (<>)) . fmap (fmap pure) . flip zip [1 ..]

slice :: Int -> Int -> [Text] -> [Text]
slice from to = take (to - from) . drop (from - 1)
