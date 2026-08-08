module Yuki.N.Transcript
  ( TranscriptStore (..),
    newTranscriptStore,
    renderTranscript,
    toAguiMessages,
    transcriptHook,
  )
where

import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (IOException, try)
import Data.Aeson (Value, decodeFileStrict, object, (.=))
import Data.Either (fromRight)
import Data.Functor ((<&>))
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory (createDirectoryIfMissing)
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.AtomicFile (atomicEncodeFile)
import Yuki.N.Context (contextSummaryMarker)
import Yuki.N.Domain.Thread (sanitizeThreadId)
import Yuki.N.Model (AssistantTurn (..), ChatMessage (..), ModelToolCall (..))

data TranscriptStore = TranscriptStore
  { transcriptSave :: Text -> [ChatMessage] -> IO (),
    transcriptLoad :: Text -> IO (Maybe [ChatMessage])
  }

newTranscriptStore :: FilePath -> IO TranscriptStore
newTranscriptStore dir =
  createDirectoryIfMissing True (transcriptsPath dir)
    *> newMVar ()
    <&> store
 where
  store lock = TranscriptStore (save lock) load
  save lock threadId messages =
    withMVar lock (const (atomicEncodeFile (transcriptPath dir threadId) (withoutSystem messages)))
  load threadId =
    fromRight Nothing
      <$> (try (decodeFileStrict (transcriptPath dir threadId)) :: IO (Either IOException (Maybe [ChatMessage])))

transcriptHook :: TranscriptStore -> AGUI.RunAgentInput -> [ChatMessage] -> IO ()
transcriptHook store input messages
  | isJust (AGUI.runParentId input) = pure ()
  | otherwise = transcriptSave store (AGUI.runThreadId input) messages

toAguiMessages :: [ChatMessage] -> [AGUI.Message]
toAguiMessages = concatMap (uncurry render) . zip [0 ..] . withoutSystem
 where
  render index = \case
    ChatSystem text ->
      [AGUI.System (AGUI.SystemMessage (auto index) text)]
    ChatUser text -> [AGUI.User (AGUI.UserMessage (auto index) text)]
    ChatAssistant turn -> assistant index turn
    ChatToolResult callId content ->
      [AGUI.Tool (AGUI.ToolMessage (auto index) content callId)]
  assistant index turn =
    [ AGUI.Reasoning (AGUI.ReasoningMessage (auto index <> "-reasoning") thought)
    | Just thought <- [turnReasoning turn]
    ]
      <> [ AGUI.Assistant
             ( AGUI.AssistantMessage
                 (turnMessageId turn)
                 (turnText turn)
                 (fmap toolCall (turnToolCalls turn))
             )
         ]
  toolCall (ModelToolCall identifier name arguments) =
    AGUI.ToolCall identifier (AGUI.FunctionCall name arguments)
  auto index = "tr-" <> Text.pack (show (index :: Int))

renderTranscript :: Text -> [ChatMessage] -> Value
renderTranscript threadId messages =
  object ["threadId" .= threadId, "messages" .= toAguiMessages messages]

withoutSystem :: [ChatMessage] -> [ChatMessage]
withoutSystem = filter (not . ephemeralSystem)
 where
  ephemeralSystem (ChatSystem text) = not (contextSummaryMarker `Text.isPrefixOf` text)
  ephemeralSystem _ = False

transcriptsPath :: FilePath -> FilePath
transcriptsPath dir = dir ++ "/transcripts"

transcriptPath :: FilePath -> Text -> FilePath
transcriptPath dir threadId = transcriptsPath dir ++ "/" ++ Text.unpack (sanitizeThreadId threadId) ++ ".json"
