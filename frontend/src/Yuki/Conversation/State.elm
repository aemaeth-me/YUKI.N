module Yuki.Conversation.State exposing (Effects, Model, init, isSame, update)

import Json.Decode as Decode
import Json.Encode as Encode
import Yuki.Conversation.Decode as DecodeMsg
import Yuki.Conversation.Encode as EncodeMsg
import Yuki.Conversation.Types exposing (..)


type alias Effects msg =
    { endpoint : String
    , runStamp : String
    , inspect : Encode.Value -> Cmd msg
    , runAgent : Encode.Value -> Cmd msg
    , navigate : String -> Cmd msg
    }


type alias Model =
    { threadId : Maybe String
    , loading : Bool
    , loadError : Maybe String
    , items : List Item
    , nextId : Int
    , draft : String
    , phase : Phase
    , activeRun : Maybe String
    , runCounter : Int
    , error : Maybe String
    , gauge : Maybe Gauge
    , autoStart : Bool
    }


init : Model
init =
    { threadId = Nothing
    , loading = False
    , loadError = Nothing
    , items = []
    , nextId = 0
    , draft = ""
    , phase = PhaseIdle
    , activeRun = Nothing
    , runCounter = 0
    , error = Nothing
    , gauge = Nothing
    , autoStart = False
    }


isSame : String -> Model -> Bool
isSame tid model =
    model.threadId == Just tid


update : Effects msg -> Msg -> Model -> ( Model, Cmd msg )
update effects msg model =
    case msg of
        Enter tid ->
            enter effects tid model

        ChatResult rest status body ->
            handleChatResult effects rest status body model

        AgentEvent value ->
            applyEvent effects value model

        TransportEvent value ->
            applyTransport value model

        ComposerChanged text ->
            ( { model | draft = text }, Cmd.none )

        Send ->
            send effects model

        Retry ->
            retry effects model

        Reload ->
            case model.threadId of
                Just tid ->
                    update effects (Enter tid) { model | loadError = Nothing }

                Nothing ->
                    ( model, Cmd.none )

        Tick ->
            tick effects model


enter : Effects msg -> String -> Model -> ( Model, Cmd msg )
enter effects tid model =
    if isSame tid model && model.activeRun == Nothing && not model.loading then
        ( model, Cmd.none )

    else
        loadTranscript effects tid { init | threadId = Just tid, autoStart = True }


loadTranscript : Effects msg -> String -> Model -> ( Model, Cmd msg )
loadTranscript effects tid model =
    ( { model | threadId = Just tid, loading = True, loadError = Nothing }
    , effects.inspect (EncodeMsg.request ("chat/transcript/" ++ tid) "GET" ("/threads/" ++ tid ++ "/transcript") Nothing effects.endpoint)
    )


handleChatResult : Effects msg -> String -> Int -> Decode.Value -> Model -> ( Model, Cmd msg )
handleChatResult effects rest status body model =
    case String.split "/" rest of
        "chat" :: "transcript" :: tid :: _ ->
            if model.threadId == Just tid then
                if status >= 200 && status < 300 then
                    case Decode.decodeValue DecodeMsg.transcript body of
                        Ok items ->
                            let
                                loaded =
                                    { model
                                        | items = items
                                        , loading = False
                                        , loadError = Nothing
                                        , phase = PhaseIdle
                                        , activeRun = Nothing
                                        , error = Nothing
                                    }
                            in
                            maybeAutoStart effects loaded

                        Err message ->
                            ( { model | loading = False, loadError = Just (Decode.errorToString message) }, Cmd.none )

                else
                    ( { model | loading = False, loadError = Just (failureMessage status body) }, Cmd.none )

            else
                ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


maybeAutoStart : Effects msg -> Model -> ( Model, Cmd msg )
maybeAutoStart effects model =
    if model.autoStart && model.phase == PhaseIdle && isLastUser model.items then
        startRun effects model

    else
        ( { model | autoStart = False }, Cmd.none )


isLastUser : List Item -> Bool
isLastUser items =
    case List.reverse items of
        UserItem _ :: _ ->
            True

        _ ->
            False


