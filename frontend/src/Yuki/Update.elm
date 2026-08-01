module Yuki.Update exposing (init, update)

import Dict
import Json.Encode as Encode
import Yuki.Config.Update as ConfigUpdate
import Yuki.Conversation.Update as ConversationUpdate
import Yuki.Decode as Decoder
import Yuki.Encode as Encoder
import Yuki.Event as Event
import Yuki.Inspection as Inspection
import Yuki.Memory.Update as MemoryUpdate
import Yuki.Request as Request
import Yuki.Self.Update as SelfUpdate
import Yuki.State as State
import Yuki.Task.Update as TaskUpdate
import Yuki.Types exposing (..)


init : Flags -> ( Model, Effect )
init flags =
    let
        model =
            { endpoint = flags.endpoint
            , threadId = flags.threadId
            , incarnationId = flags.incarnationId
            , incarnation =
                { id = flags.incarnationId
                , name = if flags.incarnationId == "yuki" then "Yuki" else flags.incarnationId
                , direction = "持续形成判断，保留经验，并对自己的工作方式负责。"
                , promptRevision = Nothing
                , impressionModel = Nothing
                , revision = 0
                , status = "active"
                , created = 0
                , updated = 0
                }
            , incarnations = Loading
            , selfNameDraft = if flags.incarnationId == "yuki" then "Yuki" else flags.incarnationId
            , selfDirectionDraft = "持续形成判断，保留经验，并对自己的工作方式负责。"
            , selfImpressionModelDraft = ""
            , selfSaving = False
            , selfError = Nothing
            , archiveYukiConfirm = False
            , deleteYukiConfirm = Nothing
            , yukiForm = Nothing
            , showArchivedYukis = False
            , prompts = Loading
            , rootPrompts = Loading
            , promptEditor = Nothing
            , generatingPrompt = False
            , activatingPrompt = Nothing
            , promptMessage = Nothing
            , runStamp = flags.runStamp
            , page = Conversation
            , memoryPinned = False
            , tasksOpen = False
            , draft = ""
            , pathSuggestions = []
            , messages = Dict.empty
            , messageOrder = []
            , tools = Dict.empty
            , transcriptLoading = True
            , phase = Idle
            , activeRun = Nothing
            , nextId = 1
            , error = Nothing
            , activeStep = Nothing
            , following = True
            , sessions = Loading
            , taskReady = False
            , taskTitle = ""
            , taskTitleDraft = ""
            , taskFormOpen = False
            , taskFormTitle = ""
            , showArchivedTasks = False
            , forkNodeDraft = ""
            , taskActionError = Nothing
            , impression = Loading
            , memorySection = Impressions
            , impressionActivations = Loading
            , impressionRevisions = Loading
            , memoryQuery = ""
            , memorySearch = Ready { snippets = [], query = "" }
            , memoryDraft = ""
            , memoryKind = "semantic"
            , memoryVisibility = "private"
            , selectedMemory = Nothing
            , memoryDetail = Loading
            , memoryReceipts = Loading
            , experiences = Loading
            , memoryActionError = Nothing
            , taskArchives = Loading
            , taskRecordQuery = ""
            , taskRecordTask = Nothing
            , taskRecordCaseSensitive = False
            , taskRecordSearch = Ready
                { query = ""
                , mode = "literal"
                , caseSensitive = False
                , scannedTasks = 0
                , scannedEntries = 0
                , matchedEntries = 0
                , totalHits = 0
                , returnedHits = 0
                , offset = 0
                , limit = 40
                , nextOffset = Nothing
                , hasMore = False
                , truncated = False
                , hits = []
                }
            , selectedTaskRecord = Nothing
            , taskRecordReader = Ready { taskId = "", anchorEntryId = "", entries = [] }
            , workingMemory = Loading
            , sleepCycles = Loading
            , sleeping = False
            , sleepMessage = Nothing
            , capabilities = Loading
            , taskConfig = Loading
            , globalConfig = Loading
            , configDraft = ConfigUpdate.emptyDraft
            , providers = Loading
            , contextPolicy = Loading
            , configSaving = False
            , configError = Nothing
            , tree = Loading
            , auditRuns = Loading
            , runSummaries = Dict.empty
            , runTraces = Dict.empty
            , runLogs = Dict.empty
            , replayReports = Dict.empty
            , selectedRun = Nothing
            , auditFacet = AuditConversation
            , auditFilter = ""
            , artifacts = Loading
            , artifactBodies = Dict.empty
            , usage = Nothing
            , contextGauge = Nothing
            , notice = Nothing
            }
    in
    ( model
    , Batch
        [ Request.sessions model
        , Request.incarnations model
        , Request.incarnation model
        , Request.impression model
        ]
    )


