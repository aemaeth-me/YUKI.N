port module Main exposing (main)

import Browser
import Dict exposing (Dict)
import Html exposing (Html, aside, button, details, div, form, h1, h2, header, input, label, main_, nav, p, pre, section, span, summary, text, textarea)
import Html.Attributes as Attr
import Html.Events as Events
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Markdown
import Process
import Set exposing (Set)
import String
import Task
import Time


port runAgent : Encode.Value -> Cmd msg


port cancelAgent : Encode.Value -> Cmd msg


port agentEvent : (Decode.Value -> msg) -> Sub msg


port transportEvent : (Decode.Value -> msg) -> Sub msg


port inspect : Encode.Value -> Cmd msg


port inspectionResult : (Decode.Value -> msg) -> Sub msg


port persistThreadId : String -> Cmd msg


port persistIncarnationId : String -> Cmd msg


port exportSessionFile : Encode.Value -> Cmd msg


port chooseSessionImport : () -> Cmd msg


port sessionImportData : (Decode.Value -> msg) -> Sub msg


port copyText : String -> Cmd msg


port followTranscript : () -> Cmd msg


port transcriptFollowChanged : (Bool -> msg) -> Sub msg


type alias Flags =
    { endpoint : String
    , threadId : String
    , incarnationId : String
    , runStamp : String
    }


type alias Model =
    { endpoint : String
    , incarnationId : String
    , incarnation : IncarnationView
    , incarnations : OptionalRemote (List IncarnationView)
    , incarnationNotice : Maybe String
    , selfNameDraft : String
    , selfDirectionDraft : String
    , selfImpressionModelDraft : String
    , savingSelf : Bool
    , selfMessage : Maybe String
    , incarnationArchiveConfirm : Bool
    , archivingIncarnation : Bool
    , restoringIncarnation : Maybe String
    , threadBase : String
    , threadId : String
    , currentTaskBelongs : Bool
    , threadNumber : Int
    , runStamp : String
    , draft : String
    , pathSuggestions : List String
    , messages : Dict String ChatMessage
    , messageOrder : List String
    , tools : Dict String ToolCall
    , phase : Phase
    , activeRun : Maybe String
    , runNumber : Int
    , nextId : Int
    , terminalSeen : Bool
    , error : Maybe String
    , activeStep : Maybe String
    , stickToBottom : Bool
    , inspection : Inspection
    , tab : Tab
    , memoryPane : MemoryPane
    , impression : OptionalRemote ImpressionStateView
    , impressionActivations : OptionalRemote (List ImpressionActivationView)
    , impressionRevisions : OptionalRemote (List ImpressionRevisionView)
    , memoryRecordMode : MemoryRecordMode
    , taskRecords : TaskRecordMemory
    , longMemoryQuery : String
    , longMemorySearch : OptionalRemote MemoryGrepView
    , workingMemory : OptionalRemote WorkingMemoryView
    , sleepCycles : OptionalRemote (List SleepCycleView)
    , rootPrompts : OptionalRemote (List PromptRevisionView)
    , prompts : OptionalRemote (List PromptRevisionView)
    , generatingPrompt : Bool
    , activatingPrompt : Maybe String
    , promptEditor : Maybe PromptEditor
    , promptMessage : Maybe String
    , usage : Maybe Usage
    , contextGauge : Maybe ContextGauge
    , compactConfirm : Bool
    , compacting : Bool
    , compactMessage : Maybe String
    , tree : Remote (Maybe (List String))
    , sessions : Remote (List SessionMeta)
    , showArchived : Bool
    , pendingSwitch : Maybe String
    , sessionTitleDraft : String
    , forkNodeDraft : String
    , sessionActionError : Maybe String
    , sessionForm : Maybe SessionForm
    , incarnationForm : Maybe IncarnationForm
    , configPanel : ConfigPanel
    , now : Maybe Time.Posix
    }


type Tab
    = NowTab
    | MemoryTab
    | TasksTab
    | CapabilitiesTab
    | SelfTab
    | AuditTab


type MemoryPane
    = ImpressionPane
    | LongTermPane
    | SleepPane


type MemoryRecordMode
    = TaskRecordMode
    | DistilledRecordMode


type alias Usage =
    { prompt : Maybe Int
    , completion : Maybe Int
    , cacheHit : Maybe Int
    }


type alias ContextGauge =
    { tokens : Int
    , budget : Int
    , willCompact : Bool
    , emergency : Bool
    , window : Maybe Int
    , reserve : Maybe Int
    , tools : Maybe Int
    }


type alias SessionForm =
    { targetId : String
    , title : String
    , cwd : String
    , fs : Bool
    , shell : Bool
    , memory : Bool
    , global : Maybe ThreadConfigView
    , session : Maybe ThreadConfigView
    , prefilled : Bool
    , saving : Bool
    , error : Maybe String
    }


type alias IncarnationForm =
    { identifier : String
    , name : String
    , direction : String
    , impressionModel : String
    , saving : Bool
    , error : Maybe String
    }


type alias SessionMeta =
    { id : String
    , title : String
    , created : Int
    , updated : Int
    , archived : Bool
    , parent : Maybe String
    , forkNode : Maybe String
    }


type alias ThreadConfigView =
    { incarnationId : Maybe String
    , cwdMode : CwdMode
    , cwd : Maybe String
    , systemPrompt : Maybe String
    , provider : Maybe String
    , model : Maybe String
    , reasoningEffort : Maybe String
    , fs : Maybe Bool
    , shell : Maybe Bool
    , memory : Maybe Bool
    , contextReserveTokens : Maybe Int
    , contextKeepUnits : Maybe Int
    , contextSummaryTokens : Maybe Int
    }


type alias ProviderEntryView =
    { name : String
    , baseUrl : String
    , dialect : String
    , defaultModel : String
    , keyReady : Bool
    , models : List String
    , contextTokens : Int
    }


type alias ConfigPanel =
    { global : Remote GlobalView
    , session : Remote ThreadConfigView
    , capabilities : Remote (List String)
    , contextPolicy : Remote ContextPolicyView
    , providers : Remote (List ProviderEntryView)
    , loadedFor : Maybe String
    , draft : ConfigDraft
    , baseline : ConfigDraft
    , saving : Bool
    , saved : Bool
    , saveError : Maybe String
    }


type alias ConfigDraft =
    { cwdMode : CwdMode
    , cwd : String
    , systemPrompt : String
    , provider : String
    , model : String
    , reasoningEffort : String
    , fs : Maybe Bool
    , shell : Maybe Bool
    , memory : Maybe Bool
    , contextReserveTokens : String
    , contextKeepUnits : String
    , contextSummaryTokens : String
    }


type alias ContextPolicyView =
    { windowTokens : Int
    , reserveTokens : Int
    , toolTokens : Int
    , budgetTokens : Int
    , keepUnits : Int
    , summaryTokens : Int
    }


type CwdMode
    = CwdInherit
    | CwdNone
    | CwdPath


type alias GlobalView =
    { provider : ProviderView
    , settings : SettingsView
    , defaults : ThreadConfigView
    }


type alias ProviderView =
    { name : String
    , model : String
    , baseUrl : String
    , apiKey : String
    , dialect : String
    , thinking : String
    , maxTokens : Maybe Int
    , contextTokens : Int
    }


type alias SettingsView =
    { host : String
    , port_ : Int
    , maxTurns : Int
    , toolExecution : String
    , systemPrompt : String
    , workDir : Maybe String
    , journalDir : Maybe String
    , artifactDir : Maybe String
    , memoryDir : Maybe String
    , memoryModel : Maybe String
    , contextReserveTokens : Int
    , contextKeepUnits : Int
    , contextSummaryTokens : Int
    }


type SessionField
    = FsField
    | ShellField


type ChatMessage
    = UserChat String String
    | SummaryChat String String
    | MemoryChat String String
    | NoticeChat String String
    | ReasoningChat ReasoningMessage
    | AssistantChat AssistantMessage
    | ToolChat ToolMessage
    | SubAgentChat SubMessage


type alias ReasoningMessage =
    { id : String
    , content : String
    , complete : Bool
    }


type alias AssistantMessage =
    { id : String
    , content : String
    , toolCalls : List String
    , complete : Bool
    }


type alias ToolMessage =
    { id : String
    , callId : String
    , content : String
    }


type alias SubMessage =
    { id : String
    , callId : String
    , content : String
    , failed : Bool
    , error : Maybe String
    , status : String
    , activity : List String
    , context : Maybe ContextGauge
    }


type alias ToolCall =
    { id : String
    , name : String
    , arguments : String
    , parentMessageId : Maybe String
    , stage : ToolStage
    , output : String
    , result : Maybe String
    }


type ToolStage
    = ToolStreaming
    | ToolWaiting
    | ToolResolved ToolResolution


type ToolResolution
    = ToolApproved
    | ToolRejected
    | ToolReturned
    | ToolInterrupted


type Phase
    = Idle
    | Connecting
    | Streaming
    | AwaitingTool
    | Canceled
    | Failed


type Remote a
    = NotAsked
    | Loading
    | LoadFailed String
    | Loaded a


type OptionalRemote a
    = OptionalIdle
    | OptionalLoading
    | OptionalUnavailable String
    | OptionalFailed String
    | OptionalLoaded a


type alias IncarnationView =
    { id : String
    , name : String
    , direction : String
    , promptRevision : Maybe String
    , impressionModel : Maybe String
    , revision : Int
    , status : String
    , created : Int
    , updated : Int
    }


type alias ImpressionItemView =
    { id : String
    , label : String
    , intuition : String
    , strength : Float
    , sourceMemoryIds : List String
    , sourceExperienceRefs : List String
    , updated : Int
    }


type alias ImpressionStateView =
    { incarnationId : String
    , revision : Int
    , items : List ImpressionItemView
    , generatorRevision : String
    , effectiveHash : String
    , updated : Int
    }


type alias ImpressionCueView =
    { hint : String
    , suggestedQuery : Maybe String
    , memoryIds : List String
    , confidence : Float
    , reason : String
    }


type alias ImpressionActivationView =
    { id : String
    , incarnationId : String
    , taskId : String
    , runId : String
    , intentId : String
    , intent : String
    , stateRevision : Int
    , cues : List ImpressionCueView
    , injectedText : String
    , generatorRevision : String
    , modelInvocationId : String
    , model : String
    , error : Maybe String
    , created : Int
    }


type alias ImpressionMemoryProposalView =
    { content : String
    , kind : String
    , visibility : String
    , sourceRefs : List String
    , reason : String
    }


type alias ImpressionRevisionView =
    { id : String
    , incarnationId : String
    , experienceRef : String
    , beforeRevision : Int
    , afterRevision : Int
    , reason : String
    , memoryProposals : List ImpressionMemoryProposalView
    , voidProposals : List String
    , modelInvocationId : String
    , model : String
    , created : Int
    }


type alias MemorySnippetView =
    { id : String
    , revision : Int
    , owner : String
    , visibility : String
    , kind : String
    , snippet : String
    , keywords : List String
    , sourceRefs : List String
    , matches : List String
    }


type alias MemoryReceiptView =
    { id : String
    , incarnationId : String
    , action : String
    , query : Maybe String
    , spaces : List Decode.Value
    , records : List Decode.Value
    , created : Int
    }


type alias MemoryGrepView =
    { snippets : List MemorySnippetView
    , receipt : MemoryReceiptView
    }


type alias TaskRecordMemory =
    { catalog : OptionalRemote (List TaskArchiveSummary)
    , query : String
    , taskId : Maybe String
    , caseSensitive : Bool
    , searchScope : String
    , search : OptionalRemote TaskRecordSearchView
    , selected : Maybe TaskRecordHitView
    , reader : OptionalRemote TaskRecordContextView
    }


type alias TaskArchiveSummary =
    { incarnationId : String
    , taskId : String
    , runCount : Int
    , entryCount : Int
    , created : Int
    , updated : Int
    , preview : String
    }


type alias TaskRecordSearchView =
    { query : String
    , mode : String
    , caseSensitive : Bool
    , scannedTasks : Int
    , scannedEntries : Int
    , truncated : Bool
    , hits : List TaskRecordHitView
    }


type alias TaskRecordHitView =
    { entryId : String
    , taskId : String
    , runId : String
    , seq : Int
    , kind : String
    , sourceId : String
    , toolName : Maybe String
    , callId : Maybe String
    , lineNumber : Int
    , matchOffset : Int
    , excerpt : String
    , created : Int
    }


type alias TaskRecordContextView =
    { taskId : String
    , anchorEntryId : String
    , entries : List TaskRecordEntryView
    }


type alias TaskRecordEntryView =
    { entryId : String
    , taskId : String
    , runId : String
    , seq : Int
    , kind : String
    , sourceId : String
    , toolName : Maybe String
    , callId : Maybe String
    , content : String
    , contentOffset : Int
    , contentTotal : Int
    , truncatedBefore : Bool
    , truncatedAfter : Bool
    , created : Int
    }


type alias FocusFrameView =
    { id : String
    , incarnationId : String
    , taskId : String
    , revision : Int
    , status : String
    , epochId : String
    , objective : String
    , activeItems : List String
    , openLoops : List String
    , provisionalClaims : List String
    , recentOutcomeRefs : List String
    , artifactRefs : List String
    , cursor : Int
    , updated : Int
    }


type alias WorkingMemoryView =
    { id : String
    , incarnationId : String
    , revision : Int
    , status : String
    , cursor : Int
    , checkpointId : Maybe String
    , wakePacketId : Maybe String
    , activeTaskId : Maybe String
    , focusFrames : List FocusFrameView
    , degradedReason : Maybe String
    , created : Int
    , updated : Int
    }


type alias ForgetDecisionView =
    { subject : String
    , reason : String
    , sourceSegmentIds : List String
    }


type alias SleepCycleView =
    { id : String
    , incarnationId : String
    , taskId : String
    , runId : Maybe String
    , baseEpochId : String
    , trigger : String
    , status : String
    , expectedRevision : Int
    , frozenCursor : Int
    , forgotten : List ForgetDecisionView
    , checkpointId : Maybe String
    , wakePacketId : Maybe String
    , replayCursor : Maybe Int
    , failure : Maybe String
    , created : Int
    , updated : Int
    }


type alias PromptRevisionView =
    { id : String
    , incarnationId : Maybe String
    , layer : String
    , sourceIntent : String
    , content : String
    , generatorRevision : String
    , modelInvocationRef : Maybe String
    , parentRevision : Maybe String
    , ordinal : Int
    , status : String
    , effectiveHash : String
    , created : Int
    }


type alias PromptEditor =
    { root : Bool
    , baseId : String
    , sourceIntent : String
    , content : String
    , saving : Bool
    }


type alias Inspection =
    { brief : Remote Brief
    , facts : Remote (List Fact)
    , artifacts : Remote (List ArtifactMeta)
    , artifactBodies : Dict String (Remote String)
    , runs : Remote (List String)
    , summaries : Dict String (Remote RunSummary)
    , runFilter : String
    , selectedRun : Maybe String
    , facet : Facet
    , runLogs : Dict String (Remote (List JournalRow))
    , replay : Remote ReplayReport
    , verdicts : Dict String Bool
    , showDeltas : Bool
    }


type Facet
    = FacetConversation
    | FacetEvents
    | FacetApi
    | FacetMemory
    | FacetEntries


type alias RunSummary =
    { runId : String
    , threadId : String
    , entryCount : Int
    , turns : Int
    , toolCalls : Int
    , agentEvents : Int
    , apiRequests : Int
    , usagePrompt : Int
    , usageCompletion : Int
    , usageCacheHit : Int
    , memoryCalls : Int
    , status : String
    , firstSeq : Int
    , lastSeq : Int
    , firstTime : Maybe Int
    , lastTime : Maybe Int
    }


type alias JournalRow =
    { seq : Int
    , scope : List String
    , kind : String
    , time : Maybe Int
    , event : Maybe Decode.Value
    , request : Maybe Decode.Value
    , input : Maybe Decode.Value
    , name : Maybe String
    , arguments : Maybe String
    , outcome : Maybe Decode.Value
    }


type alias Brief =
    { rollingSummary : String
    , episodes : List Episode
    }


type alias Episode =
    { runId : String
    , summary : String
    , time : Int
    }


type alias Fact =
    { id : String
    , content : String
    , kind : String
    , useCount : Int
    , archived : Bool
    , void : Bool
    }


type alias ArtifactMeta =
    { id : String
    , toolName : String
    , preview : String
    , chars : Int
    , time : Int
    }


type alias InspectionResult =
    { kind : String
    , status : Int
    , body : Decode.Value
    }


emptyTaskRecordMemory : TaskRecordMemory
emptyTaskRecordMemory =
    { catalog = OptionalIdle
    , query = ""
    , taskId = Nothing
    , caseSensitive = False
    , searchScope = ""
    , search = OptionalIdle
    , selected = Nothing
    , reader = OptionalIdle
    }


emptyInspection : Inspection
emptyInspection =
    { brief = NotAsked
    , facts = NotAsked
    , artifacts = NotAsked
    , artifactBodies = Dict.empty
    , runs = NotAsked
    , summaries = Dict.empty
    , runFilter = ""
    , selectedRun = Nothing
    , facet = FacetConversation
    , runLogs = Dict.empty
    , replay = NotAsked
    , verdicts = Dict.empty
    , showDeltas = False
    }


type Msg
    = DraftChanged String
    | InsertPath String
    | EndpointChanged String
    | Submit
    | RetryLast
    | CopyLastAnswer
    | ScrollLatest
    | Queue ControlKind
    | PromptSelected String
    | Cancel
    | SelectTab Tab
    | SwitchIncarnation String
    | SelectMemoryPane MemoryPane
    | RefreshImpression
    | SelectMemoryRecordMode MemoryRecordMode
    | RefreshTaskRecordCatalog
    | TaskRecordQueryChanged String
    | TaskRecordTaskChanged String
    | TaskRecordCaseSensitiveChanged Bool
    | SearchTaskRecords
    | OpenTaskRecordHit TaskRecordHitView
    | ReadTaskRecordChunk Int Int
    | CloseTaskRecordReader
    | ContinueTaskRecord String
    | LongMemoryQueryChanged String
    | SearchLongMemory
    | RefreshWorkingMemory
    | RefreshPrompts
    | GeneratePromptDraft
    | ActivatePromptRevision String
    | ActivateRootPromptRevision String Int
    | BeginPromptEdit Bool PromptRevisionView
    | PromptEditSourceChanged String
    | PromptEditContentChanged String
    | CancelPromptEdit
    | SavePromptEdit
    | SelfNameChanged String
    | SelfDirectionChanged String
    | SelfImpressionModelChanged String
    | SaveSelf
    | RequestArchiveIncarnation
    | CancelArchiveIncarnation
    | ConfirmArchiveIncarnation
    | RestoreIncarnation String Int
    | OpenIncarnationForm
    | CloseIncarnationForm
    | IncarnationIdChanged String
    | IncarnationNameChanged String
    | IncarnationDirectionChanged String
    | IncarnationModelChanged String
    | SubmitIncarnationForm
    | OpenSessionForm
    | CloseSessionForm
    | SessionTitleChanged String
    | SessionCwdChanged String
    | SessionToggle SessionField
    | SubmitSessionForm
    | RefreshSessions
    | ToggleArchivedSessions
    | SwitchSession String
    | SessionRenameChanged String
    | RenameCurrentSession
    | ArchiveSession String
    | RestoreSession String
    | ForkNodeChanged String
    | ForkCurrentSession
    | ExportCurrentSession
    | ImportSessionRequested
    | ImportSessionReceived Decode.Value
    | RequestCompact
    | CancelCompact
    | ConfirmCompact
    | ConfigCwdModeChanged CwdMode
    | ConfigCwdChanged String
    | ConfigPromptChanged String
    | ConfigProviderChanged String
    | ConfigModelChanged String
    | ConfigEffortChanged String
    | QuickModelSelected String
    | QuickEffortSelected String
    | ConfigContextReserveChanged String
    | ConfigContextKeepChanged String
    | ConfigContextSummaryChanged String
    | ConfigGate SessionField (Maybe Bool)
    | SaveConfig
    | ConfigFlashDone
    | RefreshTree
    | ResolveTool String Bool
    | AgentEventReceived Decode.Value
    | TransportEventReceived Decode.Value
    | TranscriptFollowChanged Bool
    | RefreshMemory
    | RefreshArtifacts
    | RefreshAudit
    | AuditNow Time.Posix
    | SelectRun String
    | SelectFacet Facet
    | RunFilterChanged String
    | ToggleArtifact String
    | ReplaySelected
    | ToggleDeltas
    | InspectionReceived Decode.Value


type AgentEvent
    = RunStarted String String
    | RunFinished String String
    | RunError String (Maybe String)
    | StepStarted String
    | StepFinished String
    | TextStarted String
    | TextContent String String
    | TextEnded String
    | ReasoningStarted ReasoningScope String
    | ReasoningContent String String
    | ReasoningEnded ReasoningScope String
    | ToolStarted String String (Maybe String)
    | ToolArguments String String
    | ToolEnded String
    | ToolResult String String String
    | StateObserved StateKind
    | ActivityObserved ActivityKind
    | ContextInject String
    | UsageObserved Usage
    | ShellOutput String String String
    | ProviderRetry Int Int Int String
    | ContextSplice Int Int Int
    | ContextStatus ContextGauge
    | ContextCompact Int Int Int Int Int Bool
    | SteeringInject Int Int
    | FollowUpInject Int Int
    | RunCancelled String
    | AgentSub String String Decode.Value
    | CustomObserved String
    | RawObserved
    | UnknownEvent String


type ReasoningScope
    = RunScope
    | MessageScope


type StateKind
    = StateSnapshot
    | StateDelta
    | MessagesSnapshot


type ActivityKind
    = ActivitySnapshot
    | ActivityDelta


type TransportSignal
    = TransportConnecting String
    | TransportOpen String
    | TransportClosed String
    | TransportCancelled String
    | TransportFailed String String


type ControlKind
    = SteerControl
    | FollowUpControl


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        }


init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        fallback =
            fallbackIncarnation flags.incarnationId

        model =
            { endpoint = flags.endpoint
            , incarnationId = flags.incarnationId
            , incarnation = fallback
            , incarnations = OptionalLoading
            , incarnationNotice = Nothing
            , selfNameDraft = fallback.name
            , selfDirectionDraft = fallback.direction
            , selfImpressionModelDraft = ""
            , savingSelf = False
            , selfMessage = Nothing
            , incarnationArchiveConfirm = False
            , archivingIncarnation = False
            , restoringIncarnation = Nothing
            , threadBase = flags.threadId
            , threadId = flags.threadId
            , currentTaskBelongs = False
            , threadNumber = 0
            , runStamp = flags.runStamp
            , draft = ""
            , pathSuggestions = []
            , messages = Dict.empty
            , messageOrder = []
            , tools = Dict.empty
            , phase = Idle
            , activeRun = Nothing
            , runNumber = 0
            , nextId = 1
            , terminalSeen = False
            , error = Nothing
            , activeStep = Nothing
            , stickToBottom = True
            , inspection = emptyInspection
            , tab = NowTab
            , memoryPane = ImpressionPane
            , impression = OptionalIdle
            , impressionActivations = OptionalIdle
            , impressionRevisions = OptionalIdle
            , memoryRecordMode = TaskRecordMode
            , taskRecords = emptyTaskRecordMemory
            , longMemoryQuery = ""
            , longMemorySearch = OptionalIdle
            , workingMemory = OptionalIdle
            , sleepCycles = OptionalIdle
            , rootPrompts = OptionalIdle
            , prompts = OptionalIdle
            , generatingPrompt = False
            , activatingPrompt = Nothing
            , promptEditor = Nothing
            , promptMessage = Nothing
            , usage = Nothing
            , contextGauge = Nothing
            , compactConfirm = False
            , compacting = False
            , compactMessage = Nothing
            , tree = Loading
            , sessions = Loading
            , showArchived = False
            , pendingSwitch = Nothing
            , sessionTitleDraft = ""
            , forkNodeDraft = ""
            , sessionActionError = Nothing
            , sessionForm = Nothing
            , incarnationForm = Nothing
            , configPanel = emptyConfigPanel
            , now = Nothing
            }

        ( configured, configCmd ) =
            ensureConfigLoaded model
    in
    ( configured
    , Cmd.batch
        [ sessionsCmd model
        , treeCmd model
        , transcriptCmd model
        , configCmd
        , incarnationsCmd model
        , incarnationCmd model flags.incarnationId
        ]
    )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ agentEvent AgentEventReceived
        , transportEvent TransportEventReceived
        , inspectionResult InspectionReceived
        , sessionImportData ImportSessionReceived
        , transcriptFollowChanged TranscriptFollowChanged
        ]


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        DraftChanged value ->
            updateDraft value model

        InsertPath path ->
            updateDraft (insertPathReference path model.draft) model

        EndpointChanged value ->
            ( { model | endpoint = value }, Cmd.none )

        Submit ->
            sendText model.draft model

        RetryLast ->
            retryLast model

        CopyLastAnswer ->
            ( model
            , Maybe.map copyText (lastAssistantText model)
                |> Maybe.withDefault Cmd.none
            )

        ScrollLatest ->
            ( { model | stickToBottom = True }, followTranscript () )

        Queue kind ->
            queueText kind model.draft model

        PromptSelected prompt ->
            sendText prompt model

        Cancel ->
            ( { model
                | phase = Canceled
                , activeStep = Nothing
                , error = Nothing
              }
            , cancelCurrent model
            )

        SelectTab tab ->
            case tab of
                CapabilitiesTab ->
                    if model.currentTaskBelongs then
                        ensureConfigLoaded { model | tab = tab }

                    else
                        ( { model | tab = tab }, Cmd.none )

                AuditTab ->
                    ( { model | tab = tab }, Task.perform AuditNow Time.now )

                MemoryTab ->
                    openMemoryPane model.memoryPane { model | tab = tab }

                NowTab ->
                    ( { model | tab = tab, stickToBottom = True }, followTranscript () )

                TasksTab ->
                    ( { model | tab = tab }, Cmd.none )

                SelfTab ->
                    openSelf { model | tab = tab }

        SwitchIncarnation identifier ->
            switchIncarnation identifier model

        SelectMemoryPane pane ->
            openMemoryPane pane { model | memoryPane = pane }

        RefreshImpression ->
            loadImpression model

        SelectMemoryRecordMode mode ->
            let
                changed =
                    { model | memoryRecordMode = mode }
            in
            case mode of
                TaskRecordMode ->
                    loadTaskRecordCatalog changed

                DistilledRecordMode ->
                    ( changed, Cmd.none )

        RefreshTaskRecordCatalog ->
            loadTaskRecordCatalog (mapTaskRecords (\state -> { state | catalog = OptionalIdle }) model)

        TaskRecordQueryChanged value ->
            ( mapTaskRecords
                (\state ->
                    { state
                        | query = value
                        , search = OptionalIdle
                        , selected = Nothing
                        , reader = OptionalIdle
                    }
                )
                model
            , Cmd.none
            )

        TaskRecordTaskChanged taskId ->
            ( mapTaskRecords
                (\state ->
                    { state
                        | taskId = nonEmpty taskId
                        , search = OptionalIdle
                        , selected = Nothing
                        , reader = OptionalIdle
                    }
                )
                model
            , Cmd.none
            )

        TaskRecordCaseSensitiveChanged enabled ->
            ( mapTaskRecords
                (\state ->
                    { state
                        | caseSensitive = enabled
                        , search = OptionalIdle
                        , selected = Nothing
                        , reader = OptionalIdle
                    }
                )
                model
            , Cmd.none
            )

        SearchTaskRecords ->
            searchTaskRecords model

        OpenTaskRecordHit hit ->
            readTaskRecord hit hit.matchOffset 6000 model

        ReadTaskRecordChunk offset chars ->
            model.taskRecords.selected
                |> Maybe.map (\hit -> readTaskRecord hit offset chars model)
                |> Maybe.withDefault ( model, Cmd.none )

        CloseTaskRecordReader ->
            ( mapTaskRecords (\state -> { state | selected = Nothing, reader = OptionalIdle }) model
            , Cmd.none
            )

        ContinueTaskRecord taskId ->
            continueTaskRecord taskId model

        LongMemoryQueryChanged value ->
            ( { model | longMemoryQuery = value }, Cmd.none )

        SearchLongMemory ->
            searchLongMemory model

        RefreshWorkingMemory ->
            loadWorkingMemory model

        RefreshPrompts ->
            loadPrompts model

        GeneratePromptDraft ->
            generatePromptDraft model

        ActivatePromptRevision identifier ->
            activatePromptRevision identifier model

        ActivateRootPromptRevision identifier expected ->
            activateRootPromptRevision identifier expected model

        BeginPromptEdit root revision ->
            ( { model
                | promptEditor =
                    Just
                        { root = root
                        , baseId = revision.id
                        , sourceIntent = "manual audit revision based on " ++ revision.id
                        , content = revision.content
                        , saving = False
                        }
                , promptMessage = Nothing
              }
            , Cmd.none
            )

        PromptEditSourceChanged value ->
            ( mapPromptEditor (\editor -> { editor | sourceIntent = value }) model, Cmd.none )

        PromptEditContentChanged value ->
            ( mapPromptEditor (\editor -> { editor | content = value }) model, Cmd.none )

        CancelPromptEdit ->
            ( { model | promptEditor = Nothing }, Cmd.none )

        SavePromptEdit ->
            savePromptEdit model

        SelfNameChanged value ->
            ( { model | selfNameDraft = value, selfMessage = Nothing }, Cmd.none )

        SelfDirectionChanged value ->
            ( { model | selfDirectionDraft = value, selfMessage = Nothing }, Cmd.none )

        SelfImpressionModelChanged value ->
            ( { model | selfImpressionModelDraft = value, selfMessage = Nothing }, Cmd.none )

        SaveSelf ->
            saveSelf model

        RequestArchiveIncarnation ->
            if model.incarnationId == "yuki" || isBusy model.phase || model.archivingIncarnation then
                ( model, Cmd.none )

            else
                ( { model | incarnationArchiveConfirm = True, selfMessage = Nothing }, Cmd.none )

        CancelArchiveIncarnation ->
            if model.archivingIncarnation then
                ( model, Cmd.none )

            else
                ( { model | incarnationArchiveConfirm = False }, Cmd.none )

        ConfirmArchiveIncarnation ->
            archiveIncarnation model

        RestoreIncarnation identifier revision ->
            restoreIncarnation identifier revision model

        OpenIncarnationForm ->
            ( { model
                | incarnationForm =
                    Just
                        { identifier = "yuki-" ++ String.right 5 model.runStamp
                        , name = ""
                        , direction = ""
                        , impressionModel = ""
                        , saving = False
                        , error = Nothing
                        }
              }
            , Cmd.none
            )

        CloseIncarnationForm ->
            ( { model | incarnationForm = Nothing }, Cmd.none )

        IncarnationIdChanged value ->
            ( mapIncarnationForm (\draft -> { draft | identifier = value, error = Nothing }) model, Cmd.none )

        IncarnationNameChanged value ->
            ( mapIncarnationForm (\draft -> { draft | name = value, error = Nothing }) model, Cmd.none )

        IncarnationDirectionChanged value ->
            ( mapIncarnationForm (\draft -> { draft | direction = value, error = Nothing }) model, Cmd.none )

        IncarnationModelChanged value ->
            ( mapIncarnationForm (\draft -> { draft | impressionModel = value, error = Nothing }) model, Cmd.none )

        SubmitIncarnationForm ->
            createIncarnation model

        OpenSessionForm ->
            let
                form =
                    { targetId = freshSessionId "thread" model
                    , title = ""
                    , cwd = ""
                    , fs = True
                    , shell = True
                    , memory = True
                    , global = Nothing
                    , session = Nothing
                    , prefilled = False
                    , saving = False
                    , error = Nothing
                    }
            in
            ( { model | sessionForm = Just form }
            , Cmd.batch
                [ fetchInspection model "session/global" "GET" Nothing "config"
                , fetchInspection model "session/thread" "GET" Nothing ("config/threads/" ++ model.threadId)
                ]
            )

        CloseSessionForm ->
            ( { model | sessionForm = Nothing }, Cmd.none )

        SessionTitleChanged value ->
            ( mapSessionForm (\form -> { form | title = value }) model, Cmd.none )

        SessionCwdChanged value ->
            ( mapSessionForm (\form -> { form | cwd = value }) model, Cmd.none )

        SessionToggle field ->
            ( mapSessionForm (toggleField field) model, Cmd.none )

        SubmitSessionForm ->
            case model.sessionForm of
                Just form ->
                    if form.saving || not form.prefilled then
                        ( model, Cmd.none )

                    else
                        ( { model | sessionForm = Just { form | saving = True, error = Nothing } }
                        , fetchInspection model
                            ("sessions/create/" ++ form.targetId)
                            "POST"
                            (Just
                                (Encode.object
                                    [ ( "threadId", Encode.string form.targetId )
                                    , ( "title", blankAsNull form.title )
                                    , ( "incarnationId", Encode.string model.incarnationId )
                                    ]
                                )
                            )
                            "threads"
                        )

                Nothing ->
                    ( model, Cmd.none )

        RefreshSessions ->
            ( { model | sessions = Loading, sessionActionError = Nothing }, sessionsCmd model )

        ToggleArchivedSessions ->
            ( { model | showArchived = not model.showArchived }, Cmd.none )

        SwitchSession threadId ->
            requestThreadSwitch threadId model

        SessionRenameChanged value ->
            ( { model | sessionTitleDraft = value }, Cmd.none )

        RenameCurrentSession ->
            let
                title =
                    String.trim model.sessionTitleDraft
            in
            if String.isEmpty title then
                ( model, Cmd.none )

            else
                ( { model | sessionActionError = Nothing }
                , fetchInspection model
                    ("sessions/rename/" ++ model.threadId)
                    "PATCH"
                    (Just (Encode.object [ ( "title", Encode.string title ) ]))
                    ("threads/" ++ model.threadId)
                )

        ArchiveSession threadId ->
            if threadId == model.threadId && isBusy model.phase then
                ( { model | sessionActionError = Just "运行中不能归档当前任务。" }, Cmd.none )

            else
                ( { model | sessionActionError = Nothing }
                , fetchInspection model ("sessions/archive/" ++ threadId) "POST" Nothing ("threads/" ++ threadId ++ "/archive")
                )

        RestoreSession threadId ->
            ( { model | sessionActionError = Nothing }
            , fetchInspection model ("sessions/restore/" ++ threadId) "POST" Nothing ("threads/" ++ threadId ++ "/restore")
            )

        ForkNodeChanged value ->
            ( { model | forkNodeDraft = value }, Cmd.none )

        ForkCurrentSession ->
            if isBusy model.phase then
                ( { model | sessionActionError = Just "请先结束当前运行。" }, Cmd.none )

            else
                let
                    target =
                        freshSessionId "fork" model

                    node =
                        String.trim model.forkNodeDraft

                    body =
                        Encode.object
                            ([ ( "threadId", Encode.string target ) ]
                                ++ (if String.isEmpty node then
                                        []

                                    else
                                        [ ( "messageId", Encode.string node ) ]
                                   )
                            )
                in
                ( { model | sessionActionError = Nothing }
                , fetchInspection model ("sessions/fork/" ++ target) "POST" (Just body) ("threads/" ++ model.threadId ++ "/fork")
                )

        ExportCurrentSession ->
            ( { model | sessionActionError = Nothing }
            , fetchInspection model ("sessions/export/" ++ model.threadId) "GET" Nothing ("threads/" ++ model.threadId ++ "/export")
            )

        ImportSessionRequested ->
            ( { model | sessionActionError = Nothing }, chooseSessionImport () )

        ImportSessionReceived body ->
            ( { model | sessionActionError = Nothing }
            , fetchInspection model "sessions/import" "POST" (Just body) "threads/import"
            )

        RequestCompact ->
            ( { model | compactConfirm = True, compactMessage = Nothing }, Cmd.none )

        CancelCompact ->
            ( { model | compactConfirm = False }, Cmd.none )

        ConfirmCompact ->
            if model.compacting || model.activeRun /= Nothing then
                ( model, Cmd.none )

            else
                ( { model | compacting = True, compactMessage = Nothing }
                , fetchInspection model
                    ("context/compact/" ++ model.threadId)
                    "POST"
                    (Just (Encode.object [ ( "reason", Encode.string "manual sleep requested from memory workspace" ) ]))
                    ("threads/" ++ model.threadId ++ "/sleep")
                )

        ConfigCwdChanged value ->
            ( mapConfigDraft (\draft -> { draft | cwd = value, cwdMode = CwdPath }) model, Cmd.none )

        ConfigCwdModeChanged mode ->
            ( mapConfigDraft (\draft -> { draft | cwdMode = mode }) model, Cmd.none )

        ConfigPromptChanged value ->
            ( mapConfigDraft (\draft -> { draft | systemPrompt = value }) model, Cmd.none )

        ConfigProviderChanged value ->
            ( mapConfigDraft (selectProviderDraft model.configPanel.providers value) model, Cmd.none )

        ConfigModelChanged value ->
            ( mapConfigDraft (\draft -> { draft | model = value }) model, Cmd.none )

        ConfigEffortChanged value ->
            ( mapConfigDraft (\draft -> { draft | reasoningEffort = value }) model, Cmd.none )

        QuickModelSelected value ->
            quickSelectModel value model

        QuickEffortSelected value ->
            quickSelectEffort value model

        ConfigContextReserveChanged value ->
            ( mapConfigDraft (\draft -> { draft | contextReserveTokens = value }) model, Cmd.none )

        ConfigContextKeepChanged value ->
            ( mapConfigDraft (\draft -> { draft | contextKeepUnits = value }) model, Cmd.none )

        ConfigContextSummaryChanged value ->
            ( mapConfigDraft (\draft -> { draft | contextSummaryTokens = value }) model, Cmd.none )

        ConfigGate field value ->
            ( mapConfigDraft (setGate field value) model, Cmd.none )

        SaveConfig ->
            saveConfig model

        ConfigFlashDone ->
            ( mapConfigPanel (\panel -> { panel | saved = False }) model, Cmd.none )

        RefreshTree ->
            ( { model | tree = Loading }, treeCmd model )

        ResolveTool callId approved ->
            resolveFrontendTool callId approved model

        AgentEventReceived raw ->
            receiveAgentEvent raw model

        TransportEventReceived raw ->
            receiveTransportEvent raw model

        RefreshMemory ->
            loadImpression model

        RefreshArtifacts ->
            let
                inspection =
                    model.inspection
            in
            ( { model | inspection = { inspection | artifacts = Loading } }
            , fetchInspection model "artifacts" "GET" Nothing "artifacts"
            )

        RefreshAudit ->
            let
                inspection =
                    model.inspection
            in
            ( { model
                | inspection =
                    { inspection
                        | runs = Loading
                        , summaries = Dict.empty
                        , runLogs = Dict.map (\_ _ -> Loading) inspection.runLogs
                    }
              }
            , Cmd.batch
                (fetchInspection model "runs" "GET" Nothing "journal/runs"
                    :: Task.perform AuditNow Time.now
                    :: journalRefresh model
                )
            )

        AuditNow moment ->
            ( { model | now = Just moment }, Cmd.none )

        SelectRun runId ->
            let
                inspection =
                    model.inspection
            in
            if inspection.selectedRun == Just runId then
                ( { model | inspection = { inspection | selectedRun = Nothing } }, Cmd.none )

            else
                let
                    fresh =
                        case Dict.get runId inspection.runLogs of
                            Just (Loaded _) ->
                                False

                            Just Loading ->
                                False

                            _ ->
                                True
                in
                ( { model
                    | inspection =
                        { inspection
                            | selectedRun = Just runId
                            , replay = NotAsked
                            , runLogs =
                                if fresh then
                                    Dict.insert runId Loading inspection.runLogs

                                else
                                    inspection.runLogs
                        }
                  }
                , if fresh then
                    journalCmd model runId

                  else
                    Cmd.none
                )

        SelectFacet facet ->
            let
                inspection =
                    model.inspection
            in
            ( { model | inspection = { inspection | facet = facet } }, Cmd.none )

        ReplaySelected ->
            case model.inspection.selectedRun of
                Nothing ->
                    ( model, Cmd.none )

                Just runId ->
                    let
                        inspection =
                            model.inspection
                    in
                    ( { model | inspection = { inspection | replay = Loading } }
                    , fetchInspection model ("replay/" ++ runId) "POST" (Just (Encode.object [ ( "runId", Encode.string runId ) ])) "replay"
                    )

        RunFilterChanged value ->
            let
                inspection =
                    model.inspection
            in
            ( { model | inspection = { inspection | runFilter = value } }, Cmd.none )

        ToggleArtifact identifier ->
            toggleArtifact identifier model

        ToggleDeltas ->
            let
                inspection =
                    model.inspection
            in
            ( { model | inspection = { inspection | showDeltas = not inspection.showDeltas } }, Cmd.none )

        InspectionReceived raw ->
            case Decode.decodeValue inspectionResultDecoder raw of
                Err _ ->
                    ( model, Cmd.none )

                Ok result ->
                    applyInspection result model

        TranscriptFollowChanged following ->
            ( { model | stickToBottom = following }, Cmd.none )


type alias PathCompletion =
    { prefix : String
    , paths : List String
    }


updateDraft : String -> Model -> ( Model, Cmd Msg )
updateDraft value model =
    case pathReferencePrefix value of
        Nothing ->
            ( { model | draft = value, pathSuggestions = [] }, Cmd.none )

        Just prefix ->
            ( { model | draft = value, pathSuggestions = [] }
            , fetchInspection model
                "paths"
                "POST"
                (Just (Encode.object [ ( "prefix", Encode.string prefix ) ]))
                ("config/threads/" ++ model.threadId ++ "/paths")
            )


pathReferencePrefix : String -> Maybe String
pathReferencePrefix value =
    String.indexes "@" value
        |> List.reverse
        |> List.head
        |> Maybe.andThen
            (\index ->
                let
                    suffix =
                        String.dropLeft (index + 1) value

                    boundary =
                        index == 0 || String.all isWhitespace (String.slice (index - 1) index value)
                in
                if boundary && not (String.startsWith "\"" suffix) && not (String.any isWhitespace suffix) then
                    Just suffix

                else
                    Nothing
            )


insertPathReference : String -> String -> String
insertPathReference path draft =
    case pathReferencePrefix draft of
        Nothing ->
            draft

        Just prefix ->
            let
                start =
                    String.length draft - String.length prefix - 1

                reference =
                    if String.any isWhitespace path then
                        "@\"" ++ path ++ "\""

                    else
                        "@" ++ path

                suffix =
                    if String.endsWith "/" path then
                        ""

                    else
                        " "
            in
            String.left start draft ++ reference ++ suffix


isWhitespace : Char -> Bool
isWhitespace char =
    List.member char [ ' ', '\n', '\r', '\t' ]


retryLast : Model -> ( Model, Cmd Msg )
retryLast model =
    if isBusy model.phase || hasPendingFrontendTool model then
        ( model, Cmd.none )

    else
        case retryPrefix model of
            Nothing ->
                ( model, Cmd.none )

            Just prefix ->
                startRun { prefix | error = Nothing, pathSuggestions = [] }


retryPrefix : Model -> Maybe Model
retryPrefix model =
    lastUserIndex model
        |> Maybe.map
            (\index ->
                let
                    order =
                        List.take (index + 1) model.messageOrder

                    messageIds =
                        Set.fromList order

                    toolIds =
                        order
                            |> List.filterMap (\identifier -> Dict.get identifier model.messages)
                            |> List.concatMap referencedTools
                            |> Set.fromList
                in
                { model
                    | messageOrder = order
                    , messages = Dict.filter (\identifier _ -> Set.member identifier messageIds) model.messages
                    , tools = Dict.filter (\identifier _ -> Set.member identifier toolIds) model.tools
                }
            )


lastUserIndex : Model -> Maybe Int
lastUserIndex model =
    model.messageOrder
        |> List.indexedMap Tuple.pair
        |> List.filter
            (\( _, identifier ) ->
                case Dict.get identifier model.messages of
                    Just (UserChat _ _) ->
                        True

                    _ ->
                        False
            )
        |> List.reverse
        |> List.head
        |> Maybe.map Tuple.first


referencedTools : ChatMessage -> List String
referencedTools message =
    case message of
        AssistantChat assistant ->
            assistant.toolCalls

        _ ->
            []


lastAssistantText : Model -> Maybe String
lastAssistantText model =
    orderedMessages model
        |> List.reverse
        |> List.filterMap
            (\message ->
                case message of
                    AssistantChat assistant ->
                        if String.isEmpty (String.trim assistant.content) then
                            Nothing

                        else
                            Just assistant.content

                    _ ->
                        Nothing
            )
        |> List.head


sendText : String -> Model -> ( Model, Cmd Msg )
sendText raw model =
    let
        content =
            String.trim raw
    in
    if String.isEmpty content || isBusy model.phase || hasPendingFrontendTool model then
        ( model, Cmd.none )

    else
        let
            ( identifier, identified ) =
                freshId "user" model

            next =
                { identified
                    | draft = ""
                    , pathSuggestions = []
                    , messages = Dict.insert identifier (UserChat identifier content) identified.messages
                    , messageOrder = identified.messageOrder ++ [ identifier ]
                }
        in
        startRun next


queueText : ControlKind -> String -> Model -> ( Model, Cmd Msg )
queueText kind raw model =
    let
        content =
            String.trim raw
    in
    case model.activeRun of
        Just runId ->
            if String.isEmpty content || not (isBusy model.phase) || hasPendingFrontendTool model then
                ( model, Cmd.none )

            else
                let
                    ( identifier, identified ) =
                        freshId "user" model

                    action =
                        controlAction kind

                    next =
                        { identified
                            | draft = ""
                            , pathSuggestions = []
                            , messages = Dict.insert identifier (UserChat identifier content) identified.messages
                            , messageOrder = identified.messageOrder ++ [ identifier ]
                            , error = Nothing
                        }

                    body =
                        Encode.object
                            [ ( "runId", Encode.string runId )
                            , ( "text", Encode.string content )
                            ]
                in
                ( next
                , Cmd.batch
                    [ fetchInspection next
                        ("control/" ++ action ++ "/" ++ runId ++ "/" ++ identifier)
                        "POST"
                        (Just body)
                        ("agent/" ++ action)
                    , followTranscript ()
                    ]
                )

        Nothing ->
            ( model, Cmd.none )


controlAction : ControlKind -> String
controlAction kind =
    case kind of
        SteerControl ->
            "steer"

        FollowUpControl ->
            "follow-up"


cancelCurrent : Model -> Cmd Msg
cancelCurrent model =
    case model.activeRun of
        Just runId ->
            cancelAgent <|
                Encode.object
                    [ ( "endpoint", Encode.string (String.trim model.endpoint) )
                    , ( "runId", Encode.string runId )
                    ]

        Nothing ->
            Cmd.none


startRun : Model -> ( Model, Cmd Msg )
startRun model =
    let
        number =
            model.runNumber + 1

        runId =
            model.threadId ++ "-" ++ model.runStamp ++ "-run-" ++ String.fromInt number

        next =
            { model
                | phase = Connecting
                , activeRun = Just runId
                , runNumber = number
                , terminalSeen = False
                , error = Nothing
                , activeStep = Nothing
                , stickToBottom = True
                , usage = Nothing
              }
    in
    ( next, Cmd.batch [ runAgent (encodeCommand runId next), followTranscript () ] )


resolveFrontendTool : String -> Bool -> Model -> ( Model, Cmd Msg )
resolveFrontendTool callId approved model =
    case Dict.get callId model.tools of
        Nothing ->
            ( model, Cmd.none )

        Just tool ->
            if tool.name /= confirmationToolName || tool.stage /= ToolWaiting then
                ( model, Cmd.none )

            else
                let
                    content =
                        Encode.encode 0 <|
                            Encode.object
                                [ ( "approved", Encode.bool approved )
                                , ( "decision"
                                  , Encode.string <|
                                        if approved then
                                            "approved"

                                        else
                                            "rejected"
                                  )
                                ]

                    ( identifier, identified ) =
                        freshId "tool-result" model

                    next =
                        { identified
                            | messages =
                                Dict.insert identifier
                                    (ToolChat
                                        { id = identifier
                                        , callId = callId
                                        , content = content
                                        }
                                    )
                                    identified.messages
                            , messageOrder = identified.messageOrder ++ [ identifier ]
                            , tools =
                                Dict.insert callId
                                    { tool
                                        | stage = ToolResolved (if approved then ToolApproved else ToolRejected)
                                        , result = Just content
                                    }
                                    identified.tools
                        }
                in
                startRun next


receiveAgentEvent : Decode.Value -> Model -> ( Model, Cmd Msg )
receiveAgentEvent raw model =
    case decodeAgentEvent raw of
        Err message ->
            ( { model
                | phase = Failed
                , error = Just ("协议事件无法解码：" ++ message)
                , terminalSeen = True
              }
            , cancelCurrent model
            )

        Ok event ->
            let
                applied =
                    if model.phase == Failed then
                        model

                    else
                        applyAgentEvent event model

                terminal =
                    case event of
                        RunFinished _ _ ->
                            True

                        RunError _ _ ->
                            True

                        _ ->
                            False

                ( next, inspectionCmd ) =
                    if terminal then
                        ( { applied | inspection = markLoading applied.inspection, tree = Loading }
                        , Cmd.batch [ inspectionRefreshCmds applied, treeCmd applied, Task.perform AuditNow Time.now ]
                        )

                    else
                        ( applied, Cmd.none )
            in
            ( next, inspectionCmd )


receiveTransportEvent : Decode.Value -> Model -> ( Model, Cmd Msg )
receiveTransportEvent raw model =
    case Decode.decodeValue transportDecoder raw of
        Err error ->
            ( { model
                | phase = Failed
                , error = Just ("传输状态无法解码：" ++ Decode.errorToString error)
              }
            , Cmd.none
            )

        Ok signal ->
            case signal of
                TransportConnecting runId ->
                    ( { model | phase = Connecting, activeRun = Just runId }, Cmd.none )

                TransportOpen runId ->
                    ( { model | phase = Streaming, activeRun = Just runId }, Cmd.none )

                TransportClosed runId ->
                    if model.activeRun == Just runId && not model.terminalSeen then
                        ( { model
                            | phase = Failed
                            , activeRun = Nothing
                            , error = Just "SSE 流在终止事件前关闭。"
                          }
                        , Cmd.none
                        )

                    else
                        ( model, Cmd.none )

                TransportCancelled runId ->
                    if model.activeRun == Just runId then
                        ( { model
                            | phase = Canceled
                            , activeRun = Nothing
                            , activeStep = Nothing
                          }
                        , Cmd.none
                        )

                    else
                        ( model, Cmd.none )

                TransportFailed runId message ->
                    if model.activeRun == Just runId then
                        ( { model
                            | phase = Failed
                            , activeRun = Nothing
                            , activeStep = Nothing
                            , error = Just message
                          }
                        , Cmd.none
                        )

                    else
                        ( model, Cmd.none )


applyAgentEvent : AgentEvent -> Model -> Model
applyAgentEvent event model =
    case event of
        RunStarted threadId runId ->
            { model
                | phase = Streaming
                , activeRun = Just runId
                , error =
                    if threadId == model.threadId then
                        Nothing

                    else
                        Just "后端返回了不匹配的 threadId。"
            }

        RunFinished _ _ ->
            { model
                | phase =
                    if hasPendingFrontendTool model then
                        AwaitingTool

                    else
                        Idle
                , activeRun = Nothing
                , activeStep = Nothing
                , terminalSeen = True
            }

        RunError message code ->
            { model
                | phase = Failed
                , activeRun = Nothing
                , activeStep = Nothing
                , terminalSeen = True
                , error = Just (Maybe.withDefault "RUN_ERROR" code ++ " · " ++ message)
            }

        StepStarted name ->
            { model | activeStep = Just name }

        StepFinished _ ->
            { model | activeStep = Nothing }

        TextStarted messageId ->
            ensureAssistant messageId model

        TextContent messageId delta ->
            mapAssistant messageId
                (\message -> { message | content = message.content ++ delta })
                (ensureAssistant messageId model)

        TextEnded messageId ->
            mapAssistant messageId
                (\message -> { message | complete = True })
                model

        ReasoningStarted _ messageId ->
            ensureReasoning messageId model

        ReasoningContent messageId delta ->
            mapReasoning messageId
                (\message -> { message | content = message.content ++ delta })
                (ensureReasoning messageId model)

        ReasoningEnded _ messageId ->
            mapReasoning messageId
                (\message -> { message | complete = True })
                model

        ToolStarted callId name parentId ->
            let
                linked =
                    case parentId of
                        Just parent ->
                            model
                                |> ensureAssistant parent
                                |> mapAssistant parent (referenceTool callId)

                        Nothing ->
                            model
            in
            { linked
                | tools =
                    Dict.insert callId
                        { id = callId
                        , name = name
                        , arguments = ""
                        , parentMessageId = parentId
                        , stage = ToolStreaming
                        , output = ""
                        , result = Nothing
                        }
                        linked.tools
            }

        ToolArguments callId delta ->
            mapTool callId
                (\tool -> { tool | arguments = tool.arguments ++ delta })
                model

        ToolEnded callId ->
            mapTool callId (\tool -> { tool | stage = ToolWaiting }) model

        ToolResult messageId callId content ->
            let
                withTool =
                    mapTool callId
                        (\tool ->
                            { tool
                                | stage = ToolResolved ToolReturned
                                , result = Just content
                            }
                        )
                        model
            in
            if Dict.member messageId withTool.messages then
                withTool

            else
                { withTool
                    | messages =
                        Dict.insert messageId
                            (ToolChat
                                { id = messageId
                                , callId = callId
                                , content = content
                                }
                            )
                            withTool.messages
                    , messageOrder = withTool.messageOrder ++ [ messageId ]
                }

        ContextInject content ->
            let
                ( identifier, identified ) =
                    freshId "memory" model
            in
            { identified
                | messages = Dict.insert identifier (MemoryChat identifier content) identified.messages
                , messageOrder = identified.messageOrder ++ [ identifier ]
            }

        UsageObserved usage ->
            { model | usage = Just usage }

        StateObserved _ ->
            model

        ActivityObserved _ ->
            model

        ShellOutput callId _ delta ->
            mapTool callId (\tool -> { tool | output = capTail 4000 (tool.output ++ delta) }) model

        ProviderRetry attempt maxAttempts delayMs reason ->
            appendNotice (retryNotice attempt maxAttempts delayMs reason) model

        ContextSplice stubbed savedChars keep ->
            appendNotice (spliceNotice stubbed savedChars keep) model

        ContextStatus gauge ->
            { model | contextGauge = Just gauge }

        ContextCompact step before after budget dropped emergency ->
            let
                updated =
                    appendNotice (compactNotice step before after budget dropped emergency) model
            in
            { updated | contextGauge = Just (ContextGauge after budget False emergency Nothing Nothing Nothing) }

        SteeringInject step count ->
            appendNotice (steeringNotice step count) model

        FollowUpInject step count ->
            appendNotice (followUpNotice step count) model

        RunCancelled _ ->
            appendNotice "run cancelled" model

        AgentSub _ callId nested ->
            let
                key =
                    "sub/" ++ callId

                applySub transform =
                    mapSub key transform (ensureSub key callId model)
            in
            case classifySubEvent nested of
                SubDelta delta ->
                    applySub (\sub -> { sub | content = sub.content ++ delta, status = "正在回复" })

                SubFailed message ->
                    applySub (\sub -> { sub | failed = True, error = Just message, status = "失败" })

                SubStatus status ->
                    applySub (\sub -> { sub | status = status })

                SubActivity activity ->
                    applySub (\sub -> { sub | activity = pushActivity activity sub.activity })

                SubContext gauge ->
                    applySub (\sub -> { sub | context = Just gauge })

                SubCompacted step before after budget dropped emergency ->
                    applySub
                        (\sub ->
                            { sub
                                | activity = pushActivity (compactNotice step before after budget dropped emergency) sub.activity
                                , context = Just (ContextGauge after budget False emergency Nothing Nothing Nothing)
                            }
                        )

                SubIgnored ->
                    model

        CustomObserved _ ->
            model

        RawObserved ->
            model

        UnknownEvent _ ->
            model


ensureAssistant : String -> Model -> Model
ensureAssistant identifier model =
    if Dict.member identifier model.messages then
        model

    else
        { model
            | messages =
                Dict.insert identifier
                    (AssistantChat
                        { id = identifier
                        , content = ""
                        , toolCalls = []
                        , complete = False
                        }
                    )
                    model.messages
            , messageOrder = model.messageOrder ++ [ identifier ]
        }


ensureReasoning : String -> Model -> Model
ensureReasoning identifier model =
    if Dict.member identifier model.messages then
        model

    else
        { model
            | messages =
                Dict.insert identifier
                    (ReasoningChat
                        { id = identifier
                        , content = ""
                        , complete = False
                        }
                    )
                    model.messages
            , messageOrder = model.messageOrder ++ [ identifier ]
        }


mapAssistant : String -> (AssistantMessage -> AssistantMessage) -> Model -> Model
mapAssistant identifier transform model =
    { model
        | messages =
            Dict.update identifier
                (Maybe.map
                    (\chat ->
                        case chat of
                            AssistantChat assistant ->
                                AssistantChat (transform assistant)

                            other ->
                                other
                    )
                )
                model.messages
    }


mapReasoning : String -> (ReasoningMessage -> ReasoningMessage) -> Model -> Model
mapReasoning identifier transform model =
    { model
        | messages =
            Dict.update identifier
                (Maybe.map
                    (\chat ->
                        case chat of
                            ReasoningChat reasoning ->
                                ReasoningChat (transform reasoning)

                            other ->
                                other
                    )
                )
                model.messages
    }


referenceTool : String -> AssistantMessage -> AssistantMessage
referenceTool callId message =
    { message
        | toolCalls =
            if List.member callId message.toolCalls then
                message.toolCalls

            else
                message.toolCalls ++ [ callId ]
    }


mapTool : String -> (ToolCall -> ToolCall) -> Model -> Model
mapTool identifier transform model =
    { model | tools = Dict.update identifier (Maybe.map transform) model.tools }


appendNotice : String -> Model -> Model
appendNotice content model =
    let
        ( identifier, identified ) =
            freshId "notice" model
    in
    { identified
        | messages = Dict.insert identifier (NoticeChat identifier content) identified.messages
        , messageOrder = identified.messageOrder ++ [ identifier ]
    }


ensureSub : String -> String -> Model -> Model
ensureSub identifier callId model =
    if Dict.member identifier model.messages then
        model

    else
        { model
            | messages =
                Dict.insert identifier
                    (SubAgentChat
                        { id = identifier
                        , callId = callId
                        , content = ""
                        , failed = False
                        , error = Nothing
                        , status = "等待启动"
                        , activity = []
                        , context = Nothing
                        }
                    )
                    model.messages
            , messageOrder = model.messageOrder ++ [ identifier ]
        }


mapSub : String -> (SubMessage -> SubMessage) -> Model -> Model
mapSub identifier transform model =
    { model
        | messages =
            Dict.update identifier
                (Maybe.map
                    (\chat ->
                        case chat of
                            SubAgentChat sub ->
                                SubAgentChat (transform sub)

                            other ->
                                other
                    )
                )
                model.messages
    }


type SubEvent
    = SubDelta String
    | SubFailed String
    | SubStatus String
    | SubActivity String
    | SubContext ContextGauge
    | SubCompacted Int Int Int Int Int Bool
    | SubIgnored


classifySubEvent : Decode.Value -> SubEvent
classifySubEvent nested =
    case Decode.decodeValue (Decode.field "type" Decode.string) nested of
        Ok "TEXT_MESSAGE_CONTENT" ->
            Decode.decodeValue (Decode.field "delta" Decode.string) nested
                |> Result.map SubDelta
                |> Result.withDefault SubIgnored

        Ok "RUN_ERROR" ->
            Decode.decodeValue (Decode.field "message" Decode.string) nested
                |> Result.map SubFailed
                |> Result.withDefault (SubFailed "子代理运行失败")

        Ok "RUN_STARTED" ->
            SubStatus "运行中"

        Ok "RUN_FINISHED" ->
            SubStatus "完成"

        Ok "STEP_STARTED" ->
            Decode.decodeValue (Decode.field "stepName" Decode.string) nested
                |> Result.map (\name -> SubActivity ("阶段：" ++ stepLabel name))
                |> Result.withDefault SubIgnored

        Ok "TOOL_CALL_START" ->
            Decode.decodeValue (Decode.field "toolCallName" Decode.string) nested
                |> Result.map (\name -> SubActivity ("调用：" ++ name))
                |> Result.withDefault SubIgnored

        Ok "CUSTOM" ->
            classifySubCustom nested

        _ ->
            SubIgnored


classifySubCustom : Decode.Value -> SubEvent
classifySubCustom nested =
    case Decode.decodeValue (Decode.field "name" Decode.string) nested of
        Ok "context.status" ->
            Decode.decodeValue contextGaugeDecoder nested
                |> Result.map SubContext
                |> Result.withDefault SubIgnored

        Ok "context.compact" ->
            Decode.decodeValue
                (Decode.map6 SubCompacted
                    (Decode.at [ "value", "step" ] Decode.int)
                    (Decode.at [ "value", "beforeTokens" ] Decode.int)
                    (Decode.at [ "value", "afterTokens" ] Decode.int)
                    (Decode.at [ "value", "budgetTokens" ] Decode.int)
                    (Decode.at [ "value", "droppedMessages" ] Decode.int)
                    (Decode.at [ "value", "emergency" ] Decode.bool)
                )
                nested
                |> Result.withDefault SubIgnored

        Ok "provider.retry" ->
            Decode.decodeValue
                (Decode.map4 retryNotice
                    (Decode.at [ "value", "attempt" ] Decode.int)
                    (Decode.at [ "value", "maxAttempts" ] Decode.int)
                    (Decode.at [ "value", "delayMs" ] Decode.int)
                    (Decode.at [ "value", "reason" ] Decode.string)
                )
                nested
                |> Result.map SubActivity
                |> Result.withDefault SubIgnored

        Ok "context.splice" ->
            Decode.decodeValue
                (Decode.map3 spliceNotice
                    (Decode.at [ "value", "stubbed" ] Decode.int)
                    (Decode.at [ "value", "savedChars" ] Decode.int)
                    (Decode.at [ "value", "keep" ] Decode.int)
                )
                nested
                |> Result.map SubActivity
                |> Result.withDefault SubIgnored

        _ ->
            SubIgnored


pushActivity : String -> List String -> List String
pushActivity item activity =
    List.take 8 (item :: List.filter ((/=) item) activity)


stepLabel : String -> String
stepLabel name =
    case name of
        "model" ->
            "模型"

        "tools" ->
            "工具"

        _ ->
            name


retryNotice : Int -> Int -> Int -> String -> String
retryNotice attempt maxAttempts delayMs reason =
    "模型请求重试 "
        ++ String.fromInt attempt
        ++ "/"
        ++ String.fromInt maxAttempts
        ++ "，"
        ++ String.fromFloat (toFloat delayMs / 1000)
        ++ " 秒后继续——"
        ++ reason


spliceNotice : Int -> Int -> Int -> String
spliceNotice stubbed savedChars keep =
    "上下文裁剪："
        ++ String.fromInt stubbed
        ++ " 项已存为工件，节省 "
        ++ String.fromInt savedChars
        ++ " 字符（保留最近 "
        ++ String.fromInt keep
        ++ " 项）"


compactNotice : Int -> Int -> Int -> Int -> Int -> Bool -> String
compactNotice step before after budget dropped emergency =
    "第 "
        ++ String.fromInt step
        ++ " 轮 · "
        ++ (if emergency then
                "上下文紧急压缩："

            else
                "上下文已压缩："
           )
        ++ String.fromInt before
        ++ " → "
        ++ String.fromInt after
        ++ " tokens；归纳 "
        ++ String.fromInt dropped
        ++ " 条消息（预算 "
        ++ String.fromInt budget
        ++ "）"


steeringNotice : Int -> Int -> String
steeringNotice step count =
    "steering injected: "
        ++ String.fromInt count
        ++ " at step "
        ++ String.fromInt step


followUpNotice : Int -> Int -> String
followUpNotice step count =
    "follow-up injected: "
        ++ String.fromInt count
        ++ " at step "
        ++ String.fromInt step


capTail : Int -> String -> String
capTail limit value =
    if String.length value > limit then
        String.right limit value

    else
        value


freshId : String -> Model -> ( String, Model )
freshId prefix model =
    ( prefix ++ "-" ++ model.threadId ++ "-" ++ String.fromInt model.nextId
    , { model | nextId = model.nextId + 1 }
    )


encodeCommand : String -> Model -> Encode.Value
encodeCommand runId model =
    Encode.object
        [ ( "endpoint", Encode.string (String.trim model.endpoint) )
        , ( "runId", Encode.string runId )
        , ( "input", encodeRunInput runId model )
        ]


encodeRunInput : String -> Model -> Encode.Value
encodeRunInput runId model =
    let
        history =
            prepareHistory model
    in
    Encode.object
        [ ( "threadId", Encode.string model.threadId )
        , ( "runId", Encode.string runId )
        , ( "state", Encode.object [] )
        , ( "messages", Encode.list (encodeMessage history.tools) history.messages )
        , ( "tools", Encode.list identity [ confirmationTool ] )
        , ( "context", Encode.list identity [] )
        , ( "forwardedProps"
          , Encode.object
                [ ( "client", Encode.string "yuki-n-ag-ui-elm" )
                , ( "protocolInspector", Encode.bool True )
                ]
          )
        ]


type alias PreparedHistory =
    { tools : Dict String ToolCall
    , messages : List ChatMessage
    }


{-| Tool turns must reach the provider as contiguous, one-result causal units.
-}
prepareHistory : Model -> PreparedHistory
prepareHistory model =
    let
        ordered =
            orderedMessages model

        results =
            List.foldl rememberFirstToolResult Dict.empty ordered

        tools =
            Dict.filter
                (\identifier tool ->
                    Dict.member identifier results && toolIsAttached model tool
                )
                model.tools

        normalize message =
            case message of
                AssistantChat assistant ->
                    let
                        calls =
                            List.filter (\identifier -> Dict.member identifier tools) assistant.toolCalls

                        normalized =
                            AssistantChat { assistant | toolCalls = calls }

                        paired =
                            List.filterMap
                                (\identifier -> Maybe.map ToolChat (Dict.get identifier results))
                                calls
                    in
                    if String.isEmpty (String.trim assistant.content) && List.isEmpty calls then
                        []

                    else
                        normalized :: paired

                ToolChat _ ->
                    []

                _ ->
                    if isLocalChat message then
                        []

                    else
                        [ message ]
    in
    { tools = tools
    , messages = List.concatMap normalize ordered
    }


rememberFirstToolResult : ChatMessage -> Dict String ToolMessage -> Dict String ToolMessage
rememberFirstToolResult message results =
    case message of
        ToolChat tool ->
            if Dict.member tool.callId results then
                results

            else
                Dict.insert tool.callId tool results

        _ ->
            results


toolIsAttached : Model -> ToolCall -> Bool
toolIsAttached model tool =
    tool.parentMessageId
        |> Maybe.andThen (\identifier -> Dict.get identifier model.messages)
        |> Maybe.map
            (\message ->
                case message of
                    AssistantChat assistant ->
                        List.member tool.id assistant.toolCalls

                    _ ->
                        False
            )
        |> Maybe.withDefault False


encodeMessage : Dict String ToolCall -> ChatMessage -> Encode.Value
encodeMessage tools message =
    case message of
        UserChat identifier content ->
            Encode.object
                [ ( "id", Encode.string identifier )
                , ( "role", Encode.string "user" )
                , ( "content", Encode.string content )
                ]

        SummaryChat identifier content ->
            Encode.object
                [ ( "id", Encode.string identifier )
                , ( "role", Encode.string "developer" )
                , ( "name", Encode.string "context-summary" )
                , ( "content", Encode.string content )
                ]

        MemoryChat _ _ ->
            Encode.null

        NoticeChat _ _ ->
            Encode.null

        ReasoningChat reasoning ->
            Encode.object
                [ ( "id", Encode.string reasoning.id )
                , ( "role", Encode.string "reasoning" )
                , ( "content", Encode.string reasoning.content )
                ]

        AssistantChat assistant ->
            Encode.object
                [ ( "id", Encode.string assistant.id )
                , ( "role", Encode.string "assistant" )
                , ( "content"
                  , if String.isEmpty assistant.content then
                        Encode.null

                    else
                        Encode.string assistant.content
                  )
                , ( "toolCalls"
                  , assistant.toolCalls
                        |> List.filterMap (\identifier -> Dict.get identifier tools)
                        |> Encode.list encodeToolCall
                  )
                ]

        ToolChat tool ->
            Encode.object
                [ ( "id", Encode.string tool.id )
                , ( "role", Encode.string "tool" )
                , ( "content", Encode.string tool.content )
                , ( "toolCallId", Encode.string tool.callId )
                ]

        SubAgentChat _ ->
            Encode.null


isLocalChat : ChatMessage -> Bool
isLocalChat message =
    case message of
        MemoryChat _ _ ->
            True

        SummaryChat _ _ ->
            False

        NoticeChat _ _ ->
            True

        SubAgentChat _ ->
            True

        _ ->
            False


encodeToolCall : ToolCall -> Encode.Value
encodeToolCall tool =
    Encode.object
        [ ( "id", Encode.string tool.id )
        , ( "type", Encode.string "function" )
        , ( "function"
          , Encode.object
                [ ( "name", Encode.string tool.name )
                , ( "arguments"
                  , Encode.string <|
                        if String.isEmpty tool.arguments then
                            "{}"

                        else
                            tool.arguments
                  )
                ]
          )
        ]


confirmationToolName : String
confirmationToolName =
    "request_confirmation"


confirmationTool : Encode.Value
confirmationTool =
    Encode.object
        [ ( "name", Encode.string confirmationToolName )
        , ( "description"
          , Encode.string "Ask the user to approve or reject a consequential action before continuing."
          )
        , ( "parameters"
          , Encode.object
                [ ( "type", Encode.string "object" )
                , ( "properties"
                  , Encode.object
                        [ ( "title"
                          , Encode.object
                                [ ( "type", Encode.string "string" )
                                , ( "description", Encode.string "Short action title" )
                                ]
                          )
                        , ( "details"
                          , Encode.object
                                [ ( "type", Encode.string "string" )
                                , ( "description", Encode.string "What will happen if approved" )
                                ]
                          )
                        ]
                  )
                , ( "required", Encode.list Encode.string [ "title", "details" ] )
                , ( "additionalProperties", Encode.bool False )
                ]
          )
        ]


decodeAgentEvent : Decode.Value -> Result String AgentEvent
decodeAgentEvent raw =
    Decode.decodeValue (Decode.field "type" Decode.string) raw
        |> Result.mapError Decode.errorToString
        |> Result.andThen
            (\kind ->
                Decode.decodeValue (eventDecoder kind) raw
                    |> Result.mapError Decode.errorToString
            )


eventDecoder : String -> Decoder AgentEvent
eventDecoder kind =
    case kind of
        "RUN_STARTED" ->
            Decode.map2 RunStarted
                (Decode.field "threadId" Decode.string)
                (Decode.field "runId" Decode.string)

        "RUN_FINISHED" ->
            Decode.map2 RunFinished
                (Decode.field "threadId" Decode.string)
                (Decode.field "runId" Decode.string)

        "RUN_ERROR" ->
            Decode.map2 RunError
                (Decode.field "message" Decode.string)
                (Decode.maybe (Decode.field "code" Decode.string))

        "STEP_STARTED" ->
            Decode.map StepStarted (Decode.field "stepName" Decode.string)

        "STEP_FINISHED" ->
            Decode.map StepFinished (Decode.field "stepName" Decode.string)

        "TEXT_MESSAGE_START" ->
            Decode.map TextStarted (Decode.field "messageId" Decode.string)

        "TEXT_MESSAGE_CONTENT" ->
            Decode.map2 TextContent
                (Decode.field "messageId" Decode.string)
                (Decode.field "delta" Decode.string)

        "TEXT_MESSAGE_END" ->
            Decode.map TextEnded (Decode.field "messageId" Decode.string)

        "REASONING_START" ->
            Decode.map (ReasoningStarted RunScope) (Decode.field "messageId" Decode.string)

        "REASONING_MESSAGE_START" ->
            Decode.map (ReasoningStarted MessageScope) (Decode.field "messageId" Decode.string)

        "REASONING_MESSAGE_CONTENT" ->
            Decode.map2 ReasoningContent
                (Decode.field "messageId" Decode.string)
                (Decode.field "delta" Decode.string)

        "REASONING_MESSAGE_END" ->
            Decode.map (ReasoningEnded MessageScope) (Decode.field "messageId" Decode.string)

        "REASONING_END" ->
            Decode.map (ReasoningEnded RunScope) (Decode.field "messageId" Decode.string)

        "TOOL_CALL_START" ->
            Decode.map3 ToolStarted
                (Decode.field "toolCallId" Decode.string)
                (Decode.field "toolCallName" Decode.string)
                (Decode.maybe (Decode.field "parentMessageId" Decode.string))

        "TOOL_CALL_ARGS" ->
            Decode.map2 ToolArguments
                (Decode.field "toolCallId" Decode.string)
                (Decode.field "delta" Decode.string)

        "TOOL_CALL_END" ->
            Decode.map ToolEnded (Decode.field "toolCallId" Decode.string)

        "TOOL_CALL_RESULT" ->
            Decode.map3 ToolResult
                (Decode.field "messageId" Decode.string)
                (Decode.field "toolCallId" Decode.string)
                (Decode.field "content" Decode.string)

        "STATE_SNAPSHOT" ->
            Decode.succeed (StateObserved StateSnapshot)

        "STATE_DELTA" ->
            Decode.succeed (StateObserved StateDelta)

        "MESSAGES_SNAPSHOT" ->
            Decode.succeed (StateObserved MessagesSnapshot)

        "ACTIVITY_SNAPSHOT" ->
            Decode.succeed (ActivityObserved ActivitySnapshot)

        "ACTIVITY_DELTA" ->
            Decode.succeed (ActivityObserved ActivityDelta)

        "CUSTOM" ->
            Decode.field "name" Decode.string
                |> Decode.andThen
                    (\name ->
                        case name of
                            "context.inject" ->
                                Decode.map ContextInject (Decode.at [ "value", "content" ] Decode.string)

                            "usage" ->
                                Decode.map UsageObserved (Decode.field "value" usageDecoder)

                            "shell.output" ->
                                Decode.map3 ShellOutput
                                    (Decode.at [ "value", "callId" ] Decode.string)
                                    (Decode.at [ "value", "stream" ] Decode.string)
                                    (Decode.at [ "value", "delta" ] Decode.string)
                                    |> withCustomFallback name

                            "provider.retry" ->
                                Decode.map4 ProviderRetry
                                    (Decode.at [ "value", "attempt" ] Decode.int)
                                    (Decode.at [ "value", "maxAttempts" ] Decode.int)
                                    (Decode.at [ "value", "delayMs" ] Decode.int)
                                    (Decode.at [ "value", "reason" ] Decode.string)
                                    |> withCustomFallback name

                            "context.splice" ->
                                Decode.map3 ContextSplice
                                    (Decode.at [ "value", "stubbed" ] Decode.int)
                                    (Decode.at [ "value", "savedChars" ] Decode.int)
                                    (Decode.at [ "value", "keep" ] Decode.int)
                                    |> withCustomFallback name

                            "context.status" ->
                                Decode.map ContextStatus contextGaugeDecoder
                                    |> withCustomFallback name

                            "context.compact" ->
                                Decode.map6 ContextCompact
                                    (Decode.at [ "value", "step" ] Decode.int)
                                    (Decode.at [ "value", "beforeTokens" ] Decode.int)
                                    (Decode.at [ "value", "afterTokens" ] Decode.int)
                                    (Decode.at [ "value", "budgetTokens" ] Decode.int)
                                    (Decode.at [ "value", "droppedMessages" ] Decode.int)
                                    (Decode.at [ "value", "emergency" ] Decode.bool)
                                    |> withCustomFallback name

                            "steering.inject" ->
                                Decode.map2 SteeringInject
                                    (Decode.at [ "value", "step" ] Decode.int)
                                    (Decode.at [ "value", "count" ] Decode.int)
                                    |> withCustomFallback name

                            "followup.inject" ->
                                Decode.map2 FollowUpInject
                                    (Decode.at [ "value", "step" ] Decode.int)
                                    (Decode.at [ "value", "count" ] Decode.int)
                                    |> withCustomFallback name

                            "run.cancelled" ->
                                Decode.map RunCancelled (Decode.at [ "value", "runId" ] Decode.string)
                                    |> withCustomFallback name

                            "agent.sub" ->
                                Decode.map3 AgentSub
                                    (Decode.at [ "value", "runId" ] Decode.string)
                                    (Decode.at [ "value", "callId" ] Decode.string)
                                    (Decode.at [ "value", "event" ] Decode.value)
                                    |> withCustomFallback name

                            _ ->
                                Decode.succeed (CustomObserved name)
                    )

        "RAW" ->
            Decode.succeed RawObserved

        _ ->
            Decode.succeed (UnknownEvent kind)


withCustomFallback : String -> Decoder AgentEvent -> Decoder AgentEvent
withCustomFallback name decoder =
    Decode.oneOf [ decoder, Decode.succeed (CustomObserved name) ]


usageDecoder : Decoder Usage
usageDecoder =
    Decode.map3 Usage
        (Decode.maybe (Decode.field "promptTokens" Decode.int))
        (Decode.maybe (Decode.field "completionTokens" Decode.int))
        (Decode.maybe (Decode.field "cacheHitTokens" Decode.int))


contextGaugeDecoder : Decoder ContextGauge
contextGaugeDecoder =
    Decode.succeed ContextGauge
        |> andMap (Decode.at [ "value", "tokens" ] Decode.int)
        |> andMap (Decode.at [ "value", "budgetTokens" ] Decode.int)
        |> andMap (Decode.at [ "value", "willCompact" ] Decode.bool)
        |> andMap (Decode.at [ "value", "emergency" ] Decode.bool)
        |> andMap (Decode.maybe (Decode.at [ "value", "windowTokens" ] Decode.int))
        |> andMap (Decode.maybe (Decode.at [ "value", "reserveTokens" ] Decode.int))
        |> andMap (Decode.maybe (Decode.at [ "value", "toolTokens" ] Decode.int))


incarnationDecoder : Decoder IncarnationView
incarnationDecoder =
    Decode.succeed IncarnationView
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "name" Decode.string)
        |> andMap (Decode.field "direction" Decode.string)
        |> andMap (Decode.maybe (Decode.field "promptRevision" Decode.string))
        |> andMap (Decode.maybe (Decode.field "impressionModel" Decode.string))
        |> andMap (Decode.oneOf [ Decode.field "revision" Decode.int, Decode.succeed 1 ])
        |> andMap (Decode.oneOf [ Decode.field "status" Decode.string, Decode.succeed "active" ])
        |> andMap (Decode.oneOf [ Decode.field "created" Decode.int, Decode.succeed 0 ])
        |> andMap (Decode.oneOf [ Decode.field "updated" Decode.int, Decode.succeed 0 ])


impressionItemDecoder : Decoder ImpressionItemView
impressionItemDecoder =
    Decode.succeed ImpressionItemView
        |> andMap (Decode.oneOf [ Decode.field "id" Decode.string, Decode.succeed "" ])
        |> andMap (Decode.field "label" Decode.string)
        |> andMap (Decode.field "intuition" Decode.string)
        |> andMap (Decode.field "strength" Decode.float)
        |> andMap (Decode.oneOf [ Decode.field "sourceMemoryIds" (Decode.list Decode.string), Decode.succeed [] ])
        |> andMap (Decode.oneOf [ Decode.field "sourceExperienceRefs" (Decode.list Decode.string), Decode.succeed [] ])
        |> andMap (Decode.oneOf [ Decode.field "updated" Decode.int, Decode.succeed 0 ])


impressionStateDecoder : Decoder ImpressionStateView
impressionStateDecoder =
    Decode.succeed ImpressionStateView
        |> andMap (Decode.field "incarnationId" Decode.string)
        |> andMap (Decode.oneOf [ Decode.field "revision" Decode.int, Decode.succeed 0 ])
        |> andMap (Decode.oneOf [ Decode.field "items" (Decode.list impressionItemDecoder), Decode.succeed [] ])
        |> andMap (Decode.oneOf [ Decode.field "generatorRevision" Decode.string, Decode.succeed "—" ])
        |> andMap (Decode.oneOf [ Decode.field "effectiveHash" Decode.string, Decode.succeed "" ])
        |> andMap (Decode.oneOf [ Decode.field "updated" Decode.int, Decode.succeed 0 ])


impressionCueDecoder : Decoder ImpressionCueView
impressionCueDecoder =
    Decode.succeed ImpressionCueView
        |> andMap (Decode.field "hint" Decode.string)
        |> andMap (Decode.maybe (Decode.field "suggestedQuery" Decode.string))
        |> andMap (Decode.oneOf [ Decode.field "memoryIds" (Decode.list Decode.string), Decode.succeed [] ])
        |> andMap (Decode.field "confidence" Decode.float)
        |> andMap (Decode.oneOf [ Decode.field "reason" Decode.string, Decode.succeed "" ])


impressionActivationDecoder : Decoder ImpressionActivationView
impressionActivationDecoder =
    Decode.succeed ImpressionActivationView
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "incarnationId" Decode.string)
        |> andMap (Decode.oneOf [ Decode.field "taskId" Decode.string, Decode.succeed "" ])
        |> andMap (Decode.oneOf [ Decode.field "runId" Decode.string, Decode.succeed "" ])
        |> andMap (Decode.field "intentId" Decode.string)
        |> andMap (Decode.field "intent" Decode.string)
        |> andMap (Decode.field "stateRevision" Decode.int)
        |> andMap (Decode.oneOf [ Decode.field "cues" (Decode.list impressionCueDecoder), Decode.succeed [] ])
        |> andMap (Decode.oneOf [ Decode.field "injectedText" Decode.string, Decode.succeed "" ])
        |> andMap (Decode.oneOf [ Decode.field "generatorRevision" Decode.string, Decode.succeed "—" ])
        |> andMap (Decode.oneOf [ Decode.field "modelInvocationId" Decode.string, Decode.succeed "—" ])
        |> andMap (Decode.oneOf [ Decode.field "model" Decode.string, Decode.succeed "—" ])
        |> andMap (Decode.maybe (Decode.field "error" Decode.string))
        |> andMap (Decode.oneOf [ Decode.field "created" Decode.int, Decode.succeed 0 ])


impressionMemoryProposalDecoder : Decoder ImpressionMemoryProposalView
impressionMemoryProposalDecoder =
    Decode.succeed ImpressionMemoryProposalView
        |> andMap (Decode.field "content" Decode.string)
        |> andMap (Decode.field "kind" Decode.string)
        |> andMap (Decode.oneOf [ Decode.field "visibility" Decode.string, Decode.succeed "private" ])
        |> andMap (Decode.oneOf [ Decode.field "sourceRefs" (Decode.list Decode.string), Decode.succeed [] ])
        |> andMap (Decode.oneOf [ Decode.field "reason" Decode.string, Decode.succeed "" ])


impressionRevisionDecoder : Decoder ImpressionRevisionView
impressionRevisionDecoder =
    Decode.succeed ImpressionRevisionView
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "incarnationId" Decode.string)
        |> andMap (Decode.oneOf [ Decode.field "experienceRef" Decode.string, Decode.succeed "—" ])
        |> andMap (Decode.field "beforeRevision" Decode.int)
        |> andMap (Decode.field "afterRevision" Decode.int)
        |> andMap (Decode.oneOf [ Decode.field "reason" Decode.string, Decode.succeed "" ])
        |> andMap (Decode.oneOf [ Decode.field "memoryProposals" (Decode.list impressionMemoryProposalDecoder), Decode.succeed [] ])
        |> andMap (Decode.oneOf [ Decode.field "voidProposals" (Decode.list Decode.string), Decode.succeed [] ])
        |> andMap (Decode.oneOf [ Decode.field "modelInvocationId" Decode.string, Decode.succeed "—" ])
        |> andMap (Decode.oneOf [ Decode.field "model" Decode.string, Decode.succeed "—" ])
        |> andMap (Decode.oneOf [ Decode.field "created" Decode.int, Decode.succeed 0 ])


memorySnippetDecoder : Decoder MemorySnippetView
memorySnippetDecoder =
    Decode.succeed MemorySnippetView
        |> andMap (Decode.at [ "ref", "id" ] Decode.string)
        |> andMap (Decode.at [ "ref", "revision" ] Decode.int)
        |> andMap (Decode.field "owner" Decode.string)
        |> andMap (Decode.field "visibility" Decode.string)
        |> andMap (Decode.field "kind" Decode.string)
        |> andMap (Decode.field "snippet" Decode.string)
        |> andMap (Decode.oneOf [ Decode.field "keywords" (Decode.list Decode.string), Decode.succeed [] ])
        |> andMap (Decode.oneOf [ Decode.field "sourceRefs" (Decode.list Decode.string), Decode.succeed [] ])
        |> andMap (Decode.oneOf [ Decode.field "matches" (Decode.list Decode.string), Decode.succeed [] ])


memoryReceiptDecoder : Decoder MemoryReceiptView
memoryReceiptDecoder =
    Decode.succeed MemoryReceiptView
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "incarnationId" Decode.string)
        |> andMap (Decode.field "action" Decode.string)
        |> andMap (Decode.maybe (Decode.field "query" Decode.string))
        |> andMap (Decode.oneOf [ Decode.field "spaces" (Decode.list Decode.value), Decode.succeed [] ])
        |> andMap (Decode.oneOf [ Decode.field "records" (Decode.list Decode.value), Decode.succeed [] ])
        |> andMap (Decode.field "created" Decode.int)


memoryGrepDecoder : Decoder MemoryGrepView
memoryGrepDecoder =
    Decode.map2 MemoryGrepView
        (Decode.oneOf [ Decode.field "snippets" (Decode.list memorySnippetDecoder), Decode.succeed [] ])
        (Decode.field "receipt" memoryReceiptDecoder)


taskArchiveSummaryDecoder : Decoder TaskArchiveSummary
taskArchiveSummaryDecoder =
    Decode.succeed TaskArchiveSummary
        |> andMap (Decode.field "incarnationId" Decode.string)
        |> andMap (Decode.field "taskId" Decode.string)
        |> andMap (Decode.field "runCount" Decode.int)
        |> andMap (Decode.field "entryCount" Decode.int)
        |> andMap (Decode.field "created" Decode.int)
        |> andMap (Decode.field "updated" Decode.int)
        |> andMap (Decode.field "preview" Decode.string)


taskRecordHitDecoder : Decoder TaskRecordHitView
taskRecordHitDecoder =
    Decode.succeed TaskRecordHitView
        |> andMap (Decode.field "entryId" Decode.string)
        |> andMap (Decode.field "taskId" Decode.string)
        |> andMap (Decode.field "runId" Decode.string)
        |> andMap (Decode.field "seq" Decode.int)
        |> andMap (Decode.field "kind" Decode.string)
        |> andMap (Decode.field "sourceId" Decode.string)
        |> andMap (Decode.maybe (Decode.field "toolName" Decode.string))
        |> andMap (Decode.maybe (Decode.field "callId" Decode.string))
        |> andMap (Decode.field "lineNumber" Decode.int)
        |> andMap (Decode.field "matchOffset" Decode.int)
        |> andMap (Decode.field "excerpt" Decode.string)
        |> andMap (Decode.field "created" Decode.int)


taskRecordSearchDecoder : Decoder TaskRecordSearchView
taskRecordSearchDecoder =
    Decode.succeed TaskRecordSearchView
        |> andMap (Decode.field "query" Decode.string)
        |> andMap (Decode.field "mode" Decode.string)
        |> andMap (Decode.field "caseSensitive" Decode.bool)
        |> andMap (Decode.field "scannedTasks" Decode.int)
        |> andMap (Decode.field "scannedEntries" Decode.int)
        |> andMap (Decode.field "truncated" Decode.bool)
        |> andMap (Decode.field "hits" (Decode.list taskRecordHitDecoder))


taskRecordEntryDecoder : Decoder TaskRecordEntryView
taskRecordEntryDecoder =
    Decode.succeed TaskRecordEntryView
        |> andMap (Decode.field "entryId" Decode.string)
        |> andMap (Decode.field "taskId" Decode.string)
        |> andMap (Decode.field "runId" Decode.string)
        |> andMap (Decode.field "seq" Decode.int)
        |> andMap (Decode.field "kind" Decode.string)
        |> andMap (Decode.field "sourceId" Decode.string)
        |> andMap (Decode.maybe (Decode.field "toolName" Decode.string))
        |> andMap (Decode.maybe (Decode.field "callId" Decode.string))
        |> andMap (Decode.field "content" Decode.string)
        |> andMap (Decode.field "contentOffset" Decode.int)
        |> andMap (Decode.field "contentTotal" Decode.int)
        |> andMap (Decode.field "truncatedBefore" Decode.bool)
        |> andMap (Decode.field "truncatedAfter" Decode.bool)
        |> andMap (Decode.field "created" Decode.int)


taskRecordContextDecoder : Decoder TaskRecordContextView
taskRecordContextDecoder =
    Decode.succeed TaskRecordContextView
        |> andMap (Decode.field "taskId" Decode.string)
        |> andMap (Decode.field "anchorEntryId" Decode.string)
        |> andMap (Decode.field "entries" (Decode.list taskRecordEntryDecoder))


focusFrameDecoder : Decoder FocusFrameView
focusFrameDecoder =
    Decode.succeed FocusFrameView
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "incarnationId" Decode.string)
        |> andMap (Decode.field "taskId" Decode.string)
        |> andMap (Decode.field "revision" Decode.int)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (Decode.field "epochId" Decode.string)
        |> andMap (Decode.field "objective" Decode.string)
        |> andMap (Decode.oneOf [ Decode.field "activeItems" (Decode.list Decode.string), Decode.succeed [] ])
        |> andMap (Decode.oneOf [ Decode.field "openLoops" (Decode.list Decode.string), Decode.succeed [] ])
        |> andMap (Decode.oneOf [ Decode.field "provisionalClaims" (Decode.list Decode.string), Decode.succeed [] ])
        |> andMap (Decode.oneOf [ Decode.field "recentOutcomeRefs" (Decode.list Decode.string), Decode.succeed [] ])
        |> andMap (Decode.oneOf [ Decode.field "artifactRefs" (Decode.list Decode.string), Decode.succeed [] ])
        |> andMap (Decode.field "cursor" experienceCursorSeqDecoder)
        |> andMap (Decode.field "updated" Decode.int)


workingMemoryDecoder : Decoder WorkingMemoryView
workingMemoryDecoder =
    Decode.succeed WorkingMemoryView
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "incarnationId" Decode.string)
        |> andMap (Decode.field "revision" Decode.int)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (Decode.field "cursor" experienceCursorSeqDecoder)
        |> andMap (Decode.maybe (Decode.field "checkpointId" Decode.string))
        |> andMap (Decode.maybe (Decode.field "wakePacketId" Decode.string))
        |> andMap (Decode.maybe (Decode.field "activeTaskId" Decode.string))
        |> andMap
            (Decode.oneOf
                [ Decode.field "focusFrames" (Decode.dict focusFrameDecoder) |> Decode.map Dict.values
                , Decode.succeed []
                ]
            )
        |> andMap (Decode.maybe (Decode.field "degradedReason" Decode.string))
        |> andMap (Decode.field "created" Decode.int)
        |> andMap (Decode.field "updated" Decode.int)


forgetDecisionDecoder : Decoder ForgetDecisionView
forgetDecisionDecoder =
    Decode.succeed ForgetDecisionView
        |> andMap (Decode.field "subject" Decode.string)
        |> andMap (Decode.field "reason" Decode.string)
        |> andMap (Decode.oneOf [ Decode.field "sourceSegmentIds" (Decode.list Decode.string), Decode.succeed [] ])


sleepCycleDecoder : Decoder SleepCycleView
sleepCycleDecoder =
    Decode.succeed SleepCycleView
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "incarnationId" Decode.string)
        |> andMap (Decode.field "taskId" Decode.string)
        |> andMap (Decode.maybe (Decode.field "runId" Decode.string))
        |> andMap (Decode.field "baseEpochId" Decode.string)
        |> andMap (Decode.field "trigger" Decode.string)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (Decode.field "expectedRevision" Decode.int)
        |> andMap (Decode.field "frozenCursor" experienceCursorSeqDecoder)
        |> andMap (Decode.oneOf [ Decode.field "forgotten" (Decode.list forgetDecisionDecoder), Decode.succeed [] ])
        |> andMap (Decode.maybe (Decode.field "checkpointId" Decode.string))
        |> andMap (Decode.maybe (Decode.field "wakePacketId" Decode.string))
        |> andMap (Decode.maybe (Decode.field "replayCursor" experienceCursorSeqDecoder))
        |> andMap (Decode.maybe (Decode.field "failure" Decode.string))
        |> andMap (Decode.field "created" Decode.int)
        |> andMap (Decode.field "updated" Decode.int)


experienceCursorSeqDecoder : Decoder Int
experienceCursorSeqDecoder =
    Decode.oneOf
        [ Decode.field "seq" Decode.int
        , Decode.int
        ]


promptRevisionDecoder : Decoder PromptRevisionView
promptRevisionDecoder =
    Decode.succeed PromptRevisionView
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.maybe (Decode.field "incarnationId" Decode.string))
        |> andMap (Decode.field "layer" Decode.string)
        |> andMap (Decode.field "sourceIntent" Decode.string)
        |> andMap (Decode.field "content" Decode.string)
        |> andMap (Decode.field "generatorRevision" Decode.string)
        |> andMap (Decode.maybe (Decode.field "modelInvocationRef" Decode.string))
        |> andMap (Decode.maybe (Decode.field "parentRevision" Decode.string))
        |> andMap (Decode.field "ordinal" Decode.int)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (Decode.field "effectiveHash" Decode.string)
        |> andMap (Decode.field "created" Decode.int)


configViewDecoder : Decoder ThreadConfigView
configViewDecoder =
    Decode.succeed ThreadConfigView
        |> andMap (Decode.maybe (Decode.field "incarnationId" Decode.string))
        |> andMap cwdModeDecoder
        |> andMap (Decode.maybe (Decode.field "cwd" Decode.string))
        |> andMap (Decode.maybe (Decode.field "systemPrompt" Decode.string))
        |> andMap (Decode.maybe (Decode.field "provider" Decode.string))
        |> andMap (Decode.maybe (Decode.field "model" Decode.string))
        |> andMap (Decode.maybe (Decode.field "reasoningEffort" Decode.string))
        |> andMap (Decode.maybe (Decode.field "fs" Decode.bool))
        |> andMap (Decode.maybe (Decode.field "shell" Decode.bool))
        |> andMap (Decode.maybe (Decode.field "memory" Decode.bool))
        |> andMap (Decode.maybe (Decode.field "contextReserveTokens" Decode.int))
        |> andMap (Decode.maybe (Decode.field "contextKeepUnits" Decode.int))
        |> andMap (Decode.maybe (Decode.field "contextSummaryTokens" Decode.int))


cwdModeDecoder : Decoder CwdMode
cwdModeDecoder =
    Decode.oneOf
        [ Decode.field "cwdMode" Decode.string
            |> Decode.andThen
                (\mode ->
                    case mode of
                        "inherit" ->
                            Decode.succeed CwdInherit

                        "none" ->
                            Decode.succeed CwdNone

                        "path" ->
                            Decode.succeed CwdPath

                        _ ->
                            Decode.fail ("unknown cwdMode: " ++ mode)
                )
        , Decode.succeed CwdInherit
        ]


providerEntryDecoder : Decoder ProviderEntryView
providerEntryDecoder =
    Decode.map7 ProviderEntryView
        (Decode.field "name" Decode.string)
        (Decode.field "baseUrl" Decode.string)
        (Decode.field "dialect" Decode.string)
        (Decode.field "defaultModel" Decode.string)
        (Decode.field "keyReady" Decode.bool)
        (Decode.field "models" (Decode.list Decode.string))
        (Decode.field "contextTokens" Decode.int)


emptyConfigView : ThreadConfigView
emptyConfigView =
    ThreadConfigView Nothing CwdInherit Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing


globalConfigDecoder : Decoder GlobalView
globalConfigDecoder =
    Decode.map3 GlobalView
        (Decode.field "provider" providerDecoder)
        (Decode.field "settings" settingsDecoder)
        (Decode.field "defaults" configViewDecoder)


providerDecoder : Decoder ProviderView
providerDecoder =
    Decode.map8 ProviderView
        (Decode.field "name" Decode.string)
        (Decode.field "model" Decode.string)
        (Decode.field "baseUrl" Decode.string)
        (Decode.field "apiKey" Decode.string)
        (Decode.field "dialect" Decode.string)
        (Decode.field "thinking" Decode.string)
        (Decode.maybe (Decode.field "maxTokens" Decode.int))
        (Decode.field "contextTokens" Decode.int)


settingsDecoder : Decoder SettingsView
settingsDecoder =
    Decode.succeed SettingsView
        |> andMap (Decode.field "host" Decode.string)
        |> andMap (Decode.field "port" Decode.int)
        |> andMap (Decode.field "maxTurns" Decode.int)
        |> andMap (Decode.field "toolExecution" Decode.string)
        |> andMap (Decode.field "systemPrompt" Decode.string)
        |> andMap (Decode.maybe (Decode.field "workDir" Decode.string))
        |> andMap (Decode.maybe (Decode.field "journalDir" Decode.string))
        |> andMap (Decode.maybe (Decode.field "artifactDir" Decode.string))
        |> andMap (Decode.maybe (Decode.field "memoryDir" Decode.string))
        |> andMap (Decode.maybe (Decode.field "memoryModel" Decode.string))
        |> andMap (Decode.field "contextReserveTokens" Decode.int)
        |> andMap (Decode.field "contextKeepUnits" Decode.int)
        |> andMap (Decode.field "contextSummaryTokens" Decode.int)


contextPolicyDecoder : Decoder ContextPolicyView
contextPolicyDecoder =
    Decode.map6 ContextPolicyView
        (Decode.field "windowTokens" Decode.int)
        (Decode.field "reserveTokens" Decode.int)
        (Decode.field "toolTokens" Decode.int)
        (Decode.field "budgetTokens" Decode.int)
        (Decode.field "keepUnits" Decode.int)
        (Decode.field "summaryTokens" Decode.int)


andMap : Decoder a -> Decoder (a -> b) -> Decoder b
andMap valueDecoder fnDecoder =
    Decode.map2 (\fn value -> fn value) fnDecoder valueDecoder


transportDecoder : Decoder TransportSignal
transportDecoder =
    Decode.field "kind" Decode.string
        |> Decode.andThen
            (\kind ->
                case kind of
                    "connecting" ->
                        Decode.map TransportConnecting (Decode.field "runId" Decode.string)

                    "open" ->
                        Decode.map TransportOpen (Decode.field "runId" Decode.string)

                    "closed" ->
                        Decode.map TransportClosed (Decode.field "runId" Decode.string)

                    "cancelled" ->
                        Decode.map TransportCancelled (Decode.field "runId" Decode.string)

                    "error" ->
                        Decode.map2 TransportFailed
                            (Decode.field "runId" Decode.string)
                            (Decode.field "message" Decode.string)

                    _ ->
                        Decode.fail ("unknown transport signal " ++ kind)
            )


fetchInspection : Model -> String -> String -> Maybe Encode.Value -> String -> Cmd Msg
fetchInspection model kind method maybeBody path =
    inspect <|
        Encode.object
            ([ ( "kind", Encode.string kind )
             , ( "path", Encode.string path )
             , ( "method", Encode.string method )
             , ( "endpoint", Encode.string (String.trim model.endpoint) )
             ]
                ++ (maybeBody
                        |> Maybe.map (\body -> [ ( "body", body ) ])
                        |> Maybe.withDefault []
                   )
            )


fallbackIncarnation : String -> IncarnationView
fallbackIncarnation identifier =
    { id = identifier
    , name =
        if identifier == "yuki" then
            "Yuki"

        else
            identifier
    , direction = "一个持续形成判断、保留经验，并对自身工作方式负责的 Yuki 分身。"
    , promptRevision = Nothing
    , impressionModel = Nothing
    , revision = 1
    , status = "active"
    , created = 0
    , updated = 0
    }


switchIncarnation : String -> Model -> ( Model, Cmd Msg )
switchIncarnation identifier model =
    if
        identifier
            == model.incarnationId
            || isBusy model.phase
            || model.savingSelf
            || model.generatingPrompt
            || model.activatingPrompt
            /= Nothing
            || Maybe.withDefault False (Maybe.map (\editor -> editor.saving) model.promptEditor)
    then
        ( model, Cmd.none )

    else
        let
            fallback =
                fallbackIncarnation identifier

            switched =
                { model
                    | incarnationId = identifier
                    , incarnation = fallback
                    , incarnationNotice = Nothing
                    , selfNameDraft = fallback.name
                    , selfDirectionDraft = fallback.direction
                    , selfImpressionModelDraft = ""
                    , savingSelf = False
                    , selfMessage = Nothing
                    , incarnationArchiveConfirm = False
                    , archivingIncarnation = False
                    , restoringIncarnation = Nothing
                    , impression = OptionalIdle
                    , impressionActivations = OptionalIdle
                    , impressionRevisions = OptionalIdle
                    , memoryRecordMode = TaskRecordMode
                    , taskRecords = emptyTaskRecordMemory
                    , longMemoryQuery = ""
                    , longMemorySearch = OptionalIdle
                    , workingMemory = OptionalIdle
                    , sleepCycles = OptionalIdle
                    , rootPrompts = OptionalIdle
                    , prompts = OptionalIdle
                    , generatingPrompt = False
                    , activatingPrompt = Nothing
                    , promptEditor = Nothing
                    , promptMessage = Nothing
                    , sessions = Loading
                    , threadBase = identifier
                    , threadId = "unbound-" ++ identifier
                    , currentTaskBelongs = False
                    , messages = Dict.empty
                    , messageOrder = []
                    , tools = Dict.empty
                    , draft = ""
                    , pathSuggestions = []
                    , phase = Idle
                    , activeRun = Nothing
                    , activeStep = Nothing
                    , error = Nothing
                    , tree = NotAsked
                    , usage = Nothing
                    , contextGauge = Nothing
                    , tab = NowTab
                }
        in
        ( switched
        , Cmd.batch
            [ persistIncarnationId identifier
            , incarnationCmd switched identifier
            , sessionsCmd switched
            ]
        )


incarnationsCmd : Model -> Cmd Msg
incarnationsCmd model =
    fetchInspection model "incarnations/list" "GET" Nothing "incarnations?archived=true"


incarnationCmd : Model -> String -> Cmd Msg
incarnationCmd model identifier =
    fetchInspection model ("incarnation/" ++ identifier) "GET" Nothing ("incarnations/" ++ identifier)


openMemoryPane : MemoryPane -> Model -> ( Model, Cmd Msg )
openMemoryPane pane model =
    case pane of
        ImpressionPane ->
            if
                optionalIsIdle model.impression
                    || optionalIsIdle model.impressionActivations
                    || optionalIsIdle model.impressionRevisions
            then
                loadImpression model

            else
                ( model, Cmd.none )

        LongTermPane ->
            case model.memoryRecordMode of
                TaskRecordMode ->
                    loadTaskRecordCatalog model

                DistilledRecordMode ->
                    ( model, Cmd.none )

        SleepPane ->
            if optionalIsIdle model.workingMemory || optionalIsIdle model.sleepCycles then
                loadWorkingMemory model

            else
                ( model, Cmd.none )


loadImpression : Model -> ( Model, Cmd Msg )
loadImpression model =
    ( { model
        | impression = OptionalLoading
        , impressionActivations = OptionalLoading
        , impressionRevisions = OptionalLoading
      }
    , Cmd.batch
        [ fetchInspection model
            ("impression/state/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/impression")
        , fetchInspection model
            ("impression/activations/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/impression/activations")
        , fetchInspection model
            ("impression/revisions/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/impression/revisions")
        ]
    )


mapTaskRecords : (TaskRecordMemory -> TaskRecordMemory) -> Model -> Model
mapTaskRecords transform model =
    { model | taskRecords = transform model.taskRecords }


loadTaskRecordCatalog : Model -> ( Model, Cmd Msg )
loadTaskRecordCatalog model =
    if optionalIsIdle model.taskRecords.catalog then
        ( mapTaskRecords (\state -> { state | catalog = OptionalLoading }) model
        , fetchInspection model
            ("task-records/catalog/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/task-records")
        )

    else
        ( model, Cmd.none )


searchTaskRecords : Model -> ( Model, Cmd Msg )
searchTaskRecords model =
    let
        state =
            model.taskRecords

        query =
            String.trim state.query

        body =
            Encode.object
                ([ ( "query", Encode.string query )
                 , ( "caseSensitive", Encode.bool state.caseSensitive )
                 , ( "limit", Encode.int 80 )
                 ]
                    ++ (state.taskId
                            |> Maybe.map (\taskId -> [ ( "taskId", Encode.string taskId ) ])
                            |> Maybe.withDefault []
                       )
                )
    in
    if String.isEmpty query || optionalIsLoading state.search then
        ( model, Cmd.none )

    else
        ( mapTaskRecords
            (\current ->
                { current
                    | search = OptionalLoading
                    , searchScope = Maybe.withDefault "" state.taskId
                    , selected = Nothing
                    , reader = OptionalIdle
                }
            )
            model
        , fetchInspection model
            ("task-records/search/" ++ model.incarnationId)
            "POST"
            (Just body)
            ("incarnations/" ++ model.incarnationId ++ "/task-records/search")
        )


readTaskRecord : TaskRecordHitView -> Int -> Int -> Model -> ( Model, Cmd Msg )
readTaskRecord hit offset chars model =
    ( mapTaskRecords
        (\state ->
            { state
                | selected = Just hit
                , reader = OptionalLoading
            }
        )
        model
    , fetchInspection model
        ("task-records/reader/" ++ model.incarnationId)
        "GET"
        Nothing
        ("incarnations/"
            ++ model.incarnationId
            ++ "/task-records/"
            ++ hit.entryId
            ++ "?before=2&after=2&offset="
            ++ String.fromInt (max 0 offset)
            ++ "&chars="
            ++ String.fromInt (clamp 1 6000 chars)
        )
    )


continueTaskRecord : String -> Model -> ( Model, Cmd Msg )
continueTaskRecord taskId model =
    let
        continuing =
            { model | tab = NowTab, stickToBottom = True }
    in
    if taskId == model.threadId then
        ( continuing, followTranscript () )

    else
        requestThreadSwitch taskId continuing


searchLongMemory : Model -> ( Model, Cmd Msg )
searchLongMemory model =
    let
        query =
            String.trim model.longMemoryQuery
    in
    if String.isEmpty query || optionalIsLoading model.longMemorySearch then
        ( model, Cmd.none )

    else
        ( { model | longMemorySearch = OptionalLoading }
        , fetchInspection model
            ("memory/grep/" ++ model.incarnationId)
            "POST"
            (Just
                (Encode.object
                    [ ( "action", Encode.string "grep" )
                    , ( "incarnationId", Encode.string model.incarnationId )
                    , ( "query", Encode.string query )
                    , ( "limit", Encode.int 20 )
                    ]
                )
            )
            ("incarnations/" ++ model.incarnationId ++ "/memories/search")
        )


loadWorkingMemory : Model -> ( Model, Cmd Msg )
loadWorkingMemory model =
    ( { model | workingMemory = OptionalLoading, sleepCycles = OptionalLoading }
    , Cmd.batch
        [ fetchInspection model
            ("working/head/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/working-memory")
        , fetchInspection model
            ("working/sleeps/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/sleep-cycles")
        ]
    )


openSelf : Model -> ( Model, Cmd Msg )
openSelf model =
    if optionalIsIdle model.rootPrompts || optionalIsIdle model.prompts then
        loadPrompts model

    else
        ( model, Cmd.none )


loadPrompts : Model -> ( Model, Cmd Msg )
loadPrompts model =
    ( { model | rootPrompts = OptionalLoading, prompts = OptionalLoading, promptMessage = Nothing }
    , Cmd.batch
        [ fetchInspection model "prompt/root" "GET" Nothing "prompts/root"
        , fetchInspection model
            ("prompt/list/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/prompts")
        ]
    )


generatePromptDraft : Model -> ( Model, Cmd Msg )
generatePromptDraft model =
    if model.generatingPrompt then
        ( model, Cmd.none )

    else
        ( { model | generatingPrompt = True, promptMessage = Nothing }
        , fetchInspection model
            ("prompt/generate/" ++ model.incarnationId)
            "POST"
            (Just
                (Encode.object
                    [ ( "sourceIntent", Encode.string "regenerate from the current incarnation direction for user audit" )
                    , ( "activate", Encode.bool False )
                    ]
                )
            )
            ("incarnations/" ++ model.incarnationId ++ "/prompts/generate")
        )


activatePromptRevision : String -> Model -> ( Model, Cmd Msg )
activatePromptRevision identifier model =
    case model.activatingPrompt of
        Just _ ->
            ( model, Cmd.none )

        Nothing ->
            ( { model | activatingPrompt = Just identifier, promptMessage = Nothing }
            , fetchInspection model
                ("prompt/activate/" ++ model.incarnationId ++ "/" ++ identifier)
                "POST"
                (Just (Encode.object [ ( "expectedRevision", Encode.int model.incarnation.revision ) ]))
                ("incarnations/"
                    ++ model.incarnationId
                    ++ "/prompts/"
                    ++ identifier
                    ++ "/activate"
                )
            )


activateRootPromptRevision : String -> Int -> Model -> ( Model, Cmd Msg )
activateRootPromptRevision identifier expected model =
    case model.activatingPrompt of
        Just _ ->
            ( model, Cmd.none )

        Nothing ->
            ( { model | activatingPrompt = Just identifier, promptMessage = Nothing }
            , fetchInspection model
                ("prompt/activate-root/" ++ identifier)
                "POST"
                (Just (Encode.object [ ( "expectedRevision", Encode.int expected ) ]))
                ("prompts/root/" ++ identifier ++ "/activate")
            )


mapPromptEditor : (PromptEditor -> PromptEditor) -> Model -> Model
mapPromptEditor transform model =
    { model | promptEditor = Maybe.map transform model.promptEditor, promptMessage = Nothing }


savePromptEdit : Model -> ( Model, Cmd Msg )
savePromptEdit model =
    case model.promptEditor of
        Nothing ->
            ( model, Cmd.none )

        Just editor ->
            let
                source =
                    String.trim editor.sourceIntent

                content =
                    String.trim editor.content

                kind =
                    if editor.root then
                        "prompt/edit/root"

                    else
                        "prompt/edit/incarnation/" ++ model.incarnationId

                path =
                    if editor.root then
                        "prompts/root"

                    else
                        "incarnations/" ++ model.incarnationId ++ "/prompts"
            in
            if editor.saving then
                ( model, Cmd.none )

            else if String.isEmpty source || String.isEmpty content then
                ( { model | promptMessage = Just "修改理由与 Prompt 内容不能为空。" }, Cmd.none )

            else
                ( { model
                    | promptEditor = Just { editor | saving = True }
                    , promptMessage = Nothing
                  }
                , fetchInspection model
                    kind
                    "POST"
                    (Just
                        (Encode.object
                            [ ( "sourceIntent", Encode.string source )
                            , ( "content", Encode.string content )
                            , ( "parentRevision", Encode.string editor.baseId )
                            ]
                        )
                    )
                    path
                )


saveSelf : Model -> ( Model, Cmd Msg )
saveSelf model =
    let
        name =
            String.trim model.selfNameDraft

        direction =
            String.trim model.selfDirectionDraft
    in
    if model.savingSelf then
        ( model, Cmd.none )

    else if String.isEmpty name || String.isEmpty direction then
        ( { model | selfMessage = Just "名称与方向不能为空。" }, Cmd.none )

    else
        ( { model | savingSelf = True, selfMessage = Nothing }
        , fetchInspection model
            ("self/save/" ++ model.incarnationId)
            "PATCH"
            (Just
                (Encode.object
                    [ ( "expectedRevision", Encode.int model.incarnation.revision )
                    , ( "name", Encode.string name )
                    , ( "direction", Encode.string direction )
                    , ( "impressionModel", blankAsNull model.selfImpressionModelDraft )
                    ]
                )
            )
            ("incarnations/" ++ model.incarnationId)
        )


archiveIncarnation : Model -> ( Model, Cmd Msg )
archiveIncarnation model =
    if
        model.incarnationId
            == "yuki"
            || isBusy model.phase
            || model.archivingIncarnation
            || not model.incarnationArchiveConfirm
    then
        ( model, Cmd.none )

    else
        ( { model | archivingIncarnation = True, selfMessage = Nothing }
        , fetchInspection model
            ("incarnation/archive/" ++ model.incarnationId)
            "POST"
            (Just
                (Encode.object
                    [ ( "expectedRevision", Encode.int model.incarnation.revision )
                    ]
                )
            )
            ("incarnations/" ++ model.incarnationId ++ "/archive")
        )


restoreIncarnation : String -> Int -> Model -> ( Model, Cmd Msg )
restoreIncarnation identifier revision model =
    if isBusy model.phase || model.restoringIncarnation /= Nothing then
        ( model, Cmd.none )

    else
        ( { model | restoringIncarnation = Just identifier, incarnationNotice = Nothing }
        , fetchInspection model
            ("incarnation/restore/" ++ identifier)
            "POST"
            (Just (Encode.object [ ( "expectedRevision", Encode.int revision ) ]))
            ("incarnations/" ++ identifier ++ "/restore")
        )


mapIncarnationForm : (IncarnationForm -> IncarnationForm) -> Model -> Model
mapIncarnationForm transform model =
    { model | incarnationForm = Maybe.map transform model.incarnationForm }


createIncarnation : Model -> ( Model, Cmd Msg )
createIncarnation model =
    case model.incarnationForm of
        Nothing ->
            ( model, Cmd.none )

        Just draft ->
            let
                identifier =
                    String.trim draft.identifier

                name =
                    String.trim draft.name

                direction =
                    String.trim draft.direction
            in
            if draft.saving then
                ( model, Cmd.none )

            else if isBusy model.phase then
                ( mapIncarnationForm (\formDraft -> { formDraft | error = Just "请先结束当前运行。" }) model
                , Cmd.none
                )

            else if List.any String.isEmpty [ identifier, name, direction ] then
                ( mapIncarnationForm (\formDraft -> { formDraft | error = Just "ID、名称与方向不能为空。" }) model
                , Cmd.none
                )

            else
                ( mapIncarnationForm (\formDraft -> { formDraft | saving = True, error = Nothing }) model
                , fetchInspection model
                    "incarnations/create"
                    "POST"
                    (Just
                        (Encode.object
                            [ ( "id", Encode.string identifier )
                            , ( "name", Encode.string name )
                            , ( "direction", Encode.string direction )
                            , ( "impressionModel", blankAsNull draft.impressionModel )
                            ]
                        )
                    )
                    "incarnations"
                )


optionalIsIdle : OptionalRemote a -> Bool
optionalIsIdle remote =
    case remote of
        OptionalIdle ->
            True

        _ ->
            False


optionalIsLoading : OptionalRemote a -> Bool
optionalIsLoading remote =
    case remote of
        OptionalLoading ->
            True

        _ ->
            False


journalCmd : Model -> String -> Cmd Msg
journalCmd model runId =
    fetchInspection model ("journal/" ++ runId) "GET" Nothing ("journal?run=" ++ runId)


journalRefresh : Model -> List (Cmd Msg)
journalRefresh model =
    List.map (journalCmd model) (Dict.keys model.inspection.runLogs)


inspectionRefreshCmds : Model -> Cmd Msg
inspectionRefreshCmds model =
    Cmd.batch
        ([ fetchInspection model "artifacts" "GET" Nothing "artifacts"
         , fetchInspection model "runs" "GET" Nothing "journal/runs"
         ]
            ++ journalRefresh model
        )


markLoading : Inspection -> Inspection
markLoading inspection =
    { inspection
        | artifacts = Loading
        , runs = Loading
        , summaries = Dict.empty
        , runLogs = Dict.map (\_ _ -> Loading) inspection.runLogs
    }


toggleArtifact : String -> Model -> ( Model, Cmd Msg )
toggleArtifact identifier model =
    let
        inspection =
            model.inspection
    in
    if Dict.member identifier inspection.artifactBodies then
        ( { model | inspection = { inspection | artifactBodies = Dict.remove identifier inspection.artifactBodies } }
        , Cmd.none
        )

    else
        ( { model | inspection = { inspection | artifactBodies = Dict.insert identifier Loading inspection.artifactBodies } }
        , fetchInspection model ("artifact/" ++ identifier) "GET" Nothing ("artifacts/" ++ identifier)
        )


applyInspection : InspectionResult -> Model -> ( Model, Cmd Msg )
applyInspection result model =
    let
        inspection =
            model.inspection

        resolve : String -> Decoder a -> Remote a
        resolve panel decoder =
            if result.status >= 200 && result.status < 300 then
                Decode.decodeValue decoder result.body
                    |> Result.map Loaded
                    |> Result.withDefault (LoadFailed (panel ++ "：响应无法解码"))

            else
                LoadFailed (panel ++ "：" ++ statusLabel result)

        resolveOptional : String -> Decoder a -> OptionalRemote a
        resolveOptional panel decoder =
            if result.status >= 200 && result.status < 300 then
                Decode.decodeValue decoder result.body
                    |> Result.map OptionalLoaded
                    |> Result.withDefault (OptionalFailed (panel ++ "：响应无法解码"))

            else if result.status == 404 then
                OptionalUnavailable (panel ++ "接口尚未接通")

            else
                OptionalFailed (panel ++ "：" ++ statusLabel result)

        updated : (Inspection -> Inspection) -> ( Model, Cmd Msg )
        updated transform =
            ( { model | inspection = transform inspection }, Cmd.none )
    in
    case String.split "/" result.kind of
        [ "incarnations", "list" ] ->
            let
                remote =
                    resolveOptional "分身索引" (Decode.list incarnationDecoder)

                current =
                    case remote of
                        OptionalLoaded entries ->
                            let
                                active =
                                    List.filter (\entry -> entry.status == "active") entries

                                selected =
                                    active
                                        |> List.filter (\entry -> entry.id == model.incarnationId)
                                        |> List.head

                                default =
                                    active
                                        |> List.filter (\entry -> entry.id == "yuki")
                                        |> List.head
                            in
                            orElse selected (orElse default (List.head active))
                                |> Maybe.withDefault model.incarnation

                        _ ->
                            model.incarnation

                notice =
                    case remote of
                        OptionalUnavailable _ ->
                            Just "分身接口尚未接通；当前以本机默认分身继续，任务与运行能力不受影响。"

                        OptionalFailed message ->
                            Just message

                        _ ->
                            Nothing

                base =
                    { model
                        | incarnations = remote
                        , incarnation = current
                        , incarnationNotice = notice
                        , selfNameDraft = current.name
                        , selfDirectionDraft = current.direction
                        , selfImpressionModelDraft = Maybe.withDefault "" current.impressionModel
                    }
            in
            if current.id /= model.incarnationId && current.status == "active" then
                let
                    ( switched, switchCmd ) =
                        switchIncarnation current.id base
                in
                ( { switched | incarnationNotice = Just "上次使用的分身已移除；已回到可用分身。" }
                , switchCmd
                )

            else
                ( base, Cmd.none )

        [ "incarnations", "create" ] ->
            if result.status >= 200 && result.status < 300 then
                case
                    Decode.decodeValue
                        (Decode.oneOf
                            [ Decode.field "incarnation" incarnationDecoder
                            , incarnationDecoder
                            ]
                        )
                        result.body
                of
                    Ok incarnation ->
                        let
                            entries =
                                case model.incarnations of
                                    OptionalLoaded values ->
                                        incarnation :: List.filter (\entry -> entry.id /= incarnation.id) values

                                    _ ->
                                        [ incarnation ]

                            switched =
                                { model
                                    | incarnationId = incarnation.id
                                    , incarnation = incarnation
                                    , incarnations = OptionalLoaded entries
                                    , incarnationNotice = Nothing
                                    , selfNameDraft = incarnation.name
                                    , selfDirectionDraft = incarnation.direction
                                    , selfImpressionModelDraft = Maybe.withDefault "" incarnation.impressionModel
                                    , savingSelf = False
                                    , selfMessage = Nothing
                                    , incarnationArchiveConfirm = False
                                    , archivingIncarnation = False
                                    , restoringIncarnation = Nothing
                                    , incarnationForm = Nothing
                                    , impression = OptionalIdle
                                    , impressionActivations = OptionalIdle
                                    , impressionRevisions = OptionalIdle
                                    , memoryRecordMode = TaskRecordMode
                                    , taskRecords = emptyTaskRecordMemory
                                    , longMemoryQuery = ""
                                    , longMemorySearch = OptionalIdle
                                    , workingMemory = OptionalIdle
                                    , sleepCycles = OptionalIdle
                                    , rootPrompts = model.rootPrompts
                                    , prompts = OptionalIdle
                                    , generatingPrompt = False
                                    , activatingPrompt = Nothing
                                    , promptEditor = Nothing
                                    , promptMessage = Nothing
                                    , sessions = Loading
                                    , threadBase = incarnation.id
                                    , threadId = "unbound-" ++ incarnation.id
                                    , currentTaskBelongs = False
                                    , messages = Dict.empty
                                    , messageOrder = []
                                    , tools = Dict.empty
                                    , draft = ""
                                    , pathSuggestions = []
                                    , phase = Idle
                                    , activeRun = Nothing
                                    , activeStep = Nothing
                                    , error = Nothing
                                    , tree = NotAsked
                                    , usage = Nothing
                                    , contextGauge = Nothing
                                    , tab = NowTab
                                }
                        in
                        ( switched
                        , Cmd.batch
                            [ persistIncarnationId incarnation.id
                            , sessionsCmd switched
                            ]
                        )

                    Err _ ->
                        ( mapIncarnationForm
                            (\draft -> { draft | saving = False, error = Just "创建响应无法解码。" })
                            model
                        , Cmd.none
                        )

            else
                ( mapIncarnationForm
                    (\draft -> { draft | saving = False, error = Just (statusLabel result) })
                    model
                , Cmd.none
                )

        [ "incarnation", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else
                case resolveOptional "分身详情" incarnationDecoder of
                    OptionalLoaded incarnation ->
                        ( { model
                            | incarnation = incarnation
                            , incarnationNotice = Nothing
                            , selfNameDraft = incarnation.name
                            , selfDirectionDraft = incarnation.direction
                            , selfImpressionModelDraft = Maybe.withDefault "" incarnation.impressionModel
                          }
                        , Cmd.none
                        )

                    OptionalUnavailable message ->
                        ( { model | incarnationNotice = Just (message ++ "；当前显示本机默认投影。") }, Cmd.none )

                    OptionalFailed message ->
                        ( { model | incarnationNotice = Just message }, Cmd.none )

                    _ ->
                        ( model, Cmd.none )

        [ "incarnation", "archive", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else if result.status >= 200 && result.status < 300 then
                case Decode.decodeValue incarnationDecoder result.body of
                    Ok archived ->
                        let
                            entries =
                                case model.incarnations of
                                    OptionalLoaded values ->
                                        archived :: List.filter (\entry -> entry.id /= identifier) values

                                    _ ->
                                        [ archived, fallbackIncarnation "yuki" ]

                            prepared =
                                { model
                                    | incarnations = OptionalLoaded entries
                                    , incarnationArchiveConfirm = False
                                    , archivingIncarnation = False
                                }

                            ( switched, switchCmd ) =
                                switchIncarnation "yuki" prepared
                        in
                        ( { switched
                            | incarnationNotice =
                                Just
                                    (archived.name
                                        ++ " 已移除；所属任务已归档，记忆、经验与 Prompt 仍完整保留。"
                                    )
                          }
                        , switchCmd
                        )

                    Err _ ->
                        ( { model
                            | archivingIncarnation = False
                            , selfMessage = Just "移除响应无法解码。"
                          }
                        , Cmd.none
                        )

            else
                ( { model
                    | archivingIncarnation = False
                    , selfMessage = Just ("移除失败：" ++ statusLabel result)
                  }
                , Cmd.none
                )

        [ "incarnation", "restore", identifier ] ->
            if model.restoringIncarnation /= Just identifier then
                ( model, Cmd.none )

            else if result.status >= 200 && result.status < 300 then
                case Decode.decodeValue incarnationDecoder result.body of
                    Ok restored ->
                        let
                            entries =
                                case model.incarnations of
                                    OptionalLoaded values ->
                                        restored :: List.filter (\entry -> entry.id /= identifier) values

                                    _ ->
                                        [ restored ]
                        in
                        ( { model
                            | incarnations = OptionalLoaded entries
                            , restoringIncarnation = Nothing
                            , incarnationNotice =
                                Just (restored.name ++ " 已恢复；原有任务仍保持归档，可在任务页逐项恢复。")
                          }
                        , Cmd.none
                        )

                    Err _ ->
                        ( { model
                            | restoringIncarnation = Nothing
                            , incarnationNotice = Just "恢复响应无法解码。"
                          }
                        , Cmd.none
                        )

            else
                ( { model
                    | restoringIncarnation = Nothing
                    , incarnationNotice = Just ("恢复失败：" ++ statusLabel result)
                  }
                , Cmd.none
                )

        [ "impression", "state", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else
                ( { model
                    | impression =
                        resolveOptional
                            "印象"
                            (Decode.oneOf
                                [ impressionStateDecoder
                                , Decode.null
                                    { incarnationId = identifier
                                    , revision = 0
                                    , items = []
                                    , generatorRevision = "—"
                                    , effectiveHash = ""
                                    , updated = 0
                                    }
                                ]
                            )
                  }
                , Cmd.none
                )

        [ "impression", "activations", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else
                ( { model
                    | impressionActivations =
                        resolveOptional "印象激活" (Decode.list impressionActivationDecoder)
                  }
                , Cmd.none
                )

        [ "impression", "revisions", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else
                ( { model
                    | impressionRevisions =
                        resolveOptional "印象形成记录" (Decode.list impressionRevisionDecoder)
                    }
                , Cmd.none
                )

        [ "task-records", "catalog", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else
                ( mapTaskRecords
                    (\state ->
                        { state
                            | catalog =
                                resolveOptional "任务记录目录" (Decode.list taskArchiveSummaryDecoder)
                        }
                    )
                    model
                , Cmd.none
                )

        [ "task-records", "search", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else
                let
                    remote =
                        resolveOptional "任务记录检索" taskRecordSearchDecoder
                in
                case remote of
                    OptionalLoaded search ->
                        if
                            search.query
                                == String.trim model.taskRecords.query
                                && search.caseSensitive
                                == model.taskRecords.caseSensitive
                                && model.taskRecords.searchScope
                                == Maybe.withDefault "" model.taskRecords.taskId
                        then
                            ( mapTaskRecords (\state -> { state | search = remote }) model, Cmd.none )

                        else
                            ( model, Cmd.none )

                    _ ->
                        ( mapTaskRecords (\state -> { state | search = remote }) model, Cmd.none )

        [ "task-records", "reader", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else
                let
                    remote =
                        resolveOptional "任务记录上下文" taskRecordContextDecoder
                in
                case ( remote, model.taskRecords.selected ) of
                    ( OptionalLoaded context, Just hit ) ->
                        if context.anchorEntryId == hit.entryId then
                            ( mapTaskRecords (\state -> { state | reader = remote }) model, Cmd.none )

                        else
                            ( model, Cmd.none )

                    _ ->
                        ( mapTaskRecords (\state -> { state | reader = remote }) model, Cmd.none )

        [ "memory", "grep", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else
                ( { model | longMemorySearch = resolveOptional "长期记忆检索" memoryGrepDecoder }, Cmd.none )

        [ "working", "head", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else
                ( { model | workingMemory = resolveOptional "工作记忆" workingMemoryDecoder }, Cmd.none )

        [ "working", "sleeps", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else
                ( { model | sleepCycles = resolveOptional "睡眠记录" (Decode.list sleepCycleDecoder) }, Cmd.none )

        [ "prompt", "root" ] ->
            ( { model | rootPrompts = resolveOptional "Root Prompt" (Decode.list promptRevisionDecoder) }, Cmd.none )

        [ "prompt", "list", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else
                ( { model | prompts = resolveOptional "分身 Prompt" (Decode.list promptRevisionDecoder) }, Cmd.none )

        [ "prompt", "edit", "root" ] ->
            if result.status >= 200 && result.status < 300 then
                case Decode.decodeValue promptRevisionDecoder result.body of
                    Ok revision ->
                        let
                            refreshed =
                                { model
                                    | promptEditor = Nothing
                                    , rootPrompts = OptionalLoading
                                    , promptMessage = Just ("已保存 Root 草案 " ++ revision.id ++ "；审计后再显式激活。")
                                }
                        in
                        ( refreshed
                        , fetchInspection refreshed "prompt/root" "GET" Nothing "prompts/root"
                        )

                    Err _ ->
                        ( { model
                            | promptEditor = Maybe.map (\editor -> { editor | saving = False }) model.promptEditor
                            , promptMessage = Just "Root 草案已返回，但响应无法解码。"
                          }
                        , Cmd.none
                        )

            else
                ( { model
                    | promptEditor = Maybe.map (\editor -> { editor | saving = False }) model.promptEditor
                    , promptMessage = Just ("Root 修改失败：" ++ statusLabel result)
                  }
                , Cmd.none
                )

        [ "prompt", "edit", "incarnation", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else if result.status >= 200 && result.status < 300 then
                case Decode.decodeValue promptRevisionDecoder result.body of
                    Ok revision ->
                        let
                            refreshed =
                                { model
                                    | promptEditor = Nothing
                                    , prompts = OptionalLoading
                                    , promptMessage = Just ("已保存 Charter 草案 " ++ revision.id ++ "；审计后再显式激活。")
                                }
                        in
                        ( refreshed
                        , fetchInspection refreshed
                            ("prompt/list/" ++ identifier)
                            "GET"
                            Nothing
                            ("incarnations/" ++ identifier ++ "/prompts")
                        )

                    Err _ ->
                        ( { model
                            | promptEditor = Maybe.map (\editor -> { editor | saving = False }) model.promptEditor
                            , promptMessage = Just "Charter 草案已返回，但响应无法解码。"
                          }
                        , Cmd.none
                        )

            else
                ( { model
                    | promptEditor = Maybe.map (\editor -> { editor | saving = False }) model.promptEditor
                    , promptMessage = Just ("Charter 修改失败：" ++ statusLabel result)
                  }
                , Cmd.none
                )

        [ "prompt", "generate", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else if result.status >= 200 && result.status < 300 then
                case Decode.decodeValue (Decode.field "prompt" promptRevisionDecoder) result.body of
                    Ok generated ->
                        let
                            refreshed =
                                { model
                                    | generatingPrompt = False
                                    , prompts = OptionalLoading
                                    , promptMessage = Just ("已生成草案 " ++ generated.id ++ "；尚未激活。")
                                }
                        in
                        ( refreshed
                        , fetchInspection refreshed
                            ("prompt/list/" ++ identifier)
                            "GET"
                            Nothing
                            ("incarnations/" ++ identifier ++ "/prompts")
                        )

                    Err _ ->
                        ( { model
                            | generatingPrompt = False
                            , promptMessage = Just "生成已返回，但响应无法解码。"
                          }
                        , Cmd.none
                        )

            else
                ( { model
                    | generatingPrompt = False
                    , promptMessage = Just ("生成失败：" ++ statusLabel result)
                  }
                , Cmd.none
                )

        [ "prompt", "activate", incarnationId, promptId ] ->
            if incarnationId /= model.incarnationId then
                ( model, Cmd.none )

            else if result.status >= 200 && result.status < 300 then
                case Decode.decodeValue incarnationDecoder result.body of
                    Ok incarnation ->
                        let
                            updateEntry entry =
                                if entry.id == incarnation.id then
                                    incarnation

                                else
                                    entry

                            updatedIncarnations =
                                case model.incarnations of
                                    OptionalLoaded entries ->
                                        OptionalLoaded (List.map updateEntry entries)

                                    other ->
                                        other

                            refreshed =
                                { model
                                    | incarnation = incarnation
                                    , incarnations = updatedIncarnations
                                    , activatingPrompt = Nothing
                                    , promptMessage = Just ("已激活 " ++ promptId ++ "。")
                                    , prompts = OptionalLoading
                                }
                        in
                        ( refreshed
                        , fetchInspection refreshed
                            ("prompt/list/" ++ incarnationId)
                            "GET"
                            Nothing
                            ("incarnations/" ++ incarnationId ++ "/prompts")
                        )

                    Err _ ->
                        ( { model
                            | activatingPrompt = Nothing
                            , promptMessage = Just "激活响应无法解码。"
                          }
                        , Cmd.none
                        )

            else
                ( { model
                    | activatingPrompt = Nothing
                    , promptMessage = Just ("激活失败：" ++ statusLabel result)
                  }
                , Cmd.none
                )

        [ "prompt", "activate-root", promptId ] ->
            if result.status >= 200 && result.status < 300 then
                case Decode.decodeValue promptRevisionDecoder result.body of
                    Ok revision ->
                        let
                            refreshed =
                                { model
                                    | activatingPrompt = Nothing
                                    , rootPrompts = OptionalLoading
                                    , promptMessage = Just ("已激活 Root revision " ++ revision.id ++ "。")
                                }
                        in
                        ( refreshed
                        , fetchInspection refreshed "prompt/root" "GET" Nothing "prompts/root"
                        )

                    Err _ ->
                        ( { model
                            | activatingPrompt = Nothing
                            , promptMessage = Just "Root 激活响应无法解码。"
                          }
                        , Cmd.none
                        )

            else
                ( { model
                    | activatingPrompt = Nothing
                    , promptMessage = Just ("Root 激活失败：" ++ statusLabel result)
                  }
                , Cmd.none
                )

        [ "self", "save", identifier ] ->
            if identifier /= model.incarnationId then
                ( model, Cmd.none )

            else if result.status >= 200 && result.status < 300 then
                case Decode.decodeValue (Decode.field "incarnation" incarnationDecoder) result.body of
                    Ok incarnation ->
                        let
                            updateEntry entry =
                                if entry.id == incarnation.id then
                                    incarnation

                                else
                                    entry

                            updatedIncarnations =
                                case model.incarnations of
                                    OptionalLoaded entries ->
                                        OptionalLoaded (List.map updateEntry entries)

                                    other ->
                                        other

                            refreshed =
                                { model
                                    | incarnation = incarnation
                                    , incarnations = updatedIncarnations
                                    , selfNameDraft = incarnation.name
                                    , selfDirectionDraft = incarnation.direction
                                    , selfImpressionModelDraft = Maybe.withDefault "" incarnation.impressionModel
                                    , savingSelf = False
                                    , selfMessage = Just "自我来源已更新；系统已生成一份可审计的 Charter 草案。"
                                    , prompts = OptionalLoading
                                }
                        in
                        ( refreshed
                        , fetchInspection refreshed
                            ("prompt/list/" ++ identifier)
                            "GET"
                            Nothing
                            ("incarnations/" ++ identifier ++ "/prompts")
                        )

                    Err _ ->
                        ( { model | savingSelf = False, selfMessage = Just "自我更新响应无法解码。" }, Cmd.none )

            else
                ( { model
                    | savingSelf = False
                    , selfMessage = Just ("自我更新失败：" ++ statusLabel result)
                  }
                , Cmd.none
                )

        [ "context", "compact", threadId ] ->
            if threadId /= model.threadId then
                ( model, Cmd.none )

            else if result.status < 200 || result.status >= 300 then
                ( { model
                    | compacting = False
                    , compactConfirm = False
                    , compactMessage = Just ("睡眠适配失败：" ++ statusLabel result)
                  }
                , Cmd.none
                )

            else
                case Decode.decodeValue compactResultDecoder result.body of
                    Ok (CompactUnchanged message) ->
                        ( { model
                            | compacting = False
                            , compactConfirm = False
                            , compactMessage = Just message
                          }
                        , Cmd.none
                        )

                    Ok (CompactChanged before after maybeBudget dropped) ->
                        let
                            budget =
                                maybeBudget
                                    |> Maybe.withDefault
                                        (model.contextGauge
                                            |> Maybe.map .budget
                                            |> Maybe.withDefault (max 1 after)
                                        )

                            refreshed =
                                { model
                                    | messages = Dict.empty
                                    , messageOrder = []
                                    , tools = Dict.empty
                                    , compacting = False
                                    , compactConfirm = False
                                    , compactMessage =
                                        Just
                                            ("已睡醒："
                                                ++ String.fromInt before
                                                ++ " → "
                                                ++ String.fromInt after
                                                ++ " tokens；"
                                                ++ String.fromInt dropped
                                                ++ " 条旧消息已退出活跃 context。遗忘理由见右侧睡眠记录。"
                                            )
                                    , contextGauge = Just (ContextGauge after budget False True Nothing Nothing Nothing)
                                    , workingMemory = OptionalLoading
                                    , sleepCycles = OptionalLoading
                                }
                        in
                        ( refreshed
                        , Cmd.batch
                            [ transcriptCmd refreshed
                            , followTranscript ()
                            , fetchInspection refreshed
                                ("working/head/" ++ refreshed.incarnationId)
                                "GET"
                                Nothing
                                ("incarnations/" ++ refreshed.incarnationId ++ "/working-memory")
                            , fetchInspection refreshed
                                ("working/sleeps/" ++ refreshed.incarnationId)
                                "GET"
                                Nothing
                                ("incarnations/" ++ refreshed.incarnationId ++ "/sleep-cycles")
                            ]
                        )

                    Err _ ->
                        ( { model
                            | compacting = False
                            , compactConfirm = False
                            , compactMessage = Just "睡眠响应无法解码。"
                          }
                        , Cmd.none
                        )

        [ "control", action, _, identifier ] ->
            if result.status >= 200 && result.status < 300 then
                ( appendNotice
                    (if action == "steer" then
                        "steer queued"

                     else
                        "follow-up queued"
                    )
                    model
                , Cmd.none
                )

            else
                let
                    restored =
                        restoreQueued identifier model
                in
                ( { restored | error = Just ("消息未排入运行：" ++ statusLabel result) }, Cmd.none )

        [ "brief" ] ->
            updated (\i -> { i | brief = briefRemote result })

        [ "facts" ] ->
            updated (\i -> { i | facts = resolve "事实列表" (Decode.list factDecoder) })

        [ "artifacts" ] ->
            updated (\i -> { i | artifacts = resolve "工件列表" (Decode.list artifactDecoder) })

        [ "artifact", identifier ] ->
            updated (\i -> { i | artifactBodies = Dict.insert identifier (resolve "工件内容" Decode.string) i.artifactBodies })

        [ "runs" ] ->
            let
                remote =
                    resolve "运行列表" (Decode.list Decode.string)

                keep ids =
                    Dict.filter (\runId _ -> List.member runId ids)

                summaries =
                    case remote of
                        Loaded ids ->
                            keep ids inspection.summaries

                        _ ->
                            inspection.summaries

                runLogs =
                    case remote of
                        Loaded ids ->
                            keep ids inspection.runLogs

                        _ ->
                            inspection.runLogs

                commands =
                    case remote of
                        Loaded ids ->
                            List.concat
                                [ ids
                                    |> List.filter (\runId -> needsFetch (Dict.get runId summaries))
                                    |> List.map
                                        (\runId ->
                                            fetchInspection model
                                                ("summary/" ++ runId)
                                                "GET"
                                                Nothing
                                                ("journal/runs/" ++ runId ++ "/summary")
                                        )
                                , ids
                                    |> List.filter (\runId -> needsFetch (Dict.get runId runLogs))
                                    |> List.map (journalCmd model)
                                ]

                        _ ->
                            []
            in
            ( { model | inspection = { inspection | runs = remote, summaries = summaries, runLogs = runLogs } }
            , Cmd.batch commands
            )

        [ "summary", runId ] ->
            updated (\i -> { i | summaries = Dict.insert runId (resolve "运行汇总" runSummaryDecoder) i.summaries })

        [ "replay", _ ] ->
            let
                remote =
                    resolve "回放" replayReportDecoder

                verdicts =
                    case remote of
                        Loaded report ->
                            Dict.insert report.runId (report.divergence == Nothing) inspection.verdicts

                        _ ->
                            inspection.verdicts
            in
            ( { model | inspection = { inspection | replay = remote, verdicts = verdicts } }, Cmd.none )

        [ "tree" ] ->
            ( { model | tree = treeRemote result }, Cmd.none )

        [ "paths" ] ->
            if result.status >= 200 && result.status < 300 then
                case Decode.decodeValue pathCompletionDecoder result.body of
                    Ok completion ->
                        if pathReferencePrefix model.draft == Just completion.prefix then
                            ( { model | pathSuggestions = completion.paths }, Cmd.none )

                        else
                            ( model, Cmd.none )

                    Err _ ->
                        ( { model | pathSuggestions = [] }, Cmd.none )

            else
                ( { model | pathSuggestions = [] }, Cmd.none )

        [ "sessions", "list" ] ->
            let
                remote =
                    resolve "任务列表" (Decode.list sessionMetaDecoder)

                title =
                    case remote of
                        Loaded sessions ->
                            sessions
                                |> List.filter (\session -> session.id == model.threadId)
                                |> List.head
                                |> Maybe.map .title
                                |> Maybe.withDefault model.sessionTitleDraft

                        _ ->
                            model.sessionTitleDraft

            in
            case remote of
                Loaded sessions ->
                    if List.any (\session -> session.id == model.threadId) sessions then
                        ( { model
                            | sessions = remote
                            , currentTaskBelongs = True
                            , sessionTitleDraft = title
                          }
                        , Cmd.none
                        )

                    else
                        case List.filter (\session -> not session.archived) sessions |> List.head of
                            Just first ->
                                requestThreadSwitch first.id
                                    { model
                                        | sessions = remote
                                        , currentTaskBelongs = False
                                        , sessionTitleDraft = ""
                                    }

                            Nothing ->
                                ( { model
                                    | sessions = remote
                                    , currentTaskBelongs = False
                                    , sessionTitleDraft = ""
                                  }
                                , Cmd.none
                                )

                _ ->
                    ( { model | sessions = remote, currentTaskBelongs = False }, Cmd.none )

        [ "sessions", "create", threadId ] ->
            if result.status >= 200 && result.status < 300 then
                case model.sessionForm of
                    Just form ->
                        ( model
                        , putThreadConfig model "session/save" threadId (encodeThreadConfig model.incarnationId (draftFromForm form))
                        )

                    Nothing ->
                        ( model, Cmd.none )

            else
                ( mapSessionForm (\form -> { form | saving = False, error = Just (statusLabel result) }) model
                , Cmd.none
                )

        [ "sessions", "rename", _ ] ->
            sessionMutation result model

        [ "sessions", "archive", _ ] ->
            sessionMutation result model

        [ "sessions", "restore", _ ] ->
            sessionMutation result model

        [ "sessions", "fork", target ] ->
            if result.status >= 200 && result.status < 300 then
                let
                    advanced =
                        { model | threadNumber = model.threadNumber + 1, forkNodeDraft = "" }

                    ( switching, switchCmd ) =
                        requestThreadSwitch target advanced
                in
                ( { switching | sessions = Loading }
                , Cmd.batch [ switchCmd, sessionsCmd advanced ]
                )

            else
                ( { model | sessionActionError = Just (statusLabel result) }, Cmd.none )

        [ "sessions", "export", threadId ] ->
            if result.status >= 200 && result.status < 300 then
                ( model
                , exportSessionFile
                    (Encode.object
                        [ ( "threadId", Encode.string threadId )
                        , ( "bundle", result.body )
                        ]
                    )
                )

            else
                ( { model | sessionActionError = Just (statusLabel result) }, Cmd.none )

        [ "sessions", "import" ] ->
            if result.status >= 200 && result.status < 300 then
                case Decode.decodeValue sessionMetaDecoder result.body of
                    Ok session ->
                        let
                            ( switching, switchCmd ) =
                                requestThreadSwitch session.id model
                        in
                        ( { switching | sessions = Loading }
                        , Cmd.batch [ switchCmd, sessionsCmd model ]
                        )

                    Err _ ->
                        ( { model | sessionActionError = Just "导入响应无法解码。" }, Cmd.none )

            else
                ( { model | sessionActionError = Just (statusLabel result) }, Cmd.none )

        [ "switch", threadId, "transcript" ] ->
            receiveThreadSwitch threadId result model

        [ "threads", threadId, "transcript" ] ->
            receiveTranscript threadId result model

        [ "session", "save" ] ->
            sessionSaved result model

        [ "session", scope ] ->
            ( mapSessionForm (fillScope scope result >> applyPrefill) model, Cmd.none )

        [ "config", "global" ] ->
            ( mapConfigPanel (\panel -> { panel | global = resolve "全局配置" globalConfigDecoder }) model, Cmd.none )

        [ "providers" ] ->
            ( mapConfigPanel (\panel -> { panel | providers = resolve "Provider 列表" (Decode.list providerEntryDecoder) }) model, Cmd.none )

        [ "config", "thread", threadId ] ->
            if threadId /= model.threadId then
                ( model, Cmd.none )

            else
                ( mapConfigPanel (receiveThreadConfig threadId (resolve "任务配置" configViewDecoder)) model, Cmd.none )

        [ "config", "capabilities", threadId ] ->
            if threadId /= model.threadId then
                ( model, Cmd.none )

            else
                ( mapConfigPanel
                    (\panel -> { panel | capabilities = resolve "任务能力" (Decode.list Decode.string) })
                    model
                , Cmd.none
                )

        [ "config", "context", threadId ] ->
            if threadId /= model.threadId then
                ( model, Cmd.none )

            else
                ( mapConfigPanel
                    (\panel -> { panel | contextPolicy = resolve "上下文策略" contextPolicyDecoder })
                    model
                , Cmd.none
                )

        [ "config", "save", threadId ] ->
            configSaved threadId result model

        [ "config", "quick", threadId ] ->
            configSaved threadId result model

        [ "journal", runId ] ->
            updated (\i -> { i | runLogs = Dict.insert runId (resolve "运行日志" (Decode.list journalRowDecoder)) i.runLogs })

        _ ->
            ( model, Cmd.none )


restoreQueued : String -> Model -> Model
restoreQueued identifier model =
    case Dict.get identifier model.messages of
        Just (UserChat _ content) ->
            { model
                | draft =
                    if String.isEmpty (String.trim model.draft) then
                        content

                    else
                        content ++ "\n" ++ model.draft
                , messages = Dict.remove identifier model.messages
                , messageOrder = List.filter ((/=) identifier) model.messageOrder
            }

        _ ->
            model


needsFetch : Maybe (Remote a) -> Bool
needsFetch remote =
    case remote of
        Just (Loaded _) ->
            False

        Just Loading ->
            False

        _ ->
            True


treeRemote : InspectionResult -> Remote (Maybe (List String))
treeRemote result =
    if result.status == 404 then
        Loaded Nothing

    else if result.status >= 200 && result.status < 300 then
        Decode.decodeValue (Decode.list Decode.string) result.body
            |> Result.map (Loaded << Just)
            |> Result.withDefault (LoadFailed "目录树：响应无法解码")

    else
        LoadFailed ("目录树：" ++ statusLabel result)


pathCompletionDecoder : Decoder PathCompletion
pathCompletionDecoder =
    Decode.map2 PathCompletion
        (Decode.field "prefix" Decode.string)
        (Decode.field "paths" (Decode.list Decode.string))


sessionMutation : InspectionResult -> Model -> ( Model, Cmd Msg )
sessionMutation result model =
    if result.status >= 200 && result.status < 300 then
        ( { model | sessions = Loading, sessionActionError = Nothing }
        , sessionsCmd model
        )

    else
        ( { model | sessionActionError = Just (statusLabel result) }, Cmd.none )


receiveThreadSwitch : String -> InspectionResult -> Model -> ( Model, Cmd Msg )
receiveThreadSwitch threadId result model =
    if model.pendingSwitch /= Just threadId then
        ( model, Cmd.none )

    else if result.status >= 200 && result.status < 300 then
        case Decode.decodeValue transcriptDecoder result.body of
            Ok transcript ->
                let
                    reset =
                        resetThreadState threadId model

                    restored =
                        restoreTranscript transcript reset

                    ( configured, configCmd ) =
                        if restored.tab == CapabilitiesTab then
                            ensureConfigLoaded { restored | tree = Loading }

                        else
                            ( { restored | tree = Loading }, Cmd.none )

                    title =
                        sessionTitle threadId model.sessions
                in
                ( { configured
                    | pendingSwitch = Nothing
                    , currentTaskBelongs = True
                    , sessionTitleDraft = Maybe.withDefault threadId title
                    , sessionActionError = Nothing
                  }
                , Cmd.batch
                    [ persistThreadId threadId
                    , treeCmd configured
                    , configCmd
                    , followTranscript ()
                    ]
                )

            Err _ ->
                ( { model | pendingSwitch = Nothing, sessionActionError = Just "任务记录无法解码，已保留当前任务。" }
                , Cmd.none
                )

    else
        ( { model | pendingSwitch = Nothing, sessionActionError = Just ("切换失败，已保留当前任务：" ++ statusLabel result) }
        , Cmd.none
        )


receiveTranscript : String -> InspectionResult -> Model -> ( Model, Cmd Msg )
receiveTranscript threadId result model =
    if threadId /= model.threadId || not (Dict.isEmpty model.messages) then
        ( model, Cmd.none )

    else if result.status >= 200 && result.status < 300 then
        case Decode.decodeValue transcriptDecoder result.body of
            Ok transcript ->
                ( restoreTranscript transcript model
                , Cmd.batch [ followTranscript (), sessionsCmd model ]
                )

            Err _ ->
                ( model, Cmd.none )

    else
        ( model, Cmd.none )


sessionMetaDecoder : Decoder SessionMeta
sessionMetaDecoder =
    Decode.succeed SessionMeta
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "title" Decode.string)
        |> andMap (Decode.field "created" Decode.int)
        |> andMap (Decode.field "updated" Decode.int)
        |> andMap (Decode.field "archived" Decode.bool)
        |> andMap (Decode.maybe (Decode.field "parent" Decode.string))
        |> andMap (Decode.maybe (Decode.field "forkNode" Decode.string))


type TranscriptMessage
    = TUser String String
    | TSummary String String
    | TReasoning String String
    | TAssistant String String (List TranscriptToolCall)
    | TTool String String String


type alias TranscriptToolCall =
    { id : String
    , name : String
    , arguments : String
    }


transcriptDecoder : Decoder (List TranscriptMessage)
transcriptDecoder =
    Decode.field "messages" (Decode.list (Decode.maybe transcriptMessageDecoder))
        |> Decode.map (List.filterMap identity)


transcriptMessageDecoder : Decoder TranscriptMessage
transcriptMessageDecoder =
    Decode.field "role" Decode.string
        |> Decode.andThen
            (\role ->
                case role of
                    "user" ->
                        Decode.map2 TUser
                            (Decode.field "id" Decode.string)
                            (textField "content")

                    "developer" ->
                        Decode.map2 TSummary
                            (Decode.field "id" Decode.string)
                            (textField "content")

                    "system" ->
                        Decode.map2 TSummary
                            (Decode.field "id" Decode.string)
                            (textField "content")

                    "reasoning" ->
                        Decode.map2 TReasoning
                            (Decode.field "id" Decode.string)
                            (textField "content")

                    "assistant" ->
                        Decode.map3 TAssistant
                            (Decode.field "id" Decode.string)
                            (textField "content")
                            (Decode.oneOf [ Decode.field "toolCalls" (Decode.list transcriptToolCallDecoder), Decode.succeed [] ])

                    "tool" ->
                        Decode.map3 TTool
                            (Decode.field "id" Decode.string)
                            (textField "toolCallId")
                            (textField "content")

                    _ ->
                        Decode.fail ("unknown role " ++ role)
            )


textField : String -> Decoder String
textField name =
    Decode.oneOf [ Decode.field name Decode.string, Decode.succeed "" ]


transcriptToolCallDecoder : Decoder TranscriptToolCall
transcriptToolCallDecoder =
    Decode.map3 TranscriptToolCall
        (Decode.field "id" Decode.string)
        (Decode.at [ "function", "name" ] Decode.string)
        (Decode.oneOf [ Decode.at [ "function", "arguments" ] Decode.string, Decode.succeed "" ])


restoreTranscript : List TranscriptMessage -> Model -> Model
restoreTranscript transcript model =
    List.foldl restoreMessage model transcript


restoreMessage : TranscriptMessage -> Model -> Model
restoreMessage message model =
    case message of
        TUser identifier content ->
            appendChat identifier (UserChat identifier content) model

        TSummary identifier content ->
            appendChat identifier (SummaryChat identifier content) model

        TReasoning identifier content ->
            appendChat identifier
                (ReasoningChat { id = identifier, content = content, complete = True })
                model

        TAssistant identifier content calls ->
            appendChat identifier
                (AssistantChat
                    { id = identifier
                    , content = content
                    , toolCalls = List.map .id calls
                    , complete = True
                    }
                )
                { model | tools = List.foldl (\call -> Dict.insert call.id (restoredTool identifier call)) model.tools calls }

        TTool identifier callId content ->
            appendChat identifier
                (ToolChat { id = identifier, callId = callId, content = content })
                { model
                    | tools =
                        Dict.update callId
                            (Maybe.map
                                (\tool ->
                                    { tool
                                        | stage = ToolResolved ToolReturned
                                        , result = Just content
                                    }
                                )
                            )
                            model.tools
                }


restoredTool : String -> TranscriptToolCall -> ToolCall
restoredTool parentId call =
    { id = call.id
    , name = call.name
    , arguments = call.arguments
    , parentMessageId = Just parentId
    , stage =
        if call.name == confirmationToolName then
            ToolWaiting

        else
            ToolResolved ToolInterrupted
    , output = ""
    , result = Nothing
    }


appendChat : String -> ChatMessage -> Model -> Model
appendChat identifier chat model =
    if Dict.member identifier model.messages then
        model

    else
        { model
            | messages = Dict.insert identifier chat model.messages
            , messageOrder = model.messageOrder ++ [ identifier ]
        }


sessionSaved : InspectionResult -> Model -> ( Model, Cmd Msg )
sessionSaved result model =
    case model.sessionForm of
        Nothing ->
            ( model, Cmd.none )

        Just form ->
            if result.status >= 200 && result.status < 300 then
                switchThread form.targetId { model | threadNumber = model.threadNumber + 1 }

            else
                ( mapSessionForm (\f -> { f | saving = False, error = Just (statusLabel result) }) model
                , Cmd.none
                )


fillScope : String -> InspectionResult -> SessionForm -> SessionForm
fillScope scope result form =
    let
        decoder =
            if scope == "global" then
                Decode.field "defaults" configViewDecoder

            else
                configViewDecoder

        config =
            if result.status >= 200 && result.status < 300 then
                Decode.decodeValue decoder result.body
                    |> Result.withDefault emptyConfigView

            else
                emptyConfigView
    in
    if scope == "global" then
        { form | global = Just config }

    else
        { form | session = Just config }


applyPrefill : SessionForm -> SessionForm
applyPrefill form =
    case ( form.prefilled, form.global, form.session ) of
        ( False, Just global, Just session ) ->
            { form
                | cwd = ""
                , fs = orElse session.fs global.fs /= Just False
                , shell = orElse session.shell global.shell /= Just False
                , memory = orElse session.memory global.memory /= Just False
                , prefilled = True
            }

        _ ->
            form


mapSessionForm : (SessionForm -> SessionForm) -> Model -> Model
mapSessionForm transform model =
    { model | sessionForm = Maybe.map transform model.sessionForm }


toggleField : SessionField -> SessionForm -> SessionForm
toggleField field form =
    case field of
        FsField ->
            { form | fs = not form.fs }

        ShellField ->
            { form | shell = not form.shell }


mapConfigPanel : (ConfigPanel -> ConfigPanel) -> Model -> Model
mapConfigPanel transform model =
    { model | configPanel = transform model.configPanel }


mapConfigDraft : (ConfigDraft -> ConfigDraft) -> Model -> Model
mapConfigDraft transform =
    mapConfigPanel
        (\panel ->
            { panel
                | draft = transform panel.draft
                , saved = False
                , saveError = Nothing
            }
        )


setGate : SessionField -> Maybe Bool -> ConfigDraft -> ConfigDraft
setGate field value draft =
    case field of
        FsField ->
            { draft | fs = value }

        ShellField ->
            { draft | shell = value }


ensureConfigLoaded : Model -> ( Model, Cmd Msg )
ensureConfigLoaded model =
    let
        panel =
            model.configPanel
    in
    if panel.loadedFor == Just model.threadId then
        ( model, Cmd.none )

    else
        ( { model
            | configPanel =
                { panel
                    | session = Loading
                    , capabilities = Loading
                    , contextPolicy = Loading
                    , saving = False
                    , saved = False
                    , saveError = Nothing
                    , providers =
                        case panel.providers of
                            Loaded _ ->
                                panel.providers

                            _ ->
                                Loading
                    , global =
                        case panel.global of
                            Loaded _ ->
                                panel.global

                            _ ->
                                Loading
                }
          }
        , Cmd.batch (configLoadCmds model)
        )


configLoadCmds : Model -> List (Cmd Msg)
configLoadCmds model =
    fetchInspection model ("config/thread/" ++ model.threadId) "GET" Nothing ("config/threads/" ++ model.threadId)
        :: fetchInspection model
            ("config/capabilities/" ++ model.threadId)
            "GET"
            Nothing
            ("config/threads/" ++ model.threadId ++ "/capabilities")
        :: fetchInspection model
            ("config/context/" ++ model.threadId)
            "GET"
            Nothing
            ("config/threads/" ++ model.threadId ++ "/context")
        :: fetchInspection model "providers" "GET" Nothing "providers"
        :: (case model.configPanel.global of
                Loaded _ ->
                    []

                _ ->
                    [ fetchInspection model "config/global" "GET" Nothing "config" ]
           )


providerEntries : Remote (List ProviderEntryView) -> List ProviderEntryView
providerEntries remote =
    case remote of
        Loaded entries ->
            entries

        _ ->
            []


providerByName : Remote (List ProviderEntryView) -> String -> Maybe ProviderEntryView
providerByName remote name =
    providerEntries remote
        |> List.filter (\entry -> entry.name == name)
        |> List.head


reasoningEfforts : String -> List String
reasoningEfforts provider =
    case provider of
        "deepseek" ->
            [ "high", "max" ]

        "kimi-coding" ->
            [ "low", "high", "max" ]

        _ ->
            []


defaultReasoningEffort : String -> String
defaultReasoningEffort provider =
    case provider of
        "deepseek" ->
            "high"

        "kimi-coding" ->
            "max"

        _ ->
            ""


effortForProvider : String -> String -> String
effortForProvider provider current =
    if List.member current (reasoningEfforts provider) then
        current

    else
        defaultReasoningEffort provider


selectProviderDraft : Remote (List ProviderEntryView) -> String -> ConfigDraft -> ConfigDraft
selectProviderDraft remote name draft =
    case providerByName remote name of
        Just entry ->
            { draft
                | provider = name
                , model = entry.defaultModel
                , reasoningEffort = effortForProvider name draft.reasoningEffort
            }

        Nothing ->
            { draft | provider = name, model = "", reasoningEffort = defaultReasoningEffort name }


effectiveProviderName : ConfigPanel -> String
effectiveProviderName panel =
    if not (String.isEmpty (String.trim panel.draft.provider)) then
        panel.draft.provider

    else
        case panel.global of
            Loaded global ->
                Maybe.withDefault global.provider.name global.defaults.provider

            _ ->
                ""


effectiveModelName : ConfigPanel -> String
effectiveModelName panel =
    if not (String.isEmpty (String.trim panel.draft.model)) then
        panel.draft.model

    else
        providerByName panel.providers (effectiveProviderName panel)
            |> Maybe.map .defaultModel
            |> Maybe.withDefault ""


effectiveReasoningEffort : ConfigPanel -> String
effectiveReasoningEffort panel =
    if not (String.isEmpty (String.trim panel.draft.reasoningEffort)) then
        panel.draft.reasoningEffort

    else
        defaultReasoningEffort (effectiveProviderName panel)


quickSelectModel : String -> Model -> ( Model, Cmd Msg )
quickSelectModel provider model =
    case providerByName model.configPanel.providers provider of
        Just entry ->
            if not entry.keyReady then
                ( mapConfigPanel (\panel -> { panel | saveError = Just (provider ++ " 的 key 未配置。") }) model, Cmd.none )

            else
                quickSave (selectProviderDraft model.configPanel.providers provider model.configPanel.draft) model

        Nothing ->
            ( model, Cmd.none )


quickSelectEffort : String -> Model -> ( Model, Cmd Msg )
quickSelectEffort effort model =
    let
        panel =
            model.configPanel

        provider =
            effectiveProviderName panel
    in
    if List.member effort (reasoningEfforts provider) then
        quickSave (setReasoningEffort effort panel.draft) model

    else
        ( model, Cmd.none )


setReasoningEffort : String -> ConfigDraft -> ConfigDraft
setReasoningEffort effort draft =
    { draft | reasoningEffort = effort }


quickSave : ConfigDraft -> Model -> ( Model, Cmd Msg )
quickSave draft model =
    let
        panel =
            model.configPanel
    in
    if panel.loadedFor /= Just model.threadId || panel.saving || isBusy model.phase || draft == panel.draft then
        ( model, Cmd.none )

    else
        case validateContextDraft draft of
            Just message ->
                ( { model | configPanel = { panel | saveError = Just message } }, Cmd.none )

            Nothing ->
                ( { model
                    | configPanel =
                        { panel
                            | draft = draft
                            , saving = True
                            , saved = False
                            , saveError = Nothing
                        }
                  }
                , putThreadConfig model ("config/quick/" ++ model.threadId) model.threadId (encodeThreadConfig model.incarnationId draft)
                )


saveConfig : Model -> ( Model, Cmd Msg )
saveConfig model =
    let
        panel =
            model.configPanel
    in
    if panel.saving then
        ( model, Cmd.none )

    else
        case validateContextDraft panel.draft of
            Just message ->
                ( { model | configPanel = { panel | saveError = Just message } }, Cmd.none )

            Nothing ->
                ( { model | configPanel = { panel | saving = True, saved = False, saveError = Nothing } }
                , putThreadConfig model ("config/save/" ++ model.threadId) model.threadId (encodeThreadConfig model.incarnationId panel.draft)
                )


receiveThreadConfig : String -> Remote ThreadConfigView -> ConfigPanel -> ConfigPanel
receiveThreadConfig threadId remote panel =
    { panel
        | session = remote
        , loadedFor =
            case remote of
                Loaded _ ->
                    Just threadId

                _ ->
                    Nothing
        , draft =
            case remote of
                Loaded config ->
                    draftFromConfig config

                _ ->
                    panel.draft
        , baseline =
            case remote of
                Loaded config ->
                    draftFromConfig config

                _ ->
                    panel.baseline
    }


configSaved : String -> InspectionResult -> Model -> ( Model, Cmd Msg )
configSaved threadId result model =
    let
        panel =
            model.configPanel
    in
    if threadId /= model.threadId then
        ( model, Cmd.none )

    else if result.status >= 200 && result.status < 300 then
        ( { model
            | configPanel =
                { panel
                    | capabilities = Loading
                    , contextPolicy = Loading
                    , saving = False
                    , saved = True
                    , saveError = Nothing
                    , baseline = panel.draft
                    , session = Loaded (configFromDraft panel.draft)
                }
            , tree = Loading
          }
        , Cmd.batch
            [ Process.sleep 2000 |> Task.perform (always ConfigFlashDone)
            , treeCmd model
            , fetchInspection model
                ("config/capabilities/" ++ model.threadId)
                "GET"
                Nothing
                ("config/threads/" ++ model.threadId ++ "/capabilities")
            , fetchInspection model
                ("config/context/" ++ model.threadId)
                "GET"
                Nothing
                ("config/threads/" ++ model.threadId ++ "/context")
            ]
        )

    else
        ( mapConfigPanel (\p -> { p | saving = False, saveError = Just (statusLabel result) }) model
        , Cmd.none
        )


emptyConfigPanel : ConfigPanel
emptyConfigPanel =
    { global = NotAsked
    , session = NotAsked
    , capabilities = NotAsked
    , contextPolicy = NotAsked
    , providers = NotAsked
    , loadedFor = Nothing
    , draft = emptyConfigDraft
    , baseline = emptyConfigDraft
    , saving = False
    , saved = False
    , saveError = Nothing
    }


emptyConfigDraft : ConfigDraft
emptyConfigDraft =
    ConfigDraft CwdInherit "" "" "" "" "" Nothing Nothing Nothing "" "" ""


draftFromConfig : ThreadConfigView -> ConfigDraft
draftFromConfig config =
    ConfigDraft
        config.cwdMode
        (Maybe.withDefault "" config.cwd)
        (Maybe.withDefault "" config.systemPrompt)
        (Maybe.withDefault "" config.provider)
        (Maybe.withDefault "" config.model)
        (Maybe.withDefault "" config.reasoningEffort)
        config.fs
        config.shell
        config.memory
        (config.contextReserveTokens |> Maybe.map String.fromInt |> Maybe.withDefault "")
        (config.contextKeepUnits |> Maybe.map String.fromInt |> Maybe.withDefault "")
        (config.contextSummaryTokens |> Maybe.map String.fromInt |> Maybe.withDefault "")


configFromDraft : ConfigDraft -> ThreadConfigView
configFromDraft draft =
    ThreadConfigView
        Nothing
        draft.cwdMode
        (cwdValue draft)
        (nonEmpty draft.systemPrompt)
        (nonEmpty draft.provider)
        (nonEmpty draft.model)
        (nonEmpty draft.reasoningEffort)
        draft.fs
        draft.shell
        draft.memory
        (optionalInt draft.contextReserveTokens)
        (optionalInt draft.contextKeepUnits)
        (optionalInt draft.contextSummaryTokens)


nonEmpty : String -> Maybe String
nonEmpty value =
    if String.isEmpty (String.trim value) then
        Nothing

    else
        Just value


putThreadConfig : Model -> String -> String -> Encode.Value -> Cmd Msg
putThreadConfig model kind targetId body =
    fetchInspection model kind "PUT" (Just body) ("config/threads/" ++ targetId)


draftFromForm : SessionForm -> ConfigDraft
draftFromForm form =
    ConfigDraft
        (if String.isEmpty (String.trim form.cwd) then
            CwdInherit

         else
            CwdPath
        )
        form.cwd
        ""
        ""
        ""
        ""
        (Just form.fs)
        (Just form.shell)
        (Just form.memory)
        ""
        ""
        ""


encodeThreadConfig : String -> ConfigDraft -> Encode.Value
encodeThreadConfig incarnationId draft =
    Encode.object
        [ ( "incarnationId", Encode.string incarnationId )
        , ( "cwdMode", Encode.string (cwdModeName draft.cwdMode) )
        , ( "cwd", Maybe.withDefault Encode.null (Maybe.map Encode.string (cwdValue draft)) )
        , ( "systemPrompt", blankAsNull draft.systemPrompt )
        , ( "provider", blankAsNull (String.trim draft.provider) )
        , ( "model", blankAsNull (String.trim draft.model) )
        , ( "reasoningEffort", blankAsNull (String.trim draft.reasoningEffort) )
        , ( "fs", nullableBool draft.fs )
        , ( "shell", nullableBool draft.shell )
        , ( "memory", nullableBool draft.memory )
        , ( "contextReserveTokens", nullableInt draft.contextReserveTokens )
        , ( "contextKeepUnits", nullableInt draft.contextKeepUnits )
        , ( "contextSummaryTokens", nullableInt draft.contextSummaryTokens )
        ]


optionalInt : String -> Maybe Int
optionalInt =
    String.trim >> String.toInt


nullableInt : String -> Encode.Value
nullableInt =
    optionalInt >> Maybe.map Encode.int >> Maybe.withDefault Encode.null


validateContextDraft : ConfigDraft -> Maybe String
validateContextDraft draft =
    let
        invalid ( label, minimum, raw ) =
            if String.isEmpty (String.trim raw) then
                Nothing

            else
                case optionalInt raw of
                    Just value ->
                        if value >= minimum then
                            Nothing

                        else
                            Just (label ++ "不得小于 " ++ String.fromInt minimum ++ "。")

                    Nothing ->
                        Just (label ++ "必须是整数。")
    in
    [ ( "预留 token", 1, draft.contextReserveTokens )
    , ( "保留轮组", 1, draft.contextKeepUnits )
    , ( "摘要上限", 96, draft.contextSummaryTokens )
    ]
        |> List.filterMap invalid
        |> List.head


cwdValue : ConfigDraft -> Maybe String
cwdValue draft =
    case draft.cwdMode of
        CwdPath ->
            nonEmpty draft.cwd

        _ ->
            Nothing


cwdModeName : CwdMode -> String
cwdModeName mode =
    case mode of
        CwdInherit ->
            "inherit"

        CwdNone ->
            "none"

        CwdPath ->
            "path"


blankAsNull : String -> Encode.Value
blankAsNull value =
    if String.isEmpty (String.trim value) then
        Encode.null

    else
        Encode.string value


nullableBool : Maybe Bool -> Encode.Value
nullableBool =
    Maybe.map Encode.bool >> Maybe.withDefault Encode.null


requestThreadSwitch : String -> Model -> ( Model, Cmd Msg )
requestThreadSwitch threadId model =
    if threadId == model.threadId || model.pendingSwitch /= Nothing then
        ( model, Cmd.none )

    else if isBusy model.phase then
        ( { model | sessionActionError = Just "请先结束当前运行。" }, Cmd.none )

    else
        ( { model | pendingSwitch = Just threadId, sessionActionError = Nothing }
        , fetchInspection model
            ("switch/" ++ threadId ++ "/transcript")
            "GET"
            Nothing
            ("threads/" ++ threadId ++ "/transcript")
        )


freshSessionId : String -> Model -> String
freshSessionId kind model =
    String.left 80 model.threadBase
        ++ "-"
        ++ kind
        ++ "-"
        ++ model.runStamp
        ++ "-"
        ++ String.fromInt (model.threadNumber + 1)


sessionTitle : String -> Remote (List SessionMeta) -> Maybe String
sessionTitle threadId remote =
    case remote of
        Loaded sessions ->
            sessions
                |> List.filter (\session -> session.id == threadId)
                |> List.head
                |> Maybe.map .title

        _ ->
            Nothing


switchThread : String -> Model -> ( Model, Cmd Msg )
switchThread newId model =
    let
        next =
            resetThreadState newId model

        ( configured, configCmd ) =
            ensureConfigLoaded { next | tree = Loading }
    in
    ( { configured | sessions = Loading, pendingSwitch = Nothing }
    , Cmd.batch
        [ if isBusy model.phase then
            cancelCurrent model

          else
            Cmd.none
        , persistThreadId newId
        , treeCmd configured
        , transcriptCmd configured
        , sessionsCmd configured
        , configCmd
        ]
    )


resetThreadState : String -> Model -> Model
resetThreadState newId model =
    { model
        | threadId = newId
        , draft = ""
        , pathSuggestions = []
        , messages = Dict.empty
        , messageOrder = []
        , tools = Dict.empty
        , phase = Idle
        , activeRun = Nothing
        , runNumber = 0
        , terminalSeen = False
        , error = Nothing
        , activeStep = Nothing
        , stickToBottom = True
        , inspection = emptyInspection
        , usage = Nothing
        , contextGauge = Nothing
        , compactConfirm = False
        , compacting = False
        , compactMessage = Nothing
        , tree = NotAsked
        , sessionForm = Nothing
        , configPanel = emptyConfigPanel
    }


treeCmd : Model -> Cmd Msg
treeCmd model =
    fetchInspection model "tree" "GET" Nothing ("config/threads/" ++ model.threadId ++ "/tree?depth=2")


transcriptCmd : Model -> Cmd Msg
transcriptCmd model =
    fetchInspection model
        ("threads/" ++ model.threadId ++ "/transcript")
        "GET"
        Nothing
        ("threads/" ++ model.threadId ++ "/transcript")


sessionsCmd : Model -> Cmd Msg
sessionsCmd model =
    fetchInspection model
        "sessions/list"
        "GET"
        Nothing
        ("incarnations/" ++ model.incarnationId ++ "/tasks?archived=true")


orElse : Maybe a -> Maybe a -> Maybe a
orElse primary fallback =
    case primary of
        Just _ ->
            primary

        Nothing ->
            fallback


tokenLabel : Maybe Int -> String
tokenLabel =
    Maybe.map String.fromInt >> Maybe.withDefault "—"


statusLabel : InspectionResult -> String
statusLabel result =
    if result.status == 0 then
        Decode.decodeValue Decode.string result.body
            |> Result.withDefault "网络错误"

    else
        Decode.decodeValue (Decode.field "error" Decode.string) result.body
            |> Result.withDefault ("HTTP " ++ String.fromInt result.status)


inspectionResultDecoder : Decoder InspectionResult
inspectionResultDecoder =
    Decode.map3 InspectionResult
        (Decode.field "kind" Decode.string)
        (Decode.field "status" Decode.int)
        (Decode.field "body" Decode.value)


briefRemote : InspectionResult -> Remote Brief
briefRemote result =
    if result.status == 404 then
        Loaded (Brief "" [])

    else if result.status >= 200 && result.status < 300 then
        Decode.decodeValue briefDecoder result.body
            |> Result.map Loaded
            |> Result.withDefault (LoadFailed "记忆摘要：响应无法解码")

    else
        LoadFailed ("记忆摘要：HTTP " ++ String.fromInt result.status)


briefDecoder : Decoder Brief
briefDecoder =
    Decode.map2 Brief
        (Decode.field "rollingSummary" Decode.string)
        (Decode.field "episodes" (Decode.list episodeDecoder))


episodeDecoder : Decoder Episode
episodeDecoder =
    Decode.map3 Episode
        (Decode.field "runId" Decode.string)
        (Decode.field "summary" Decode.string)
        (Decode.field "time" Decode.int)


factDecoder : Decoder Fact
factDecoder =
    Decode.map6 Fact
        (Decode.field "id" Decode.string)
        (Decode.field "content" Decode.string)
        (Decode.field "kind" Decode.string)
        (Decode.field "useCount" Decode.int)
        (Decode.field "archived" Decode.bool)
        (Decode.field "void" Decode.bool)


artifactDecoder : Decoder ArtifactMeta
artifactDecoder =
    Decode.map5 ArtifactMeta
        (Decode.field "id" Decode.string)
        (Decode.field "toolName" Decode.string)
        (Decode.oneOf [ Decode.field "preview" Decode.string, Decode.succeed "" ])
        (Decode.field "chars" Decode.int)
        (Decode.field "time" Decode.int)


type CompactResult
    = CompactUnchanged String
    | CompactChanged Int Int (Maybe Int) Int


compactResultDecoder : Decoder CompactResult
compactResultDecoder =
    Decode.oneOf
        [ Decode.field "changed" Decode.bool
            |> Decode.andThen
                (\changed ->
                    if changed then
                        Decode.map4 CompactChanged
                            (Decode.field "beforeTokens" Decode.int)
                            (Decode.field "afterTokens" Decode.int)
                            (Decode.maybe (Decode.field "budgetTokens" Decode.int))
                            (Decode.field "droppedMessages" Decode.int)

                    else
                        Decode.map CompactUnchanged
                            (Decode.oneOf
                                [ Decode.field "message" Decode.string
                                , Decode.succeed "当前工作记忆尚无需睡眠整理。"
                                ]
                            )
                )
        , Decode.map3
            (\before after dropped -> CompactChanged before after Nothing dropped)
            (Decode.field "beforeTokens" Decode.int)
            (Decode.field "afterTokens" Decode.int)
            (Decode.field "droppedMessages" Decode.int)
        ]


runSummaryDecoder : Decoder RunSummary
runSummaryDecoder =
    Decode.succeed RunSummary
        |> andMap (Decode.field "runId" Decode.string)
        |> andMap (Decode.field "threadId" Decode.string)
        |> andMap (Decode.field "entryCount" Decode.int)
        |> andMap (Decode.field "turns" Decode.int)
        |> andMap (Decode.field "toolCalls" Decode.int)
        |> andMap (Decode.field "agentEvents" Decode.int)
        |> andMap (Decode.field "apiRequests" Decode.int)
        |> andMap (Decode.at [ "usage", "prompt" ] Decode.int)
        |> andMap (Decode.at [ "usage", "completion" ] Decode.int)
        |> andMap (Decode.at [ "usage", "cacheHit" ] Decode.int)
        |> andMap (Decode.field "memoryCalls" Decode.int)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (Decode.field "firstSeq" Decode.int)
        |> andMap (Decode.field "lastSeq" Decode.int)
        |> andMap (Decode.maybe (Decode.field "firstTime" Decode.int))
        |> andMap (Decode.maybe (Decode.field "lastTime" Decode.int))


type alias ReplayReport =
    { runId : String
    , events : Int
    , divergence : Maybe ReplayDivergence
    }


type alias ReplayDivergence =
    { at : Int
    , expected : Maybe Decode.Value
    , actual : Maybe Decode.Value
    , note : Maybe String
    }


replayReportDecoder : Decoder ReplayReport
replayReportDecoder =
    Decode.map3 ReplayReport
        (Decode.field "runId" Decode.string)
        (Decode.field "events" Decode.int)
        (Decode.maybe divergenceDecoder)


divergenceDecoder : Decoder ReplayDivergence
divergenceDecoder =
    Decode.succeed ReplayDivergence
        |> andMap (Decode.field "at" Decode.int)
        |> andMap (Decode.maybe (Decode.field "expected" Decode.value))
        |> andMap (Decode.maybe (Decode.field "actual" Decode.value))
        |> andMap (Decode.maybe (Decode.field "note" Decode.string))


journalRowDecoder : Decoder JournalRow
journalRowDecoder =
    Decode.succeed JournalRow
        |> andMap (Decode.field "seq" Decode.int)
        |> andMap (Decode.field "scope" (Decode.list Decode.string))
        |> andMap (Decode.field "kind" Decode.string)
        |> andMap (Decode.maybe (Decode.field "time" Decode.int))
        |> andMap (Decode.maybe (Decode.field "event" Decode.value))
        |> andMap (Decode.maybe (Decode.field "request" Decode.value))
        |> andMap (Decode.maybe (Decode.field "input" Decode.value))
        |> andMap (Decode.maybe (Decode.field "name" Decode.string))
        |> andMap (Decode.maybe (Decode.field "arguments" Decode.string))
        |> andMap (Decode.maybe (Decode.field "outcome" Decode.value))


view : Model -> Html Msg
view model =
    div [ Attr.class "incarnation-shell" ]
        [ viewIncarnationRail model
        , div [ Attr.class "incarnation-surface" ]
            [ viewHeader model
            , case model.tab of
                NowTab ->
                    viewWork model

                MemoryTab ->
                    viewMemoryWorkspace model

                TasksTab ->
                    viewTasks model

                CapabilitiesTab ->
                    viewConfig model

                SelfTab ->
                    viewSelf model

                AuditTab ->
                    viewAudit model
            ]
        , viewIncarnationForm model
        , viewSessionForm model
        , viewIncarnationArchiveConfirmation model
        ]


viewIncarnationRail : Model -> Html Msg
viewIncarnationRail model =
    aside [ Attr.class "incarnation-rail" ]
        [ div [ Attr.class "rail-brand" ]
            [ div [ Attr.class "sigil" ] [ text "Y/N" ]
            , span [ Attr.class "rail-wordmark" ] [ text "YUKI.N" ]
            ]
        , div [ Attr.class "rail-label" ] [ text "分身" ]
        , div [ Attr.class "incarnation-list" ] (viewIncarnationList model)
        , button
            [ Attr.class "new-incarnation"
            , Attr.type_ "button"
            , Attr.disabled
                (isBusy model.phase
                    || model.savingSelf
                    || model.generatingPrompt
                    || model.activatingPrompt
                    /= Nothing
                )
            , Events.onClick OpenIncarnationForm
            ]
            [ span [] [ text "+" ]
            , span [] [ text "新分身" ]
            ]
        , viewArchivedIncarnations model
        , div [ Attr.class "rail-system" ]
            [ button
                [ Attr.classList
                    [ ( "incarnation-switch", True )
                    , ( "system", True )
                    , ( "active", model.tab == AuditTab )
                    ]
                , Attr.type_ "button"
                , Events.onClick (SelectTab AuditTab)
                ]
                [ span [ Attr.class "incarnation-mark" ] [ text "R" ]
                , span [ Attr.class "incarnation-switch-copy" ]
                    [ span [ Attr.class "incarnation-switch-name" ] [ text "Root" ]
                    , span [ Attr.class "incarnation-switch-state" ] [ text "系统审计" ]
                    ]
                ]
            ]
        ]


viewIncarnationList : Model -> List (Html Msg)
viewIncarnationList model =
    let
        entries =
            case model.incarnations of
                OptionalLoaded values ->
                    let
                        active =
                            List.filter (\entry -> entry.status == "active") values
                    in
                    if List.isEmpty active then
                        [ model.incarnation ]

                    else
                        active

                _ ->
                    [ model.incarnation ]
    in
    List.map (viewIncarnationSwitch model) entries


viewArchivedIncarnations : Model -> Html Msg
viewArchivedIncarnations model =
    let
        entries =
            case model.incarnations of
                OptionalLoaded values ->
                    List.filter (\entry -> entry.status == "archived") values

                _ ->
                    []
    in
    if List.isEmpty entries then
        text ""

    else
        details [ Attr.class "rail-archive" ]
            [ summary []
                [ text ("已移除 · " ++ String.fromInt (List.length entries)) ]
            , div [ Attr.class "rail-archive-list" ]
                (List.map (viewArchivedIncarnation model) entries)
            ]


viewArchivedIncarnation : Model -> IncarnationView -> Html Msg
viewArchivedIncarnation model incarnation =
    div [ Attr.class "rail-archive-row" ]
        [ div [ Attr.class "incarnation-switch-copy" ]
            [ span [ Attr.class "incarnation-switch-name" ] [ text incarnation.name ]
            , span [ Attr.class "incarnation-switch-state" ] [ text incarnation.id ]
            ]
        , button
            [ Attr.class "mini-button"
            , Attr.type_ "button"
            , Attr.disabled
                (isBusy model.phase
                    || model.restoringIncarnation
                    /= Nothing
                )
            , Events.onClick (RestoreIncarnation incarnation.id incarnation.revision)
            ]
            [ text
                (if model.restoringIncarnation == Just incarnation.id then
                    "恢复中…"

                 else
                    "恢复"
                )
            ]
        ]


viewIncarnationSwitch : Model -> IncarnationView -> Html Msg
viewIncarnationSwitch model incarnation =
    button
        [ Attr.classList
            [ ( "incarnation-switch", True )
            , ( "active", incarnation.id == model.incarnationId && model.tab /= AuditTab )
            ]
        , Attr.type_ "button"
        , Attr.disabled
            ((isBusy model.phase
                || model.savingSelf
                || model.generatingPrompt
                || model.activatingPrompt
                /= Nothing
             )
                && incarnation.id
                /= model.incarnationId
            )
        , Attr.title incarnation.direction
        , Events.onClick (SwitchIncarnation incarnation.id)
        ]
        [ span [ Attr.class "incarnation-mark" ] [ text (incarnationInitial incarnation.name) ]
        , span [ Attr.class "incarnation-switch-copy" ]
            [ span [ Attr.class "incarnation-switch-name" ] [ text incarnation.name ]
            , span [ Attr.class "incarnation-switch-state" ]
                [ text
                    (if incarnation.id == model.incarnationId then
                        phaseLabel model

                     else
                        statusZh incarnation.status
                    )
                ]
            ]
        ]


incarnationInitial : String -> String
incarnationInitial name =
    String.left 1 (String.trim name)
        |> (\value -> if String.isEmpty value then "Y" else value)


statusZh : String -> String
statusZh status =
    case status of
        "active" ->
            "可用"

        "archived" ->
            "归档"

        _ ->
            status


viewHeader : Model -> Html Msg
viewHeader model =
    header [ Attr.class "topbar" ]
        [ div [ Attr.class "manifest" ]
            [ div [ Attr.class "manifest-line" ]
                [ h1 [ Attr.class "manifest-name" ] [ text model.incarnation.name ]
                , span [ Attr.class ("manifest-status " ++ phaseClass model.phase) ]
                    [ span [ Attr.class "status-dot" ] []
                    , text (phaseLabel model)
                    ]
                ]
            , p [ Attr.class "manifest-direction" ] [ text model.incarnation.direction ]
            ]
        , nav [ Attr.class "tabs" ]
            [ viewTab model NowTab "此刻"
            , viewTab model MemoryTab "记忆"
            , viewTab model TasksTab "任务"
            , viewTab model CapabilitiesTab "能力"
            , viewTab model SelfTab "自我"
            ]
        , div [ Attr.class "top-actions" ]
            [ viewContextGauge model.contextGauge
            , viewUsage model.usage
            , button
                [ Attr.class "ghost-button new-thread"
                , Attr.type_ "button"
                , Events.onClick OpenSessionForm
                ]
                [ text "新任务" ]
            ]
        ]


viewTab : Model -> Tab -> String -> Html Msg
viewTab model tab label =
    button
        [ Attr.class
            ("tab"
                ++ (if model.tab == tab then
                        " active"

                    else
                        ""
                   )
            )
        , Attr.type_ "button"
        , Events.onClick (SelectTab tab)
        ]
        [ text label ]


viewUsage : Maybe Usage -> Html Msg
viewUsage maybeUsage =
    case maybeUsage of
        Nothing ->
            text ""

        Just usage ->
            div [ Attr.class "usage", Attr.title "本 run tokens · prompt / completion / cacheHit" ]
                [ usageChip "in" usage.prompt
                , usageChip "out" usage.completion
                , usageChip "hit" usage.cacheHit
                ]


usageChip : String -> Maybe Int -> Html Msg
usageChip label value =
    span [ Attr.class "usage-chip" ]
        [ span [ Attr.class "usage-label" ] [ text label ]
        , text (" " ++ tokenLabel value)
        ]


viewContextGauge : Maybe ContextGauge -> Html msg
viewContextGauge maybeGauge =
    case maybeGauge of
        Nothing ->
            text ""

        Just gauge ->
            let
                percent =
                    if gauge.budget <= 0 then
                        0

                    else
                        clamp 0 100 (gauge.tokens * 100 // gauge.budget)

                state =
                    if gauge.willCompact then
                        " · 待压缩"

                    else if gauge.emergency then
                        " · 紧急线"

                    else
                        ""

                formula =
                    case ( gauge.window, gauge.reserve, gauge.tools ) of
                        ( Just window, Just reserve, Just tools ) ->
                            "；触发线 = "
                                ++ String.fromInt window
                                ++ " − "
                                ++ String.fromInt reserve
                                ++ " − "
                                ++ String.fromInt tools

                        _ ->
                            ""
            in
            div
                [ Attr.classList
                    [ ( "context-gauge", True )
                    , ( "warning", gauge.willCompact || percent >= 85 )
                    ]
                , Attr.title
                    ("当前发送上下文估算："
                        ++ String.fromInt gauge.tokens
                        ++ " / "
                        ++ String.fromInt gauge.budget
                        ++ " tokens"
                        ++ formula
                    )
                ]
                [ span []
                    [ text
                        ("上下文 "
                            ++ String.fromInt percent
                            ++ "% · "
                            ++ String.fromInt gauge.tokens
                            ++ "/"
                            ++ String.fromInt gauge.budget
                            ++ state
                        )
                    ]
                , span [ Attr.class "context-track" ]
                    [ span
                        [ Attr.class "context-fill"
                        , Attr.style "width" (String.fromInt percent ++ "%")
                        ]
                        []
                    ]
                ]


viewWork : Model -> Html Msg
viewWork model =
    let
        notice =
            model.incarnationNotice
                |> Maybe.map (\message -> [ p [ Attr.class "integration-note" ] [ text message ] ])
                |> Maybe.withDefault []
    in
    main_ [ Attr.class "page now-page" ]
        (notice
            ++ [ section [ Attr.class "intent-workspace" ]
                    [ div [ Attr.class "intent-head" ]
                        [ div [ Attr.class "intent-heading" ]
                            [ span [ Attr.class "eyebrow" ]
                                [ text <|
                                    if model.currentTaskBelongs then
                                        "当前任务"

                                    else
                                        "当前意图"
                                ]
                            , h2 [ Attr.class "page-title small" ] [ text (currentTaskTitle model) ]
                            , p [ Attr.class "intent-thread", Attr.title model.threadId ]
                                [ text model.threadId ]
                            ]
                        , div [ Attr.class "intent-runtime" ]
                            [ span
                                [ Attr.classList
                                    [ ( "intent-state", True )
                                    , ( phaseClass model.phase, not (String.isEmpty (phaseClass model.phase)) )
                                    ]
                                ]
                                [ span [ Attr.class "status-dot" ] []
                                , text (phaseLabel model)
                                ]
                            ]
                        ]
                    , if model.currentTaskBelongs then
                        div [ Attr.class "conversation" ]
                            [ div [ Attr.class "transcript-shell" ]
                                [ div
                                    [ Attr.class "transcript"
                                    , Attr.id "transcript"
                                    , Attr.tabindex 0
                                    , Attr.attribute "role" "region"
                                    , Attr.attribute "aria-label" "对话记录"
                                    ]
                                    (viewTranscript model)
                                , viewLatestButton model
                                ]
                            , viewComposer model
                            ]

                      else
                        viewNoCurrentTask
                    ]
               ]
        )


currentTaskTitle : Model -> String
currentTaskTitle model =
    let
        title =
            String.trim model.sessionTitleDraft
    in
    if not model.currentTaskBelongs then
        "尚无当前任务"

    else if String.isEmpty title || title == model.threadId then
        "当前任务"

    else
        title


viewNoCurrentTask : Html Msg
viewNoCurrentTask =
    div [ Attr.class "no-current-task" ]
        [ span [ Attr.class "eyebrow" ] [ text "运行适配边界" ]
        , h2 [ Attr.class "snapshot-title" ] [ text "这个分身还没有任务" ]
        , p [ Attr.class "boundary-copy" ]
            [ text "Direct Intent 的无任务运行接口尚未接通；现在创建任务，避免把另一个分身的 thread 错挂到这里。" ]
        , button
            [ Attr.class "send-button"
            , Attr.type_ "button"
            , Events.onClick OpenSessionForm
            ]
            [ text "创建第一个任务" ]
        ]


capabilityHeadline : Remote (List String) -> String
capabilityHeadline remote =
    case remote of
        Loaded capabilities ->
            String.fromInt (List.length capabilities) ++ " 项能力可用"

        Loading ->
            "正在核对能力"

        LoadFailed _ ->
            "能力快照暂不可用"

        NotAsked ->
            "能力尚未核对"


viewTasks : Model -> Html Msg
viewTasks model =
    main_ [ Attr.class "page tasks-page" ]
        [ div [ Attr.class "page-heading" ]
            [ div []
                [ span [ Attr.class "eyebrow" ] [ text "属于此分身" ]
                , h2 [ Attr.class "page-title" ] [ text "任务" ]
                , p [ Attr.class "page-description" ]
                    [ text "任务承载一次具体工作；原始记录成为可回溯经历，但人格与提炼记忆仍属于分身。" ]
                ]
            , button
                [ Attr.class "send-button"
                , Attr.type_ "button"
                , Events.onClick OpenSessionForm
                ]
                [ text "新任务" ]
            ]
        , div [ Attr.class "tasks-layout" ]
            [ aside [ Attr.class "task-index" ] [ viewSessions model ]
            , if model.currentTaskBelongs then
                section [ Attr.class "task-detail" ]
                    [ div [ Attr.class "task-contract" ]
                    [ span [ Attr.class "eyebrow" ] [ text "当前任务" ]
                    , h2 [ Attr.class "snapshot-title" ] [ text (currentTaskTitle model) ]
                    , p [ Attr.class "task-objective" ]
                        [ text "目标与约束由当前任务上下文承载；分身的长期方向与记忆仍独立于它。" ]
                    , div [ Attr.class "snapshot-meta" ]
                        [ meta "thread" model.threadId
                        , meta "state" (phaseLabel model)
                        , meta "run" (Maybe.withDefault "—" model.activeRun)
                        ]
                        ]
                    , div [ Attr.class "task-runtime-grid" ]
                        [ div [ Attr.class "inspector-section" ]
                        [ h2 [ Attr.class "section-title" ] [ text "执行投影" ]
                        , p [ Attr.class "section-note" ]
                            [ text "Transcript 仅供核查本次执行；工具、Worker 与事件保留原始审计链。" ]
                        , details [ Attr.class "task-transcript" ]
                            [ summary [] [ text "展开 transcript" ]
                            , div [ Attr.class "transcript task-transcript-body" ] (viewTranscript model)
                            ]
                        ]
                        , div [ Attr.class "inspector-section" ]
                        [ h2 [ Attr.class "section-title" ]
                            [ text "工作目录"
                            , refreshButton RefreshTree
                            ]
                        , viewTree model.tree
                            ]
                        ]
                    ]

              else
                section [ Attr.class "task-detail" ] [ viewNoCurrentTask ]
            ]
        ]


viewMemoryWorkspace : Model -> Html Msg
viewMemoryWorkspace model =
    main_ [ Attr.class "page memory-page" ]
        [ div [ Attr.class "page-heading" ]
            [ div []
                [ span [ Attr.class "eyebrow" ] [ text "连续性的本体" ]
                , h2 [ Attr.class "page-title" ] [ text "记忆" ]
                , p [ Attr.class "page-description" ]
                    [ text "印象提供线索；Task Archive 保存长期记忆原件，提炼记录只是可重建索引；睡眠整理短期工作记忆。" ]
                ]
            ]
        , nav [ Attr.class "memory-tabs" ]
            [ memoryPaneButton model ImpressionPane "印象"
            , memoryPaneButton model LongTermPane "长期记忆"
            , memoryPaneButton model SleepPane "睡眠"
            ]
        , case model.memoryPane of
            ImpressionPane ->
                viewImpressionPane model

            LongTermPane ->
                viewLongMemoryPane model

            SleepPane ->
                viewSleepPane model
        ]


memoryPaneButton : Model -> MemoryPane -> String -> Html Msg
memoryPaneButton model pane label =
    button
        [ Attr.classList
            [ ( "memory-tab", True )
            , ( "active", model.memoryPane == pane )
            ]
        , Attr.type_ "button"
        , Events.onClick (SelectMemoryPane pane)
        ]
        [ text label ]


viewImpressionPane : Model -> Html Msg
viewImpressionPane model =
    div [ Attr.class "memory-layout" ]
        [ section [ Attr.class "memory-primary" ]
            [ div [ Attr.class "section-heading" ]
                [ div []
                    [ span [ Attr.class "eyebrow" ] [ text "潜意识投影" ]
                    , h2 [ Attr.class "section-heading-title" ] [ text "当前印象" ]
                    ]
                , refreshButton RefreshImpression
                ]
            , p [ Attr.class "boundary-copy" ]
                [ text "印象只生成“也许值得检索”的 cue；它不是事实，也不会预载 Task Archive 正文。采用线索时须先 literal grep，再 bounded read。" ]
            , viewOptional "尚未读取印象。" viewImpressionState model.impression
            ]
        , aside [ Attr.class "memory-secondary" ]
            [ section [ Attr.class "impression-audit-section" ]
                [ span [ Attr.class "eyebrow" ] [ text "形成记录" ]
                , viewOptional "尚未读取形成记录。" viewImpressionRevisions model.impressionRevisions
                ]
            , section [ Attr.class "impression-audit-section" ]
                [ span [ Attr.class "eyebrow" ] [ text "最近激活" ]
                , viewOptional "尚未读取激活记录。" viewImpressionActivations model.impressionActivations
                ]
            ]
        ]


viewImpressionState : ImpressionStateView -> Html Msg
viewImpressionState state =
    if List.isEmpty state.items then
        note "这个分身尚未形成稳定印象。"

    else
        div []
            [ div [ Attr.class "memory-revision" ]
                [ text
                    ("revision "
                        ++ String.fromInt state.revision
                        ++ " · generator "
                        ++ state.generatorRevision
                    )
                ]
            , div [ Attr.class "impression-list" ] (List.map viewImpressionItem state.items)
            ]


viewImpressionItem : ImpressionItemView -> Html Msg
viewImpressionItem item =
    div [ Attr.class "impression-item" ]
        [ div [ Attr.class "impression-item-head" ]
            [ span [ Attr.class "impression-label" ] [ text item.label ]
            , span [ Attr.class "confidence" ]
                [ text (String.fromInt (round (item.strength * 100)) ++ "%") ]
            ]
        , p [ Attr.class "impression-intuition" ] [ text item.intuition ]
        , p [ Attr.class "memory-source" ]
            [ text
                (String.fromInt (List.length item.sourceMemoryIds)
                    ++ " 个档案引用 · "
                    ++ String.fromInt (List.length item.sourceExperienceRefs)
                    ++ " 个审计来源"
                )
            ]
        ]


viewImpressionActivations : List ImpressionActivationView -> Html Msg
viewImpressionActivations activations =
    if List.isEmpty activations then
        note "尚无激活记录。"

    else
        div [ Attr.class "activation-list" ]
            (activations
                |> List.reverse
                |> List.take 8
                |> List.map viewImpressionActivation
            )


viewImpressionRevisions : List ImpressionRevisionView -> Html Msg
viewImpressionRevisions revisions =
    if List.isEmpty revisions then
        note "尚无模型形成记录。"

    else
        div [ Attr.class "activation-list" ]
            (revisions
                |> List.reverse
                |> List.take 8
                |> List.map viewImpressionRevision
            )


viewImpressionRevision : ImpressionRevisionView -> Html Msg
viewImpressionRevision revision =
    details [ Attr.class "activation-card" ]
        [ summary []
            [ span [ Attr.class "activation-intent" ]
                [ text
                    ("revision "
                        ++ String.fromInt revision.beforeRevision
                        ++ " → "
                        ++ String.fromInt revision.afterRevision
                    )
                ]
            , span [ Attr.class "activation-count" ]
                [ text
                    (String.fromInt (List.length revision.memoryProposals)
                        ++ " legacy proposals"
                    )
                ]
            ]
        , div [ Attr.class "activation-body" ]
            [ p [ Attr.class "cue-hint" ] [ text revision.reason ]
            , if List.isEmpty revision.memoryProposals then
                note "新 revision 不生成记忆写入提案。"

              else
                div [ Attr.class "impression-proposal-list" ]
                    (List.map viewImpressionProposal revision.memoryProposals)
            , if List.isEmpty revision.voidProposals then
                text ""

              else
                p [ Attr.class "memory-source" ]
                    [ text ("legacy void proposals · " ++ String.join " · " revision.voidProposals) ]
            , p [ Attr.class "memory-source" ]
                [ text
                    ("experience "
                        ++ revision.experienceRef
                        ++ " · "
                        ++ revision.model
                        ++ " · "
                        ++ revision.modelInvocationId
                    )
                ]
            ]
        ]


viewImpressionProposal : ImpressionMemoryProposalView -> Html Msg
viewImpressionProposal proposal =
    div [ Attr.class "impression-proposal" ]
        [ p [ Attr.class "cue-hint" ] [ text proposal.content ]
        , p [ Attr.class "memory-source" ]
            [ text
                (proposal.kind
                    ++ " · "
                    ++ proposal.visibility
                    ++ " · legacy proposal only · "
                    ++ proposal.reason
                )
            ]
        ]


viewImpressionActivation : ImpressionActivationView -> Html Msg
viewImpressionActivation activation =
    details [ Attr.class "activation-card" ]
        [ summary []
            [ span [ Attr.class "activation-intent" ] [ text activation.intent ]
            , span [ Attr.class "activation-count" ]
                [ text
                    (activation.error
                        |> Maybe.map (always "失败")
                        |> Maybe.withDefault (String.fromInt (List.length activation.cues) ++ " cues")
                    )
                ]
            ]
        , div [ Attr.class "activation-body" ]
            [ activation.error
                |> Maybe.map (\failure -> p [ Attr.class "section-note error" ] [ text ("激活失败：" ++ failure) ])
                |> Maybe.withDefault (div [] (List.map viewImpressionCue activation.cues))
            , p [ Attr.class "memory-source" ]
                [ text
                    ("task "
                        ++ activation.taskId
                        ++ " · run "
                        ++ activation.runId
                        ++ " · intent "
                        ++ activation.intentId
                    )
                ]
            , details [ Attr.class "audit-fragment" ]
                [ summary [] [ text "查看投影文本与模型来源" ]
                , pre [ Attr.class "memory-copy" ] [ text activation.injectedText ]
                , p [ Attr.class "memory-source" ]
                    [ text (activation.model ++ " · " ++ activation.modelInvocationId) ]
                ]
            ]
        ]


viewImpressionCue : ImpressionCueView -> Html Msg
viewImpressionCue cue =
    div [ Attr.class "cue-row" ]
        [ div []
            [ p [ Attr.class "cue-hint" ] [ text cue.hint ]
            , p [ Attr.class "memory-source" ] [ text cue.reason ]
            ]
        , cue.suggestedQuery
            |> Maybe.map (\query -> span [ Attr.class "query-chip" ] [ text ("grep: " ++ query) ])
            |> Maybe.withDefault (text "")
        ]


viewLongMemoryPane : Model -> Html Msg
viewLongMemoryPane model =
    section [ Attr.class "long-memory" ]
        [ div [ Attr.class "long-memory-boundary" ]
            [ span [ Attr.class "eyebrow" ] [ text "可回溯的长期记忆" ]
            , h2 [ Attr.class "section-heading-title" ] [ text "经历是原件，提炼是索引" ]
            , p [ Attr.class "boundary-copy" ]
                [ text "Task Archive 保存同一分身全部 Task（含归档）的原始记录；提炼记录可修订、可作废、可由原件重建。两者都不会在未检索时预载正文。" ]
            ]
        , nav [ Attr.class "memory-record-modes", Attr.attribute "aria-label" "长期记忆类型" ]
            [ memoryRecordModeButton model TaskRecordMode "任务记录" "原始经历"
            , memoryRecordModeButton model DistilledRecordMode "提炼记录" "可修订索引"
            ]
        , case model.memoryRecordMode of
            TaskRecordMode ->
                viewTaskRecordPane model

            DistilledRecordMode ->
                viewDistilledRecordPane model
        ]


memoryRecordModeButton : Model -> MemoryRecordMode -> String -> String -> Html Msg
memoryRecordModeButton model mode title subtitle =
    button
        [ Attr.classList
            [ ( "memory-record-mode", True )
            , ( "active", model.memoryRecordMode == mode )
            ]
        , Attr.type_ "button"
        , Events.onClick (SelectMemoryRecordMode mode)
        ]
        [ span [] [ text title ]
        , span [ Attr.class "memory-record-mode-note" ] [ text subtitle ]
        ]


viewTaskRecordPane : Model -> Html Msg
viewTaskRecordPane model =
    let
        state =
            model.taskRecords
    in
    div [ Attr.class "task-record-workspace" ]
        [ viewTaskRecordCatalog model state
        , form [ Attr.class "memory-search task-record-search", Events.onSubmit SearchTaskRecords ]
            [ input
                [ Attr.value state.query
                , Attr.placeholder "在历史 Task 中搜索固定字符串"
                , Attr.attribute "aria-label" "任务记录查询"
                , Events.onInput TaskRecordQueryChanged
                ]
                []
            , button
                [ Attr.class "send-button"
                , Attr.type_ "submit"
                , Attr.disabled
                    (String.isEmpty (String.trim state.query)
                        || optionalIsLoading state.search
                    )
                ]
                [ text
                    (if optionalIsLoading state.search then
                        "搜索中…"

                     else
                        "搜索记录"
                    )
                ]
            , div [ Attr.class "task-record-search-options" ]
                [ label [ Attr.class "task-case-toggle" ]
                    [ input
                        [ Attr.type_ "checkbox"
                        , Attr.checked state.caseSensitive
                        , Events.onCheck TaskRecordCaseSensitiveChanged
                        ]
                        []
                    , span [] [ text "区分大小写" ]
                    ]
                , span [ Attr.class "task-scope-status" ]
                    [ text
                        (state.taskId
                            |> Maybe.map (\taskId -> "范围 · " ++ taskId)
                            |> Maybe.withDefault "范围 · 本分身全部 Task（含归档）"
                        )
                    ]
                , span [ Attr.class "task-search-law" ] [ text "literal · 不做语义扩写" ]
                ]
            ]
        , div [ Attr.class "task-memory-grid" ]
            [ section [ Attr.class "task-record-results" ] [ viewTaskRecordSearch model ]
            , aside [ Attr.class "task-record-reader" ] [ viewTaskRecordReader model ]
            ]
        ]


viewTaskRecordCatalog : Model -> TaskRecordMemory -> Html Msg
viewTaskRecordCatalog model state =
    section [ Attr.class "task-record-catalog" ]
        [ div [ Attr.class "task-record-catalog-head" ]
            [ div []
                [ span [ Attr.class "eyebrow" ] [ text "Task scope" ]
                , p [ Attr.class "task-record-catalog-title" ] [ text "先限定经历范围，也可检索全部历史。" ]
                ]
            , refreshButton RefreshTaskRecordCatalog
            ]
        , div [ Attr.class "task-scope-list" ]
            (taskScopeAllButton state
                :: (case state.catalog of
                        OptionalLoaded catalog ->
                            List.map (viewTaskScope model state) catalog

                        _ ->
                            []
                   )
            )
        , case state.catalog of
            OptionalIdle ->
                note "尚未读取任务记录目录。"

            OptionalLoading ->
                note "正在读取任务记录目录…"

            OptionalUnavailable message ->
                viewIntegrationBoundary message

            OptionalFailed message ->
                errorNote message

            OptionalLoaded catalog ->
                if List.isEmpty catalog then
                    note "这个分身还没有可检索的任务记录。"

                else
                    div [ Attr.class "task-catalog-summary" ]
                        [ span [] [ text (String.fromInt (List.length catalog) ++ " tasks") ]
                        , span []
                            [ text
                                (String.fromInt (List.sum (List.map .entryCount catalog))
                                    ++ " entries"
                                )
                            ]
                        ]
        ]


taskScopeAllButton : TaskRecordMemory -> Html Msg
taskScopeAllButton state =
    button
        [ Attr.classList
            [ ( "task-scope-card", True )
            , ( "active", state.taskId == Nothing )
            ]
        , Attr.type_ "button"
        , Events.onClick (TaskRecordTaskChanged "")
        ]
        [ span [ Attr.class "task-scope-name" ] [ text "全部 Task" ]
        , span [ Attr.class "task-scope-preview" ] [ text "本分身完整任务历史，含已归档 Task" ]
        ]


viewTaskScope : Model -> TaskRecordMemory -> TaskArchiveSummary -> Html Msg
viewTaskScope model state archive =
    button
        [ Attr.classList
            [ ( "task-scope-card", True )
            , ( "active", state.taskId == Just archive.taskId )
            ]
        , Attr.type_ "button"
        , Events.onClick (TaskRecordTaskChanged archive.taskId)
        ]
        [ span [ Attr.class "task-scope-name" ] [ text archive.taskId ]
        , span [ Attr.class "task-scope-preview" ] [ text (clip 88 archive.preview) ]
        , span [ Attr.class "task-scope-meta" ]
            [ text
                (String.fromInt archive.runCount
                    ++ " runs · "
                    ++ String.fromInt archive.entryCount
                    ++ " entries · "
                    ++ relativeTime model.now (Just archive.updated)
                )
            ]
        ]


viewTaskRecordSearch : Model -> Html Msg
viewTaskRecordSearch model =
    case model.taskRecords.search of
        OptionalIdle ->
            div [ Attr.class "memory-blank task-record-blank" ]
                [ span [ Attr.class "memory-blank-mark" ] [ text "⌕" ]
                , p [] [ text "输入原文片段后搜索。这里只读索引；命中后再按需读取附近记录。" ]
                ]

        OptionalLoading ->
            note "正在扫描所选 Task 的原始记录…"

        OptionalUnavailable message ->
            viewIntegrationBoundary message

        OptionalFailed message ->
            errorNote message

        OptionalLoaded result ->
            div [ Attr.class "task-search-result" ]
                [ div [ Attr.class "receipt-line" ]
                    [ span []
                        [ text
                            (String.fromInt (List.length result.hits)
                                ++ " hits · "
                                ++ result.mode
                            )
                        ]
                    , span []
                        [ text
                            (String.fromInt result.scannedTasks
                                ++ " tasks · "
                                ++ String.fromInt result.scannedEntries
                                ++ " entries"
                            )
                        ]
                    ]
                , if result.truncated then
                    p [ Attr.class "section-note task-search-truncated" ]
                        [ text "结果已达到上限；请缩小字符串或限定 Task。" ]

                  else
                    text ""
                , if List.isEmpty result.hits then
                    note "没有找到这段原文。"

                  else
                    div [ Attr.class "task-hit-list" ]
                        (List.map (viewTaskRecordHit model result) result.hits)
                ]


viewTaskRecordHit : Model -> TaskRecordSearchView -> TaskRecordHitView -> Html Msg
viewTaskRecordHit model result hit =
    button
        [ Attr.classList
            [ ( "task-record-hit", True )
            , ( "active"
              , Maybe.map .entryId model.taskRecords.selected == Just hit.entryId
              )
            ]
        , Attr.type_ "button"
        , Events.onClick (OpenTaskRecordHit hit)
        ]
        [ div [ Attr.class "task-record-hit-head" ]
            [ span [ Attr.class ("record-kind " ++ taskRecordKindTone hit.kind) ] [ text hit.kind ]
            , span [ Attr.class "task-record-hit-task" ] [ text hit.taskId ]
            , span [ Attr.class "task-record-hit-time" ] [ text (relativeTime model.now (Just hit.created)) ]
            ]
        , p [ Attr.class "task-record-excerpt" ]
            [ viewLiteralMatch result.caseSensitive result.query hit.excerpt ]
        , div [ Attr.class "task-record-hit-foot" ]
            [ span [] [ text ("run " ++ shortId hit.runId ++ " · #" ++ String.fromInt hit.seq) ]
            , span []
                [ text
                    (hit.toolName
                        |> Maybe.map (\name -> name ++ " · ")
                        |> Maybe.withDefault ""
                        |> (\prefix -> prefix ++ "line " ++ String.fromInt hit.lineNumber)
                    )
                ]
            ]
        ]


viewLiteralMatch : Bool -> String -> String -> Html Msg
viewLiteralMatch caseSensitive query content =
    case literalMatchOffset caseSensitive query content of
        Nothing ->
            text content

        Just offset ->
            span []
                [ text (String.left offset content)
                , Html.node "mark"
                    [ Attr.class "memory-match" ]
                    [ text (String.slice offset (offset + String.length query) content) ]
                , text (String.dropLeft (offset + String.length query) content)
                ]


literalMatchOffset : Bool -> String -> String -> Maybe Int
literalMatchOffset caseSensitive query content =
    let
        normalize =
            if caseSensitive then
                identity

            else
                String.toLower
    in
    normalize content
        |> String.indexes (normalize query)
        |> List.head


viewTaskRecordReader : Model -> Html Msg
viewTaskRecordReader model =
    case model.taskRecords.reader of
        OptionalIdle ->
            div [ Attr.class "task-record-reader-empty" ]
                [ span [ Attr.class "eyebrow" ] [ text "Context reader" ]
                , p [] [ text "选择一个命中，只读取它前后两条记录；不会切换当前 Task。" ]
                ]

        OptionalLoading ->
            note "正在读取命中附近的原始上下文…"

        OptionalUnavailable message ->
            viewIntegrationBoundary message

        OptionalFailed message ->
            errorNote message

        OptionalLoaded context ->
            div []
                [ div [ Attr.class "task-record-reader-head" ]
                    [ div []
                        [ span [ Attr.class "eyebrow" ] [ text "只读上下文" ]
                        , h2 [ Attr.class "task-record-reader-title" ] [ text context.taskId ]
                        ]
                    , button
                        [ Attr.class "text-button"
                        , Attr.type_ "button"
                        , Events.onClick CloseTaskRecordReader
                        ]
                        [ text "关闭" ]
                    ]
                , p [ Attr.class "boundary-copy task-reader-boundary" ]
                    [ text "阅读不会改变当前工作。只有下方“继续此 Task”会显式切换。" ]
                , viewTaskRecordChunkBefore context
                , div [ Attr.class "task-record-entry-list" ]
                    (List.map
                        (viewTaskRecordEntry model context.anchorEntryId)
                        context.entries
                    )
                , viewTaskRecordChunkAfter context
                , div [ Attr.class "task-reader-actions" ]
                    [ button
                        [ Attr.class "send-button"
                        , Attr.type_ "button"
                        , Attr.disabled
                            (model.pendingSwitch
                                /= Nothing
                                || (context.taskId /= model.threadId && isBusy model.phase)
                            )
                        , Events.onClick (ContinueTaskRecord context.taskId)
                        ]
                        [ text
                            (if context.taskId == model.threadId then
                                "回到当前 Task"

                             else
                                "继续此 Task"
                            )
                        ]
                    ]
                ]


viewTaskRecordChunkBefore : TaskRecordContextView -> Html Msg
viewTaskRecordChunkBefore context =
    case taskRecordAnchor context of
        Just entry ->
            if entry.truncatedBefore then
                let
                    visible =
                        min entry.contentOffset (taskRecordContentLength entry)

                    ( offset, chars ) =
                        taskRecordChunkRequest
                            (entry.contentOffset - visible)
                            visible
                            (List.length context.entries - 1)
                in
                button
                    [ Attr.class "record-page-action"
                    , Attr.type_ "button"
                    , Events.onClick (ReadTaskRecordChunk offset chars)
                    ]
                    [ text "← 读取这条记录更早的部分" ]

            else
                text ""

        Nothing ->
            text ""


viewTaskRecordChunkAfter : TaskRecordContextView -> Html Msg
viewTaskRecordChunkAfter context =
    case taskRecordAnchor context of
        Just entry ->
            if entry.truncatedAfter then
                let
                    start =
                        entry.contentOffset + taskRecordContentLength entry

                    visible =
                        min (taskRecordContentLength entry) (entry.contentTotal - start)

                    ( offset, chars ) =
                        taskRecordChunkRequest start visible (List.length context.entries - 1)
                in
                button
                    [ Attr.class "record-page-action"
                    , Attr.type_ "button"
                    , Events.onClick (ReadTaskRecordChunk offset chars)
                    ]
                    [ text "读取这条记录后续部分 →" ]

            else
                text ""

        Nothing ->
            text ""


taskRecordAnchor : TaskRecordContextView -> Maybe TaskRecordEntryView
taskRecordAnchor context =
    context.entries
        |> List.filter (\entry -> entry.entryId == context.anchorEntryId)
        |> List.head


taskRecordContentLength : TaskRecordEntryView -> Int
taskRecordContentLength =
    List.length << String.toList << .content


taskRecordChunkRequest : Int -> Int -> Int -> ( Int, Int )
taskRecordChunkRequest start visible rawNeighbours =
    let
        neighbours =
            max 0 rawNeighbours

        shared =
            neighbours * 400

        requested =
            if neighbours == 0 then
                visible

            else if visible >= shared then
                visible + shared

            else
                visible * 2

        chars =
            clamp 1 6000 requested

        anchorBudget =
            if neighbours == 0 then
                chars

            else
                max 1 (max (chars // 2) (chars - shared))
    in
    ( max 0 (start + anchorBudget // 3), chars )


viewTaskRecordEntry : Model -> String -> TaskRecordEntryView -> Html Msg
viewTaskRecordEntry model anchorId entry =
    let
        attributes =
            [ Attr.classList
                [ ( "task-record-entry", True )
                , ( taskRecordKindTone entry.kind, True )
                , ( "anchor", entry.entryId == anchorId )
                ]
            ]

        body =
            [ viewTaskRecordEntryHead model entry
            , pre [ Attr.class "task-record-entry-content" ]
                [ if entry.entryId == anchorId then
                    viewLiteralMatch
                        model.taskRecords.caseSensitive
                        model.taskRecords.query
                        entry.content

                  else
                    text entry.content
                ]
            , p [ Attr.class "task-record-entry-range" ]
                [ text
                    ("chars "
                        ++ String.fromInt (entry.contentOffset + 1)
                        ++ "–"
                        ++ String.fromInt (entry.contentOffset + taskRecordContentLength entry)
                        ++ " / "
                        ++ String.fromInt entry.contentTotal
                    )
                ]
            ]
    in
    if taskRecordKindTone entry.kind == "tool" then
        details attributes
            [ summary [] [ viewTaskRecordEntryHead model entry ]
            , div [ Attr.class "task-record-entry-detail" ] (List.drop 1 body)
            ]

    else
        div attributes body


viewTaskRecordEntryHead : Model -> TaskRecordEntryView -> Html Msg
viewTaskRecordEntryHead model entry =
    div [ Attr.class "task-record-entry-head" ]
        [ span [ Attr.class ("record-kind " ++ taskRecordKindTone entry.kind) ] [ text entry.kind ]
        , entry.toolName
            |> Maybe.map (\name -> span [ Attr.class "task-record-tool" ] [ text name ])
            |> Maybe.withDefault (text "")
        , span [ Attr.class "task-record-seq" ] [ text ("#" ++ String.fromInt entry.seq) ]
        , span [ Attr.class "task-record-hit-time" ] [ text (relativeTime model.now (Just entry.created)) ]
        ]


taskRecordKindTone : String -> String
taskRecordKindTone kind =
    let
        normalized =
            String.toLower kind
    in
    if String.contains "user" normalized then
        "user"

    else if String.contains "assistant" normalized then
        "assistant"

    else if String.contains "tool" normalized then
        "tool"

    else
        "system"


viewDistilledRecordPane : Model -> Html Msg
viewDistilledRecordPane model =
    div [ Attr.class "distilled-record-pane" ]
        [ p [ Attr.class "boundary-copy distilled-boundary" ]
            [ text "提炼记录是带来源的可修订索引，不是历史 Task 的替代品；需要核对原话时，请回到“任务记录”。" ]
        , form [ Attr.class "memory-search", Events.onSubmit SearchLongMemory ]
            [ input
                [ Attr.value model.longMemoryQuery
                , Attr.placeholder "在提炼记录中主动回忆"
                , Attr.attribute "aria-label" "提炼记录查询"
                , Events.onInput LongMemoryQueryChanged
                ]
                []
            , button
                [ Attr.class "send-button"
                , Attr.type_ "submit"
                , Attr.disabled
                    (String.isEmpty (String.trim model.longMemoryQuery)
                        || optionalIsLoading model.longMemorySearch
                    )
                ]
                [ text
                    (if optionalIsLoading model.longMemorySearch then
                        "检索中…"

                     else
                        "检索"
                    )
                ]
            ]
        , case model.longMemorySearch of
            OptionalIdle ->
                div [ Attr.class "memory-blank" ]
                    [ span [ Attr.class "memory-blank-mark" ] [ text "∅" ]
                    , p [] [ text "提炼正文保持关闭，直到你或 Yuki 明确发起 grep。" ]
                    ]

            OptionalLoading ->
                note "正在检索可见记忆空间…"

            OptionalUnavailable message ->
                viewIntegrationBoundary message

            OptionalFailed message ->
                errorNote message

            OptionalLoaded result ->
                viewMemoryGrepResult result
        ]


viewMemoryGrepResult : MemoryGrepView -> Html Msg
viewMemoryGrepResult result =
    div [ Attr.class "memory-results" ]
        [ div [ Attr.class "receipt-line" ]
            [ span [] [ text ("读取回执 · " ++ result.receipt.id) ]
            , span []
                [ text
                    (String.fromInt (List.length result.receipt.records)
                        ++ " records · "
                        ++ String.fromInt (List.length result.receipt.spaces)
                        ++ " spaces"
                    )
                ]
            ]
        , if List.isEmpty result.snippets then
            note "没有命中。未读取任何正文。"

          else
            div [ Attr.class "memory-result-list" ] (List.map viewMemorySnippet result.snippets)
        ]


viewMemorySnippet : MemorySnippetView -> Html Msg
viewMemorySnippet snippet =
    div [ Attr.class "memory-result" ]
        [ div [ Attr.class "memory-result-head" ]
            [ span [ Attr.class "kind-chip" ] [ text snippet.kind ]
            , span [ Attr.class "memory-id" ]
                [ text (snippet.id ++ " · r" ++ String.fromInt snippet.revision) ]
            , span [ Attr.class "memory-visibility" ] [ text snippet.visibility ]
            ]
        , p [ Attr.class "memory-result-copy" ] [ text snippet.snippet ]
        , p [ Attr.class "memory-source" ]
            [ text
                ("owner "
                    ++ snippet.owner
                    ++ " · "
                    ++ String.fromInt (List.length snippet.sourceRefs)
                    ++ " sources"
                )
            ]
        ]


viewSleepPane : Model -> Html Msg
viewSleepPane model =
    div [ Attr.class "memory-layout sleep-layout" ]
        [ section [ Attr.class "memory-primary" ]
            [ div [ Attr.class "section-heading" ]
                [ div []
                    [ span [ Attr.class "eyebrow" ] [ text "短期工作记忆" ]
                    , h2 [ Attr.class "section-heading-title" ] [ text "睡眠与醒来" ]
                    ]
                , refreshButton RefreshWorkingMemory
                ]
            , p [ Attr.class "boundary-copy" ]
                [ text "睡眠会冻结当前 cursor，决定保留与遗忘，再生成可审计的 WakePacket。它整理 context，不改写长期记忆。" ]
            , viewOptional "尚未读取工作记忆。" viewWorkingMemory model.workingMemory
            , viewSleepControl model
            ]
        , aside [ Attr.class "memory-secondary" ]
            [ span [ Attr.class "eyebrow" ] [ text "睡眠记录" ]
            , viewOptional "尚未读取睡眠记录。" viewSleepCycles model.sleepCycles
            ]
        ]


viewWorkingMemory : WorkingMemoryView -> Html Msg
viewWorkingMemory working =
    div [ Attr.class "working-memory" ]
        [ div [ Attr.class "working-head" ]
            [ span [ Attr.class ("working-status " ++ working.status) ] [ text working.status ]
            , span [] [ text ("revision " ++ String.fromInt working.revision) ]
            , span [] [ text ("cursor " ++ String.fromInt working.cursor) ]
            ]
        , working.degradedReason
            |> Maybe.map (\reason -> p [ Attr.class "section-note error" ] [ text reason ])
            |> Maybe.withDefault (text "")
        , if List.isEmpty working.focusFrames then
            note "当前没有活跃 focus frame。"

          else
            div [ Attr.class "focus-list" ] (List.map viewFocusFrame working.focusFrames)
        ]


viewFocusFrame : FocusFrameView -> Html Msg
viewFocusFrame frame =
    div [ Attr.class "focus-card" ]
        [ div [ Attr.class "focus-card-head" ]
            [ span [] [ text frame.objective ]
            , span [ Attr.class "kind-chip" ] [ text frame.status ]
            ]
        , p [ Attr.class "memory-source" ]
            [ text
                (frame.taskId
                    ++ " · "
                    ++ String.fromInt (List.length frame.activeItems)
                    ++ " active · "
                    ++ String.fromInt (List.length frame.openLoops)
                    ++ " open"
                )
            ]
        ]


viewSleepControl : Model -> Html Msg
viewSleepControl model =
    if not model.currentTaskBelongs then
        div [ Attr.class "sleep-control" ] [ note "当前没有任务，无需生成 WakePacket。" ]

    else
        div [ Attr.class "sleep-control" ]
            (if model.compactConfirm then
            [ p [ Attr.class "boundary-copy" ]
                [ text "Yuki 会冻结当前短期记忆，先决定主动遗忘什么，再生成 WakePacket，并在同一任务中醒来继续。" ]
            , div [ Attr.class "session-file-actions" ]
                [ button
                    [ Attr.class "ghost-button"
                    , Attr.type_ "button"
                    , Events.onClick CancelCompact
                    ]
                    [ text "取消" ]
                , button
                    [ Attr.class "send-button"
                    , Attr.type_ "button"
                    , Attr.disabled (model.compacting || model.activeRun /= Nothing)
                    , Events.onClick ConfirmCompact
                    ]
                    [ text
                        (if model.compacting then
                            "入睡中…"

                         else
                            "确认睡眠"
                        )
                    ]
                ]
            ]

         else
            [ button
                [ Attr.class "ghost-button"
                , Attr.type_ "button"
                , Attr.disabled (model.activeRun /= Nothing)
                , Events.onClick RequestCompact
                ]
                [ text
                    (if model.activeRun /= Nothing then
                        "运行结束后可睡"

                     else
                        "让当前任务睡一觉"
                    )
                ]
            ]
                ++ (model.compactMessage
                        |> Maybe.map (\message -> [ p [ Attr.class "section-note" ] [ text message ] ])
                        |> Maybe.withDefault []
                   )
            )


viewSleepCycles : List SleepCycleView -> Html Msg
viewSleepCycles cycles =
    if List.isEmpty cycles then
        note "还没有睡眠记录。"

    else
        div [ Attr.class "sleep-cycles" ]
            (cycles
                |> List.reverse
                |> List.take 10
                |> List.map viewSleepCycle
            )


viewSleepCycle : SleepCycleView -> Html Msg
viewSleepCycle cycle =
    details [ Attr.class "sleep-cycle" ]
        [ summary []
            [ span [] [ text cycle.taskId ]
            , span [ Attr.class "kind-chip" ] [ text cycle.status ]
            ]
        , div [ Attr.class "sleep-cycle-body" ]
            [ meta "trigger" cycle.trigger
            , meta "epoch" cycle.baseEpochId
            , meta "frozen cursor" (String.fromInt cycle.frozenCursor)
            , cycle.wakePacketId
                |> Maybe.map (meta "wake packet")
                |> Maybe.withDefault (text "")
            , cycle.checkpointId
                |> Maybe.map (meta "checkpoint")
                |> Maybe.withDefault (text "")
            , if List.isEmpty cycle.forgotten then
                note "这次睡眠没有提交遗忘项。"

              else
                div [ Attr.class "forget-list" ]
                    (List.map viewForgetDecision cycle.forgotten)
            , cycle.failure
                |> Maybe.map (\failure -> p [ Attr.class "section-note error" ] [ text failure ])
                |> Maybe.withDefault (text "")
            ]
        ]


viewForgetDecision : ForgetDecisionView -> Html Msg
viewForgetDecision decision =
    div [ Attr.class "forget-decision" ]
        [ p [ Attr.class "forget-subject" ] [ text decision.subject ]
        , p [ Attr.class "forget-reason" ] [ text decision.reason ]
        , if List.isEmpty decision.sourceSegmentIds then
            text ""

          else
            p [ Attr.class "memory-source" ]
                [ text ("segments · " ++ String.join " · " decision.sourceSegmentIds) ]
        ]


viewOptional : String -> (a -> Html Msg) -> OptionalRemote a -> Html Msg
viewOptional idle render remote =
    case remote of
        OptionalIdle ->
            note idle

        OptionalLoading ->
            note "读取中…"

        OptionalUnavailable message ->
            viewIntegrationBoundary message

        OptionalFailed message ->
            errorNote message

        OptionalLoaded value ->
            render value


viewIntegrationBoundary : String -> Html Msg
viewIntegrationBoundary message =
    div [ Attr.class "integration-boundary" ]
        [ span [ Attr.class "eyebrow" ] [ text "接口边界" ]
        , p [] [ text message ]
        , p [ Attr.class "section-note" ] [ text "界面已按新领域对象建模；旧任务运行仍可继续。" ]
        ]


viewSelf : Model -> Html Msg
viewSelf model =
    main_ [ Attr.class "page self-page" ]
        [ div [ Attr.class "page-heading" ]
            [ div []
                [ span [ Attr.class "eyebrow" ] [ text "可认识、可修改" ]
                , h2 [ Attr.class "page-title" ] [ text "自我" ]
                , p [ Attr.class "page-description" ]
                    [ text "你修改的是有语义、可版本化的源对象；Prompt 是这些对象的编译结果，不是人格文本框。" ]
                ]
            ]
        , div [ Attr.class "self-grid" ]
            [ viewSelfCard
                "规范自我"
                "Charter"
                model.incarnation.direction
                "使命、原则、方法倾向、表达风格与质量标准。每次修改应生成 diff 与 revision。"
            , viewSelfCard
                "经验自我"
                "Self Model"
                "由历史 Task 证据、提炼记录与稳定印象归纳"
                "稳定认识必须能回到原始经历；提炼记录提供索引，不替代其来源。"
            , viewSelfCard
                "现实自我"
                "Capability Snapshot"
                (capabilityHeadline model.configPanel.capabilities)
                "模型、工具、workspace、预算与当前限制由运行时确定，不能由 Charter 宣称。"
            ]
        , viewSelfSourceEditor model
        , section [ Attr.class "prompt-governance" ]
            [ div [ Attr.class "section-heading" ]
                [ div []
                    [ span [ Attr.class "eyebrow" ] [ text "生成方式" ]
                    , h2 [ Attr.class "section-heading-title" ] [ text "Prompt Program" ]
                    ]
                , div [ Attr.class "prompt-actions" ]
                    [ span [ Attr.class "revision-chip" ]
                        [ text
                            (model.incarnation.promptRevision
                                |> Maybe.map (\revision -> "active · " ++ revision)
                                |> Maybe.withDefault "尚无 active revision"
                            )
                        ]
                    , button
                        [ Attr.class "mini-button"
                        , Attr.type_ "button"
                        , Events.onClick RefreshPrompts
                        ]
                        [ text "刷新审计" ]
                    , button
                        [ Attr.class "mini-button"
                        , Attr.type_ "button"
                        , Attr.disabled model.generatingPrompt
                        , Events.onClick GeneratePromptDraft
                        ]
                        [ text
                            (if model.generatingPrompt then
                                "生成中…"

                             else
                                "生成新草案"
                            )
                        ]
                    ]
                ]
            , div [ Attr.class "prompt-layers" ]
                [ promptLayer "01" "Root Constitution" "所有 Coordinator 与 Worker 共用的根律；可审计、版本化。"
                , promptLayer "02" "Composite Incarnation Charter" "一次生成方向、风格、判断倾向、工具、记忆与自我管理协议；可审计、修改、激活。"
                , promptLayer "03" "Workspace Contract" "项目规范与当前工作目录的真实约束，只在相关任务中生效。"
                , promptLayer "04" "Task / Run Spec" "只为一次任务或执行生成，不反向定义分身。"
                ]
            , p [ Attr.class "boundary-copy" ]
                [ text "Root 与 Charter 保留 source、generator、model invocation、effective hash 与历史版本；Workspace 与 Task 层由配置和 Journal 留痕。" ]
            , model.promptMessage
                |> Maybe.map (\message -> p [ Attr.class "section-note" ] [ text message ])
                |> Maybe.withDefault (text "")
            , viewPromptAudit model
            ]
        , viewIncarnationLifecycle model
        , button
            [ Attr.class "text-button audit-link"
            , Attr.type_ "button"
            , Events.onClick (SelectTab AuditTab)
            ]
            [ text "进入系统审计 →" ]
        ]


viewIncarnationLifecycle : Model -> Html Msg
viewIncarnationLifecycle model =
    section [ Attr.class "incarnation-lifecycle" ]
        [ div []
            [ span [ Attr.class "eyebrow" ] [ text "生命周期" ]
            , h2 [ Attr.class "section-heading-title" ] [ text "移除这个分身" ]
            , p [ Attr.class "boundary-copy" ]
                [ text
                    (if model.incarnationId == "yuki" then
                        "默认 Yuki 承担系统回退，不能移除。切换到其它分身后，可在这里移除。"

                     else
                        "移除后，它会从常用列表消失，所属任务一并归档；记忆、经验、Prompt 与审计记录不会被物理擦除。"
                    )
                ]
            ]
        , if model.incarnationId == "yuki" then
            span [ Attr.class "revision-chip" ] [ text "默认分身" ]

          else
            button
                [ Attr.class "danger-button"
                , Attr.type_ "button"
                , Attr.disabled
                    (isBusy model.phase
                        || model.archivingIncarnation
                    )
                , Events.onClick RequestArchiveIncarnation
                ]
                [ text "移除分身" ]
        ]


viewIncarnationArchiveConfirmation : Model -> Html Msg
viewIncarnationArchiveConfirmation model =
    if not model.incarnationArchiveConfirm then
        text ""

    else
        div [ Attr.class "overlay" ]
            [ div [ Attr.class "session-form incarnation-archive-confirm" ]
                [ span [ Attr.class "eyebrow" ] [ text "可恢复移除" ]
                , h2 [ Attr.class "form-title" ] [ text ("移除「" ++ model.incarnation.name ++ "」？") ]
                , p [ Attr.class "boundary-copy" ]
                    [ text "该分身的活动任务会同时归档，正在运行的任务会阻止本次操作。所有记忆、经验、Prompt 与来源记录仍会保留，并可从左栏恢复分身。" ]
                , model.selfMessage
                    |> Maybe.map (\message -> p [ Attr.class "section-note error" ] [ text message ])
                    |> Maybe.withDefault (text "")
                , div [ Attr.class "form-actions" ]
                    [ button
                        [ Attr.class "ghost-button"
                        , Attr.type_ "button"
                        , Attr.disabled model.archivingIncarnation
                        , Events.onClick CancelArchiveIncarnation
                        ]
                        [ text "取消" ]
                    , button
                        [ Attr.class "danger-button"
                        , Attr.type_ "button"
                        , Attr.disabled model.archivingIncarnation
                        , Events.onClick ConfirmArchiveIncarnation
                        ]
                        [ text
                            (if model.archivingIncarnation then
                                "移除中…"

                             else
                                "确认移除"
                            )
                        ]
                    ]
                ]
            ]


viewSelfSourceEditor : Model -> Html Msg
viewSelfSourceEditor model =
    let
        dirty =
            String.trim model.selfNameDraft /= model.incarnation.name
                || String.trim model.selfDirectionDraft
                /= model.incarnation.direction
                || nonEmpty model.selfImpressionModelDraft
                /= model.incarnation.impressionModel
    in
    section [ Attr.class "self-source-editor" ]
        [ div [ Attr.class "section-heading" ]
            [ div []
                [ span [ Attr.class "eyebrow" ] [ text "规范自我的来源" ]
                , h2 [ Attr.class "section-heading-title" ] [ text "修改方向，不手写完整 Prompt" ]
                ]
            , span [ Attr.class "revision-chip" ]
                [ text ("incarnation revision " ++ String.fromInt model.incarnation.revision) ]
            ]
        , p [ Attr.class "boundary-copy" ]
            [ text "保存这些语义源后，系统生成新的 Charter revision 供审计；现有 active revision 不会被静默覆盖。" ]
        , div [ Attr.class "self-source-grid" ]
            [ div [ Attr.class "form-field" ]
                [ span [ Attr.class "field-label" ] [ text "名称" ]
                , input
                    [ Attr.value model.selfNameDraft
                    , Attr.disabled model.savingSelf
                    , Events.onInput SelfNameChanged
                    ]
                    []
                ]
            , div [ Attr.class "form-field" ]
                [ span [ Attr.class "field-label" ] [ text "印象模型 profile" ]
                , input
                    [ Attr.value model.selfImpressionModelDraft
                    , Attr.placeholder "留空使用默认模型"
                    , Attr.disabled model.savingSelf
                    , Events.onInput SelfImpressionModelChanged
                    ]
                    []
                ]
            , div [ Attr.class "form-field self-direction-field" ]
                [ span [ Attr.class "field-label" ] [ text "方向 / 使命" ]
                , textarea
                    [ Attr.value model.selfDirectionDraft
                    , Attr.rows 4
                    , Attr.disabled model.savingSelf
                    , Events.onInput SelfDirectionChanged
                    ]
                    []
                ]
            ]
        , div [ Attr.class "form-actions" ]
            [ model.selfMessage
                |> Maybe.map (\message -> span [ Attr.class "section-note" ] [ text message ])
                |> Maybe.withDefault (text "")
            , button
                [ Attr.class "send-button"
                , Attr.type_ "button"
                , Attr.disabled
                    (model.savingSelf
                        || not dirty
                        || String.isEmpty (String.trim model.selfNameDraft)
                        || String.isEmpty (String.trim model.selfDirectionDraft)
                    )
                , Events.onClick SaveSelf
                ]
                [ text
                    (if model.savingSelf then
                        "保存中…"

                     else
                        "保存并生成草案"
                    )
                ]
            ]
        ]


viewPromptAudit : Model -> Html Msg
viewPromptAudit model =
    div [ Attr.class "prompt-audit" ]
        [ viewPromptRemote model True "Root Constitution" model.rootPrompts
        , viewPromptRemote model False "Incarnation revisions" model.prompts
        , viewPromptEditor model
        ]


viewPromptRemote : Model -> Bool -> String -> OptionalRemote (List PromptRevisionView) -> Html Msg
viewPromptRemote model root title remote =
    section [ Attr.class "prompt-audit-group" ]
        [ p [ Attr.class "field-label" ] [ text title ]
        , case remote of
            OptionalIdle ->
                note "尚未读取。"

            OptionalLoading ->
                note "读取中…"

            OptionalUnavailable message ->
                viewIntegrationBoundary message

            OptionalFailed message ->
                errorNote message

            OptionalLoaded revisions ->
                if List.isEmpty revisions then
                    note "尚无 revision。"

                else
                    div [ Attr.class "prompt-revision-list" ]
                        (List.map (viewPromptRevision model root) (List.reverse (List.take 8 (List.reverse revisions))))
        ]


viewPromptRevision : Model -> Bool -> PromptRevisionView -> Html Msg
viewPromptRevision model root revision =
    details
        [ Attr.classList
            [ ( "prompt-revision", True )
            , ( "active", revision.status == "active" )
            ]
        ]
        [ summary []
            [ span [ Attr.class ("prompt-state " ++ revision.status) ] [ text revision.status ]
            , span [ Attr.class "prompt-revision-name" ]
                [ text
                    (revision.layer
                        ++ " · "
                        ++ revision.id
                        ++ " · r"
                        ++ String.fromInt revision.ordinal
                    )
                ]
            , span [ Attr.class "prompt-generator" ] [ text revision.generatorRevision ]
            ]
        , div [ Attr.class "prompt-revision-body" ]
            [ p [ Attr.class "memory-source" ] [ text ("source · " ++ revision.sourceIntent) ]
            , pre [ Attr.class "prompt-content" ] [ text revision.content ]
            , div [ Attr.class "snapshot-meta" ]
                [ meta "hash" revision.effectiveHash
                , meta "parent" (Maybe.withDefault "—" revision.parentRevision)
                , meta "invocation" (Maybe.withDefault "—" revision.modelInvocationRef)
                ]
            , div [ Attr.class "prompt-revision-actions" ]
                [ button
                    [ Attr.class "mini-button"
                    , Attr.type_ "button"
                    , Attr.disabled (Maybe.withDefault False (Maybe.map (\editor -> editor.saving) model.promptEditor))
                    , Events.onClick (BeginPromptEdit root revision)
                    ]
                    [ text "基于此修改" ]
                , if revision.status == "draft" then
                    button
                        [ Attr.class "mini-button prompt-activate"
                        , Attr.type_ "button"
                        , Attr.disabled (model.activatingPrompt /= Nothing)
                        , Events.onClick
                            (if root then
                                ActivateRootPromptRevision revision.id (activeRootOrdinal model.rootPrompts)

                             else
                                ActivatePromptRevision revision.id
                            )
                        ]
                        [ text
                            (if model.activatingPrompt == Just revision.id then
                                "激活中…"

                             else
                                "激活此 revision"
                            )
                        ]

                  else
                    text ""
                ]
            ]
        ]


activeRootOrdinal : OptionalRemote (List PromptRevisionView) -> Int
activeRootOrdinal remote =
    case remote of
        OptionalLoaded revisions ->
            revisions
                |> List.filter (\revision -> revision.status == "active")
                |> List.map .ordinal
                |> List.maximum
                |> Maybe.withDefault 0

        _ ->
            0


viewPromptEditor : Model -> Html Msg
viewPromptEditor model =
    case model.promptEditor of
        Nothing ->
            text ""

        Just editor ->
            section [ Attr.class "prompt-source-editor" ]
                [ div [ Attr.class "section-heading" ]
                    [ div []
                        [ span [ Attr.class "eyebrow" ]
                            [ text
                                (if editor.root then
                                    "Root draft"

                                 else
                                    "Charter draft"
                                )
                            ]
                        , h2 [ Attr.class "section-heading-title" ] [ text "审计后修改" ]
                        ]
                    , span [ Attr.class "revision-chip" ] [ text ("base · " ++ editor.baseId) ]
                    ]
                , p [ Attr.class "boundary-copy" ]
                    [ text "保存只创建 draft；不会静默改变当前生效行为。Root 与 Charter 都须另行激活。" ]
                , div [ Attr.class "form-field" ]
                    [ span [ Attr.class "field-label" ] [ text "修改理由 / source intent" ]
                    , input
                        [ Attr.value editor.sourceIntent
                        , Attr.disabled editor.saving
                        , Events.onInput PromptEditSourceChanged
                        ]
                        []
                    ]
                , div [ Attr.class "form-field" ]
                    [ span [ Attr.class "field-label" ] [ text "完整内容" ]
                    , textarea
                        [ Attr.value editor.content
                        , Attr.rows 18
                        , Attr.disabled editor.saving
                        , Events.onInput PromptEditContentChanged
                        ]
                        []
                    ]
                , div [ Attr.class "form-actions" ]
                    [ button
                        [ Attr.class "ghost-button"
                        , Attr.type_ "button"
                        , Attr.disabled editor.saving
                        , Events.onClick CancelPromptEdit
                        ]
                        [ text "取消" ]
                    , button
                        [ Attr.class "send-button"
                        , Attr.type_ "button"
                        , Attr.disabled
                            (editor.saving
                                || String.isEmpty (String.trim editor.sourceIntent)
                                || String.isEmpty (String.trim editor.content)
                            )
                        , Events.onClick SavePromptEdit
                        ]
                        [ text
                            (if editor.saving then
                                "保存中…"

                             else
                                "保存为草案"
                            )
                        ]
                    ]
                ]


viewSelfCard : String -> String -> String -> String -> Html Msg
viewSelfCard title kind value explanation =
    section [ Attr.class "self-card" ]
        [ span [ Attr.class "eyebrow" ] [ text kind ]
        , h2 [ Attr.class "self-card-title" ] [ text title ]
        , p [ Attr.class "self-card-value" ] [ text value ]
        , p [ Attr.class "self-card-copy" ] [ text explanation ]
        ]


promptLayer : String -> String -> String -> Html Msg
promptLayer ordinal name explanation =
    div [ Attr.class "prompt-layer" ]
        [ span [ Attr.class "prompt-ordinal" ] [ text ordinal ]
        , div []
            [ p [ Attr.class "prompt-layer-name" ] [ text name ]
            , p [ Attr.class "prompt-layer-copy" ] [ text explanation ]
            ]
        ]


viewSessions : Model -> Html Msg
viewSessions model =
    div [ Attr.class "inspector-section sessions-panel" ]
        [ h2 [ Attr.class "section-title" ]
            [ text "任务"
            , div [ Attr.class "section-actions" ]
                [ button
                    [ Attr.class "mini-button"
                    , Attr.type_ "button"
                    , Events.onClick ToggleArchivedSessions
                    ]
                    [ text
                        (if model.showArchived then
                            "隐藏归档"

                         else
                            "显示归档"
                        )
                    ]
                , refreshButton RefreshSessions
                ]
            ]
        , viewSessionList model
        , if model.currentTaskBelongs then
            div [ Attr.class "session-current" ]
                [ span [ Attr.class "field-label" ] [ text ("当前 · " ++ model.threadId) ]
            , div [ Attr.class "session-inline" ]
                [ input
                    [ Attr.value model.sessionTitleDraft
                    , Attr.placeholder "任务名称"
                    , Events.onInput SessionRenameChanged
                    ]
                    []
                , button
                    [ Attr.class "mini-button"
                    , Attr.type_ "button"
                    , Attr.disabled (String.isEmpty (String.trim model.sessionTitleDraft))
                    , Events.onClick RenameCurrentSession
                    ]
                    [ text "命名" ]
                ]
            , div [ Attr.class "session-inline" ]
                [ input
                    [ Attr.value model.forkNodeDraft
                    , Attr.placeholder "fork 节点 ID；留空取末尾"
                    , Events.onInput ForkNodeChanged
                    ]
                    []
                , button
                    [ Attr.class "mini-button"
                    , Attr.type_ "button"
                    , Attr.disabled (isBusy model.phase)
                    , Events.onClick ForkCurrentSession
                    ]
                    [ text "分叉" ]
                ]
            , div [ Attr.class "session-file-actions" ]
                [ button
                    [ Attr.class "mini-button"
                    , Attr.type_ "button"
                    , Events.onClick ExportCurrentSession
                    ]
                    [ text "导出" ]
                , button
                    [ Attr.class "mini-button"
                    , Attr.type_ "button"
                    , Events.onClick ImportSessionRequested
                    ]
                    [ text "导入" ]
                ]
            , case model.pendingSwitch of
                Just _ ->
                    p [ Attr.class "section-note" ] [ text "切换中…" ]

                Nothing ->
                    text ""
                , Maybe.map (\message -> p [ Attr.class "section-note error" ] [ text message ]) model.sessionActionError
                    |> Maybe.withDefault (text "")
                ]

          else
            text ""
        ]


viewSessionList : Model -> Html Msg
viewSessionList model =
    case model.sessions of
        NotAsked ->
            note "尚未拉取"

        Loading ->
            note "拉取中…"

        LoadFailed message ->
            errorNote message

        Loaded sessions ->
            let
                visible =
                    List.filter (\session -> model.showArchived || not session.archived) sessions
            in
            if List.isEmpty visible then
                note "这个分身尚无任务"

            else
                div [ Attr.class "session-list" ] (List.map (viewSessionRow model) visible)


viewSessionRow : Model -> SessionMeta -> Html Msg
viewSessionRow model session =
    div
        [ Attr.classList
            [ ( "session-row", True )
            , ( "active", session.id == model.threadId )
            , ( "archived", session.archived )
            ]
        ]
        [ button
            [ Attr.class "session-switch"
            , Attr.type_ "button"
            , Attr.disabled (session.id == model.threadId || model.pendingSwitch /= Nothing || isBusy model.phase)
            , Events.onClick (SwitchSession session.id)
            ]
            [ span [ Attr.class "session-title" ] [ text session.title ]
            , span [ Attr.class "session-id" ] [ text session.id ]
            ]
        , button
            [ Attr.class "session-state"
            , Attr.type_ "button"
            , Attr.disabled (session.id == model.threadId && isBusy model.phase)
            , Events.onClick
                (if session.archived then
                    RestoreSession session.id

                 else
                    ArchiveSession session.id
                )
            ]
            [ text
                (if session.archived then
                    "恢复"

                 else
                    "归档"
                )
            ]
        ]


viewTree : Remote (Maybe (List String)) -> Html Msg
viewTree remote =
    case remote of
        NotAsked ->
            note "尚未拉取"

        Loading ->
            note "拉取中…"

        LoadFailed message ->
            errorNote message

        Loaded Nothing ->
            note "该任务未绑定工作目录"

        Loaded (Just entries) ->
            if List.isEmpty entries then
                note "空目录"

            else
                pre [ Attr.class "tree-view" ] [ text (String.join "\n" entries) ]


viewConfig : Model -> Html Msg
viewConfig model =
    main_ [ Attr.class "page capabilities-page" ]
        [ div [ Attr.class "page-heading" ]
            [ div []
                [ span [ Attr.class "eyebrow" ] [ text "现实自我" ]
                , h2 [ Attr.class "page-title" ] [ text "能力" ]
                , p [ Attr.class "page-description" ]
                    [ text "这里配置当前任务可实际使用的模型、工具与 workspace。Prompt 的身份与行为层在「自我」中治理。" ]
                ]
            ]
        , if model.currentTaskBelongs then
            div []
                [ viewAutonomyStatus model
                , div [ Attr.class "config-grid" ]
                    [ viewSessionConfig model
                    , viewGlobalConfig model.configPanel.global
                    ]
                ]

          else
            viewNoCurrentTask
        ]


viewAutonomyStatus : Model -> Html Msg
viewAutonomyStatus model =
    let
        capabilities =
            case model.configPanel.capabilities of
                Loaded names ->
                    names

                _ ->
                    []

        toolCount =
            List.length capabilities

        canDelegate =
            List.member "sub_agent" capabilities

        canSearchMemory =
            List.member "memory_grep" capabilities
                || List.member "memory" capabilities

        policyRevision =
            model.incarnation.promptRevision
                |> Maybe.map (\revision -> "由 prompt " ++ revision ++ " 约束")
                |> Maybe.withDefault "等待 Root Prompt Compiler 接通"
    in
    section [ Attr.class "autonomy-panel" ]
        [ div [ Attr.class "section-heading" ]
            [ div []
                [ span [ Attr.class "eyebrow" ] [ text "Coordinator 自治" ]
                , h2 [ Attr.class "section-heading-title" ] [ text "会不会自己判断如何工作" ]
                ]
            , span [ Attr.class "revision-chip" ] [ text policyRevision ]
            ]
        , div [ Attr.class "autonomy-grid" ]
            [ autonomyItem
                "工具"
                (if toolCount == 0 then
                    "能力快照尚未读取"

                 else
                    String.fromInt toolCount ++ " 项工具可见"
                )
                "Root 的 Tool Policy 应定义何时检索、调用、复核与停止；工具菜单本身不等于行为协议。"
            , autonomyItem
                "编排"
                (if canDelegate then
                    "当前运行时可调用 sub_agent"

                 else
                    "当前能力未开放 sub_agent"
                )
                "Orchestration Policy 应生成角色、上下文租约、预算、验收与写回边界；Worker 不继承长期记忆写权限。"
            , autonomyItem
                "记忆"
                (if canSearchMemory then
                    "可主动检索长期记忆"

                 else
                    "长期记忆工具尚未出现在快照"
                )
                "印象只给 cue；Coordinator 判断相关后再 grep / read，并留下 Memory Read Receipt。"
            ]
        ]


autonomyItem : String -> String -> String -> Html Msg
autonomyItem label title copy =
    div [ Attr.class "autonomy-item" ]
        [ span [ Attr.class "eyebrow" ] [ text label ]
        , p [ Attr.class "autonomy-title" ] [ text title ]
        , p [ Attr.class "autonomy-copy" ] [ text copy ]
        ]


viewGlobalConfig : Remote GlobalView -> Html Msg
viewGlobalConfig remote =
    details [ Attr.class "inspector-section config-global" ]
        [ summary [ Attr.class "config-global-summary" ] [ text "全局生效配置 · 只读参考" ]
        , viewRemote renderGlobal remote
        ]


renderGlobal : GlobalView -> Html Msg
renderGlobal global =
    div []
        [ p [ Attr.class "field-label config-group" ] [ text ("provider · " ++ global.provider.name) ]
        , div [ Attr.class "run-meta" ]
            [ meta "model" global.provider.model
            , meta "baseUrl" global.provider.baseUrl
            , meta "apiKey" global.provider.apiKey
            , meta "dialect" global.provider.dialect
            , meta "thinking" global.provider.thinking
            , meta "maxTokens" (tokenLabel global.provider.maxTokens)
            , meta "contextTokens" (String.fromInt global.provider.contextTokens)
            ]
        , p [ Attr.class "field-label config-group" ] [ text "settings" ]
        , div [ Attr.class "run-meta" ]
            [ meta "host" global.settings.host
            , meta "port" (String.fromInt global.settings.port_)
            , meta "maxTurns" (String.fromInt global.settings.maxTurns)
            , meta "toolExecution" global.settings.toolExecution
            , meta "workDir" (maybeDash global.settings.workDir)
            , meta "journalDir" (maybeDash global.settings.journalDir)
            , meta "artifactDir" (maybeDash global.settings.artifactDir)
            , meta "memoryDir" (maybeDash global.settings.memoryDir)
            , meta "memoryModel" (maybeDash global.settings.memoryModel)
            , meta "contextReserveTokens" (String.fromInt global.settings.contextReserveTokens)
            , meta "contextKeepUnits" (String.fromInt global.settings.contextKeepUnits)
            , meta "contextSummaryTokens" (String.fromInt global.settings.contextSummaryTokens)
            ]
        ]


maybeOr : Maybe a -> Maybe a -> Maybe a
maybeOr fallback preferred =
    case preferred of
        Just _ ->
            preferred

        Nothing ->
            fallback


orDash : String -> String
orDash value =
    if String.isEmpty (String.trim value) then
        "—"

    else
        value


maybeDash : Maybe String -> String
maybeDash =
    Maybe.withDefault "—"


viewSessionConfig : Model -> Html Msg
viewSessionConfig model =
    let
        dirty =
            model.configPanel.draft /= model.configPanel.baseline
    in
    div [ Attr.class "inspector-section" ]
        [ h2 [ Attr.class "section-title" ]
            [ text ("当前任务 · " ++ model.threadId)
            , if dirty then
                span [ Attr.class "dirty-flag" ] [ text "未保存" ]

              else
                text ""
            ]
        , viewRemote (\_ -> viewConfigForm model) model.configPanel.session
        ]


viewConfigForm : Model -> Html Msg
viewConfigForm model =
    let
        panel =
            model.configPanel

        dirty =
            panel.draft /= panel.baseline

        defaults =
            case panel.global of
                Loaded global ->
                    Just global.defaults

                _ ->
                    Nothing

        inherit pick =
            Maybe.andThen pick defaults

        placeholder pick =
            maybeDash (Maybe.andThen pick defaults)

        providers =
            case panel.providers of
                Loaded list ->
                    list

                _ ->
                    []

        globalProviderName =
            case panel.global of
                Loaded global ->
                    global.provider.name

                _ ->
                    ""

        selectedProviderEntry =
            let
                name =
                    if String.isEmpty panel.draft.provider then
                        inherit .provider |> Maybe.withDefault globalProviderName

                    else
                        panel.draft.provider
            in
            List.filter (\p -> p.name == name) providers |> List.head

        providerModels =
            Maybe.map .models selectedProviderEntry |> Maybe.withDefault []

        effectiveProvider =
            if String.isEmpty panel.draft.provider then
                inherit .provider

            else
                Just panel.draft.provider

        effectiveCwd =
            case panel.draft.cwdMode of
                CwdPath ->
                    nonEmpty panel.draft.cwd

                CwdNone ->
                    Nothing

                CwdInherit ->
                    inherit .cwd

        effectiveTools =
            case panel.capabilities of
                Loaded tools ->
                    if List.isEmpty tools then
                        "无"

                    else
                        capabilitySummary tools

                Loading ->
                    "读取中…"

                LoadFailed _ ->
                    "读取失败"

                NotAsked ->
                    "尚未读取"

        inheritedReserve =
            inherit .contextReserveTokens

        inheritedKeep =
            inherit .contextKeepUnits

        inheritedSummary =
            inherit .contextSummaryTokens
    in
    div []
        [ p [ Attr.class "section-note config-hint" ]
            [ text "cwd 明确区分继承、无目录与指定目录；其余项留空即继承全局。任务级 legacy systemPrompt 不在此编辑，避免一次任务反向定义分身。" ]
        , div [ Attr.class "form-field" ]
            [ span [ Attr.class "field-label" ] [ text "工作目录 cwd" ]
            , div [ Attr.class "field-suggestions" ]
                [ cwdModeButton panel.draft.cwdMode CwdInherit "继承全局"
                , cwdModeButton panel.draft.cwdMode CwdNone "无目录"
                , cwdModeButton panel.draft.cwdMode CwdPath "指定目录"
                ]
            , input
                [ Attr.value panel.draft.cwd
                , Attr.placeholder (placeholder .cwd)
                , Attr.disabled (panel.draft.cwdMode /= CwdPath)
                , Events.onInput ConfigCwdChanged
                ]
                []
            , p [ Attr.class "field-inherit-hint" ]
                [ text
                    ("生效能力："
                        ++ effectiveTools
                        ++ (effectiveCwd
                                |> Maybe.map (\cwd -> " · " ++ cwd)
                                |> Maybe.withDefault " · 无工作目录"
                           )
                    )
                ]
            ]
        , div [ Attr.class "form-field" ]
            [ span [ Attr.class "field-label" ] [ text "provider" ]
            , div [ Attr.class "field-suggestions" ]
                (List.map (providerChip panel.draft.provider) providers)
            , p [ Attr.class "field-inherit-hint" ]
                [ text
                    ("生效："
                        ++ (effectiveProvider |> Maybe.withDefault globalProviderName |> orDash)
                        ++ (if String.isEmpty panel.draft.provider then
                                " · 继承全局"

                            else
                                " · 本任务设定"
                           )
                    )
                ]
            ]
        , div [ Attr.class "form-field" ]
            [ span [ Attr.class "field-label" ] [ text "模型 model" ]
            , input
                [ Attr.value panel.draft.model
                , Attr.placeholder "可直接输入模型 ID；留空继承全局"
                , Events.onInput ConfigModelChanged
                ]
                []
            , div [ Attr.class "field-suggestions" ]
                (List.map (modelChip panel.draft.model) providerModels)
            , p [ Attr.class "field-inherit-hint" ]
                [ text
                    ("生效："
                        ++ (if String.isEmpty panel.draft.model then
                                (inherit .model
                                    |> maybeOr (Maybe.map .defaultModel selectedProviderEntry)
                                    |> Maybe.withDefault ""
                                    |> orDash
                                )
                                    ++ " · 继承全局"

                            else
                                panel.draft.model ++ " · 本任务设定"
                           )
                    )
                ]
            ]
        , viewConfigEffort panel.draft (effectiveProviderName panel)
        , viewContextConfig
            panel.draft
            inheritedReserve
            inheritedKeep
            inheritedSummary
            panel.contextPolicy
        , gateRow "fs · 文件工具" panel.draft.fs (inherit .fs) FsField
        , gateRow "shell · 命令执行" panel.draft.shell (inherit .shell) ShellField
        , div [ Attr.class "form-actions" ]
            [ span [ Attr.class "save-status" ]
                [ if dirty then
                    span [ Attr.class "section-note save-dirty" ] [ text "有未保存改动" ]

                  else if panel.saved then
                    span [ Attr.class "section-note replay-ok" ] [ text "已保存" ]

                  else
                    text ""
                , case panel.saveError of
                    Just message ->
                        span [ Attr.class "section-note error" ] [ text message ]

                    Nothing ->
                        text ""
                ]
            , button
                [ Attr.class "send-button"
                , Attr.type_ "button"
                , Attr.disabled (panel.saving || not dirty)
                , Events.onClick SaveConfig
                ]
                [ text
                    (if panel.saving then
                        "保存中…"

                     else
                        "保存"
                    )
                ]
            ]
        ]


viewConfigEffort : ConfigDraft -> String -> Html Msg
viewConfigEffort draft provider =
    let
        efforts =
            reasoningEfforts provider

        effective =
            if String.isEmpty draft.reasoningEffort then
                defaultReasoningEffort provider

            else
                draft.reasoningEffort
    in
    div [ Attr.class "form-field" ]
        [ span [ Attr.class "field-label" ] [ text "思考强度 reasoningEffort" ]
        , if List.isEmpty efforts then
            p [ Attr.class "field-inherit-hint" ]
                [ text
                    (if provider == "zai" then
                        "GLM-5.2 保持 thinking 开启；其 API 未公开 effort 档位。"

                     else
                        "当前模型未声明 effort 档位。"
                    )
                ]

          else
            div [ Attr.class "field-suggestions" ]
                (List.map (effortChip effective ConfigEffortChanged) efforts)
        , if List.isEmpty efforts then
            text ""

          else
            p [ Attr.class "field-inherit-hint" ]
                [ text
                    ("生效："
                        ++ effective
                        ++ (if String.isEmpty draft.reasoningEffort then
                                " · 模型默认"

                            else
                                " · 本任务设定"
                           )
                    )
                ]
        ]


effortChip : String -> (String -> Msg) -> String -> Html Msg
effortChip selected onSelect effort =
    button
        [ Attr.class
            ("field-chip"
                ++ (if selected == effort then
                        " active"

                    else
                        ""
                   )
            )
        , Attr.type_ "button"
        , Events.onClick (onSelect effort)
        ]
        [ text effort ]


viewContextConfig : ConfigDraft -> Maybe Int -> Maybe Int -> Maybe Int -> Remote ContextPolicyView -> Html Msg
viewContextConfig draft inheritedReserve inheritedKeep inheritedSummary remote =
    let
        reserve =
            maybeOr inheritedReserve (optionalInt draft.contextReserveTokens)

        formula policy =
            let
                appliedReserve =
                    Maybe.withDefault policy.reserveTokens reserve

                projectedBudget =
                    max 256 (policy.windowTokens - appliedReserve - policy.toolTokens)

                pending =
                    if projectedBudget /= policy.budgetTokens then
                        " · 未保存预估"

                    else
                        " · 当前实际"
            in
            "模型窗口 "
                ++ String.fromInt policy.windowTokens
                ++ " − 预留 "
                ++ String.fromInt appliedReserve
                ++ " − 工具定义 "
                ++ String.fromInt policy.toolTokens
                ++ " = 触发线 "
                ++ String.fromInt projectedBudget
                ++ " tokens"
                ++ pending
    in
    div [ Attr.class "context-settings" ]
        [ div [ Attr.class "context-settings-head" ]
            [ span [ Attr.class "field-label" ] [ text "短期上下文边界" ]
            , span [ Attr.class "section-note" ] [ text "每次模型调用前判定" ]
            ]
        , p [ Attr.class "section-note context-explanation" ]
            [ text "消息估算超过触发线即进入兼容整理流程；预留越大，越早准备睡眠。工具调用与对应结果视作一个不可拆轮组。" ]
        , div [ Attr.class "context-settings-grid" ]
            [ contextNumberField
                "预留 token"
                draft.contextReserveTokens
                inheritedReserve
                1
                "控制时机；为模型输出与误差留余量。"
                ConfigContextReserveChanged
            , contextNumberField
                "保留轮组"
                draft.contextKeepUnits
                inheritedKeep
                1
                "醒来后最多保留多少个最近因果轮组。"
                ConfigContextKeepChanged
            , contextNumberField
                "摘要上限"
                draft.contextSummaryTokens
                inheritedSummary
                96
                "兼容 WakePacket 投影可占用的最大 token。"
                ConfigContextSummaryChanged
            ]
        , case remote of
            Loaded policy ->
                p [ Attr.class "context-formula" ] [ text (formula policy) ]

            Loading ->
                p [ Attr.class "context-formula quiet" ] [ text "正在计算当前触发线…" ]

            LoadFailed message ->
                p [ Attr.class "context-formula error" ] [ text message ]

            NotAsked ->
                text ""
        , p [ Attr.class "field-inherit-hint" ] [ text "若同时改了 provider 或工具开关，保存后会按实际模型窗口与工具定义重新计算。" ]
        ]


contextNumberField : String -> String -> Maybe Int -> Int -> String -> (String -> Msg) -> Html Msg
contextNumberField labelText value inherited minimum help onInput =
    div [ Attr.class "form-field context-number-field" ]
        [ span [ Attr.class "field-label" ] [ text labelText ]
        , input
            [ Attr.type_ "number"
            , Attr.attribute "aria-label" labelText
            , Attr.min (String.fromInt minimum)
            , Attr.step "1"
            , Attr.value value
            , Attr.placeholder (inherited |> Maybe.map String.fromInt |> Maybe.withDefault "继承全局")
            , Events.onInput onInput
            ]
            []
        , p [ Attr.class "field-inherit-hint" ]
            [ text
                (help
                    ++ " 留空继承"
                    ++ (inherited
                            |> Maybe.map (\number -> "（" ++ String.fromInt number ++ "）")
                            |> Maybe.withDefault "全局"
                       )
                )
            ]
        ]


providerChip : String -> ProviderEntryView -> Html Msg
providerChip selected entry =
    button
        [ Attr.class
            ("field-chip"
                ++ (if selected == entry.name then
                        " active"

                    else
                        ""
                   )
                ++ (if not entry.keyReady then
                        " disabled"

                    else
                        ""
                   )
            )
        , Attr.type_ "button"
        , Attr.disabled (not entry.keyReady)
        , Attr.title
            (entry.name
                ++ " · "
                ++ entry.defaultModel
                ++ (if not entry.keyReady then
                        " · key 未设"

                    else
                        ""
                   )
            )
        , Events.onClick (ConfigProviderChanged entry.name)
        ]
        [ text (entry.name ++ (if not entry.keyReady then "  (key 未设)" else "")) ]


capabilitySummary : List String -> String
capabilitySummary names =
    let
        groups =
            [ ( "工件读取", [ "artifact_read" ] )
            , ( "文件（读、写、改、搜索）", [ "fs_edit", "fs_glob", "fs_grep", "fs_list", "fs_read", "fs_write" ] )
            , ( "命令", [ "shell" ] )
            , ( "后台任务", [ "shell_bg", "shell_kill", "shell_output", "shell_stdin" ] )
            , ( "任务计划", [ "plan" ] )
            , ( "子代理", [ "sub_agent" ] )
            ]

        known =
            List.concatMap Tuple.second groups

        labels =
            groups
                |> List.filterMap
                    (\( label, members ) ->
                        if List.any (\name -> List.member name names) members then
                            Just label

                        else
                            Nothing
                    )
    in
    String.join " / " (labels ++ List.filter (\name -> not (List.member name known)) names)


cwdModeButton : CwdMode -> CwdMode -> String -> Html Msg
cwdModeButton selected mode labelText =
    button
        [ Attr.class
            ("field-chip"
                ++ (if selected == mode then
                        " active"

                    else
                        ""
                   )
            )
        , Attr.type_ "button"
        , Events.onClick (ConfigCwdModeChanged mode)
        ]
        [ text labelText ]


modelChip : String -> String -> Html Msg
modelChip selected name =
    button
        [ Attr.class
            ("field-chip"
                ++ (if selected == name then
                        " active"

                    else
                        ""
                   )
            )
        , Attr.type_ "button"
        , Events.onClick (ConfigModelChanged name)
        ]
        [ text name ]


gateRow : String -> Maybe Bool -> Maybe Bool -> SessionField -> Html Msg
gateRow labelText current inherited field =
    let
        effective =
            orElse current inherited /= Just False

        source =
            case current of
                Just _ ->
                    "本任务设定"

                Nothing ->
                    "继承全局"
    in
    div [ Attr.class "form-field" ]
        [ div [ Attr.class "gate-label-row" ]
            [ span [ Attr.class "field-label" ] [ text labelText ]
            , span
                [ Attr.class
                    ("gate-state "
                        ++ (if effective then
                                "on"

                            else
                                "off"
                           )
                    )
                ]
                [ text (("生效：" ++ boolLabel effective) ++ " · " ++ source) ]
            ]
        , div [ Attr.class "gate-group" ]
            [ gateButton field current Nothing "继承"
            , gateButton field current (Just True) "开"
            , gateButton field current (Just False) "关"
            ]
        ]


boolLabel : Bool -> String
boolLabel on =
    if on then
        "开"

    else
        "关"


gateButton : SessionField -> Maybe Bool -> Maybe Bool -> String -> Html Msg
gateButton field current value label =
    button
        [ Attr.class
            ("ghost-button small gate"
                ++ (if current == value then
                        " active"

                    else
                        ""
                   )
            )
        , Attr.type_ "button"
        , Events.onClick (ConfigGate field value)
        ]
        [ text label ]


viewAudit : Model -> Html Msg
viewAudit model =
    main_ [ Attr.class "page audit" ]
        [ div [ Attr.class "page-heading" ]
            [ div []
                [ span [ Attr.class "eyebrow" ] [ text "Root / system plane" ]
                , h2 [ Attr.class "page-title" ] [ text "系统审计" ]
                , p [ Attr.class "page-description" ]
                    [ text "低频检查层：Run、Journal、Replay 与工件。旧 brief / facts 不再作为分身记忆呈现。" ]
                ]
            , button
                [ Attr.class "ghost-button"
                , Attr.type_ "button"
                , Events.onClick (SelectTab SelfTab)
                ]
                [ text "返回分身" ]
            ]
        , div [ Attr.class "audit-grid" ]
            [ viewRunsSection model
            , viewArtifactsSection model
            ]
        ]


viewIncarnationForm : Model -> Html Msg
viewIncarnationForm model =
    case model.incarnationForm of
        Nothing ->
            text ""

        Just draft ->
            div [ Attr.class "overlay" ]
                [ div [ Attr.class "session-form incarnation-form" ]
                    [ h2 [ Attr.class "form-title" ] [ text "新分身" ]
                    , p [ Attr.class "boundary-copy" ]
                        [ text "定义方向即可。系统会生成首个 Charter 草案；无需手写完整 system prompt。" ]
                    , div [ Attr.class "form-field" ]
                        [ span [ Attr.class "field-label" ] [ text "稳定 ID" ]
                        , input
                            [ Attr.value draft.identifier
                            , Attr.disabled draft.saving
                            , Events.onInput IncarnationIdChanged
                            ]
                            []
                        ]
                    , div [ Attr.class "form-field" ]
                        [ span [ Attr.class "field-label" ] [ text "名称" ]
                        , input
                            [ Attr.value draft.name
                            , Attr.placeholder "例如：研究 Yuki"
                            , Attr.disabled draft.saving
                            , Events.onInput IncarnationNameChanged
                            ]
                            []
                        ]
                    , div [ Attr.class "form-field" ]
                        [ span [ Attr.class "field-label" ] [ text "方向 / 使命" ]
                        , textarea
                            [ Attr.value draft.direction
                            , Attr.placeholder "它长期面对什么方向，如何判断工作是否做好"
                            , Attr.rows 5
                            , Attr.disabled draft.saving
                            , Events.onInput IncarnationDirectionChanged
                            ]
                            []
                        ]
                    , div [ Attr.class "form-field" ]
                        [ span [ Attr.class "field-label" ] [ text "印象模型 profile" ]
                        , input
                            [ Attr.value draft.impressionModel
                            , Attr.placeholder "留空使用默认模型"
                            , Attr.disabled draft.saving
                            , Events.onInput IncarnationModelChanged
                            ]
                            []
                        ]
                    , draft.error
                        |> Maybe.map (\message -> p [ Attr.class "section-note error" ] [ text message ])
                        |> Maybe.withDefault (text "")
                    , div [ Attr.class "form-actions" ]
                        [ button
                            [ Attr.class "ghost-button"
                            , Attr.type_ "button"
                            , Attr.disabled draft.saving
                            , Events.onClick CloseIncarnationForm
                            ]
                            [ text "取消" ]
                        , button
                            [ Attr.class "send-button"
                            , Attr.type_ "button"
                            , Attr.disabled
                                (draft.saving
                                    || String.isEmpty (String.trim draft.identifier)
                                    || String.isEmpty (String.trim draft.name)
                                    || String.isEmpty (String.trim draft.direction)
                                )
                            , Events.onClick SubmitIncarnationForm
                            ]
                            [ text
                                (if draft.saving then
                                    "生成中…"

                                 else
                                    "创建并生成 Charter"
                                )
                            ]
                        ]
                    ]
                ]


viewSessionForm : Model -> Html Msg
viewSessionForm model =
    case model.sessionForm of
        Nothing ->
            text ""

        Just form ->
            div [ Attr.class "overlay" ]
                [ div [ Attr.class "session-form" ]
                    [ h2 [ Attr.class "form-title" ] [ text "新任务" ]
                    , div [ Attr.class "form-field" ]
                        [ span [ Attr.class "field-label" ] [ text "任务 ID" ]
                        , input [ Attr.value form.targetId, Attr.disabled True ] []
                        , p [ Attr.class "field-inherit-hint" ]
                            [ text ("归属分身 · " ++ model.incarnation.name ++ " / " ++ model.incarnationId) ]
                        ]
                    , div [ Attr.class "form-field" ]
                        [ span [ Attr.class "field-label" ] [ text "名称" ]
                        , input
                            [ Attr.value form.title
                            , Attr.placeholder "可留空，首条消息将作为名称"
                            , Events.onInput SessionTitleChanged
                            ]
                            []
                        ]
                    , div [ Attr.class "form-field" ]
                        [ span [ Attr.class "field-label" ] [ text "工作目录 cwd" ]
                        , input
                            [ Attr.value form.cwd
                            , Attr.placeholder "默认继承本机工作目录；也可指定其他目录"
                            , Events.onInput SessionCwdChanged
                            ]
                            []
                        , p [ Attr.class "field-inherit-hint" ]
                            [ text
                                (if String.isEmpty (String.trim form.cwd) then
                                    "将继承全局目录；全局无目录时不会注册 fs/shell。"

                                 else
                                    "子代理将继承此目录及已启用的本机工具。"
                                )
                            ]
                        ]
                    , toggleRow "fs · 文件工具" form.fs FsField
                    , toggleRow "shell · 命令执行" form.shell ShellField
                    , form.error
                        |> Maybe.map (\message -> p [ Attr.class "section-note error" ] [ text message ])
                        |> Maybe.withDefault (text "")
                    , div [ Attr.class "form-actions" ]
                        [ button
                            [ Attr.class "ghost-button"
                            , Attr.type_ "button"
                            , Events.onClick CloseSessionForm
                            ]
                            [ text "取消" ]
                        , button
                            [ Attr.class "send-button"
                            , Attr.type_ "button"
                            , Attr.disabled (form.saving || not form.prefilled)
                            , Events.onClick SubmitSessionForm
                            ]
                            [ text
                                (if form.saving then
                                    "创建中…"

                                 else if form.prefilled then
                                    "创建"

                                 else
                                    "载入中…"
                                )
                            ]
                        ]
                    ]
                ]


toggleRow : String -> Bool -> SessionField -> Html Msg
toggleRow labelText checked field =
    label [ Attr.class "toggle-row" ]
        [ input
            [ Attr.type_ "checkbox"
            , Attr.checked checked
            , Events.onCheck (\_ -> SessionToggle field)
            ]
            []
        , span [] [ text labelText ]
        ]


viewTranscript : Model -> List (Html Msg)
viewTranscript model =
    if Dict.isEmpty model.messages then
        [ viewEmptyState ]

    else
        Maybe.map viewError model.error
            |> Maybe.withDefault (text "")
            |> (\banner -> banner :: List.concatMap (viewMessage model) (orderedMessages model))


viewEmptyState : Html Msg
viewEmptyState =
    section [ Attr.class "empty-state" ]
        [ h2 [ Attr.class "empty-title" ] [ text "把意图交给这个 Yuki。" ]
        , p [ Attr.class "empty-description" ]
            [ text "可以提问、交付工作或纠正它。系统应先判断路由；只有持续工作才形成任务。" ]
        , div [ Attr.class "suggestions" ]
            [ suggestion "你现在如何理解自己的方向？"
            , suggestion "检查当前能力，再说明你真正能做什么。"
            , suggestion "把接下来的工作拆成任务，并说明是否需要委派。"
            ]
        ]


suggestion : String -> Html Msg
suggestion prompt =
    button
        [ Attr.class "suggestion"
        , Attr.type_ "button"
        , Events.onClick (PromptSelected prompt)
        ]
        [ text prompt ]


viewMessage : Model -> ChatMessage -> List (Html Msg)
viewMessage model message =
    case message of
        UserChat _ content ->
            [ div [ Attr.class "message-row user" ]
                [ div [ Attr.class "message" ]
                    [ p [ Attr.class "message-copy" ] [ text content ] ]
                ]
            ]

        SummaryChat _ content ->
            [ details [ Attr.class "memory-card legacy-context" ]
                [ summary [] [ text "旧上下文 · 兼容投影" ]
                , pre [ Attr.class "memory-copy" ] [ text content ]
                ]
            ]

        MemoryChat _ content ->
            [ details [ Attr.class "memory-card legacy-context" ]
                [ summary [] [ text "运行上下文 · 来源可审计" ]
                , pre [ Attr.class "memory-copy" ] [ text content ]
                ]
            ]

        NoticeChat _ content ->
            [ div [ Attr.class "notice-line" ] [ text content ] ]

        SubAgentChat sub ->
            [ viewSubCard sub ]

        ReasoningChat reasoning ->
            if String.isEmpty reasoning.content then
                []

            else
                [ details [ Attr.class "reasoning" ]
                    [ summary []
                        [ text <|
                            if reasoning.complete then
                                "推理轨迹"

                            else
                                "推理中…"
                        ]
                    , pre [ Attr.class "reasoning-copy" ] [ text reasoning.content ]
                    ]
                ]

        AssistantChat assistant ->
            let
                calls =
                    List.filterMap (\identifier -> Dict.get identifier model.tools) assistant.toolCalls

                copy =
                    if String.isEmpty assistant.content then
                        []

                    else if assistant.complete then
                        [ div [ Attr.class "message-copy markdown" ]
                            [ Markdown.toHtml [] assistant.content ]
                        ]

                    else
                        [ p [ Attr.class "message-copy stream-caret" ] [ text assistant.content ] ]

                toolStack =
                    if List.isEmpty calls then
                        []

                    else
                        [ div [ Attr.class "tool-stack" ] (List.map viewTool calls) ]
            in
            if List.isEmpty copy && List.isEmpty calls then
                []

            else
                [ div [ Attr.class "message-row assistant" ]
                    [ div [ Attr.class "message" ]
                        (p [ Attr.class "message-label" ] [ text "YUKI.N" ]
                            :: (copy ++ toolStack)
                        )
                    ]
                ]

        ToolChat tool ->
            case Dict.get tool.callId model.tools of
                Just call ->
                    if toolIsAttached model call then
                        []

                    else
                        [ div [ Attr.class "tool-stack orphan-tool" ] [ viewTool call ] ]

                Nothing ->
                    if isDiff tool.content then
                        [ div [ Attr.class "tool-result diff-result" ]
                            [ div [ Attr.class "diff-head" ] [ text ("↳ tool " ++ tool.callId) ]
                            , div [ Attr.class "diff-view" ] (List.map viewDiffLine (String.lines tool.content))
                            ]
                        ]

                    else
                        [ div [ Attr.class "tool-result" ]
                            [ text ("↳ tool " ++ tool.callId ++ " · " ++ compact tool.content) ]
                        ]


isDiff : String -> Bool
isDiff content =
    String.startsWith "--- " content && String.contains "@@ " content


viewDiffLine : String -> Html Msg
viewDiffLine line =
    div [ Attr.class (diffLineClass line) ] [ text line ]


diffLineClass : String -> String
diffLineClass line =
    if String.startsWith "@@" line then
        "diff-line hunk"

    else if String.startsWith "+" line then
        "diff-line add"

    else if String.startsWith "-" line then
        "diff-line del"

    else
        "diff-line"


viewTool : ToolCall -> Html Msg
viewTool tool =
    let
        needsDecision =
            tool.name == confirmationToolName && tool.stage == ToolWaiting

        target =
            toolTarget tool.name tool.arguments

        resultBrief =
            tool.result
                |> Maybe.map compact
                |> Maybe.withDefault ""

        openAttr =
            if needsDecision then
                [ Attr.attribute "open" "" ]

            else
                []

        decision =
            if needsDecision then
                [ div [ Attr.class "tool-actions" ]
                    [ button
                        [ Attr.class "action-button reject"
                        , Attr.type_ "button"
                        , Events.onClick (ResolveTool tool.id False)
                        ]
                        [ text "拒绝" ]
                    , button
                        [ Attr.class "action-button approve"
                        , Attr.type_ "button"
                        , Events.onClick (ResolveTool tool.id True)
                        ]
                        [ text "允许并继续" ]
                    ]
                ]

            else
                []

        body =
            (argumentField "details" tool.arguments
                |> Maybe.map (\copy -> [ p [ Attr.class "tool-detail" ] [ text copy ] ])
                |> Maybe.withDefault []
            )
                ++ (if String.isEmpty (String.trim tool.arguments) then
                        []

                    else
                        [ details [ Attr.class "tool-payload" ]
                            [ summary [] [ text "参数" ]
                            , pre [ Attr.class "tool-args" ] [ text (prettyJson tool.arguments) ]
                            ]
                        ]
                   )
                ++ liveOutputBlocks tool
                ++ toolResultBlocks tool
                ++ decision
    in
    details
        (Attr.classList
            [ ( "tool-line", True )
            , ( toolStageClass tool.stage, True )
            ]
            :: openAttr
        )
        [ summary [ Attr.class "tool-summary" ]
            [ span [ Attr.class "tool-mark", Attr.attribute "aria-hidden" "true" ] []
            , span [ Attr.class "tool-action" ] [ text (toolActionLabel tool.name) ]
            , if String.isEmpty target then
                text ""

              else
                span [ Attr.class "tool-target", Attr.title target ] [ text target ]
            , if String.isEmpty resultBrief then
                text ""

              else
                span [ Attr.class "tool-result-brief", Attr.title resultBrief ] [ text ("· " ++ resultBrief) ]
            , span [ Attr.class "tool-stage" ] [ text (toolStageLabel tool.stage) ]
            ]
        , div [ Attr.class "tool-body" ] body
        ]


liveOutputBlocks : ToolCall -> List (Html Msg)
liveOutputBlocks tool =
    if String.isEmpty tool.output then
        []

    else
        let
            openAttr =
                case tool.stage of
                    ToolResolved ToolReturned ->
                        []

                    _ ->
                        [ Attr.attribute "open" "" ]
        in
        [ details (Attr.class "tool-output" :: openAttr)
            [ summary [] [ text "实时输出" ]
            , pre [ Attr.class "tool-args" ] [ text tool.output ]
            ]
        ]


toolResultBlocks : ToolCall -> List (Html Msg)
toolResultBlocks tool =
    tool.result
        |> Maybe.map
            (\content ->
                [ details [ Attr.class "tool-output tool-result-body" ]
                    [ summary [] [ text "结果" ]
                    , if isDiff content then
                        div [ Attr.class "diff-view" ] (List.map viewDiffLine (String.lines content))

                      else
                        pre [ Attr.class "tool-args" ] [ text content ]
                    ]
                ]
            )
        |> Maybe.withDefault []


toolActionLabel : String -> String
toolActionLabel name =
    case name of
        "shell" ->
            "运行"

        "shell_bg" ->
            "后台运行"

        "fs_read" ->
            "读取"

        "fs_write" ->
            "写入"

        "fs_edit" ->
            "编辑"

        "fs_list" ->
            "浏览"

        "fs_glob" ->
            "匹配"

        "fs_grep" ->
            "搜索"

        "sub_agent" ->
            "委派"

        "memory_grep" ->
            "检索记忆"

        "memory_read" ->
            "读取记忆"

        "memory_remember" ->
            "记住"

        "memory_void" ->
            "撤销记忆"

        "self_inspect" ->
            "检查自身"

        "self_update" ->
            "更新自身"

        "sleep" ->
            "等待"

        "request_confirmation" ->
            "需要确认"

        _ ->
            String.replace "_" " " name


toolTarget : String -> String -> String
toolTarget name arguments =
    let
        fields =
            case name of
                "shell" ->
                    [ "command", "cmd" ]

                "shell_bg" ->
                    [ "command", "cmd" ]

                "fs_read" ->
                    [ "path" ]

                "fs_write" ->
                    [ "path" ]

                "fs_edit" ->
                    [ "path" ]

                "fs_list" ->
                    [ "path" ]

                "fs_glob" ->
                    [ "pattern", "path" ]

                "fs_grep" ->
                    [ "query", "pattern", "path" ]

                _ ->
                    [ "title", "path", "command", "query", "pattern", "task", "reason", "content" ]
    in
    fields
        |> List.filterMap (\field -> argumentField field arguments)
        |> List.head
        |> Maybe.map compact
        |> Maybe.withDefault ""


toolStageClass : ToolStage -> String
toolStageClass stage =
    case stage of
        ToolStreaming ->
            "working"

        ToolWaiting ->
            "waiting"

        ToolResolved ToolRejected ->
            "rejected"

        ToolResolved ToolInterrupted ->
            "interrupted"

        ToolResolved _ ->
            "done"


viewError : String -> Html Msg
viewError message =
    div [ Attr.class "error-banner" ] [ text message ]


viewQuickConfig : Model -> Html Msg
viewQuickConfig model =
    let
        panel =
            model.configPanel

        blocked =
            panel.saving || isBusy model.phase
    in
    if panel.loadedFor /= Just model.threadId then
        div [ Attr.class "quick-config loading" ] [ span [] [ text "读取模型配置…" ] ]

    else
        let
            provider =
                effectiveProviderName panel

            modelName =
                effectiveModelName panel

            effort =
                effectiveReasoningEffort panel

            efforts =
                reasoningEfforts provider
        in
        div [ Attr.class "quick-config" ]
            [ div [ Attr.class "quick-config-group model-switcher" ]
                (span [ Attr.class "quick-config-label" ] [ text "MODEL" ]
                    :: List.map (quickModelButton provider modelName blocked) (providerEntries panel.providers)
                )
            , div [ Attr.class "quick-config-group effort-switcher" ]
                (span [ Attr.class "quick-config-label" ] [ text "EFFORT" ]
                    :: (if List.isEmpty efforts then
                            [ span [ Attr.class "quick-config-fixed" ] [ text "thinking on · fixed" ] ]

                        else
                            List.map (quickEffortButton effort blocked) efforts
                       )
                )
            , viewQuickConfigStatus panel
            ]


quickModelButton : String -> String -> Bool -> ProviderEntryView -> Html Msg
quickModelButton selectedProvider selectedModel blocked entry =
    let
        active =
            selectedProvider == entry.name && selectedModel == entry.defaultModel
    in
    button
        [ Attr.class
            ("quick-config-chip"
                ++ (if active then
                        " active"

                    else
                        ""
                   )
            )
        , Attr.type_ "button"
        , Attr.disabled (blocked || not entry.keyReady)
        , Attr.title
            (entry.defaultModel
                ++ (if entry.keyReady then
                        ""

                    else
                        " · key 未配置"
                   )
            )
        , Events.onClick (QuickModelSelected entry.name)
        ]
        [ text (quickModelLabel entry) ]


quickModelLabel : ProviderEntryView -> String
quickModelLabel entry =
    case entry.name of
        "deepseek" ->
            "DeepSeek V4 Pro"

        "zai" ->
            "GLM-5.2"

        "kimi-coding" ->
            "Kimi K3"

        _ ->
            entry.defaultModel


quickEffortButton : String -> Bool -> String -> Html Msg
quickEffortButton selected blocked effort =
    button
        [ Attr.class
            ("quick-config-chip effort"
                ++ (if selected == effort then
                        " active"

                    else
                        ""
                   )
            )
        , Attr.type_ "button"
        , Attr.disabled blocked
        , Events.onClick (QuickEffortSelected effort)
        ]
        [ text effort ]


viewQuickConfigStatus : ConfigPanel -> Html Msg
viewQuickConfigStatus panel =
    if panel.saving then
        span [ Attr.class "quick-config-status" ] [ text "应用中…" ]

    else
        case panel.saveError of
            Just message ->
                span [ Attr.class "quick-config-status error" ] [ text message ]

            Nothing ->
                text ""


viewComposer : Model -> Html Msg
viewComposer model =
    let
        busy =
            isBusy model.phase

        pending =
            hasPendingFrontendTool model
    in
    section [ Attr.class "composer-zone" ]
        [ viewQuickConfig model
        , form [ Attr.class "composer", Events.onSubmit Submit ]
            [ textarea
                [ Attr.placeholder <|
                    if pending then
                        "请先处理上方的工具请求…"

                    else if busy then
                        "输入对当前运行的引导，或排入回答后的下一轮…"

                    else
                        "交给这个 Yuki：提问、工作或纠正…"
                , Attr.value model.draft
                , Attr.disabled pending
                , Attr.rows 2
                , Events.onInput DraftChanged
                ]
                []
            , if List.isEmpty model.pathSuggestions then
                text ""

              else
                div [ Attr.class "path-suggestions" ]
                    (List.map
                        (\path ->
                            button
                                [ Attr.class "path-suggestion"
                                , Attr.type_ "button"
                                , Events.onClick (InsertPath path)
                                ]
                                [ text ("@" ++ path) ]
                        )
                        model.pathSuggestions
                    )
            , div [ Attr.class "composer-footer" ]
                [ div [ Attr.class "endpoint" ]
                    [ span [] [ text "POST" ]
                    , input
                        [ Attr.value model.endpoint
                        , Attr.disabled busy
                        , Attr.attribute "aria-label" "AG-UI endpoint"
                        , Events.onInput EndpointChanged
                        ]
                        []
                    ]
                , if busy then
                    div [ Attr.class "composer-actions" ]
                        [ button
                            [ Attr.class "send-button queue steer"
                            , Attr.type_ "button"
                            , Attr.disabled (String.isEmpty (String.trim model.draft) || pending)
                            , Events.onClick (Queue SteerControl)
                            ]
                            [ text "引导当前" ]
                        , button
                            [ Attr.class "send-button queue follow-up"
                            , Attr.type_ "button"
                            , Attr.disabled (String.isEmpty (String.trim model.draft) || pending)
                            , Events.onClick (Queue FollowUpControl)
                            ]
                            [ text "随后处理" ]
                        , button
                            [ Attr.class "send-button cancel"
                            , Attr.type_ "button"
                            , Events.onClick Cancel
                            ]
                            [ text "中止" ]
                        ]

                  else
                    div [ Attr.class "composer-actions" ]
                        [ button
                            [ Attr.class "composer-tool"
                            , Attr.type_ "button"
                            , Attr.disabled (lastUserIndex model == Nothing || pending)
                            , Attr.title "保留最后一条用户消息，重新生成其后的回答"
                            , Events.onClick RetryLast
                            ]
                            [ text "重试" ]
                        , button
                            [ Attr.class "composer-tool"
                            , Attr.type_ "button"
                            , Attr.disabled (lastAssistantText model == Nothing)
                            , Events.onClick CopyLastAnswer
                            ]
                            [ text "复制末答" ]
                        , button
                            [ Attr.class "send-button"
                            , Attr.type_ "submit"
                            , Attr.disabled (String.isEmpty (String.trim model.draft) || pending)
                            ]
                            [ text "发送" ]
                        ]
                ]
            ]
        ]


viewLatestButton : Model -> Html Msg
viewLatestButton model =
    if model.stickToBottom then
        text ""

    else
        button
            [ Attr.class "latest-button"
            , Attr.type_ "button"
            , Events.onClick ScrollLatest
            ]
            [ text <|
                if isBusy model.phase then
                    "模型仍在工作 · 回到最新"

                else
                    "回到最新"
            ]


viewRunsSection : Model -> Html Msg
viewRunsSection model =
    div [ Attr.class "inspector-section" ]
        [ h2 [ Attr.class "section-title" ]
            [ text "运行"
            , refreshButton RefreshAudit
            ]
        , input
            [ Attr.class "run-filter"
            , Attr.placeholder "过滤 runId / threadId…"
            , Attr.value model.inspection.runFilter
            , Events.onInput RunFilterChanged
            ]
            []
        , viewRemote (viewRunCards model) model.inspection.runs
        , viewDrilldown model
        ]


viewRunCards : Model -> List String -> Html Msg
viewRunCards model runIds =
    let
        summaryOf runId =
            Dict.get runId model.inspection.summaries
                |> Maybe.andThen remoteValue

        ordered =
            List.sortBy
                (\runId -> negate (Maybe.withDefault -1 (Maybe.map .firstSeq (summaryOf runId))))
                runIds

        visible =
            List.filter (matchesRunFilter model.inspection.runFilter summaryOf) ordered
    in
    if List.isEmpty visible then
        note "无匹配运行"

    else
        div [] (List.map (viewRunCard model summaryOf) visible)


verdictChip : Model -> String -> List (Html Msg)
verdictChip model runId =
    case Dict.get runId model.inspection.verdicts of
        Just True ->
            [ span [ Attr.class "verdict-chip good", Attr.title "回放复现一致" ] [ text "✓" ] ]

        Just False ->
            [ span [ Attr.class "verdict-chip bad", Attr.title "回放复现分歧" ] [ text "✗" ] ]

        Nothing ->
            []


matchesRunFilter : String -> (String -> Maybe RunSummary) -> String -> Bool
matchesRunFilter filterText summaryOf runId =
    let
        needle =
            String.toLower (String.trim filterText)

        haystack =
            String.toLower
                (runId ++ " " ++ Maybe.withDefault "" (Maybe.map .threadId (summaryOf runId)))
    in
    String.isEmpty needle || String.contains needle haystack


remoteValue : Remote a -> Maybe a
remoteValue remote =
    case remote of
        Loaded value ->
            Just value

        _ ->
            Nothing


viewRunCard : Model -> (String -> Maybe RunSummary) -> String -> Html Msg
viewRunCard model summaryOf runId =
    case summaryOf runId of
        Just info ->
            let
                rows =
                    runLogOf model runId

                opening =
                    Maybe.andThen firstUserMessage rows

                files =
                    Maybe.map touchedFiles rows
                        |> Maybe.withDefault []
            in
            div
                [ Attr.class
                    ("run-card"
                        ++ (if model.inspection.selectedRun == Just runId then
                                " selected"

                            else
                                ""
                           )
                    )
                , Events.onClick (SelectRun runId)
                ]
                [ div [ Attr.class "run-card-head" ]
                    [ span [ Attr.class ("run-status " ++ info.status), Attr.title info.status ] []
                    , span
                        [ Attr.class "run-card-title"
                        , Attr.title (Maybe.withDefault runId opening)
                        ]
                        [ text (Maybe.withDefault (shortId runId) (Maybe.map (clip 60) opening)) ]
                    , span [ Attr.class "run-card-time" ]
                        [ text (relativeTime model.now info.firstTime) ]
                    ]
                , div [ Attr.class "run-card-meta" ]
                    ([ text (shortId runId)
                     , text ("turns " ++ String.fromInt info.turns)
                     , text ("in " ++ String.fromInt info.usagePrompt)
                     , text ("out " ++ String.fromInt info.usageCompletion)
                     , text ("tools " ++ String.fromInt info.toolCalls)
                     ]
                        ++ verdictChip model runId
                    )
                , if List.isEmpty files then
                    text ""

                  else
                    div [ Attr.class "file-chips" ] (fileChips files)
                ]

        Nothing ->
            div [ Attr.class "run-card pending" ]
                [ div [ Attr.class "run-card-head" ]
                    [ span [ Attr.class "run-card-id", Attr.title runId ] [ text (shortId runId) ]
                    , span [ Attr.class "run-card-time" ] [ text "汇总中…" ]
                    ]
                ]


fileChips : List String -> List (Html Msg)
fileChips files =
    let
        rest =
            List.length files - 6
    in
    List.map (\path -> span [ Attr.class "file-chip", Attr.title path ] [ text path ]) (List.take 6 files)
        ++ (if rest > 0 then
                [ span [ Attr.class "file-chip" ] [ text ("+" ++ String.fromInt rest) ] ]

            else
                []
           )


runLogOf : Model -> String -> Maybe (List JournalRow)
runLogOf model runId =
    Dict.get runId model.inspection.runLogs
        |> Maybe.andThen remoteValue


firstUserMessage : List JournalRow -> Maybe String
firstUserMessage rows =
    rows
        |> List.filter (\row -> row.kind == "run.begin")
        |> List.head
        |> Maybe.andThen .input
        |> Maybe.andThen lastUserContent


lastUserContent : Decode.Value -> Maybe String
lastUserContent =
    Decode.decodeValue (Decode.field "messages" (Decode.list chatMessageDecoder))
        >> Result.toMaybe
        >> Maybe.andThen (List.filter (\message -> message.role == "user") >> List.reverse >> List.head)
        >> Maybe.map .content
        >> Maybe.andThen nonEmpty


chatMessageDecoder : Decoder { role : String, content : String }
chatMessageDecoder =
    Decode.map2 (\role content -> { role = role, content = content })
        (Decode.field "role" Decode.string)
        (Decode.oneOf [ Decode.field "content" Decode.string, Decode.succeed "" ])


touchedFiles : List JournalRow -> List String
touchedFiles =
    List.filterMap touchedPath >> unique


touchedPath : JournalRow -> Maybe String
touchedPath row =
    if row.kind == "tool.call" && List.member (Maybe.withDefault "" row.name) [ "fs_write", "fs_edit" ] then
        Maybe.andThen (argumentField "path") row.arguments

    else
        Nothing


unique : List comparable -> List comparable
unique =
    List.foldl (\item acc -> if List.member item acc then acc else acc ++ [ item ]) []


relativeTime : Maybe Time.Posix -> Maybe Int -> String
relativeTime now maybeEpoch =
    case ( now, maybeEpoch ) of
        ( Just moment, Just epoch ) ->
            ago epoch (Time.toSecond Time.utc moment - epoch)

        ( _, Just epoch ) ->
            epochLabel epoch

        _ ->
            "—"


ago : Int -> Int -> String
ago epoch diff =
    if diff < 10 then
        "刚刚"

    else if diff < 60 then
        String.fromInt diff ++ " 秒前"

    else if diff < 3600 then
        String.fromInt (diff // 60) ++ " 分钟前"

    else if diff < 86400 then
        String.fromInt (diff // 3600) ++ " 小时前"

    else if diff < 604800 then
        String.fromInt (diff // 86400) ++ " 天前"

    else
        epochLabel epoch


shortId : String -> String
shortId identifier =
    if String.length identifier > 22 then
        String.left 10 identifier ++ "…" ++ String.right 8 identifier

    else
        identifier


viewDrilldown : Model -> Html Msg
viewDrilldown model =
    case model.inspection.selectedRun of
        Nothing ->
            text ""

        Just runId ->
            div [ Attr.class "drilldown" ]
                [ div [ Attr.class "facet-tabs" ]
                    [ facetTab model FacetConversation "对话"
                    , facetTab model FacetEvents "事件"
                    , facetTab model FacetApi "API"
                    , facetTab model FacetMemory "决策"
                    , facetTab model FacetEntries "条目"
                    , button
                        [ Attr.class "ghost-button replay-trigger"
                        , Attr.type_ "button"
                        , Attr.disabled (model.inspection.replay == Loading)
                        , Events.onClick ReplaySelected
                        ]
                        [ text "回放" ]
                    ]
                , viewReplayReport model.inspection.replay
                , viewRemote (viewFacetRows model model.inspection.facet)
                    (Dict.get runId model.inspection.runLogs
                        |> Maybe.withDefault NotAsked
                    )
                ]


viewReplayReport : Remote ReplayReport -> Html Msg
viewReplayReport remote =
    case remote of
        NotAsked ->
            text ""

        Loading ->
            div [ Attr.class "replay-report" ] [ span [ Attr.class "section-note" ] [ text "回放中……正在以日志效应复演此 run" ] ]

        LoadFailed message ->
            div [ Attr.class "replay-report replay-gate" ]
                [ div [ Attr.class "replay-verdict" ] [ text "无法忠实回放" ]
                , div [ Attr.class "section-note" ] [ text message ]
                ]

        Loaded report ->
            case report.divergence of
                Nothing ->
                    div [ Attr.class "replay-report replay-good" ]
                        [ div [ Attr.class "replay-verdict" ]
                            [ text ("✓ 复现成功 · " ++ String.fromInt report.events ++ " events") ]
                        , div [ Attr.class "section-note" ]
                            [ text "新事件流与日志逐帧一致——此 run 的记录完备可信。" ]
                        ]

                Just divergence ->
                    div [ Attr.class "replay-report replay-bad" ]
                        [ div [ Attr.class "replay-verdict" ]
                            [ text ("✗ 复现分歧 · 第 " ++ String.fromInt divergence.at ++ " 帧") ]
                        , div [ Attr.class "section-note" ]
                            [ text "日志之外存在未记录的非确定性，或日志已被改动。" ]
                        , divergenceRow "期望" divergence.expected
                        , divergenceRow "实际" divergence.actual
                        , Maybe.map (\noteText -> div [ Attr.class "section-note" ] [ text noteText ]) divergence.note
                            |> Maybe.withDefault (text "")
                        ]


divergenceRow : String -> Maybe Decode.Value -> Html Msg
divergenceRow label value =
    case value of
        Nothing ->
            text ""

        Just raw ->
            pre [ Attr.class "tool-args" ] [ text (label ++ ": " ++ Encode.encode 2 raw) ]


facetTab : Model -> Facet -> String -> Html Msg
facetTab model facet label =
    button
        [ Attr.class
            ("facet-tab"
                ++ (if model.inspection.facet == facet then
                        " active"

                    else
                        ""
                   )
            )
        , Attr.type_ "button"
        , Events.onClick (SelectFacet facet)
        ]
        [ text label ]


viewFacetRows : Model -> Facet -> List JournalRow -> Html Msg
viewFacetRows model facet rows =
    case facet of
        FacetConversation ->
            viewConversation rows

        FacetEvents ->
            viewJournalEvents model (List.filter (\row -> row.kind == "agent.event") rows)

        FacetApi ->
            viewApiRows (List.filter (\row -> row.kind == "api.request") rows)

        FacetMemory ->
            viewWatcherCalls (List.filter (\row -> List.member "memory" row.scope) rows)

        FacetEntries ->
            viewEntryRows rows


viewJournalEvents : Model -> List JournalRow -> Html Msg
viewJournalEvents model rows =
    if List.isEmpty rows then
        note "无事件"

    else if model.inspection.showDeltas then
        div []
            ( eventStats model rows
                :: [ div [ Attr.class "event-list drilldown-list" ] (List.map viewJournalEvent rows) ]
            )

    else
        let
            ( deltas, structural ) =
                List.partition isDeltaRow rows

            groups =
                groupDeltas deltas
        in
        div []
            ( eventStats model rows
                :: [ div [ Attr.class "event-list drilldown-list" ]
                        (List.map viewEventRow (mergeBySeq structural groups))
                   ]
            )


eventStats : Model -> List JournalRow -> Html Msg
eventStats model rows =
    let
        deltaCount =
            List.length (List.filter isDeltaRow rows)

        label =
            "共 "
                ++ String.fromInt (List.length rows)
                ++ " 事件 · 结构 "
                ++ String.fromInt (List.length rows - deltaCount)
                ++ " · delta "
                ++ String.fromInt deltaCount
                ++ (if model.inspection.showDeltas then
                        "（已展开）"

                    else
                        "（已折叠）"
                   )
    in
    div [ Attr.class "event-stats" ]
        [ span [ Attr.class "section-note" ] [ text label ]
        , button
            [ Attr.class "ghost-button small"
            , Attr.type_ "button"
            , Events.onClick ToggleDeltas
            ]
            [ text
                (if model.inspection.showDeltas then
                    "折叠 delta"

                 else
                    "展开 delta"
                )
            ]
        ]


isDeltaRow : JournalRow -> Bool
isDeltaRow row =
    Maybe.map (\t -> List.member t deltaKinds) (Maybe.andThen (stringField "type") row.event)
        |> Maybe.withDefault False


deltaKinds : List String
deltaKinds =
    [ "TEXT_MESSAGE_CONTENT", "REASONING_MESSAGE_CONTENT", "TOOL_CALL_ARGS" ]


type alias DeltaGroup =
    { kind : String
    , identifier : String
    , count : Int
    , firstSeq : Int
    , preview : String
    }


groupDeltas : List JournalRow -> List DeltaGroup
groupDeltas rows =
    let
        step row acc =
            let
                key =
                    deltaKey row

                ( kind, identifier ) =
                    key
            in
            Dict.update key
                (\existing ->
                    Just
                        (case existing of
                            Nothing ->
                                DeltaGroup kind identifier 1 row.seq (deltaText row)

                            Just group ->
                                { group | count = group.count + 1, preview = group.preview ++ deltaText row }
                        )
                )
                acc
    in
    Dict.values (List.foldl step Dict.empty rows)


deltaKey : JournalRow -> ( String, String )
deltaKey row =
    let
        kind =
            Maybe.withDefault "?" (Maybe.andThen (stringField "type") row.event)

        identifier =
            [ "messageId", "toolCallId" ]
                |> List.filterMap (\field -> Maybe.andThen (stringField field) row.event)
                |> List.head
                |> Maybe.withDefault "?"
    in
    ( kind, identifier )


deltaText : JournalRow -> String
deltaText row =
    Maybe.withDefault "" (Maybe.andThen (stringField "delta") row.event)


type EventRow
    = StructuralRow JournalRow
    | GroupRow DeltaGroup


mergeBySeq : List JournalRow -> List DeltaGroup -> List EventRow
mergeBySeq structural groups =
    List.sortBy rowSeq
        (List.map StructuralRow structural ++ List.map GroupRow groups)


rowSeq : EventRow -> Int
rowSeq eventRow =
    case eventRow of
        StructuralRow row ->
            row.seq

        GroupRow group ->
            group.firstSeq


viewEventRow : EventRow -> Html Msg
viewEventRow eventRow =
    case eventRow of
        StructuralRow row ->
            viewJournalEvent row

        GroupRow group ->
            div [ Attr.class "event delta-group" ]
                [ span [ Attr.class "event-index" ] [ text ("#" ++ String.fromInt group.firstSeq) ]
                , span [ Attr.class "event-kind", Attr.title group.kind ] [ text (group.kind ++ " ×" ++ String.fromInt group.count) ]
                , span [ Attr.class "event-summary", Attr.title group.preview ] [ text (compact (group.identifier ++ " " ++ group.preview)) ]
                ]


viewJournalEvent : JournalRow -> Html Msg
viewJournalEvent row =
    let
        kind =
            Maybe.withDefault "?" (Maybe.andThen (stringField "type") row.event)

        summary =
            Maybe.withDefault "" (journalEventSummary row.event)
    in
    div [ Attr.class "event" ]
        [ span [ Attr.class "event-index" ] [ text ("#" ++ String.fromInt row.seq) ]
        , span [ Attr.class "event-kind", Attr.title kind ] [ text kind ]
        , span [ Attr.class "event-summary", Attr.title summary ] [ text summary ]
        ]


journalEventSummary : Maybe Decode.Value -> Maybe String
journalEventSummary value =
    [ "runId", "messageId", "toolCallName", "toolCallId", "stepName", "name", "message", "delta", "content" ]
        |> List.filterMap (\field -> Maybe.andThen (stringField field) value)
        |> List.head
        |> Maybe.map compact


stringField : String -> Decode.Value -> Maybe String
stringField field =
    Decode.decodeValue (Decode.field field Decode.string) >> Result.toMaybe


viewApiRows : List JournalRow -> Html Msg
viewApiRows rows =
    if List.isEmpty rows then
        note "无 API 请求"

    else
        div [] (List.map viewApiRow rows)


viewApiRow : JournalRow -> Html Msg
viewApiRow row =
    details [ Attr.class "api-card" ]
        [ summary [] [ text ("#" ++ String.fromInt row.seq ++ " " ++ apiLabel row.request) ]
        , pre [ Attr.class "tool-args" ]
            [ text (Maybe.withDefault "" (Maybe.map (Encode.encode 2) row.request)) ]
        ]


apiLabel : Maybe Decode.Value -> String
apiLabel request =
    Maybe.withDefault "api.request" (Maybe.andThen (stringField "model") request)


viewEntryRows : List JournalRow -> Html Msg
viewEntryRows rows =
    if List.isEmpty rows then
        note "无条目"

    else
        div [ Attr.class "entry-table" ] (List.map viewEntryRow rows)


viewEntryRow : JournalRow -> Html Msg
viewEntryRow row =
    div [ Attr.class "data-row entry-row" ]
        [ span [ Attr.class "cell quiet" ] [ text (String.fromInt row.seq) ]
        , span [ Attr.class "cell", Attr.title (String.join " › " row.scope) ] [ text (String.join " › " row.scope) ]
        , span [ Attr.class "cell quiet" ] [ text row.kind ]
        ]


type alias Conversation =
    { order : List String
    , blocks : Dict String ConvBlock
    }


type ConvBlock
    = CUser String
    | CAssistant String
    | CReasoning String
    | CTool ToolBlock
    | CMemory String
    | CRunError String
    | CNotice String
    | CSub SubBlock


type alias ToolBlock =
    { name : String
    , args : String
    , result : Maybe String
    , output : String
    }


type alias SubBlock =
    { callId : String
    , content : String
    , failed : Bool
    , error : Maybe String
    , status : String
    , activity : List String
    , context : Maybe ContextGauge
    }


buildConversation : List JournalRow -> Conversation
buildConversation rows =
    let
        seed =
            firstUserMessage rows
                |> Maybe.map (\content -> Conversation [ "user" ] (Dict.singleton "user" (CUser content)))
                |> Maybe.withDefault (Conversation [] Dict.empty)
    in
    List.foldl applyEventRow seed (List.filter (\row -> row.kind == "agent.event") rows)


applyEventRow : JournalRow -> Conversation -> Conversation
applyEventRow row conversation =
    let
        field name =
            Maybe.andThen (stringField name) row.event

        keyed prefix key block =
            Maybe.map (\id -> openBlock (prefix ++ id) block conversation) key
                |> Maybe.withDefault conversation
    in
    case field "type" of
        Just "TEXT_MESSAGE_START" ->
            keyed "text/" (field "messageId") (CAssistant "")

        Just "TEXT_MESSAGE_CONTENT" ->
            Maybe.map2 (\id delta -> appendText ("text/" ++ id) delta conversation)
                (field "messageId")
                (field "delta")
                |> Maybe.withDefault conversation

        Just "REASONING_START" ->
            keyed "reasoning/" (field "messageId") (CReasoning "")

        Just "REASONING_MESSAGE_START" ->
            keyed "reasoning/" (field "messageId") (CReasoning "")

        Just "REASONING_MESSAGE_CONTENT" ->
            Maybe.map2 (\id delta -> appendText ("reasoning/" ++ id) delta conversation)
                (field "messageId")
                (field "delta")
                |> Maybe.withDefault conversation

        Just "TOOL_CALL_START" ->
            Maybe.map2
                (\id name -> openBlock ("tool/" ++ id) (CTool (ToolBlock name "" Nothing "")) conversation)
                (field "toolCallId")
                (field "toolCallName")
                |> Maybe.withDefault conversation

        Just "TOOL_CALL_ARGS" ->
            Maybe.map2 (\id delta -> appendArgs ("tool/" ++ id) delta conversation)
                (field "toolCallId")
                (field "delta")
                |> Maybe.withDefault conversation

        Just "TOOL_CALL_RESULT" ->
            Maybe.map2 (\id content -> setResult ("tool/" ++ id) content conversation)
                (field "toolCallId")
                (field "content")
                |> Maybe.withDefault conversation

        Just "CUSTOM" ->
            row.event
                |> Maybe.andThen (Decode.decodeValue (eventDecoder "CUSTOM") >> Result.toMaybe)
                |> Maybe.map (\event -> applyCustomEvent row.seq event conversation)
                |> Maybe.withDefault conversation

        Just "RUN_ERROR" ->
            Maybe.map (\message -> openBlock ("error/" ++ String.fromInt row.seq) (CRunError message) conversation)
                (field "message")
                |> Maybe.withDefault conversation

        _ ->
            conversation


openBlock : String -> ConvBlock -> Conversation -> Conversation
openBlock key block conversation =
    if Dict.member key conversation.blocks then
        conversation

    else
        { conversation
            | order = conversation.order ++ [ key ]
            , blocks = Dict.insert key block conversation.blocks
        }


applyCustomEvent : Int -> AgentEvent -> Conversation -> Conversation
applyCustomEvent seq event conversation =
    case event of
        ContextInject content ->
            openBlock ("memory/" ++ String.fromInt seq) (CMemory content) conversation

        ShellOutput callId _ delta ->
            appendOutput ("tool/" ++ callId) delta conversation

        ProviderRetry attempt maxAttempts delayMs reason ->
            openBlock ("notice/" ++ String.fromInt seq) (CNotice (retryNotice attempt maxAttempts delayMs reason)) conversation

        ContextSplice stubbed savedChars keep ->
            openBlock ("notice/" ++ String.fromInt seq) (CNotice (spliceNotice stubbed savedChars keep)) conversation

        ContextCompact step before after budget dropped emergency ->
            openBlock ("notice/" ++ String.fromInt seq) (CNotice (compactNotice step before after budget dropped emergency)) conversation

        SteeringInject step count ->
            openBlock ("notice/" ++ String.fromInt seq) (CNotice (steeringNotice step count)) conversation

        FollowUpInject step count ->
            openBlock ("notice/" ++ String.fromInt seq) (CNotice (followUpNotice step count)) conversation

        RunCancelled _ ->
            openBlock ("notice/" ++ String.fromInt seq) (CNotice "run cancelled") conversation

        AgentSub _ callId nested ->
            let
                key =
                    "sub/" ++ callId

                ensured =
                    openBlock key
                        (CSub
                            (SubBlock callId "" False Nothing "等待启动" [] Nothing)
                        )
                        conversation
            in
            case classifySubEvent nested of
                SubDelta delta ->
                    mapSubBlock key (\sub -> { sub | content = sub.content ++ delta, status = "正在回复" }) ensured

                SubFailed message ->
                    mapSubBlock key (\sub -> { sub | failed = True, error = Just message, status = "失败" }) ensured

                SubStatus status ->
                    mapSubBlock key (\sub -> { sub | status = status }) ensured

                SubActivity activity ->
                    mapSubBlock key (\sub -> { sub | activity = pushActivity activity sub.activity }) ensured

                SubContext gauge ->
                    mapSubBlock key (\sub -> { sub | context = Just gauge }) ensured

                SubCompacted step before after budget dropped emergency ->
                    mapSubBlock key
                        (\sub ->
                            { sub
                                | activity = pushActivity (compactNotice step before after budget dropped emergency) sub.activity
                                , context = Just (ContextGauge after budget False emergency Nothing Nothing Nothing)
                            }
                        )
                        ensured

                SubIgnored ->
                    conversation

        _ ->
            conversation


appendOutput : String -> String -> Conversation -> Conversation
appendOutput key delta =
    mapBlock key
        (\block ->
            case block of
                CTool tool ->
                    CTool { tool | output = capTail 4000 (tool.output ++ delta) }

                other ->
                    other
        )


mapSubBlock : String -> (SubBlock -> SubBlock) -> Conversation -> Conversation
mapSubBlock key transform =
    mapBlock key
        (\block ->
            case block of
                CSub sub ->
                    CSub (transform sub)

                other ->
                    other
        )


mapBlock : String -> (ConvBlock -> ConvBlock) -> Conversation -> Conversation
mapBlock key transform conversation =
    { conversation | blocks = Dict.update key (Maybe.map transform) conversation.blocks }


appendText : String -> String -> Conversation -> Conversation
appendText key delta =
    mapBlock key
        (\block ->
            case block of
                CAssistant content ->
                    CAssistant (content ++ delta)

                CReasoning content ->
                    CReasoning (content ++ delta)

                other ->
                    other
        )


appendArgs : String -> String -> Conversation -> Conversation
appendArgs key delta =
    mapBlock key
        (\block ->
            case block of
                CTool tool ->
                    CTool { tool | args = tool.args ++ delta }

                other ->
                    other
        )


setResult : String -> String -> Conversation -> Conversation
setResult key content =
    mapBlock key
        (\block ->
            case block of
                CTool tool ->
                    CTool { tool | result = Just content }

                other ->
                    other
        )


viewConversation : List JournalRow -> Html Msg
viewConversation rows =
    let
        conversation =
            buildConversation rows
    in
    if List.isEmpty conversation.order then
        note "无对话内容"

    else
        div [ Attr.class "conv" ]
            (List.filterMap
                (\key -> Maybe.map viewConvBlock (Dict.get key conversation.blocks))
                conversation.order
            )


viewConvBlock : ConvBlock -> Html Msg
viewConvBlock block =
    case block of
        CUser content ->
            div [ Attr.class "message-row user" ]
                [ div [ Attr.class "message" ]
                    [ p [ Attr.class "message-copy" ] [ text content ] ]
                ]

        CAssistant content ->
            if String.isEmpty (String.trim content) then
                text ""

            else
                div [ Attr.class "message-row assistant" ]
                    [ div [ Attr.class "message" ]
                        [ p [ Attr.class "message-label" ] [ text "YUKI.N" ]
                        , div [ Attr.class "message-copy markdown" ] [ Markdown.toHtml [] content ]
                        ]
                    ]

        CReasoning content ->
            if String.isEmpty content then
                text ""

            else
                details [ Attr.class "reasoning" ]
                    [ summary [] [ text "推理轨迹" ]
                    , pre [ Attr.class "reasoning-copy" ] [ text content ]
                    ]

        CTool tool ->
            viewConvTool tool

        CMemory content ->
            details [ Attr.class "memory-card legacy-context" ]
                [ summary [] [ text "运行上下文 · 来源可审计" ]
                , pre [ Attr.class "memory-copy" ] [ text content ]
                ]

        CRunError message ->
            div [ Attr.class "error-banner" ] [ text message ]

        CNotice content ->
            div [ Attr.class "conv-notice" ] [ text content ]

        CSub sub ->
            viewConvSub sub


viewConvTool : ToolBlock -> Html Msg
viewConvTool tool =
    let
        target =
            toolTarget tool.name tool.args

        brief =
            tool.result
                |> Maybe.map compact
                |> Maybe.withDefault ""
    in
    details
        [ Attr.classList
            [ ( "tool-line", True )
            , ( "conv-tool", True )
            , ( "working", tool.result == Nothing )
            , ( "done", tool.result /= Nothing )
            ]
        ]
        [ summary [ Attr.class "tool-summary" ]
            [ span [ Attr.class "tool-mark", Attr.attribute "aria-hidden" "true" ] []
            , span [ Attr.class "tool-action" ] [ text (toolActionLabel tool.name) ]
            , if String.isEmpty target then
                text ""

              else
                span [ Attr.class "tool-target", Attr.title target ] [ text target ]
            , if String.isEmpty brief then
                text ""

              else
                span [ Attr.class "tool-result-brief", Attr.title brief ] [ text ("· " ++ brief) ]
            , span [ Attr.class "tool-stage" ]
                [ text <|
                    if tool.result == Nothing then
                        "运行中"

                    else
                        "已返回"
                ]
            ]
        , div [ Attr.class "tool-body" ]
            (pre [ Attr.class "tool-args" ] [ text (prettyJson tool.args) ]
                :: convOutputBlocks tool
                ++ (tool.result
                        |> Maybe.map
                            (\content ->
                                [ details [ Attr.class "tool-output tool-result-body" ]
                                    [ summary [] [ text "结果" ]
                                    , viewConvResult content
                                    ]
                                ]
                            )
                        |> Maybe.withDefault []
                   )
            )
        ]


convOutputBlocks : ToolBlock -> List (Html Msg)
convOutputBlocks tool =
    if String.isEmpty tool.output then
        []

    else
        case tool.result of
            Just _ ->
                [ details [ Attr.class "tool-output" ]
                    [ summary [] [ text "shell 输出" ]
                    , pre [ Attr.class "tool-args" ] [ text tool.output ]
                    ]
                ]

            Nothing ->
                [ pre [ Attr.class "tool-args" ] [ text tool.output ] ]


subTitle : { a | failed : Bool, status : String } -> String
subTitle sub =
    "子代理 · "
        ++ (if sub.failed then
                "失败"

            else
                sub.status
           )


viewSubCard : { a | content : String, failed : Bool, error : Maybe String, status : String, activity : List String, context : Maybe ContextGauge } -> Html Msg
viewSubCard sub =
    details
        ([ Attr.classList [ ( "sub-card", True ), ( "failed", sub.failed ) ] ]
            ++ (if sub.failed || sub.status == "运行中" then
                    [ Attr.attribute "open" "" ]

                else
                    []
               )
        )
        (summary [] [ text (subTitle sub) ]
            :: viewSubBody sub
        )


viewSubBody : { a | content : String, error : Maybe String, activity : List String, context : Maybe ContextGauge } -> List (Html msg)
viewSubBody sub =
    (sub.context
        |> Maybe.map (\gauge -> [ viewContextGauge (Just gauge) ])
        |> Maybe.withDefault []
    )
        ++ (if List.isEmpty sub.activity then
                []

            else
                [ div [ Attr.class "sub-activity" ]
                    (List.map (\item -> p [] [ text item ]) (List.reverse sub.activity))
                ]
           )
        ++ (sub.error
                |> Maybe.map (\message -> [ p [ Attr.class "section-note error" ] [ text message ] ])
                |> Maybe.withDefault []
           )
        ++ (if String.isEmpty (String.trim sub.content) then
                []

            else
                [ div [ Attr.class "memory-copy markdown" ] [ Markdown.toHtml [] sub.content ] ]
           )


viewConvSub : SubBlock -> Html Msg
viewConvSub sub =
    viewSubCard sub


viewConvResult : String -> Html Msg
viewConvResult content =
    if isDiff content then
        div [ Attr.class "diff-view conv-diff" ] (List.map viewDiffLine (String.lines content))

    else
        pre [ Attr.class "tool-args" ] [ text content ]


type alias WatcherCall =
    { seq : Int
    , prompt : String
    , output : String
    , closed : Bool
    }


watcherCalls : List JournalRow -> List WatcherCall
watcherCalls =
    List.foldl watcherStep ( [], Nothing )
        >> (\( done, current ) -> done ++ maybeList current)


maybeList : Maybe a -> List a
maybeList =
    Maybe.map List.singleton >> Maybe.withDefault []


watcherStep : JournalRow -> ( List WatcherCall, Maybe WatcherCall ) -> ( List WatcherCall, Maybe WatcherCall )
watcherStep row ( done, current ) =
    case row.kind of
        "model.request" ->
            ( done ++ maybeList current
            , Just (WatcherCall row.seq (watcherPromptOf row) "" False)
            )

        "model.event" ->
            ( done, Maybe.map (\call -> { call | output = call.output ++ modelDelta row }) current )

        "model.finish" ->
            ( done, Maybe.map (\call -> { call | closed = True }) current )

        _ ->
            ( done, current )


modelDelta : JournalRow -> String
modelDelta row =
    row.event
        |> Maybe.andThen (Decode.decodeValue (Decode.field "contents" Decode.string) >> Result.toMaybe)
        |> Maybe.withDefault ""


watcherPromptOf : JournalRow -> String
watcherPromptOf row =
    row.request
        |> Maybe.andThen (Decode.decodeValue (Decode.field "messages" (Decode.list taggedContentDecoder)) >> Result.toMaybe)
        |> Maybe.andThen (List.filter (\message -> message.tag == "ChatUser") >> List.reverse >> List.head)
        |> Maybe.map .contents
        |> Maybe.withDefault "（无法读取 watcher 输入）"


taggedContentDecoder : Decoder { tag : String, contents : String }
taggedContentDecoder =
    Decode.map2 (\tag contents -> { tag = tag, contents = contents })
        (Decode.field "tag" Decode.string)
        (Decode.oneOf [ Decode.field "contents" Decode.string, Decode.succeed "" ])


type alias WatcherDecision =
    { summary : Maybe String
    , memorize : List Memorandum
    , retrieve : Maybe Retrieval
    , invalidate : List Invalidation
    }


type alias Memorandum =
    { content : String
    , kind : String
    , reason : String
    }


type alias Retrieval =
    { query : String
    , reason : String
    }


type alias Invalidation =
    { content : String
    , reason : String
    }


decisionDecoder : Decoder WatcherDecision
decisionDecoder =
    Decode.map4 WatcherDecision
        (Decode.maybe (Decode.field "summary" Decode.string))
        (Decode.maybe (Decode.field "memorize" (Decode.list memorandumDecoder)) |> Decode.map (Maybe.withDefault []))
        (Decode.maybe (Decode.field "retrieve" (Decode.nullable retrievalDecoder)) |> Decode.map (Maybe.withDefault Nothing))
        (Decode.maybe (Decode.field "invalidate" (Decode.list invalidationDecoder)) |> Decode.map (Maybe.withDefault []))


memorandumDecoder : Decoder Memorandum
memorandumDecoder =
    Decode.map3 Memorandum
        (Decode.field "content" Decode.string)
        (Decode.maybe (Decode.field "kind" Decode.string) |> Decode.map (Maybe.withDefault "fact"))
        (Decode.maybe (Decode.field "reason" Decode.string) |> Decode.map (Maybe.withDefault ""))


retrievalDecoder : Decoder Retrieval
retrievalDecoder =
    Decode.map2 Retrieval
        (Decode.field "query" Decode.string)
        (Decode.maybe (Decode.field "reason" Decode.string) |> Decode.map (Maybe.withDefault ""))


invalidationDecoder : Decoder Invalidation
invalidationDecoder =
    Decode.map2 Invalidation
        (Decode.field "content" Decode.string)
        (Decode.maybe (Decode.field "reason" Decode.string) |> Decode.map (Maybe.withDefault ""))


viewWatcherCalls : List JournalRow -> Html Msg
viewWatcherCalls rows =
    case watcherCalls rows of
        [] ->
            note "无 watcher 调用"

        calls ->
            div [] (List.map viewWatcherCall calls)


viewWatcherCall : WatcherCall -> Html Msg
viewWatcherCall call =
    div [ Attr.class "watcher-call" ]
        [ div [ Attr.class "watcher-head" ] [ text ("watcher · #" ++ String.fromInt call.seq) ]
        , details [ Attr.class "watcher-block" ]
            [ summary [] [ text "watcher 看到了什么" ]
            , pre [ Attr.class "tool-args" ] [ text call.prompt ]
            ]
        , div [ Attr.class "watcher-block" ]
            [ div [ Attr.class "watcher-label" ] [ text "决定了什么" ]
            , viewDecision call
            ]
        ]


viewDecision : WatcherCall -> Html Msg
viewDecision call =
    case Decode.decodeString decisionDecoder call.output of
        Ok decision ->
            if decisionEmpty decision then
                note "（无决定）"

            else
                div [ Attr.class "decision" ]
                    (List.filterMap identity
                        [ Maybe.map (\content -> p [ Attr.class "decision-summary" ] [ text content ]) decision.summary
                        , Maybe.map (\r -> decisionLine "检索" (r.query ++ reasonSuffix r.reason)) decision.retrieve
                        ]
                        ++ List.map (\m -> decisionLine ("记住·" ++ m.kind) (m.content ++ reasonSuffix m.reason)) decision.memorize
                        ++ List.map (\i -> decisionLine "作废" (i.content ++ reasonSuffix i.reason)) decision.invalidate
                    )

        Err _ ->
            if String.isEmpty (String.trim call.output) then
                note "（无输出）"

            else
                pre [ Attr.class "tool-args" ] [ text call.output ]


decisionEmpty : WatcherDecision -> Bool
decisionEmpty decision =
    decision.summary == Nothing && decision.retrieve == Nothing && List.isEmpty decision.memorize && List.isEmpty decision.invalidate


decisionLine : String -> String -> Html Msg
decisionLine label content =
    div [ Attr.class "decision-line" ]
        [ span [ Attr.class "decision-label" ] [ text label ]
        , span [ Attr.class "decision-content" ] [ text content ]
        ]


reasonSuffix : String -> String
reasonSuffix reason =
    if String.isEmpty reason then
        ""

    else
        " — " ++ reason


meta : String -> String -> Html Msg
meta label value =
    div [ Attr.class "meta-line" ]
        [ span [ Attr.class "meta-label" ] [ text label ]
        , span [ Attr.class "meta-value", Attr.title value ] [ text value ]
        ]


viewMemorySection : Model -> Html Msg
viewMemorySection model =
    div [ Attr.class "inspector-section" ]
        [ h2 [ Attr.class "section-title" ]
            [ text "记忆"
            , refreshButton RefreshMemory
            ]
        , viewRemote viewBrief model.inspection.brief
        , viewRemote viewFacts model.inspection.facts
        ]


viewArtifactsSection : Model -> Html Msg
viewArtifactsSection model =
    div [ Attr.class "inspector-section" ]
        [ h2 [ Attr.class "section-title" ]
            [ text "工件"
            , refreshButton RefreshArtifacts
            ]
        , viewRemote (viewArtifacts model) model.inspection.artifacts
        ]


refreshButton : Msg -> Html Msg
refreshButton msg =
    button
        [ Attr.class "ghost-button small"
        , Attr.type_ "button"
        , Events.onClick msg
        ]
        [ text "刷新" ]


viewRemote : (a -> Html Msg) -> Remote a -> Html Msg
viewRemote render remote =
    case remote of
        NotAsked ->
            note "尚未拉取"

        Loading ->
            note "拉取中…"

        LoadFailed message ->
            errorNote message

        Loaded value ->
            render value


note : String -> Html Msg
note message =
    p [ Attr.class "section-note" ] [ text message ]


errorNote : String -> Html Msg
errorNote message =
    p [ Attr.class "section-note error" ] [ text message ]


viewBrief : Brief -> Html Msg
viewBrief brief =
    div []
        [ if String.isEmpty brief.rollingSummary && List.isEmpty brief.episodes then
            note "此 thread 尚无记忆摘要"

          else if String.isEmpty brief.rollingSummary then
            note "（无滚动摘要）"

          else
            p [ Attr.class "tool-detail" ] [ text brief.rollingSummary ]
        , div [] (List.map viewEpisode brief.episodes)
        ]


viewEpisode : Episode -> Html Msg
viewEpisode episode =
    div [ Attr.class "data-row" ]
        [ span [ Attr.class "cell quiet" ] [ text (epochLabel episode.time) ]
        , span
            [ Attr.class "cell"
            , Attr.title (episode.runId ++ " · " ++ episode.summary)
            ]
            [ text episode.summary ]
        ]


viewFacts : List Fact -> Html Msg
viewFacts facts =
    if List.isEmpty facts then
        note "无事实"

    else
        div [] (List.map viewFact facts)


viewFact : Fact -> Html Msg
viewFact fact =
    div
        [ Attr.class <|
            "data-row"
                ++ (if fact.archived || fact.void then
                        " faded"

                    else
                        ""
                   )
        ]
        [ span [ Attr.class "cell quiet" ] [ text fact.kind ]
        , span [ Attr.class "cell", Attr.title fact.content ] [ text fact.content ]
        , span [ Attr.class "cell quiet" ] [ text ("×" ++ String.fromInt fact.useCount) ]
        ]


viewArtifacts : Model -> List ArtifactMeta -> Html Msg
viewArtifacts model artifacts =
    if List.isEmpty artifacts then
        note "无工件"

    else
        div []
            [ p [ Attr.class "section-note" ]
                [ text
                    ("共 "
                        ++ String.fromInt (List.length artifacts)
                        ++ " 条本机保留内容；按来源与摘要展示，内部 ID 默认隐藏。"
                    )
                ]
            , div [] (List.concatMap (viewArtifact model) artifacts)
            ]


viewArtifact : Model -> ArtifactMeta -> List (Html Msg)
viewArtifact model artifact =
    let
        body =
            Dict.get artifact.id model.inspection.artifactBodies

        row =
            div
                [ Attr.class <|
                    "data-row clickable"
                        ++ (if body /= Nothing then
                                " selected"

                            else
                                ""
                           )
                , Attr.title ("展开查看 · " ++ artifactLabel artifact.toolName)
                , Events.onClick (ToggleArtifact artifact.id)
                ]
                [ span [ Attr.class "cell quiet" ] [ text (epochLabel artifact.time) ]
                , span [ Attr.class "cell artifact-summary" ]
                    [ span [ Attr.class "artifact-label" ] [ text (artifactLabel artifact.toolName) ]
                    , span [ Attr.class "artifact-preview" ] [ text (orDash artifact.preview) ]
                    ]
                , span [ Attr.class "cell quiet" ] [ text (String.fromInt artifact.chars ++ "c") ]
                ]
    in
    row
        :: (case body of
                Nothing ->
                    []

                Just (Loaded content) ->
                    [ div [ Attr.class "artifact-detail" ]
                        [ p [ Attr.class "field-inherit-hint" ]
                            [ text ("内部标识：" ++ artifact.id ++ " · 来源：" ++ artifact.toolName) ]
                        , pre [ Attr.class "tool-args" ] [ text content ]
                        ]
                    ]

                Just Loading ->
                    [ note "拉取中…" ]

                Just (LoadFailed message) ->
                    [ errorNote message ]

                Just NotAsked ->
                    []
           )


artifactLabel : String -> String
artifactLabel toolName =
    case toolName of
        "context_compaction" ->
            "上下文压缩快照"

        "fs_read" ->
            "文件读取原文"

        "fs_write" ->
            "文件写入版本"

        "fs_edit" ->
            "文件编辑版本"

        "shell" ->
            "命令输出"

        "sub_agent" ->
            "子代理输出"

        other ->
            other


phaseLabel : Model -> String
phaseLabel model =
    case model.phase of
        Idle ->
            "就绪"

        Connecting ->
            "连接中"

        Streaming ->
            Maybe.map (\step -> "运行 · " ++ step) model.activeStep
                |> Maybe.withDefault "流式响应"

        AwaitingTool ->
            "等待确认"

        Canceled ->
            "已中止"

        Failed ->
            "异常"


phaseClass : Phase -> String
phaseClass phase =
    case phase of
        Connecting ->
            "busy"

        Streaming ->
            "busy"

        AwaitingTool ->
            "attention"

        Failed ->
            "failed"

        _ ->
            ""


isBusy : Phase -> Bool
isBusy phase =
    phase == Connecting || phase == Streaming


hasPendingFrontendTool : Model -> Bool
hasPendingFrontendTool model =
    model.tools
        |> Dict.values
        |> List.any
            (\tool ->
                tool.name == confirmationToolName && tool.stage == ToolWaiting
            )


orderedMessages : Model -> List ChatMessage
orderedMessages model =
    List.filterMap (\identifier -> Dict.get identifier model.messages) model.messageOrder


toolStageLabel : ToolStage -> String
toolStageLabel stage =
    case stage of
        ToolStreaming ->
            "参数生成中"

        ToolWaiting ->
            "等待处理"

        ToolResolved ToolApproved ->
            "已允许"

        ToolResolved ToolRejected ->
            "已拒绝"

        ToolResolved ToolReturned ->
            "已返回"

        ToolResolved ToolInterrupted ->
            "未完成"


argumentField : String -> String -> Maybe String
argumentField field source =
    Decode.decodeString (Decode.field field Decode.string) source
        |> Result.toMaybe


prettyJson : String -> String
prettyJson source =
    Decode.decodeString Decode.value source
        |> Result.map (Encode.encode 2)
        |> Result.withDefault source


compact : String -> String
compact =
    clip 72


clip : Int -> String -> String
clip limit value =
    let
        singleLine =
            value
                |> String.lines
                |> String.join " "
                |> String.trim
    in
    if String.length singleLine > limit then
        String.left limit singleLine ++ "…"

    else
        singleLine


epochLabel : Int -> String
epochLabel seconds =
    let
        moment =
            Time.millisToPosix (seconds * 1000)

        pad value =
            String.padLeft 2 '0' (String.fromInt value)
    in
    String.fromInt (Time.toYear Time.utc moment)
        ++ "-"
        ++ pad (monthNumber (Time.toMonth Time.utc moment))
        ++ "-"
        ++ pad (Time.toDay Time.utc moment)
        ++ " "
        ++ pad (Time.toHour Time.utc moment)
        ++ ":"
        ++ pad (Time.toMinute Time.utc moment)


monthNumber : Time.Month -> Int
monthNumber month =
    case month of
        Time.Jan -> 1
        Time.Feb -> 2
        Time.Mar -> 3
        Time.Apr -> 4
        Time.May -> 5
        Time.Jun -> 6
        Time.Jul -> 7
        Time.Aug -> 8
        Time.Sep -> 9
        Time.Oct -> 10
        Time.Nov -> 11
        Time.Dec -> 12
