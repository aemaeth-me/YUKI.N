module Yuki.Inspection exposing (apply, switchTask)

import Dict
import Json.Decode as Decode
import Yuki.Decode as Decoder
import Yuki.Encode as Encoder
import Yuki.Inspection.Audit as Audit
import Yuki.Inspection.Memory as Memory
import Yuki.Request as Request
import Yuki.State as State
import Yuki.Types exposing (..)


apply : InspectionResult -> Model -> ( Model, Effect )
apply result model =
    case String.split "/" result.kind of
        "memory" :: path ->
            Memory.apply path result model

        "audit" :: path ->
            Audit.apply path result model

        [ "tasks", "list" ] ->
            tasks result model

        [ "incarnations", "list" ] ->
            incarnationList result model

        [ "yuki", "update", identifier ] ->
            receiveYuki identifier False result model

        [ "yuki", "create", identifier ] ->
            receiveYuki identifier True result model

        [ "yuki", "archive", identifier ] ->
            yukiLifecycle "Yuki 已归档。" identifier result model

        [ "yuki", "delete", identifier ] ->
            yukiLifecycle "Yuki 已删除，记忆与任务已一并清除。" identifier result model

        [ "yuki", "restore", identifier ] ->
            yukiLifecycle "Yuki 已恢复。" identifier result model

        [ "prompts", "list", identifier ] ->
            promptList identifier False result model

        [ "prompts", "root" ] ->
            promptList model.incarnationId True result model

        [ "prompts", "generate", identifier ] ->
            promptMutation identifier "新 Prompt 草案已生成。" result model

        [ "prompts", "edit", identifier ] ->
            promptMutation identifier "Prompt 修订已保存为草案。" result model

        [ "prompts", "edit-root" ] ->
            promptMutation model.incarnationId "Root Prompt 修订已保存为草案。" result model

        [ "prompts", "activate", _ ] ->
            promptActivation False result model

        [ "prompts", "activate-root", _ ] ->
            promptActivation True result model

        [ "tasks", "create", identifier ] ->
            if successful result then
                switchTask identifier
                    { model
                        | notice = Just "新任务已经建立。"
                        , taskFormOpen = False
                        , taskFormTitle = ""
                    }

            else
                ( { model | taskActionError = Just ("未能建立任务：" ++ statusLabel result) }, None )

        [ "task", "rename", identifier ] ->
            taskMutation "任务名称已更新。" identifier result model

        [ "task", "archive", identifier ] ->
            taskMutation "任务已归档。" identifier result model

        [ "task", "restore", identifier ] ->
            taskMutation "任务已恢复。" identifier result model

        [ "task", "fork", identifier ] ->
            if successful result then
                switchTask identifier { model | notice = Just "已从当前节点分叉为新任务。" }

            else
                ( { model | taskActionError = Just ("分叉失败：" ++ statusLabel result) }, None )

        [ "task", "export", identifier ] ->
            if successful result then
                ( model, ExportSession identifier result.body )

            else
                ( { model | taskActionError = Just ("导出失败：" ++ statusLabel result) }, None )

        [ "task", "import" ] ->
            if successful result then
                case Decode.decodeValue Decoder.session result.body of
                    Ok imported ->
                        switchTask imported.id { model | notice = Just "任务已导入。" }

                    Err _ ->
                        ( { model | taskActionError = Just "任务已返回，但导入结果无法辨认。" }, None )

            else
                ( { model | taskActionError = Just ("导入失败：" ++ statusLabel result) }, None )

        [ "transcript", identifier ] ->
            transcript identifier result model

        [ "incarnation", identifier ] ->
            incarnation identifier result model

        [ "impression", identifier ] ->
            impression identifier result model

        [ "capabilities", identifier ] ->
            capabilities identifier result model

        [ "config", "task", identifier ] ->
            taskConfig identifier result model

        [ "config", "global" ] ->
            ( { model
                | globalConfig =
                    if successful result then
                        Ready result.body

                    else
                        Unavailable (statusLabel result)
              }
            , None
            )

        [ "config", "providers" ] ->
            providers result model

        [ "config", "context", identifier ] ->
            contextPolicy identifier result model

        [ "config", "tree", identifier ] ->
            tree identifier result model

        [ "config", "save", identifier ] ->
            configSaved identifier result model

        [ "config", "paths", identifier ] ->
            if identifier /= model.threadId then
                ( model, None )

            else if successful result then
                Decode.decodeValue (Decode.field "paths" (Decode.list Decode.string)) result.body
                    |> Result.map (\paths -> ( { model | pathSuggestions = paths }, None ))
                    |> Result.withDefault ( { model | pathSuggestions = [] }, None )

            else
                ( { model | pathSuggestions = [] }, None )

        _ ->
            ( model, None )