update : Msg -> Model -> ( Model, Effect )
update msg model =
    case msg of
        DraftChanged value ->
            ConversationUpdate.updateDraft value model

        InsertPath path ->
            ( { model | draft = ConversationUpdate.insertPathReference path model.draft, pathSuggestions = [] }, None )

        Submit ->
            ConversationUpdate.send model.draft model

        SubmitPrompt prompt ->
            ConversationUpdate.send prompt model

        Queue kind ->
            ConversationUpdate.queue kind model

        Cancel ->
            ( { model | phase = Canceled, activeStep = Nothing }
            , model.activeRun
                |> Maybe.map (\runId -> CancelAgent (Encoder.cancelCommand runId model))
                |> Maybe.withDefault None
            )

        RetryLast ->
            ConversationUpdate.retry model

        CopyLast ->
            ( model, Maybe.map Copy (State.lastAssistantText model) |> Maybe.withDefault None )

        SelectPage page ->
            selectPage page model

        SwitchYuki identifier ->
            SelfUpdate.switch identifier model

        SelfNameChanged value ->
            ( { model | selfNameDraft = value, selfError = Nothing }, None )

        SelfDirectionChanged value ->
            ( { model | selfDirectionDraft = value, selfError = Nothing }, None )

        SelfImpressionModelChanged value ->
            ( { model | selfImpressionModelDraft = value, selfError = Nothing }, None )

        SaveSelf ->
            SelfUpdate.save model

        OpenYukiForm ->
            if model.selfSaving || model.generatingPrompt || model.activatingPrompt /= Nothing || model.promptEditor /= Nothing then
                ( model, None )

            else
                ( { model
                    | yukiForm =
                        Just
                            { identifier = "yuki-" ++ String.right 6 model.runStamp
                            , name = ""
                            , direction = ""
                            , impressionModel = ""
                            , saving = False
                            , error = Nothing
                            }
                  }
                , None
                )

        CloseYukiForm ->
            ( { model | yukiForm = Nothing }, None )

        YukiIdChanged value ->
            ( SelfUpdate.mapDraft (\draft -> { draft | identifier = value, error = Nothing }) model, None )

        YukiNameChanged value ->
            ( SelfUpdate.mapDraft (\draft -> { draft | name = value, error = Nothing }) model, None )

        YukiDirectionChanged value ->
            ( SelfUpdate.mapDraft (\draft -> { draft | direction = value, error = Nothing }) model, None )

        YukiModelChanged value ->
            ( SelfUpdate.mapDraft (\draft -> { draft | impressionModel = value, error = Nothing }) model, None )

        SubmitYukiForm ->
            SelfUpdate.create model

        ArchiveYuki ->
            ( { model | archiveYukiConfirm = True }, None )

        ConfirmArchiveYuki ->
            SelfUpdate.archive model

        CancelArchiveYuki ->
            ( { model | archiveYukiConfirm = False }, None )

        DeleteYuki identifier revision ->
            ( { model | deleteYukiConfirm = Just ( identifier, revision ) }, None )

        ConfirmDeleteYuki ->
            case model.deleteYukiConfirm of
                Just ( identifier, revision ) ->
                    SelfUpdate.delete identifier revision model

                Nothing ->
                    ( model, None )

        CancelDeleteYuki ->
            ( { model | deleteYukiConfirm = Nothing }, None )

        RestoreYuki identifier revision ->
            SelfUpdate.restore identifier revision model

        ToggleArchivedYukis ->
            ( { model | showArchivedYukis = not model.showArchivedYukis }, None )

        RefreshPrompts ->
            ( { model | prompts = Loading, rootPrompts = Loading }
            , Batch [ Request.prompts model, Request.rootPrompts model ]
            )

        GeneratePrompt ->
            SelfUpdate.generatePrompt model

        ActivatePrompt identifier ->
            SelfUpdate.activatePrompt False identifier model.incarnation.revision model

        ActivateRootPrompt identifier expected ->
            SelfUpdate.activatePrompt True identifier expected model

        BeginPromptEdit root revision ->
            ( { model
                | promptEditor =
                    Just
                        { root = root
                        , baseId = revision.id
                        , sourceIntent = "manual revision based on " ++ revision.id
                        , content = revision.content
                        , saving = False
                        }
                , promptMessage = Nothing
              }
            , None
            )

        PromptSourceChanged value ->
            ( SelfUpdate.mapPromptEditor (\editor -> { editor | sourceIntent = value }) model, None )

        PromptContentChanged value ->
            ( SelfUpdate.mapPromptEditor (\editor -> { editor | content = value }) model, None )

        SavePromptEdit ->
            SelfUpdate.savePromptEdit model

        CancelPromptEdit ->
            ( { model | promptEditor = Nothing }, None )

        OpenTaskForm ->
            ( { model | taskFormOpen = True, taskFormTitle = "", taskActionError = Nothing }, None )

        CloseTaskForm ->
            ( { model | taskFormOpen = False }, None )

        TaskFormTitleChanged value ->
            ( { model | taskFormTitle = value }, None )

        SubmitTaskForm ->
            TaskUpdate.create model.taskFormTitle model

        TaskTitleChanged value ->
            ( { model | taskTitleDraft = value }, None )

        RenameTask ->
            TaskUpdate.rename model

        ArchiveTask identifier ->
            TaskUpdate.mutate "archive" identifier model

        RestoreTask identifier ->
            TaskUpdate.mutate "restore" identifier model

        ForkNodeChanged value ->
            ( { model | forkNodeDraft = value }, None )

        ForkTask ->
            TaskUpdate.fork model

        ExportTask ->
            ( { model | taskActionError = Nothing }
            , Inspect <|
                Encoder.inspectionRequest model
                    ("task/export/" ++ model.threadId)
                    "GET"
                    Nothing
                    ("threads/" ++ model.threadId ++ "/export")
            )

        ImportTaskRequested ->
            ( { model | taskActionError = Nothing }, ChooseSessionImport )

        ToggleArchivedTasks ->
            ( { model | showArchivedTasks = not model.showArchivedTasks }, None )

        ToggleMemory ->
            ( { model | memoryPinned = not model.memoryPinned, tasksOpen = False }, None )

        ToggleTasks ->
            ( { model | tasksOpen = not model.tasksOpen, memoryPinned = False }, None )

        CloseEdges ->
            ( { model
                | tasksOpen = False
                , memoryPinned = False
                , taskFormOpen = False
                , yukiForm = Nothing
                , archiveYukiConfirm = False
                , deleteYukiConfirm = Nothing
                , selectedMemory = Nothing
                , selectedTaskRecord = Nothing
              }
            , None
            )

        ClearNotice ->
            ( { model | notice = Nothing }, None )

        SwitchTask identifier ->
            Inspection.switchTask identifier model

        CreateTask ->
            TaskUpdate.create "" model

        MemoryQueryChanged value ->
            MemoryUpdate.queryChanged value model

        SearchMemory ->
            MemoryUpdate.search model

        MemoryDraftChanged value ->
            MemoryUpdate.draftChanged value model

        MemoryKindChanged value ->
            MemoryUpdate.kindChanged value model

        MemoryVisibilityChanged value ->
            MemoryUpdate.visibilityChanged value model

        RememberMemory ->
            MemoryUpdate.remember model

        OpenMemory identifier revision ->
            MemoryUpdate.open identifier revision model

        CloseMemory ->
            MemoryUpdate.close model

        VoidMemory identifier revision ->
            MemoryUpdate.void identifier revision model

        RefreshMemory ->
            MemoryUpdate.refresh model

        SelectMemorySection section ->
            MemoryUpdate.selectSection section model

        RefreshTaskArchives ->
            MemoryUpdate.refreshArchives model

        TaskRecordQueryChanged value ->
            MemoryUpdate.recordQueryChanged value model

        TaskRecordTaskChanged value ->
            MemoryUpdate.recordTaskChanged value model

        TaskRecordCaseChanged value ->
            MemoryUpdate.recordCaseChanged value model

        SearchTaskRecords ->
            MemoryUpdate.searchRecords model

        SearchMoreTaskRecords ->
            MemoryUpdate.searchMoreRecords model

        OpenTaskRecord hit ->
            MemoryUpdate.openRecord hit model

        ExpandTaskRecord ->
            MemoryUpdate.expandRecord model

        CloseTaskRecord ->
            MemoryUpdate.closeRecord model

        ContinueArchivedTask taskId ->
            MemoryUpdate.continueTask taskId model

        RefreshWorkingMemory ->
            MemoryUpdate.refreshWorking model

        SleepCurrentTask ->
            MemoryUpdate.sleep model

        RefreshCapabilities ->
            ( { model
                | capabilities = Loading
                , taskConfig = Loading
                , globalConfig = Loading
                , providers = Loading
                , contextPolicy = Loading
              }
            , ConfigUpdate.load model
            )

        EndpointChanged value ->
            ( { model | endpoint = value }, None )

        ConfigCwdModeChanged value ->
            ( ConfigUpdate.mapDraft (\draft -> { draft | cwdMode = value }) model, None )

        ConfigCwdChanged value ->
            ( ConfigUpdate.mapDraft (\draft -> { draft | cwd = value, cwdMode = "path" }) model, None )

        ConfigPromptChanged value ->
            ( ConfigUpdate.mapDraft (\draft -> { draft | systemPrompt = value }) model, None )

        ConfigProviderChanged value ->
            ( ConfigUpdate.mapDraft (\draft -> { draft | provider = value, model = "" }) model, None )

        ConfigModelChanged value ->
            ( ConfigUpdate.mapDraft (\draft -> { draft | model = value }) model, None )

        ConfigEffortChanged value ->
            ( ConfigUpdate.mapDraft (\draft -> { draft | reasoningEffort = value }) model, None )

        ConfigGateChanged gate value ->
            ( ConfigUpdate.mapDraft (ConfigUpdate.setGate gate value) model, None )

        ConfigReserveChanged value ->
            ( ConfigUpdate.mapDraft (\draft -> { draft | contextReserveTokens = value }) model, None )

        ConfigKeepChanged value ->
            ( ConfigUpdate.mapDraft (\draft -> { draft | contextKeepUnits = value }) model, None )

        ConfigSummaryChanged value ->
            ( ConfigUpdate.mapDraft (\draft -> { draft | contextSummaryTokens = value }) model, None )

        SaveConfig ->
            ConfigUpdate.save model

        RefreshTree ->
            ( { model | tree = Loading }, Request.tree model )

        RefreshAudit ->
            ( { model | auditRuns = Loading, runSummaries = Dict.empty, runTraces = Dict.empty, runLogs = Dict.empty, artifacts = Loading }
            , Batch [ Request.auditRuns model, Request.artifacts model ]
            )

        SelectRun runId ->
            if model.selectedRun == Just runId then
                ( { model | selectedRun = Nothing }, None )

            else
                let
                    traceReady =
                        case Dict.get runId model.runTraces of
                            Just (Ready _) ->
                                True

                            _ ->
                                False

                    traceEffect =
                        if traceReady then
                            []

                        else
                            [ Inspect <|
                                Encoder.inspectionRequest model
                                    ("audit/trace/" ++ runId)
                                    "GET"
                                    Nothing
                                    ("journal/runs/" ++ runId ++ "/trace")
                            ]

                    logReady =
                        case Dict.get runId model.runLogs of
                            Just (Ready _) ->
                                True

                            _ ->
                                False

                    logEffect =
                        if logReady then
                            []

                        else
                            [ Inspect <|
                                Encoder.inspectionRequest model
                                    ("audit/log/" ++ runId)
                                    "GET"
                                    Nothing
                                    ("journal?run=" ++ runId)
                            ]
                in
                ( { model
                    | selectedRun = Just runId
                    , runTraces =
                        if traceReady then
                            model.runTraces

                        else
                            Dict.insert runId Loading model.runTraces
                    , runLogs =
                        if logReady then
                            model.runLogs

                        else
                            Dict.insert runId Loading model.runLogs
                  }
                , Batch (traceEffect ++ logEffect)
                )

        ReplayRun runId ->
            ( { model | replayReports = Dict.insert runId Loading model.replayReports }
            , Inspect <|
                Encoder.inspectionRequest model
                    ("audit/replay/" ++ runId)
                    "POST"
                    (Just (Encode.object [ ( "runId", Encode.string runId ) ]))
                    "replay"
            )

        SelectAuditFacet facet ->
            ( { model | auditFacet = facet }, None )

        AuditFilterChanged value ->
            ( { model | auditFilter = value }, None )

        ToggleArtifact identifier ->
            case Dict.get identifier model.artifactBodies of
                Just _ ->
                    ( { model | artifactBodies = Dict.remove identifier model.artifactBodies }, None )

                Nothing ->
                    ( { model | artifactBodies = Dict.insert identifier Loading model.artifactBodies }
                    , Inspect <|
                        Encoder.inspectionRequest model
                            ("audit/artifact/" ++ identifier)
                            "GET"
                            Nothing
                            ("artifacts/" ++ identifier)
                    )

        ResolveTool callId approved ->
            ConversationUpdate.resolveTool callId approved model

        ScrollLatest ->
            ( { model | following = True }, FollowTranscript )

        AgentEventReceived raw ->
            case Decoder.agentEventEnvelope raw of
                Ok envelope ->
                    if relevantAgentEvent envelope model then
                        Event.applyAgent envelope.event model

                    else
                        ( model, None )

                Err _ ->
                    failActiveRun "收到了一段无法辨认的运行事件。" model

        TransportEventReceived raw ->
            case Decoder.transportSignal raw of
                Ok signal ->
                    Event.applyTransport signal model

                Err _ ->
                    failActiveRun "运行连接返回了无法辨认的状态。" model

        InspectionReceived raw ->
            Decoder.inspectionResult raw
                |> Result.map (\result -> Inspection.apply result model)
                |> Result.withDefault
                    ( { model | notice = Just "一项本机资料无法读取。" }, None )

        TranscriptFollowChanged following ->
            ( { model | following = following }, None )

        SessionImportReceived raw ->
            ( { model | taskActionError = Nothing }
            , Inspect <| Encoder.inspectionRequest model "task/import" "POST" (Just raw) "threads/import"
            )

        NoOp ->
            ( model, None )


