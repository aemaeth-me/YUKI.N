module Yuki.Workbench.Format exposing (elapsedSeconds, formatDuration, formatRelative, formatTokens)

import Time


elapsedSeconds : Time.Posix -> Int -> Int
elapsedSeconds now stampSeconds =
    max 0 (Time.posixToMillis now // 1000 - stampSeconds)


formatDuration : Int -> String
formatDuration seconds =
    if seconds < 60 then
        String.fromInt seconds ++ "s"

    else if seconds < 3600 then
        String.fromInt (seconds // 60) ++ "m " ++ String.fromInt (modBy 60 seconds) ++ "s"

    else if seconds < 86400 then
        String.fromInt (seconds // 3600) ++ "h " ++ String.fromInt (modBy 3600 seconds // 60) ++ "m"

    else
        String.fromInt (seconds // 86400) ++ "d " ++ String.fromInt (modBy 86400 seconds // 3600) ++ "h"


formatRelative : Int -> String
formatRelative seconds =
    if seconds < 60 then
        "刚刚"

    else if seconds < 3600 then
        String.fromInt (seconds // 60) ++ " 分钟前"

    else if seconds < 86400 then
        String.fromInt (seconds // 3600) ++ " 小时前"

    else
        String.fromInt (seconds // 86400) ++ " 天前"


formatTokens : Int -> String
formatTokens count =
    if count >= 1000000 then
        compact (toFloat count / 1000000) "m"

    else if count >= 1000 then
        compact (toFloat count / 1000) "k"

    else
        String.fromInt count


compact : Float -> String -> String
compact value suffix =
    let
        tenths =
            round (value * 10)
    in
    String.fromInt (tenths // 10)
        ++ (if modBy 10 tenths == 0 then
                ""

            else
                "." ++ String.fromInt (modBy 10 tenths)
           )
        ++ suffix
