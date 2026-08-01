module Yuki.N.Transcript
  ( TranscriptStore (..),
    newMemoryTranscriptStore,
    newTranscriptStore,
    renderTranscript,
    toAguiMessages,
    transcriptHooks,
  )
where

import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.Aeson (Value, decodeFileStrict, object, (.=))
import Data.Either (fromRight)
import Data.Functor ((<&>))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent (AgentHooks (..), defaultHooks)
import Yuki.N.AtomicFile (atomicEncodeFile)
import Yuki.N.Context (contextSummaryMarker)
import Yuki.N.Memory (sanitizeThreadId)
import Yuki.N.Memory.Working (wakePacketMarker)
import Yuki.N.Model (AssistantTurn (..), ChatMessage (..), ModelToolCall (..))

data TranscriptStore = TranscriptStore
  { transcriptSave :: Text -> [ChatMessage] -> IO (),
    transcriptLoad :: Text -> IO (Maybe [ChatMessage]),
    transcriptDelete :: Text -> IO ()
  }

newTranscriptStore :: FilePath -> IO TranscriptStore
newTranscriptStore dir =
  createDirectoryIfMissing True (transcriptsPath dir)
    *> newMVar ()
    <&> \lock -> TranscriptStore (save lock) load (delete lock)
 where
  save lock threadId messages =
    withMVar lock (const (atomicEncodeFile (transcriptPath dir threadId) (withoutSystem messages)))
  load threadId =
    fromRight Nothing
      <$> (try (decodeFileStrict (transcriptPath dir threadId)) :: IO (Either IOException (Maybe [ChatMessage])))
  delete lock threadId =
    withMVar lock (const (removeIfExists (transcriptPath dir threadId)))

removeIfExists :: FilePath -> IO ()
removeIfExists path = doesFileExist path >>= flip when (removeFile path)

newMemoryTranscriptStore :: IO TranscriptStore
newMemoryTranscriptStore =
  newIORef Map.empty
    <&> \transcripts ->
      TranscriptStore
        (\threadId -> modifyIORef' transcripts . Map.insert threadId . withoutSystem)
        (\threadId -> Map.lookup threadId <$> readIORef transcripts)
        (\threadId -> modifyIORef' transcripts (Map.delete threadId))

transcriptHooks :: TranscriptStore -> AgentHooks
transcriptHooks store = defaultHooks {afterRun = persist}
 where
  persist input messages
    | isJust (AGUI.runParentId input) = pure ()
    | otherwise = ignoringIO (transcriptSave store (AGUI.runThreadId input) messages)

ignoringIO :: IO () -> IO ()
ignoringIO action = fromRight () <$> (try action :: IO (Either IOException ()))

toAguiMessages :: [ChatMessage] -> [AGUI.Message]
toAguiMessages = concatMap (uncurry render) . zip [0 ..] . withoutSystem
 where
  render index = \case
    ChatSystem text
      | contextSummaryMarker `Text.isPrefixOf` text ->
          [AGUI.Developer (AGUI.DeveloperMessage (auto index) text (Just "context-summary"))]
      | wakePacketMarker `Text.isPrefixOf` text ->
          [AGUI.Developer (AGUI.DeveloperMessage (auto index) text (Just "wake-packet"))]
      | otherwise -> []
    ChatUser text -> [AGUI.User (AGUI.UserMessage (auto index) (AGUI.UserText text) Nothing)]
    ChatAssistant turn -> assistant index turn
    ChatToolResult callId content ->
      [AGUI.Tool (AGUI.ToolMessage (auto index) content callId Nothing Nothing)]
  assistant index turn =
    [ AGUI.Reasoning (AGUI.ReasoningMessage (auto index <> "-reasoning") thought Nothing)
    | Just thought <- [turnReasoning turn]
    ]
      <> [ AGUI.Assistant
             ( AGUI.AssistantMessage
                 (turnMessageId turn)
                 (turnText turn)
                 Nothing
                 (fmap toolCall (turnToolCalls turn))
             )
         ]
  toolCall (ModelToolCall identifier name arguments) =
    AGUI.ToolCall identifier (AGUI.FunctionCall name arguments) Nothing
  auto index = "tr-" <> Text.pack (show (index :: Int))

renderTranscript :: Text -> [ChatMessage] -> Value
renderTranscript threadId messages =
  object ["threadId" .= threadId, "messages" .= toAguiMessages messages]

withoutSystem :: [ChatMessage] -> [ChatMessage]
withoutSystem = filter (not . ephemeralSystem)
 where
  ephemeralSystem (ChatSystem text) =
    not
      ( contextSummaryMarker `Text.isPrefixOf` text
          || wakePacketMarker `Text.isPrefixOf` text
      )
  ephemeralSystem _ = False

transcriptsPath :: FilePath -> FilePath
transcriptsPath dir = dir ++ "/transcripts"

transcriptPath :: FilePath -> Text -> FilePath
transcriptPath dir threadId = transcriptsPath dir ++ "/" ++ Text.unpack (sanitizeThreadId threadId) ++ ".json"