send : Effects msg -> Model -> ( Model, Cmd msg )
send effects model =
    let
        content =
            String.trim model.draft
    in
    case model.threadId of
        Just tid ->
            if
                String.isEmpty content
                    || not (List.member model.phase [ PhaseIdle, PhaseFailed ])
                    || model.activeRun /= Nothing
                    || hasWaitingTool model.items
            then
                ( model, Cmd.none )

            else
                let
                    identifier =
                        "user-" ++ tid ++ "-" ++ String.fromInt model.nextId

                    appended =
                        { model
                            | nextId = model.nextId + 1
                            , draft = ""
                            , items = model.items ++ [ UserItem { id = identifier, content = content } ]
                            , error = Nothing
                        }
                in
                startRun effects appended

        Nothing ->
            ( model, Cmd.none )


retry : Effects msg -> Model -> ( Model, Cmd msg )
retry effects model =
    if model.phase == PhaseFailed && model.activeRun == Nothing && isLastUser model.items then
        startRun effects { model | items = dropTrailingNonUser model.items, error = Nothing }

    else
        ( model, Cmd.none )


dropTrailingNonUser : List Item -> List Item
dropTrailingNonUser items =
    case List.reverse items of
        UserItem _ :: _ ->
            items

        _ :: rest ->
            dropTrailingNonUser (List.reverse rest)

        [] ->
            []


startRun : Effects msg -> Model -> ( Model, Cmd msg )
startRun effects model =
    case model.threadId of
        Just tid ->
            let
                runId =
                    tid ++ "-" ++ effects.runStamp ++ "-run-" ++ String.fromInt model.runCounter

                started =
                    { model
                        | phase = PhaseConnecting
                        , activeRun = Just runId
                        , runCounter = model.runCounter + 1
                        , gauge = Nothing
                        , autoStart = False
                    }
            in
            ( started
            , effects.runAgent (EncodeMsg.runCommand effects.endpoint runId tid started.items)
            )

        Nothing ->
            ( model, Cmd.none )


hasWaitingTool : List Item -> Bool
hasWaitingTool items =
    List.any
        (\item ->
            case item of
                ToolItem tool ->
                    tool.name == "request_confirmation" && tool.stage == ToolWaiting

                _ ->
                    False
        )
        items


tick : Effects msg -> Model -> ( Model, Cmd msg )
tick _ model =
    ( model, Cmd.none )


applyEvent : Effects msg -> Decode.Value -> Model -> ( Model, Cmd msg )
applyEvent effects raw model =
    case DecodeMsg.eventThread raw of
        Just threadId ->
            if threadId /= Maybe.withDefault "" model.threadId then
                ( model, Cmd.none )

            else
                case DecodeMsg.agentEvent raw of
                    Ok event ->
                        applyAgentEvent effects event model

                    Err _ ->
                        ( model, Cmd.none )

        Nothing ->
            ( model, Cmd.none )