tasks : InspectionResult -> Model -> ( Model, Effect )
tasks result model =
    if successful result then
        case Decode.decodeValue Decoder.sessions result.body of
            Ok entries ->
                let
                    active =
                        List.filter (\entry -> not entry.archived) entries

                    selected =
                        List.filter (\entry -> entry.id == model.threadId && not entry.archived) entries |> List.head
                in
                case ( selected, List.head active ) of
                    ( Just current, _ ) ->
                        let
                            updated =
                                { model
                                    | sessions = Ready entries
                                    , taskReady = True
                                    , taskTitle = State.taskName current
                                    , taskTitleDraft = State.taskName current
                                }
                        in
                        if model.taskReady then
                            ( updated, None )

                        else
                            loadTaskResources updated

                    ( Nothing, Just first ) ->
                        switchTask first.id { model | sessions = Ready entries }

                    _ ->
                        ( { model
                            | sessions = Ready entries
                            , taskReady = False
                            , transcriptLoading = False
                            , taskTitle = "未命名任务"
                            , taskTitleDraft = ""
                            , messages = Dict.empty
                            , messageOrder = []
                            , tools = Dict.empty
                          }
                        , None
                        )

            Err _ ->
                ( { model | sessions = Unavailable "任务列表无法辨认。" }, None )

    else
        ( { model | sessions = Unavailable (statusLabel result) }, None )


incarnationList : InspectionResult -> Model -> ( Model, Effect )
incarnationList result model =
    if successful result then
        Decode.decodeValue (Decode.list Decoder.incarnation) result.body
            |> Result.map (\entries -> ( { model | incarnations = Ready entries }, None ))
            |> Result.withDefault ( { model | incarnations = Unavailable "Yuki 列表无法辨认。" }, None )

    else
        ( { model | incarnations = Unavailable (statusLabel result) }, None )


receiveYuki : String -> Bool -> InspectionResult -> Model -> ( Model, Effect )
receiveYuki identifier created result model =
    if successful result then
        case
            Decode.decodeValue
                (Decode.oneOf
                    [ Decode.field "incarnation" Decoder.incarnation
                    , Decoder.incarnation
                    ]
                )
                result.body
        of
            Ok incarnationValue ->
                if created then
                    switchYukiFromInspection incarnationValue
                        { model
                            | yukiForm = Nothing
                            , selfSaving = False
                            , notice = Just "新的 Yuki 已建立，并生成了初始 Prompt。"
                        }

                else
                    ( { model
                        | incarnation = incarnationValue
                        , selfNameDraft = incarnationValue.name
                        , selfDirectionDraft = incarnationValue.direction
                        , selfImpressionModelDraft = Maybe.withDefault "" incarnationValue.impressionModel
                        , selfSaving = False
                        , selfError = Nothing
                        , archiveYukiConfirm = False
                        , notice = Just "自我来源已更新；新 Prompt 草案可在版本区核查。"
                      }
                    , Request.incarnations model
                    )

            Err _ ->
                ( { model | selfSaving = False, selfError = Just "Yuki 响应无法辨认。" }, None )

    else
        ( { model
            | selfSaving = False
            , selfError = Just (statusLabel result)
            , yukiForm =
                if created then
                    Maybe.map (\draft -> { draft | saving = False, error = Just (statusLabel result) }) model.yukiForm

                else
                    model.yukiForm
          }
        , None
        )


