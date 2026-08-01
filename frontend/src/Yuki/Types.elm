module Yuki.Types exposing (..)

import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Encode as Encode


type alias Flags =
    { endpoint : String
    , threadId : String
    , incarnationId : String
    , runStamp : String
    }


type Page
    = Conversation
    | Tasks
    | Memory
    | Capabilities
    | Self
    | Audit


type Phase
    = Idle
    | Connecting
    | Streaming
    | AwaitingTool
    | Canceled
    | Failed


type Remote a
    = Loading
    | Ready a
    | Unavailable String


type alias Model =
    { endpoint : String
    , threadId : String
    , incarnationId : String
    , incarnation : Incarnation
    , incarnations : Remote (List Incarnation)
    , selfNameDraft : String
    , selfDirectionDraft : String
    , selfImpressionModelDraft : String
    , selfSaving : Bool
    , selfError : Maybe String
    , archiveYukiConfirm : Bool
    , deleteYukiConfirm : Maybe ( String, Int )
    , yukiForm : Maybe YukiDraft
    , showArchivedYukis : Bool
    , prompts : Remote (List PromptRevision)
    , rootPrompts : Remote (List PromptRevision)
    , promptEditor : Maybe PromptEditor
    , generatingPrompt : Bool
    , activatingPrompt : Maybe String
    , promptMessage : Maybe String
    , runStamp : String
    , page : Page
    , memoryPinned : Bool
    , tasksOpen : Bool
    , draft : String
    , pathSuggestions : List String
    , messages : Dict String Message
    , messageOrder : List String
    , tools : Dict String ToolCall
    , transcriptLoading : Bool
    , phase : Phase
    , activeRun : Maybe String
    , nextId : Int
    , error : Maybe String
    , activeStep : Maybe String
    , following : Bool
    , sessions : Remote (List SessionMeta)
    , taskReady : Bool
    , taskTitle : String
    , taskTitleDraft : String
    , taskFormOpen : Bool
    , taskFormTitle : String
    , showArchivedTasks : Bool
    , forkNodeDraft : String
    , taskActionError : Maybe String
    , impression : Remote ImpressionState
    , memorySection : MemorySection
    , impressionActivations : Remote (List Decode.Value)
    , impressionRevisions : Remote (List Decode.Value)
    , memoryQuery : String
    , memorySearch : Remote MemorySearch
    , memoryDraft : String
    , memoryKind : String
    , memoryVisibility : String
    , selectedMemory : Maybe ( String, Int )
    , memoryDetail : Remote Decode.Value
    , memoryReceipts : Remote (List Decode.Value)
    , experiences : Remote (List Decode.Value)
    , memoryActionError : Maybe String
    , taskArchives : Remote (List TaskArchiveSummary)
    , taskRecordQuery : String
    , taskRecordTask : Maybe String
    , taskRecordCaseSensitive : Bool
    , taskRecordSearch : Remote TaskRecordSearch
    , selectedTaskRecord : Maybe TaskRecordHit
    , taskRecordReader : Remote TaskRecordContext
    , workingMemory : Remote Decode.Value
    , sleepCycles : Remote (List Decode.Value)
    , sleeping : Bool
    , sleepMessage : Maybe String
    , capabilities : Remote (List String)
    , taskConfig : Remote TaskConfig
    , globalConfig : Remote Decode.Value
    , configDraft : ConfigDraft
    , providers : Remote (List ProviderEntry)
    , contextPolicy : Remote ContextPolicy
    , configSaving : Bool
    , configError : Maybe String
    , tree : Remote (Maybe (List String))
    , auditRuns : Remote (List String)
    , runSummaries : Dict String (Remote RunSummary)
    , runTraces : Dict String (Remote RunTrace)
    , runLogs : Dict String (Remote (List JournalRow))
    , replayReports : Dict String (Remote Decode.Value)
    , selectedRun : Maybe String
    , auditFacet : AuditFacet
    , auditFilter : String
    , artifacts : Remote (List ArtifactMeta)
    , artifactBodies : Dict String (Remote String)
    , usage : Maybe Usage
    , contextGauge : Maybe ContextGauge
    , notice : Maybe String
    }


type Message
    = UserMessage String String
    | SummaryMessage String String
    | ReasoningMessage Reasoning
    | AssistantMessage Assistant
    | ToolCallMessage String
    | ToolMessage ToolResult
    | SubAgentMessage SubAgent
    | NoticeMessage String String


type alias Reasoning =
    { id : String
    , content : String
    , chunks : List String
    , complete : Bool
    }


