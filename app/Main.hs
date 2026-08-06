module Main (main) where

import Data.Text qualified as Text
import System.Environment (getArgs)
import System.Exit (die)
import Yuki.N (runFromEnvironment)
import Yuki.N.Config (loadSettings)

main :: IO ()
main = getArgs >>= dispatch

dispatch :: [String] -> IO ()
dispatch [] = runFromEnvironment
dispatch ["check"] = loadSettings >>= either (die . Text.unpack) (const (putStrLn "YUKI.N configuration OK"))
dispatch _ = die "usage: yuki-n [check]"
