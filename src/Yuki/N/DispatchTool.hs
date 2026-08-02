module Yuki.N.DispatchTool
  ( proposeDispatchTool,
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson
import Data.Bool (bool)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Functor (($>))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import Yuki.N.AGUI.Event (Event (..))
import Yuki.N.AGUI.Types qualified as AGUI
import Yuki.N.Agent
import Yuki.N.Dispatch.Types
import Yuki.N.Telemetry (ActivityFrame (..), Telemetry, publish)
import Yuki.N.Telemetry.Ledger (quietly)
import Yuki.N.ThreadConfig.Types (emptyThreadConfig)

proposeDispatchTool :: Int -> DispatchStore -> Maybe Telemetry -> BackendTool
proposeDispatchTool timeoutSeconds store hub =
  BackendTool (AGUI.ToolSpec name description schema) execute
 where
  name = "propose_dispatch"
  description =
    "Propose dispatching a persistent task to this Yuki's workbench. Use when the conversation reveals work that should outlive this chat: multi-step builds, long investigations, or anything the user would want to pause, resume, or inspect later. The user reviews and may edit your proposal before it is dispatched — nothing happens silently. Give title (at most 60 characters, verb-led), prompt (the complete first instruction the task agent will see; self-contained — it does not see this conversation), and reason (why this belongs in a task rather than here). The call blocks until the user confirms or rejects; on confirm you receive the new task's threadId, on rejection an error you should acknowledge gracefully before continuing the conversation. Do not propose for casual questions, one-off lookups, or work you can finish now."
  schema =
    object
      [ "type" .= ("object" :: Text),
        "properties"
          .= object
            [ "title" .= stringSchema,
              "prompt" .= stringSchema,
              "reason" .= stringSchema
            ],
        "required" .= (["title", "prompt"] :: [Text]),
        "additionalProperties" .= False
      ]
  stringSchema = object ["type" .= ("string" :: Text)]

  execute context arguments =
    case fromJSON arguments of
      Error message -> pure (failure ("invalid tool arguments: " <> Text.pack message))
      Success (Proposal title prompt reason) -> propose context title prompt reason

  propose context title prompt reason =
    createDispatch store (NewDispatch (DispatchAgent (toolContextRunId context) (toolContextCallId context)) (toolContextIncarnation context) (fromMaybe "" reason) title prompt emptyThreadConfig GeneratedAgent)
      >>= announce context
      >>= settle
  announce context draft =
    toolContextEmit context (Custom "dispatch.draft" (toJSON draft))
      *> traverse_ (\telemetry -> quietly (publish telemetry (FrameDraft draft))) hub
      $> draft
  settle draft =
    getPOSIXTime >>= poll draft . (+ fromIntegral timeoutSeconds)
  poll draft deadline =
    getDispatch store (dispatchId draft) >>= \case
      Just current
        | dispatchStatus current == Draft ->
            getPOSIXTime >>= \now ->
              bool (threadDelay 500000 *> poll current deadline) (pure (outcome current)) (now >= deadline)
        | otherwise -> pure (outcome current)
      Nothing -> pure (failure "dispatch proposal rejected: draft unavailable")
  outcome current = case dispatchStatus current of
    Dispatched ->
      success
        ( TextEncoding.decodeUtf8
            ( LazyByteString.toStrict
                (encode (object ["threadId" .= dispatchCreatedThreadId current, "status" .= ("dispatched" :: Text)]))
            )
        )
    Cancelled -> failure "dispatch proposal rejected: cancelled by user"
    Draft -> failure "dispatch proposal rejected: confirmation timed out"

data Proposal = Proposal Text Text (Maybe Text)

instance FromJSON Proposal where
  parseJSON = withObject "Proposal" $ \fields ->
    Proposal <$> fields .: "title" <*> fields .: "prompt" <*> fields .:? "reason"

success :: Text -> ToolOutcome
success content = ToolOutcome content False False

failure :: Text -> ToolOutcome
failure content = ToolOutcome content True False