switchYukiFromInspection : Incarnation -> Model -> ( Model, Effect )
switchYukiFromInspection incarnationValue model =
    let
        next =
            { model
                | incarnationId = incarnationValue.id
                , incarnation = incarnationValue
                , selfNameDraft = incarnationValue.name
                , selfDirectionDraft = incarnationValue.direction
                , selfImpressionModelDraft = Maybe.withDefault "" incarnationValue.impressionModel
                , archiveYukiConfirm = False
                , sessions = Loading
                , taskReady = False
                , messages = Dict.empty
                , messageOrder = []
                , tools = Dict.empty
                , transcriptLoading = True
                , memoryReceipts = Loading
                , experiences = Loading
                , taskArchives = Loading
                , workingMemory = Loading
                , sleepCycles = Loading
                , globalConfig = Loading
                , page = Conversation
            }
    in
    ( next
    , Batch
        [ PersistIncarnation incarnationValue.id
        , Request.incarnation next
        , Request.incarnations next
        , Request.sessions next
        , Request.impression next
        , Request.prompts next
        , Request.rootPrompts next
        ]
    )


yukiLifecycle : String -> String -> InspectionResult -> Model -> ( Model, Effect )
yukiLifecycle successMessage identifier result model =
    if successful result then
        if identifier == model.incarnationId then
            switchYukiFromInspection
                { id = "yuki"
                , name = "Yuki"
                , direction = ""
                , promptRevision = Nothing
                , impressionModel = Nothing
                , revision = 0
                , status = "active"
                , created = 0
                , updated = 0
                }
                { model | selfSaving = False, notice = Just successMessage }

        else
            ( { model | notice = Just successMessage, archiveYukiConfirm = False, deleteYukiConfirm = Nothing }, Request.incarnations model )

    else
        ( { model | selfSaving = False, selfError = Just (statusLabel result), deleteYukiConfirm = Nothing }, None )


promptList : String -> Bool -> InspectionResult -> Model -> ( Model, Effect )
promptList identifier root result model =
    if not root && identifier /= model.incarnationId then
        ( model, None )

    else if successful result then
        case Decode.decodeValue (Decode.list Decoder.promptRevision) result.body of
            Ok revisions ->
                if root then
                    ( { model | rootPrompts = Ready revisions }, None )

                else
                    ( { model | prompts = Ready revisions }, None )

            Err _ ->
                if root then
                    ( { model | rootPrompts = Unavailable "Root Prompt 版本无法辨认。" }, None )

                else
                    ( { model | prompts = Unavailable "Yuki Prompt 版本无法辨认。" }, None )

    else if root then
        ( { model | rootPrompts = Unavailable (statusLabel result) }, None )

    else
        ( { model | prompts = Unavailable (statusLabel result) }, None )


promptMutation : String -> String -> InspectionResult -> Model -> ( Model, Effect )
promptMutation identifier successMessage result model =
    if identifier /= model.incarnationId then
        ( model, None )

    else if successful result then
        ( { model
            | generatingPrompt = False
            , promptEditor = Nothing
            , promptMessage = Just successMessage
          }
        , Batch [ Request.prompts model, Request.rootPrompts model ]
        )

    else
        ( { model
            | generatingPrompt = False
            , promptEditor = Maybe.map (\editor -> { editor | saving = False }) model.promptEditor
            , promptMessage = Just (statusLabel result)
          }
        , None
        )


promptActivation : Bool -> InspectionResult -> Model -> ( Model, Effect )
promptActivation root result model =
    if successful result then
        ( { model | activatingPrompt = Nothing, promptMessage = Just "Prompt 版本已激活。" }
        , Batch
            [ Request.prompts model
            , Request.rootPrompts model
            , Request.incarnation model
            ]
        )

    else
        ( { model | activatingPrompt = Nothing, promptMessage = Just (statusLabel result) }, None )


