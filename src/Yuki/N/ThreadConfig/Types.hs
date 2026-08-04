module Yuki.N.ThreadConfig.Types
  ( CwdSetting (..),
    ThreadConfig (..),
    ThreadConfigStore (..),
    cwdPath,
    emptyThreadConfig,
    resolveThreadConfig,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Yuki.N.Provider.OpenAI (ReasoningEffort)

data CwdSetting
  = CwdInherit
  | CwdNone
  | CwdPath FilePath
  deriving stock (Eq, Show)

cwdPath :: CwdSetting -> Maybe FilePath
cwdPath CwdInherit = Nothing
cwdPath CwdNone = Nothing
cwdPath (CwdPath path) = Just path

data ThreadConfig = ThreadConfig
  { configCwd :: CwdSetting,
    configIncarnationId :: Maybe Text,
    configSystemPrompt :: Maybe Text,
    configProvider :: Maybe Text,
    configModel :: Maybe Text,
    configReasoningEffort :: Maybe ReasoningEffort,
    configFs :: Maybe Bool,
    configShell :: Maybe Bool,
    configMemory :: Maybe Bool,
    configContextReserveTokens :: Maybe Int,
    configContextKeepUnits :: Maybe Int,
    configContextSummaryTokens :: Maybe Int
  }
  deriving stock (Eq, Show)

emptyThreadConfig :: ThreadConfig
emptyThreadConfig = ThreadConfig CwdInherit Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

instance Semigroup ThreadConfig where
  session <> fallback =
    ThreadConfig
      cwd
      (pick configIncarnationId)
      (pick configSystemPrompt)
      (pick configProvider)
      (pick configModel)
      (pick configReasoningEffort)
      (pick configFs)
      (pick configShell)
      (pick configMemory)
      (pick configContextReserveTokens)
      (pick configContextKeepUnits)
      (pick configContextSummaryTokens)
   where
    cwd = case configCwd session of
      CwdInherit -> configCwd fallback
      explicit -> explicit
    pick :: (ThreadConfig -> Maybe field) -> Maybe field
    pick field = field session <|> field fallback

instance Monoid ThreadConfig where
  mempty = emptyThreadConfig

resolveThreadConfig :: ThreadConfig -> ThreadConfig -> ThreadConfig
resolveThreadConfig = (<>)

instance ToJSON ThreadConfig where
  toJSON config =
    object
      ( cwdPairs (configCwd config)
          <> [ "cwdMode" .= cwdMode cwd,
               "incarnationId" .= configIncarnationId config,
               "systemPrompt" .= configSystemPrompt config,
               "provider" .= configProvider config,
               "model" .= configModel config,
               "reasoningEffort" .= configReasoningEffort config,
               "fs" .= configFs config,
               "shell" .= configShell config,
               "memory" .= configMemory config,
               "contextReserveTokens" .= configContextReserveTokens config,
               "contextKeepUnits" .= configContextKeepUnits config,
               "contextSummaryTokens" .= configContextSummaryTokens config
             ]
      )
   where
    cwd = configCwd config
    cwdPairs CwdInherit = []
    cwdPairs CwdNone = ["cwd" .= Null]
    cwdPairs (CwdPath path) = ["cwd" .= path]
    cwdMode CwdInherit = "inherit" :: Text
    cwdMode CwdNone = "none"
    cwdMode CwdPath {} = "path"

instance FromJSON ThreadConfig where
  parseJSON = withObject "ThreadConfig" $ \fields ->
    ThreadConfig
      <$> parseCwd fields
      <*> fields .:? "incarnationId"
      <*> fields .:? "systemPrompt"
      <*> fields .:? "provider"
      <*> fields .:? "model"
      <*> fields .:? "reasoningEffort"
      <*> fields .:? "fs"
      <*> fields .:? "shell"
      <*> fields .:? "memory"
      <*> fields .:? "contextReserveTokens"
      <*> fields .:? "contextKeepUnits"
      <*> fields .:? "contextSummaryTokens"
   where
    parseCwd fields =
      fields .:? "cwdMode" >>= maybe (pure CwdInherit) (explicit fields)
    explicit _ "inherit" = pure CwdInherit
    explicit _ "none" = pure CwdNone
    explicit fields "path" = CwdPath <$> fields .: "cwd"
    explicit _ mode = fail ("unknown cwdMode: " <> Text.unpack mode)

data ThreadConfigStore = ThreadConfigStore
  { threadConfigRead :: Text -> IO ThreadConfig,
    threadConfigWrite :: Text -> ThreadConfig -> IO (),
    threadConfigDelete :: Text -> IO ()
  }