relevantAgentEvent : AgentEnvelope -> Model -> Bool
relevantAgentEvent envelope model =
    envelope.threadId == model.threadId
        && (case envelope.event of
                RunStarted _ runId ->
                    model.activeRun == Just envelope.runId && runId == envelope.runId

                _ ->
                    model.activeRun == Just envelope.runId
           )


failActiveRun : String -> Model -> ( Model, Effect )
failActiveRun message model =
    let
        next =
            State.completeStreaming
                { model
                    | phase = Failed
                    , activeRun = Nothing
                    , activeStep = Nothing
                    , error = Just message
                }
    in
    ( next
    , model.activeRun
        |> Maybe.map (\runId -> CancelAgent (Encoder.cancelCommand runId model))
        |> Maybe.withDefault None
    )


selectPage : Page -> Model -> ( Model, Effect )
selectPage page model =
    let
        selected =
            { model | page = page, tasksOpen = False }
    in
    case page of
        Conversation ->
            ( { selected | following = True }, FollowTranscript )

        Tasks ->
            ( selected, Request.sessions selected )

        Memory ->
            MemoryUpdate.selectSection selected.memorySection selected

        Capabilities ->
            ( selected, ConfigUpdate.load selected )

        Self ->
            ( selected
            , Batch
                [ Request.incarnation selected
                , Request.incarnations selected
                , Request.prompts selected
                , Request.rootPrompts selected
                ]
            )

        Audit ->
            ( selected, Batch [ Request.auditRuns selected, Request.artifacts selected ] )
