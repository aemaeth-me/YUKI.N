module Yuki.N.Domain.Thread
  ( sanitizeThreadId,
  )
where

import Data.Bool (bool)
import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as Text

sanitizeThreadId :: Text -> Text
sanitizeThreadId raw = bool cleaned "thread" (Text.null cleaned)
 where
  cleaned = Text.map safe raw
  safe char
    | Char.isAsciiLower char || Char.isAsciiUpper char || Char.isDigit char || char == '-' || char == '_' || char == '.' = char
    | otherwise = '-'