applyAgentEvent : Effects msg -> AgentEvent -> Model -> ( Model, Cmd msg )
applyAgentEvent effects event model =
    case event of
        RunStarted _ runId ->
            if model.activeRun == Just runId then
                ( { model | phase = PhaseStreaming, error = Nothing }, Cmd.none )

            else
                ( model, Cmd.none )

        RunFinished _ runId ->
            if model.activeRun == Just runId then
                ( { model | phase = PhaseIdle, activeRun = Nothing, error = Nothing }, Cmd.none )

            else
                ( model, Cmd.none )

        RunError message code ->
            ( { model | phase = PhaseFailed, activeRun = Nothing, error = Just (runErrorLabel message code) }, Cmd.none )

        RunCancelled runId ->
            if model.activeRun == Just runId then
                ( { model | phase = PhaseCanceled, activeRun = Nothing }, Cmd.none )

            else
                ( model, Cmd.none )

        StepStarted _ ->
            ( model, Cmd.none )

        StepFinished _ ->
            ( model, Cmd.none )

        TextStarted messageId ->
            ( { model | items = ensureItem (matchesId messageId) (AssistantItem { id = messageId, content = "", complete = False }) model.items }, Cmd.none )

        TextContent messageId delta ->
            let
                items =
                    ensureItem (matchesId messageId) (AssistantItem { id = messageId, content = "", complete = False }) model.items
            in
            ( { model | items = updateItem (matchesId messageId) (appendAssistantText delta) items }, Cmd.none )

        TextEnded messageId ->
            ( { model | items = updateItem (matchesId messageId) completeAssistant model.items }, Cmd.none )

        ReasoningStarted messageId ->
            ( { model | items = ensureItem (matchesId messageId) (ReasoningItem { id = messageId, content = "" }) model.items }, Cmd.none )

        ReasoningContent messageId delta ->
            let
                items =
                    ensureItem (matchesId messageId) (ReasoningItem { id = messageId, content = "" }) model.items
            in
            ( { model | items = updateItem (matchesId messageId) (appendReasoningText delta) items }, Cmd.none )

        ReasoningEnded _ ->
            ( model, Cmd.none )

        ToolStarted callId name _ ->
            ( { model
                | items =
                    ensureItem (matchesId callId)
                        (ToolItem { callId = callId, name = name, arguments = "", result = Nothing, stage = ToolStreaming, open = False })
                        model.items
              }
            , Cmd.none
            )

        ToolArgs callId delta ->
            let
                items =
                    ensureItem (matchesId callId)
                        (ToolItem { callId = callId, name = "unknown_tool", arguments = "", result = Nothing, stage = ToolStreaming, open = False })
                        model.items
            in
            ( { model | items = updateItem (matchesId callId) (appendToolArgs delta) items }, Cmd.none )

        ToolEnded callId ->
            let
                waiting =
                    toolNameOf callId model.items == Just "request_confirmation"
            in
            ( { model
                | items =
                    updateItem (matchesId callId)
                        (\item ->
                            case item of
                                ToolItem tool ->
                                    ToolItem { tool | stage = if waiting then ToolWaiting else ToolStreaming }

                                other ->
                                    other
                        )
                        model.items
                , phase = if waiting then PhaseAwaiting else model.phase
              }
            , Cmd.none
            )

        ToolResult callId _ content ->
            ( { model
                | items =
                    updateItem (matchesId callId)
                        (\item ->
                            case item of
                                ToolItem tool ->
                                    ToolItem { tool | stage = ToolDone, result = Just (limit 20000 content) }

                                other ->
                                    other
                        )
                        model.items
              }
            , Cmd.none
            )

        Custom name value ->
            applyCustom name value model

        Ignored ->
            ( model, Cmd.none )


