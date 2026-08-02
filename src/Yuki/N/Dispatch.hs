module Yuki.N.Dispatch
  ( module Yuki.N.Dispatch.Types,
    DispatchService (..),
    confirmDraft,
    draftGenerationPrompt,
    fallbackDraft,
    generateDraft,
    newDispatchService,
    newDispatchStore,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar
import Control.Exception (IOException, SomeException, displayException, try)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Bool (bool)
import Data.Functor (($>), (<&>))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Unique (hashUnique, newUnique)
import System.Directory (createDirectoryIfMissing)
import System.IO (stderr)
import System.IO.Error (isDoesNotExistError)
import Yuki.N.AtomicFile (atomicEncodeFile)
import Yuki.N.Dispatch.Types
import Yuki.N.Incarnation
import Yuki.N.Invocation
import Yuki.N.Journal (Journal)
import Yuki.N.Model (ChatMessage (..), Model)
import Yuki.N.Sessions
import Yuki.N.ThreadConfig.Types
import Yuki.N.Transcript

newDispatchStore :: FilePath -> IO DispatchStore
newDispatchStore dir =
  createDirectoryIfMissing True dir
    *> loadDrafts path
    >>= newMVar
    <&> store
 where
  path = dir ++ "/dispatches.json"
  store lock =
    DispatchStore
      { createDispatch = create lock path,
        getDispatch = \identifier -> Map.lookup identifier <$> readMVar lock,
        listDispatches = \incarnation status ->
          sortOn (Down . dispatchCreatedAt)
            . filter (matches incarnation status)
            . Map.elems
            <$> readMVar lock,
        patchDispatch = \identifier patch -> mutate lock path identifier (applyPatch patch),
        markDispatchDispatched = \identifier threadId ->
          mutate lock path identifier $ \now draft ->
            draft
              { dispatchStatus = Dispatched,
                dispatchCreatedThreadId = Just threadId,
                dispatchError = Nothing,
                dispatchDispatchedAt = Just now,
                dispatchUpdatedAt = now
              },
        markDispatchCancelled = \identifier ->
          mutate lock path identifier $ \now draft ->
            draft {dispatchStatus = Cancelled, dispatchUpdatedAt = now},
        markDispatchError = \identifier failure ->
          mutate lock path identifier $ \now draft ->
            draft {dispatchError = Just failure, dispatchUpdatedAt = now}
      }
  matches incarnation status draft =
    dispatchIncarnationId draft == incarnation
      && maybe True (== dispatchStatus draft) status

create :: MVar (Map Text DispatchDraft) -> FilePath -> NewDispatch -> IO DispatchDraft
create lock path new =
  newDispatchId >>= \identifier ->
    getPOSIXTime >>= \now ->
      modifyMVar lock $ \drafts ->
        let stamp = round now
            draft =
              DispatchDraft
                identifier
                (newDispatchIncarnationId new)
                (newDispatchSource new)
                (newDispatchInput new)
                (newDispatchTitle new)
                (newDispatchPrompt new)
                (newDispatchConfig new)
                (newDispatchGeneration new)
                Draft
                Nothing
                Nothing
                stamp
                stamp
                Nothing
            updated = Map.insert identifier draft drafts
         in persist path updated $> (updated, draft)

applyPatch :: DispatchPatch -> Integer -> DispatchDraft -> DispatchDraft
applyPatch patch now draft =
  draft
    { dispatchTitle = fromMaybe (dispatchTitle draft) (patchTitle patch),
      dispatchPrompt = fromMaybe (dispatchPrompt draft) (patchPrompt patch),
      dispatchConfig = fromMaybe (dispatchConfig draft) (patchConfig patch),
      dispatchUpdatedAt = now
    }

mutate :: MVar (Map Text DispatchDraft) -> FilePath -> Text -> (Integer -> DispatchDraft -> DispatchDraft) -> IO (Either Text DispatchDraft)
mutate lock path identifier change =
  getPOSIXTime >>= \now ->
    modifyMVar lock $ \drafts ->
      case Map.lookup identifier drafts of
        Nothing -> pure (drafts, Left ("unknown dispatch: " <> identifier))
        Just current
          | dispatchStatus current /= Draft ->
              pure (drafts, Left ("dispatch is not draft: " <> identifier))
          | otherwise ->
              let changed = change (round now) current
                  updated = Map.insert identifier changed drafts
               in persist path updated $> (updated, Right changed)

persist :: FilePath -> Map Text DispatchDraft -> IO ()
persist path = atomicEncodeFile path . Map.elems

loadDrafts :: FilePath -> IO (Map Text DispatchDraft)
loadDrafts path =
  (try (eitherDecodeFileStrict path) :: IO (Either IOException (Either String [DispatchDraft]))) >>= \case
    Left failure
      | isDoesNotExistError failure -> pure Map.empty
      | otherwise -> warn (displayException failure)
    Right (Left failure) -> warn failure
    Right (Right drafts) -> pure (Map.fromList [(dispatchId draft, draft) | draft <- drafts])
 where
  warn failure =
    Map.empty
      <$ TextIO.hPutStrLn stderr ("YUKI.N dispatches index: " <> Text.pack failure)

newDispatchId :: IO Text
newDispatchId = liftA2 render timestamp (hashUnique <$> newUnique)
 where
  timestamp = round . (* 1000000) <$> getPOSIXTime
  render micros unique =
    "dsp-" <> Text.pack (show (micros :: Integer)) <> "-" <> Text.pack (show unique)

draftGenerationPrompt :: Text
draftGenerationPrompt =
  Text.intercalate
    "\n"
    [ "You are the dispatch drafter for YUKI.N. The user wants to hand a piece of work to a task agent that shares the persona named below. You receive three inputs: the persona's name, the persona's direction (its long-term character), and the user's request.",
      "",
      "Produce exactly one JSON object {\"title\": string, \"prompt\": string} and nothing else: no markdown fences, no commentary.",
      "",
      "Rules for \"title\":",
      "- At most 60 characters. A concrete, verb-led label for the task.",
      "- Use the language of the user's request. No quotes, emoji, or prefixes like \"Task:\".",
      "",
      "Rules for \"prompt\":",
      "- This is the first and only instruction the task agent will see; it does NOT see the current conversation. Make it self-contained: what to do, why, the relevant details from the request, the constraints and preferences the user stated, and how completion will be judged.",
      "- Stay faithful to the request. Never invent scope, requirements, file paths, deadlines, or facts the user did not state. If the request is vague, write the simplest reasonable interpretation instead of padding.",
      "- The task agent runs with its own capabilities (file system, shell, memory search, sub-agents) under a capability snapshot the user confirms. When natural, mention that it should search its memory for relevant prior experience and may delegate independent subtasks to sub-agents. Do not enumerate tool names or dictate a workflow.",
      "- Length: one short paragraph when the request is simple; a compact structure (goal / context / constraints / done-when) when the request is complex. Use the language of the user's request."
    ]

generateDraft :: (InvocationSpec -> IO (Either Text InvocationResult)) -> [Model] -> Int -> Maybe Journal -> Incarnation -> Text -> IO (Text, Text, DispatchGeneration)
generateDraft invoke models timeoutSeconds journal incarnation input
  | null models = pure (fallbackDraft input)
  | otherwise =
      newDispatchId >>= \identifier ->
        either (const (fallbackDraft input)) (generated identifier)
          <$> invoke (specification identifier)
 where
  specification identifier =
    InvocationSpec
      identifier
      "dispatch.draft"
      "dispatch-draft-generator/v1"
      models
      [ ChatSystem draftGenerationPrompt,
        ChatUser
          ( Text.intercalate
              "\n"
              [ "Incarnation: " <> incarnationName incarnation,
                "Direction: " <> incarnationDirection incarnation,
                "Request: " <> input
              ]
          )
      ]
      1
      2000
      (max 1 timeoutSeconds * 1000)
      journal
  generated identifier result =
    fromMaybe (fallbackDraft input) (parseGenerated identifier (invocationResultText result))

parseGenerated :: Text -> Text -> Maybe (Text, Text, DispatchGeneration)
parseGenerated identifier raw =
  either (const Nothing) validate decoded
 where
  decoded =
    eitherDecodeStrict (TextEncoding.encodeUtf8 (unfence raw))
      >>= parseEither (withObject "dispatch draft" (\fields -> (,) <$> fields .: "title" <*> fields .: "prompt"))
  validate (title, prompt)
    | Text.null cleanTitle || Text.null cleanPrompt = Nothing
    | otherwise = Just (Text.take 60 cleanTitle, cleanPrompt, GeneratedModel identifier)
   where
    cleanTitle = Text.strip title
    cleanPrompt = Text.strip prompt

unfence :: Text -> Text
unfence raw =
  fromMaybe trimmed $ do
    inner <- Text.stripPrefix "```json" trimmed <|> Text.stripPrefix "```" trimmed
    Text.stripSuffix "```" (Text.strip inner)
 where
  trimmed = Text.strip raw

fallbackDraft :: Text -> (Text, Text, DispatchGeneration)
fallbackDraft input = (fallbackTitle input, input, GeneratedFallback)

fallbackTitle :: Text -> Text
fallbackTitle input =
  bool firstLine (Text.take 60 (Text.strip input)) (Text.null firstLine)
 where
  firstLine = Text.take 60 (Text.takeWhile (/= '\n') (Text.strip input))

confirmDraft :: DispatchStore -> SessionService -> IncarnationStore -> IO Text -> Text -> IO ConfirmOutcome
confirmDraft dispatches service incarnations newThreadId identifier =
  getDispatch dispatches identifier >>= maybe (pure ConfirmMissing) check
 where
  check draft
    | dispatchStatus draft /= Draft =
        pure (ConfirmConflict ("dispatch is not draft: " <> identifier))
    | otherwise =
        incarnationRead incarnations (dispatchIncarnationId draft)
          >>= maybe (report draft ("unknown incarnation: " <> dispatchIncarnationId draft)) (proceed draft)
  proceed draft incarnation
    | incarnationStatus incarnation == IncarnationArchived =
        report draft ("incarnation is archived: " <> dispatchIncarnationId draft)
    | otherwise = newThreadId >>= open draft
  open draft threadId =
    createSession sessions threadId (Just (dispatchTitle draft)) (dispatchIncarnationId draft) Nothing Nothing
      >>= either (report draft) (const (stage draft threadId [rollbackSession threadId] (provisions draft threadId)))
  provisions draft threadId =
    [ (threadConfigWrite configs threadId (dispatchConfig draft), rollbackConfig threadId),
      (transcriptSave transcripts threadId [ChatUser (dispatchPrompt draft)], rollbackTranscript threadId)
    ]
  stage draft threadId rollbacks [] =
    markDispatchDispatched dispatches identifier threadId
      >>= either (rollbackAll rollbacks draft) (const (pure (ConfirmOk threadId)))
  stage draft threadId rollbacks ((action, undo) : rest) =
    attempt action
      >>= either (rollbackAll rollbacks draft) (const (stage draft threadId (undo : rollbacks) rest))
  rollbackAll rollbacks draft failure =
    sequence_ rollbacks *> report draft failure
  rollbackSession threadId = archiveSession service threadId $> ()
  rollbackConfig = threadConfigDelete configs
  rollbackTranscript = transcriptDelete transcripts
  report draft failure =
    markDispatchError dispatches (dispatchId draft) failure
      $> ConfirmError failure
  sessions = serviceSessions service
  configs = serviceConfigs service
  transcripts = serviceTranscripts service

attempt :: IO () -> IO (Either Text ())
attempt action =
  either (Left . Text.pack . displayException) Right
    <$> (try action :: IO (Either SomeException ()))

data DispatchService = DispatchService
  { dispatchServiceStore :: DispatchStore,
    dispatchServiceGenerate :: Incarnation -> Text -> IO DispatchDraft,
    dispatchServiceConfirm :: Text -> IO ConfirmOutcome
  }

newDispatchService :: DispatchStore -> SessionService -> IncarnationStore -> IO Text -> (Incarnation -> Text -> IO (Text, Text, DispatchGeneration)) -> DispatchService
newDispatchService dispatches service incarnations newThreadId generate =
  DispatchService dispatches materialize (confirmDraft dispatches service incarnations newThreadId)
 where
  materialize incarnation input =
    generate incarnation input >>= \(title, prompt, generation) ->
      threadConfigRead (serviceConfigs service) (homeThreadId (incarnationId incarnation)) >>= \config ->
        createDispatch
          dispatches
          (NewDispatch DispatchUser (incarnationId incarnation) input title prompt config generation)