type alias Assistant =
    { id : String
    , content : String
    , chunks : List String
    , toolCalls : List String
    , complete : Bool
    }


type alias ToolResult =
    { id : String
    , callId : String
    , content : String
    }


type alias SubAgent =
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


type alias SessionMeta =
    { id : String
    , title : String
    , created : Int
    , updated : Int
    , archived : Bool
    , parent : Maybe String
    , forkNode : Maybe String
    }


type alias Incarnation =
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


type alias YukiDraft =
    { identifier : String
    , name : String
    , direction : String
    , impressionModel : String
    , saving : Bool
    , error : Maybe String
    }


type alias PromptRevision =
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


type alias ImpressionState =
    { revision : Int
    , items : List ImpressionItem
    , updated : Int
    }


type alias ImpressionItem =
    { id : String
    , label : String
    , intuition : String
    , strength : Float
    , sources : List String
    }


type alias MemorySearch =
    { snippets : List MemorySnippet
    , query : String
    }


type alias MemorySnippet =
    { id : String
    , revision : Int
    , kind : String
    , snippet : String
    , sources : List String
    }


type MemorySection
    = Impressions
    | LongTerm
    | Working


type alias TaskArchiveSummary =
    { incarnationId : String
    , taskId : String
    , runCount : Int
    , entryCount : Int
    , created : Int
    , updated : Int
    , preview : String
    }


type alias TaskRecordSearch =
    { query : String
    , mode : String
    , caseSensitive : Bool
    , scannedTasks : Int
    , scannedEntries : Int
    , matchedEntries : Int
    , totalHits : Int
    , returnedHits : Int
    , offset : Int
    , limit : Int
    , nextOffset : Maybe Int
    , hasMore : Bool
    , truncated : Bool
    , hits : List TaskRecordHit
    }


type alias TaskRecordHit =
    { entryId : String
    , taskId : String
    , runId : String
    , seq : Int
    , kind : String
    , sourceId : String
    , toolName : Maybe String
    , callId : Maybe String
    , evidenceClass : String
    , sourceCompleteness : String
    , artifactIds : List String
    , lineNumber : Int
    , matchOffset : Int
    , entryMatchIndex : Int
    , entryMatchCount : Int
    , excerpt : String
    , created : Int
    }


type alias TaskRecordContext =
    { taskId : String
    , anchorEntryId : String
    , entries : List TaskRecordEntry
    }


type alias TaskRecordEntry =
    { entryId : String
    , taskId : String
    , runId : String
    , seq : Int
    , kind : String
    , sourceId : String
    , toolName : Maybe String
    , callId : Maybe String
    , evidenceClass : String
    , sourceCompleteness : String
    , artifactIds : List String
    , content : String
    , contentOffset : Int
    , contentTotal : Int
    , truncatedBefore : Bool
    , truncatedAfter : Bool
    , created : Int
    }


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
    }