transcript : String -> InspectionResult -> Model -> ( Model, Effect )
transcript identifier result model =
    if identifier /= model.threadId then
        ( model, None )

    else if successful result then
        case Decode.decodeValue Decoder.transcript result.body of
            Ok entries ->
                ( State.restoreTranscript entries
                    { model
                        | messages = Dict.empty
                        , messageOrder = []
                        , tools = Dict.empty
                        , transcriptLoading = False
                    }
                , FollowTranscript
                )

            Err _ ->
                ( { model | transcriptLoading = False, notice = Just "这项任务的记录无法辨认。" }, None )

    else
        ( { model | transcriptLoading = False, notice = Just ("任务载入失败：" ++ statusLabel result) }, None )


incarnation : String -> InspectionResult -> Model -> ( Model, Effect )
incarnation identifier result model =
    if identifier /= model.incarnationId || not (successful result) then
        ( model, None )

    else
        Decode.decodeValue Decoder.incarnation result.body
            |> Result.map
                (\value ->
                    ( { model
                        | incarnation = value
                        , selfNameDraft = value.name
                        , selfDirectionDraft = value.direction
                        , selfImpressionModelDraft = Maybe.withDefault "" value.impressionModel
                      }
                    , None
                    )
                )
            |> Result.withDefault ( model, None )


impression : String -> InspectionResult -> Model -> ( Model, Effect )
impression identifier result model =
    if identifier /= model.incarnationId then
        ( model, None )

    else if successful result then
        Decode.decodeValue Decoder.impressionState result.body
            |> Result.map (\value -> ( { model | impression = Ready value }, None ))
            |> Result.withDefault ( { model | impression = Unavailable "印象无法辨认。" }, None )

    else if result.status == 404 then
        ( { model | impression = Ready { revision = 0, items = [], updated = 0 } }, None )

    else
        ( { model | impression = Unavailable (statusLabel result) }, None )


capabilities : String -> InspectionResult -> Model -> ( Model, Effect )
capabilities identifier result model =
    if identifier /= model.threadId then
        ( model, None )

    else if successful result then
        Decode.decodeValue (Decode.list Decode.string) result.body
            |> Result.map (\values -> ( { model | capabilities = Ready values }, None ))
            |> Result.withDefault ( { model | capabilities = Unavailable "能力清单无法辨认。" }, None )

    else
        ( { model | capabilities = Unavailable (statusLabel result) }, None )


taskConfig : String -> InspectionResult -> Model -> ( Model, Effect )
taskConfig identifier result model =
    if identifier /= model.threadId then
        ( model, None )

    else if successful result then
        case Decode.decodeValue Decoder.taskConfig result.body of
            Ok config ->
                ( { model | taskConfig = Ready config, configDraft = draftFromConfig config }, None )

            Err _ ->
                ( { model | taskConfig = Unavailable "任务配置无法辨认。" }, None )

    else
        ( { model | taskConfig = Unavailable (statusLabel result) }, None )


providers : InspectionResult -> Model -> ( Model, Effect )
providers result model =
    if successful result then
        Decode.decodeValue (Decode.list Decoder.providerEntry) result.body
            |> Result.map (\values -> ( { model | providers = Ready values }, None ))
            |> Result.withDefault ( { model | providers = Unavailable "Provider 列表无法辨认。" }, None )

    else
        ( { model | providers = Unavailable (statusLabel result) }, None )


contextPolicy : String -> InspectionResult -> Model -> ( Model, Effect )
contextPolicy identifier result model =
    if identifier /= model.threadId then
        ( model, None )

    else if successful result then
        Decode.decodeValue Decoder.contextPolicy result.body
            |> Result.map (\value -> ( { model | contextPolicy = Ready value }, None ))
            |> Result.withDefault ( { model | contextPolicy = Unavailable "上下文策略无法辨认。" }, None )

    else
        ( { model | contextPolicy = Unavailable (statusLabel result) }, None )


tree : String -> InspectionResult -> Model -> ( Model, Effect )
tree identifier result model =
    if identifier /= model.threadId then
        ( model, None )

    else if result.status == 404 then
        ( { model | tree = Ready Nothing }, None )

    else if successful result then
        Decode.decodeValue (Decode.list Decode.string) result.body
            |> Result.map (\paths -> ( { model | tree = Ready (Just paths) }, None ))
            |> Result.withDefault ( { model | tree = Unavailable "目录树无法辨认。" }, None )

    else
        ( { model | tree = Unavailable (statusLabel result) }, None )