applyCustom : String -> Decode.Value -> Model -> ( Model, Cmd msg )
applyCustom name value model =
    case name of
        "context.status" ->
            case Decode.decodeValue gaugeDecoder value of
                Ok gauge ->
                    ( { model | gauge = Just gauge }, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        "agent.sub" ->
            applySub value model

        "provider.retry" ->
            case Decode.decodeValue retryDecoder value of
                Ok ( attempt, maxAttempts, reason ) ->
                    note
                        ("模型服务重试 " ++ String.fromInt attempt ++ "/" ++ String.fromInt maxAttempts ++ " · " ++ compact reason)
                        NoteWarn
                        model

                Err _ ->
                    ( model, Cmd.none )

        "context.compact" ->
            case Decode.decodeValue compactDecoder value of
                Ok ( before, after ) ->
                    note
                        ("工作记忆已整理 · " ++ String.fromInt before ++ " → " ++ String.fromInt after ++ " tokens")
                        NoteInfo
                        model

                Err _ ->
                    ( model, Cmd.none )

        "run.cancelled" ->
            ( { model | phase = PhaseCanceled, activeRun = Nothing }, Cmd.none )

        _ ->
            ( model, Cmd.none )


applySub : Decode.Value -> Model -> ( Model, Cmd msg )
applySub value model =
    case
        ( Decode.decodeValue (Decode.field "callId" Decode.string) value |> Result.toMaybe
        , Decode.decodeValue (Decode.field "event" Decode.value) value |> Result.toMaybe
        )
    of
        ( Just callId, Just nested ) ->
            let
                items =
                    ensureItem (matchesId callId)
                        (SubItem { callId = callId, content = "", status = "运行中", failed = False, error = Nothing, activity = [], context = Nothing, open = False })
                        model.items
            in
            ( { model | items = updateItem (matchesId callId) (applySubEvent nested) items }, Cmd.none )

        _ ->
            ( model, Cmd.none )


applySubEvent : Decode.Value -> Item -> Item
applySubEvent nested item =
    case item of
        SubItem sub ->
            case Decode.decodeValue (Decode.field "type" Decode.string) nested |> Result.toMaybe of
                Just "TEXT_MESSAGE_CONTENT" ->
                    SubItem { sub | content = sub.content ++ fieldString "delta" nested, status = "正在汇报" }

                Just "RUN_ERROR" ->
                    SubItem { sub | failed = True, error = Just (fieldString "message" nested), status = "失败" }

                Just "RUN_STARTED" ->
                    SubItem { sub | status = "运行中" }

                Just "RUN_FINISHED" ->
                    SubItem { sub | status = "完成" }

                Just "STEP_STARTED" ->
                    SubItem { sub | activity = pushActivity ("阶段 · " ++ fieldString "stepName" nested) sub.activity }

                Just "TOOL_CALL_START" ->
                    SubItem { sub | activity = pushActivity ("调用 · " ++ fieldString "toolCallName" nested) sub.activity }

                Just "CUSTOM" ->
                    case Decode.decodeValue (Decode.field "name" Decode.string) nested |> Result.toMaybe of
                        Just "context.status" ->
                            SubItem { sub | context = Decode.decodeValue (Decode.at [ "value" ] gaugeDecoder) nested |> Result.toMaybe }

                        Just "provider.retry" ->
                            SubItem
                                { sub
                                    | activity =
                                        pushActivity
                                            ("模型服务重试 "
                                                ++ String.fromInt (Decode.decodeValue (Decode.at [ "value", "attempt" ] Decode.int) nested |> Result.withDefault 0)
                                                ++ "/"
                                                ++ String.fromInt (Decode.decodeValue (Decode.at [ "value", "maxAttempts" ] Decode.int) nested |> Result.withDefault 0)
                                            )
                                            sub.activity
                                }

                        Just "context.compact" ->
                            SubItem
                                { sub
                                    | activity =
                                        pushActivity
                                            ("工作记忆整理 "
                                                ++ String.fromInt (Decode.decodeValue (Decode.at [ "value", "beforeTokens" ] Decode.int) nested |> Result.withDefault 0)
                                                ++ " → "
                                                ++ String.fromInt (Decode.decodeValue (Decode.at [ "value", "afterTokens" ] Decode.int) nested |> Result.withDefault 0)
                                            )
                                            sub.activity
                                }

                        _ ->
                            item

                _ ->
                    item

        _ ->
            item


applyTransport : Decode.Value -> Model -> ( Model, Cmd msg )
applyTransport raw model =
    case
        ( Decode.decodeValue (Decode.field "kind" Decode.string) raw |> Result.toMaybe
        , Decode.decodeValue (Decode.field "runId" Decode.string) raw |> Result.toMaybe
        )
    of
        ( Just kind, Just runId ) ->
            if model.activeRun == Just runId then
                case kind of
                    "connecting" ->
                        ( { model | phase = PhaseConnecting }, Cmd.none )

                    "open" ->
                        ( { model | phase = PhaseStreaming }, Cmd.none )

                    "closed" ->
                        ( { model | phase = PhaseIdle, activeRun = Nothing }, Cmd.none )

                    "cancelled" ->
                        ( { model | phase = PhaseCanceled, activeRun = Nothing }, Cmd.none )

                    "error" ->
                        ( { model
                            | phase = PhaseFailed
                            , activeRun = Nothing
                            , error = Just (Decode.decodeValue (Decode.field "message" Decode.string) raw |> Result.withDefault "连接中断")
                          }
                        , Cmd.none
                        )

                    _ ->
                        ( model, Cmd.none )

            else
                ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


gaugeDecoder : Decode.Decoder Gauge
gaugeDecoder =
    Decode.map4 Gauge
        (Decode.field "tokens" Decode.int)
        (Decode.field "budgetTokens" Decode.int)
        (Decode.field "willCompact" Decode.bool)
        (Decode.field "emergency" Decode.bool)


retryDecoder : Decode.Decoder ( Int, Int, String )
retryDecoder =
    Decode.map3 (\attempt maxAttempts reason -> ( attempt, maxAttempts, reason ))
        (Decode.field "attempt" Decode.int)
        (Decode.field "maxAttempts" Decode.int)
        (Decode.field "reason" Decode.string)


compactDecoder : Decode.Decoder ( Int, Int )
compactDecoder =
    Decode.map2 Tuple.pair
        (Decode.field "beforeTokens" Decode.int)
        (Decode.field "afterTokens" Decode.int)


fieldString : String -> Decode.Value -> String
fieldString field value =
    Decode.decodeValue (Decode.field field Decode.string) value |> Result.withDefault ""


pushActivity : String -> List String -> List String
pushActivity item activity =
    List.take 8 (item :: List.filter ((/=) item) activity)


note : String -> NoteKind -> Model -> ( Model, Cmd msg )
note text kind model =
    ( { model
        | nextId = model.nextId + 1
        , items = model.items ++ [ NoteItem { id = "note-" ++ String.fromInt model.nextId, text = text, kind = kind } ]
      }
    , Cmd.none
    )


runErrorLabel : String -> Maybe String -> String
runErrorLabel message code =
    case code of
        Just "MAX_TURNS_EXCEEDED" ->
            "运行已停在本机轮次上限。\n" ++ message

        Just "PROVIDER_ERROR" ->
            "模型服务没有完成这次回应。\n" ++ message

        Just "PERSISTENCE_ERROR" ->
            "回应已经发生，但未能完整保存。\n" ++ message

        _ ->
            "运行没有完成。\n" ++ message


compact : String -> String
compact text =
    String.join " " (String.words text) |> limit 160


limit : Int -> String -> String
limit length text =
    if String.length text > length then
        String.left length text ++ "…"

    else
        text


failureMessage : Int -> Decode.Value -> String
failureMessage status body =
    case Decode.decodeValue (Decode.field "error" Decode.string) body of
        Ok message ->
            message

        Err _ ->
            case Decode.decodeValue Decode.string body of
                Ok message ->
                    message

                Err _ ->
                    "请求失败（HTTP " ++ String.fromInt status ++ "）"


appendAssistantText : String -> Item -> Item
appendAssistantText delta item =
    case item of
        AssistantItem assistant ->
            AssistantItem { assistant | content = assistant.content ++ delta }

        other ->
            other


completeAssistant : Item -> Item
completeAssistant item =
    case item of
        AssistantItem assistant ->
            AssistantItem { assistant | complete = True }

        other ->
            other


appendReasoningText : String -> Item -> Item
appendReasoningText delta item =
    case item of
        ReasoningItem reasoning ->
            ReasoningItem { reasoning | content = reasoning.content ++ delta }

        other ->
            other


appendToolArgs : String -> Item -> Item
appendToolArgs delta item =
    case item of
        ToolItem tool ->
            ToolItem { tool | arguments = tool.arguments ++ delta }

        other ->
            other


toolNameOf : String -> List Item -> Maybe String
toolNameOf callId items =
    List.filterMap asTool items
        |> List.filter (\tool -> tool.callId == callId)
        |> List.head
        |> Maybe.map .name


asTool : Item -> Maybe ToolState
asTool item =
    case item of
        ToolItem tool ->
            Just tool

        _ ->
            Nothing


matchesId : String -> Item -> Bool
matchesId identifier item =
    case item of
        UserItem message ->
            message.id == identifier

        AssistantItem message ->
            message.id == identifier

        ReasoningItem message ->
            message.id == identifier

        ToolItem tool ->
            tool.callId == identifier

        ToolResultItem result ->
            result.id == identifier

        SubItem sub ->
            sub.callId == identifier

        NoteItem noteItem ->
            noteItem.id == identifier


ensureItem : (Item -> Bool) -> Item -> List Item -> List Item
ensureItem matches defaultItem items =
    if List.any matches items then
        items

    else
        items ++ [ defaultItem ]


updateItem : (Item -> Bool) -> (Item -> Item) -> List Item -> List Item
updateItem matches transform items =
    List.map
        (\item ->
            if matches item then
                transform item

            else
                item
        )
        items