type alias TaskConfig =
    { incarnationId : Maybe String
    , cwdMode : String
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


type alias ConfigDraft =
    { cwdMode : String
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


type alias ProviderEntry =
    { name : String
    , baseUrl : String
    , dialect : String
    , defaultModel : String
    , keyReady : Bool
    , models : List String
    , contextTokens : Int
    }


type alias ContextPolicy =
    { enabled : Bool
    , windowTokens : Int
    , reserveTokens : Int
    , toolTokens : Int
    , budgetTokens : Int
    , keepUnits : Int
    , summaryTokens : Int
    }


type AuditFacet
    = AuditConversation
    | AuditEvents
    | AuditApi
    | AuditEntries


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

type alias RunTrace =
    { runId : String
    , threadId : String
    , status : String
    , steps : List RunTraceStep
    }


type alias RunTraceStep =
    { seq : Int
    , time : Maybe Int
    , kind : String
    , label : String
    , detail : String
    , status : String
    , callId : Maybe String
    , artifactIds : List String
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


type alias ArtifactMeta =
    { id : String
    , toolName : String
    , preview : String
    , chars : Int
    , time : Int
    }


type AgentEvent
    = RunStarted String String
    | RunFinished String String
    | RunError String (Maybe String)
    | StepStarted String
    | StepFinished String
    | TextStarted String
    | TextContent String String
    | TextEnded String
    | ReasoningStarted String
    | ReasoningContent String String
    | ReasoningEnded String
    | ToolStarted String String (Maybe String)
    | ToolArguments String String
    | ToolEnded String
    | ToolResultReceived String String String
    | ContextInject String
    | UsageObserved Usage
    | ShellOutput String String
    | ProviderRetry Int Int Int String
    | ContextStatus ContextGauge
    | ContextCompact Int Int
    | RunCancelled String
    | SubAgentObserved String Decode.Value
    | CustomObserved String
    | IgnoredEvent


type alias AgentEnvelope =
    { threadId : String
    , runId : String
    , event : AgentEvent
    }


type TransportSignal
    = TransportConnecting String
    | TransportOpen String
    | TransportClosed String
    | TransportCancelled String
    | TransportFailed String String


type alias InspectionResult =
    { kind : String
    , status : Int
    , body : Decode.Value
    }


type TranscriptMessage
    = TranscriptUser String String
    | TranscriptSummary String String
    | TranscriptReasoning String String
    | TranscriptAssistant String String (List TranscriptTool)
    | TranscriptToolResult String String String


type alias TranscriptTool =
    { id : String
    , name : String
    , arguments : String
    }


type ControlKind
    = Steer
    | FollowUp


type Msg
    = DraftChanged String
    | InsertPath String
    | Submit
    | SubmitPrompt String
    | Queue ControlKind
    | Cancel
    | RetryLast
    | CopyLast
    | SelectPage Page
    | SwitchYuki String
    | SelfNameChanged String
    | SelfDirectionChanged String
    | SelfImpressionModelChanged String
    | SaveSelf
    | OpenYukiForm
    | CloseYukiForm
    | YukiIdChanged String
    | YukiNameChanged String
    | YukiDirectionChanged String
    | YukiModelChanged String
    | SubmitYukiForm
    | ArchiveYuki
    | ConfirmArchiveYuki
    | CancelArchiveYuki
    | DeleteYuki String Int
    | ConfirmDeleteYuki
    | CancelDeleteYuki
    | RestoreYuki String Int
    | ToggleArchivedYukis
    | RefreshPrompts
    | GeneratePrompt
    | ActivatePrompt String
    | ActivateRootPrompt String Int
    | BeginPromptEdit Bool PromptRevision
    | PromptSourceChanged String
    | PromptContentChanged String
    | SavePromptEdit
    | CancelPromptEdit
    | OpenTaskForm
    | CloseTaskForm
    | TaskFormTitleChanged String
    | SubmitTaskForm
    | TaskTitleChanged String
    | RenameTask
    | ArchiveTask String
    | RestoreTask String
    | ForkNodeChanged String
    | ForkTask
    | ExportTask
    | ImportTaskRequested
    | ToggleArchivedTasks
    | ToggleMemory
    | ToggleTasks
    | CloseEdges
    | ClearNotice
    | SwitchTask String
    | CreateTask
    | MemoryQueryChanged String
    | SearchMemory
    | MemoryDraftChanged String
    | MemoryKindChanged String
    | MemoryVisibilityChanged String
    | RememberMemory
    | OpenMemory String Int
    | CloseMemory
    | VoidMemory String Int
    | RefreshMemory
    | SelectMemorySection MemorySection
    | RefreshTaskArchives
    | TaskRecordQueryChanged String
    | TaskRecordTaskChanged String
    | TaskRecordCaseChanged Bool
    | SearchTaskRecords
    | SearchMoreTaskRecords
    | OpenTaskRecord TaskRecordHit
    | ExpandTaskRecord
    | CloseTaskRecord
    | ContinueArchivedTask String
    | RefreshWorkingMemory
    | SleepCurrentTask
    | RefreshCapabilities
    | EndpointChanged String
    | ConfigCwdModeChanged String
    | ConfigCwdChanged String
    | ConfigPromptChanged String
    | ConfigProviderChanged String
    | ConfigModelChanged String
    | ConfigEffortChanged String
    | ConfigGateChanged String (Maybe Bool)
    | ConfigReserveChanged String
    | ConfigKeepChanged String
    | ConfigSummaryChanged String
    | SaveConfig
    | RefreshTree
    | RefreshAudit
    | SelectRun String
    | ReplayRun String
    | SelectAuditFacet AuditFacet
    | AuditFilterChanged String
    | ToggleArtifact String
    | ResolveTool String Bool
    | ScrollLatest
    | AgentEventReceived Decode.Value
    | TransportEventReceived Decode.Value
    | InspectionReceived Decode.Value
    | TranscriptFollowChanged Bool
    | SessionImportReceived Decode.Value
    | NoOp


type Effect
    = None
    | Batch (List Effect)
    | RunAgent Encode.Value
    | CancelAgent Encode.Value
    | Inspect Encode.Value
    | PersistThread String
    | PersistIncarnation String
    | ExportSession String Encode.Value
    | ChooseSessionImport
    | Copy String
    | FollowTranscript