configSaved : String -> InspectionResult -> Model -> ( Model, Effect )
configSaved identifier result model =
    if identifier /= model.threadId then
        ( model, None )

    else if successful result then
        ( { model | configSaving = False, configError = Nothing, notice = Just "任务能力配置已保存。" }
        , Batch
            [ Request.config model
            , Request.capabilities model
            , Request.contextPolicy model
            , Request.tree model
            ]
        )

    else
        ( { model | configSaving = False, configError = Just (statusLabel result) }, None )


draftFromConfig : TaskConfig -> ConfigDraft
draftFromConfig config =
    { cwdMode = config.cwdMode
    , cwd = Maybe.withDefault "" config.cwd
    , systemPrompt = Maybe.withDefault "" config.systemPrompt
    , provider = Maybe.withDefault "" config.provider
    , model = Maybe.withDefault "" config.model
    , reasoningEffort = Maybe.withDefault "" config.reasoningEffort
    , fs = config.fs
    , shell = config.shell
    , memory = config.memory
    , contextReserveTokens = Maybe.map String.fromInt config.contextReserveTokens |> Maybe.withDefault ""
    , contextKeepUnits = Maybe.map String.fromInt config.contextKeepUnits |> Maybe.withDefault ""
    , contextSummaryTokens = Maybe.map String.fromInt config.contextSummaryTokens |> Maybe.withDefault ""
    }


switchTask : String -> Model -> ( Model, Effect )
switchTask identifier model =
    if (identifier == model.threadId && model.taskReady) || State.isBusy model.phase then
        ( { model | tasksOpen = False }, None )

    else
        let
            title =
                case model.sessions of
                    Ready entries ->
                        entries
                            |> List.filter (\entry -> entry.id == identifier)
                            |> List.head
                            |> Maybe.map State.taskName
                            |> Maybe.withDefault "未命名任务"

                    _ ->
                        "未命名任务"

            next =
                { model
                    | threadId = identifier
                    , taskReady = True
                    , taskTitle = title
                    , taskTitleDraft = title
                    , tasksOpen = False
                    , page = Conversation
                    , messages = Dict.empty
                    , messageOrder = []
                    , tools = Dict.empty
                    , transcriptLoading = True
                    , draft = ""
                    , pathSuggestions = []
                    , phase = Idle
                    , activeRun = Nothing
                    , error = Nothing
                    , activeStep = Nothing
                    , usage = Nothing
                    , contextGauge = Nothing
                    , capabilities = Loading
                    , notice = Nothing
                }
        in
        ( next
        , Batch
            [ PersistThread identifier
            , Request.transcript next
            , Request.capabilities next
            , Request.config next
            , Request.contextPolicy next
            , Request.tree next
            , Request.sessions next
            ]
        )


loadTaskResources : Model -> ( Model, Effect )
loadTaskResources model =
    ( { model
        | transcriptLoading = True
        , messages = Dict.empty
        , messageOrder = []
        , tools = Dict.empty
      }
    , Batch
        [ Request.transcript model
        , Request.capabilities model
        , Request.config model
        , Request.contextPolicy model
        , Request.tree model
        ]
    )


taskMutation : String -> String -> InspectionResult -> Model -> ( Model, Effect )
taskMutation successMessage identifier result model =
    if successful result then
        ( { model | notice = Just successMessage, taskActionError = Nothing }
        , Request.sessions model
        )

    else
        ( { model | taskActionError = Just (statusLabel result ++ " · " ++ identifier) }, None )


successful : InspectionResult -> Bool
successful result =
    result.status >= 200 && result.status < 300


statusLabel : InspectionResult -> String
statusLabel result =
    if result.status == 0 then
        Decode.decodeValue Decode.string result.body |> Result.withDefault "网络错误"

    else
        Decode.decodeValue (Decode.field "error" Decode.string) result.body
            |> Result.withDefault ("HTTP " ++ String.fromInt result.status)
