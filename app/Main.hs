module Main (main) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Environment (getArgs)
import System.Exit (die)
import Yuki.N (runFromEnvironment)
import Yuki.N.AGUI.Event (eventType)
import Yuki.N.Agent (defaultHooks)
import Yuki.N.Anatomy (anatomyFile, renderAnatomy)
import Yuki.N.Config (loadSettings)
import Yuki.N.Replay

main :: IO ()
main =
  getArgs >>= \case
    [] -> runFromEnvironment
    ["check"] -> loadSettings >>= either (die . Text.unpack) (const (putStrLn "YUKI.N configuration OK"))
    ["replay", path] -> audit path Nothing
    ["replay", path, runId] -> audit path (Just (Text.pack runId))
    ["anatomy", path] -> anatomize path
    _ -> die "usage: yuki-n [check | replay JOURNAL [RUN_ID] | anatomy JOURNAL]"

anatomize :: FilePath -> IO ()
anatomize path =
  anatomyFile path >>= either (die . Text.unpack) (TextIO.putStrLn . renderAnatomy)

audit :: FilePath -> Maybe Text -> IO ()
audit path wanted =
  replayFile defaultHooks path wanted
    >>= either (die . Text.unpack) report
  where
    report result =
      maybe clean diverged (reportDivergence result)
      where
        clean =
          putStrLn
            ( "replay OK: run "
                <> Text.unpack (reportRunId result)
                <> ", "
                <> show (reportEvents result)
                <> " events reproduced"
            )
        diverged divergence =
          die
            ( "replay diverged at event "
                <> show (divergenceAt divergence)
                <> ": expected "
                <> maybe "∅" showEvent (divergenceExpected divergence)
                <> ", got "
                <> maybe "∅" showEvent (divergenceActual divergence)
                <> maybe "" (("\n" <>) . Text.unpack) (divergenceNote divergence)
            )
    showEvent = Text.unpack . eventType
