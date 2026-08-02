module Yuki.Run.Monitor exposing (Effects, Model, Msg(..), init, update, view)

import Dict exposing (Dict)
import Html exposing (..)
import Html.Attributes exposing (class, classList, href)
import Json.Decode as Decode
import Json.Encode as Encode
import Time exposing (Posix)
import Yuki.Changes.Decode exposing (fsChangePageDecoder)
import Yuki.Delivery.Decode exposing (deliveryPageDecoder)
import Yuki.Run.StatusCard as StatusCard
import Yuki.Telemetry.State exposing (TelemetryState)
import Yuki.Telemetry.Types exposing (..)
import Yuki.Workbench.Format as Format


type alias Effects msg =
    { endpoint : String
    , inspect : Encode.Value -> Cmd msg
    , telemetry : TelemetryState
    }


type alias RunSummary =
    { runId : String
    , threadId : String
    , turns : Int
    , toolCalls : Int
    , apiRequests : Int
    , memoryCalls : Int
    , status : String
    , usage : Maybe ( Int, Int )
    , firstTime : Maybe Int
    , lastTime : Maybe Int
    }


type alias Model =
    { yuki : Maybe String
    , runId : Maybe String
    , summary : Maybe RunSummary
    , summaryPending : Bool
    , summaryError : Maybe String
    , deliveries : List DeliveryRecord
    , deliveriesPending : Bool
    , changes : List FsChangeRecord
    , changesPending : Bool
    , error : Maybe String
    }


init : Model
init =
    { yuki = Nothing
    , runId = Nothing
    , summary = Nothing
    , summaryPending = False
    , summaryError = Nothing
    , deliveries = []
    , deliveriesPending = False
    , changes = []
    , changesPending = False
    , error = Nothing
    }


type Msg
    = Enter String String
    | ActivityChanged String String
    | Result String Int Decode.Value
    | Card StatusCard.Msg


update : Effects msg -> Msg -> Model -> ( Model, Cmd msg )
update effects msg model =
    case msg of
        Enter yuki runId ->
            let
                fresh =
                    model.yuki /= Just yuki || model.runId /= Just runId

                retry =
                    model.summaryError /= Nothing || model.error /= Nothing
            in
            if not fresh && not retry && not (busy model) then
                ( model, Cmd.none )

            else
                fetch effects yuki runId
                    (if fresh then
                        { model | yuki = Just yuki, runId = Just runId, deliveries = [], changes = [], error = Nothing }

                     else
                        model
                    )

        ActivityChanged yuki runId ->
            if model.yuki == Just yuki && model.runId == Just runId && not (busy model) then
                fetch effects yuki runId model

            else
                ( model, Cmd.none )

        Result kind status body ->
            handleResult effects kind status body model

        Card _ ->
            ( model, Cmd.none )


busy : Model -> Bool
busy model =
    model.summaryPending || model.deliveriesPending || model.changesPending


fetch : Effects msg -> String -> String -> Model -> ( Model, Cmd msg )
fetch effects yuki runId model =
    case Dict.get runId effects.telemetry.runs of
        Just run ->
            fetchSections effects yuki runId (Just run.threadId) { model | summary = Nothing, summaryPending = False, summaryError = Nothing }

        Nothing ->
            ( { model | summary = Nothing, summaryPending = True, summaryError = Nothing }
            , effects.inspect (request ("summary/" ++ runId) "GET" ("/journal/runs/" ++ runId ++ "/summary") Nothing effects.endpoint)
            )


fetchSections : Effects msg -> String -> String -> Maybe String -> Model -> ( Model, Cmd msg )
fetchSections effects yuki runId maybeThread model =
    ( { model | deliveriesPending = True, changesPending = True, summaryPending = False }
    , Cmd.batch
        [ effects.inspect (request "monitor/deliveries" "GET" ("/incarnations/" ++ yuki ++ "/deliveries?limit=50" ++ threadQuery maybeThread) Nothing effects.endpoint)
        , effects.inspect (request "monitor/changes" "GET" ("/incarnations/" ++ yuki ++ "/fs-changes?runId=" ++ runId ++ "&limit=50" ++ threadQuery maybeThread) Nothing effects.endpoint)
        ]
    )


threadQuery : Maybe String -> String
threadQuery maybeThread =
    case maybeThread of
        Just tid ->
            "&threadId=" ++ tid

        Nothing ->
            ""


handleResult : Effects msg -> String -> Int -> Decode.Value -> Model -> ( Model, Cmd msg )
handleResult effects kind status body model =
    case String.split "/" kind of
        "summary" :: _ ->
            if status >= 400 then
                ( { model | summaryPending = False, summaryError = Just (failureMessage status body) }, Cmd.none )

            else
                case Decode.decodeValue summaryDecoder body of
                    Ok summary ->
                        let
                            yuki =
                                Maybe.withDefault "" model.yuki
                        in
                        fetchSections effects yuki summary.runId (Just summary.threadId)
                            { model | summary = Just summary, summaryPending = False, summaryError = Nothing }

                    Err message ->
                        ( { model | summaryPending = False, summaryError = Just (Decode.errorToString message) }, Cmd.none )

        "monitor" :: rest ->
            case rest of
                "deliveries" :: _ ->
                    if status >= 400 then
                        ( { model | deliveriesPending = False, error = Just (failureMessage status body) }, Cmd.none )

                    else
                        case Decode.decodeValue deliveryPageDecoder body of
                            Ok page ->
                                let
                                    runId =
                                        Maybe.withDefault "" model.runId
                                in
                                ( { model
                                    | deliveries = List.filter (\record -> record.runId == runId) page.items
                                    , deliveriesPending = False
                                    , error = Nothing
                                  }
                                , Cmd.none
                                )

                            Err message ->
                                ( { model | deliveriesPending = False, error = Just (Decode.errorToString message) }, Cmd.none )

                "changes" :: _ ->
                    if status >= 400 then
                        ( { model | changesPending = False, error = Just (failureMessage status body) }, Cmd.none )

                    else
                        case Decode.decodeValue fsChangePageDecoder body of
                            Ok page ->
                                ( { model | changes = page.items, changesPending = False, error = Nothing }, Cmd.none )

                            Err message ->
                                ( { model | changesPending = False, error = Just (Decode.errorToString message) }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


summaryDecoder : Decode.Decoder RunSummary
summaryDecoder =
    Decode.succeed RunSummary
        |> decodeAndMap (Decode.field "runId" Decode.string)
        |> decodeAndMap (Decode.field "threadId" Decode.string)
        |> decodeAndMap (Decode.field "turns" Decode.int)
        |> decodeAndMap (Decode.field "toolCalls" Decode.int)
        |> decodeAndMap (Decode.field "apiRequests" Decode.int)
        |> decodeAndMap (Decode.field "memoryCalls" Decode.int)
        |> decodeAndMap (Decode.field "status" Decode.string)
        |> decodeAndMap (Decode.maybe usageDecoder)
        |> decodeAndMap (Decode.field "firstTime" (Decode.maybe Decode.int))
        |> decodeAndMap (Decode.field "lastTime" (Decode.maybe Decode.int))


usageDecoder : Decode.Decoder ( Int, Int )
usageDecoder =
    Decode.map2 Tuple.pair
        (Decode.field "prompt" Decode.int)
        (Decode.field "completion" Decode.int)


decodeAndMap : Decode.Decoder a -> Decode.Decoder (a -> b) -> Decode.Decoder b
decodeAndMap value build =
    Decode.map2 (<|) build value


view : TelemetryState -> StatusCard.Config -> Model -> String -> String -> Html Msg
view telemetry cfg model yuki runId =
    div [ class "run-monitor" ]
        [ div [ class "run-monitor-head" ]
            [ a [ class "rsc-action run-back", href ("/yuki/" ++ yuki ++ "/now") ] [ text "← 返回现在视图" ]
            ]
        , case Dict.get runId telemetry.runs of
            Just run ->
                Html.map Card (StatusCard.view { cfg | wide = True } run)

            Nothing ->
                historicalSection cfg.now model
        , workerSection telemetry yuki runId
        , monitorDeliveriesSection cfg.now model yuki
        , monitorChangesSection cfg.now model yuki
        , errorNote model
        ]


historicalSection : Posix -> Model -> Html Msg
historicalSection now model =
    section [ class "wb-section" ]
        [ h2 [ class "wb-section-title" ] [ text "已结束" ]
        , case model.summary of
            Just summary ->
                summaryCard now summary

            Nothing ->
                div [ class "now-empty" ]
                    [ text (if model.summaryPending then "正在读取运行摘要…" else "该 Run 没有摘要记录") ]
        , case model.summaryError of
            Just message ->
                div [ class "wb-note-error" ] [ text ("摘要加载失败：" ++ message) ]

            Nothing ->
                text ""
        ]


summaryCard : Posix -> RunSummary -> Html Msg
summaryCard now summary =
    div [ class "run-summary" ]
        [ div [ class "run-summary-grid" ]
            [ summaryCell "状态" summary.status
            , summaryCell "轮次" (String.fromInt summary.turns)
            , summaryCell "工具调用" (String.fromInt summary.toolCalls)
            , summaryCell "API 请求" (String.fromInt summary.apiRequests)
            , summaryCell "记忆调用" (String.fromInt summary.memoryCalls)
            , summaryCell "输入 tokens" (Format.formatTokens (usagePrompt summary.usage))
            , summaryCell "输出 tokens" (Format.formatTokens (usageCompletion summary.usage))
            ]
        , case duration summary of
            Just seconds ->
                div [ class "run-summary-duration" ] [ text ("时长 " ++ Format.formatDuration seconds) ]

            Nothing ->
                text ""
        ]


summaryCell : String -> String -> Html Msg
summaryCell label value =
    div [ class "run-summary-cell" ]
        [ span [ class "run-summary-label" ] [ text label ]
        , span [ class "run-summary-value" ] [ text value ]
        ]


usagePrompt : Maybe ( Int, Int ) -> Int
usagePrompt usage =
    Maybe.map Tuple.first usage |> Maybe.withDefault 0


usageCompletion : Maybe ( Int, Int ) -> Int
usageCompletion usage =
    Maybe.map Tuple.second usage |> Maybe.withDefault 0


duration : RunSummary -> Maybe Int
duration summary =
    case ( summary.firstTime, summary.lastTime ) of
        ( Just first, Just last ) ->
            Just (max 0 (last - first))

        _ ->
            Nothing


workerSection : TelemetryState -> String -> String -> Html Msg
workerSection telemetry yuki runId =
    let
        workers =
            childrenOf runId (runsForIncarnation yuki telemetry)
    in
    if List.isEmpty workers then
        text ""

    else
        section [ class "wb-section" ]
            [ h2 [ class "wb-section-title" ] [ text "Worker 子树" ]
            , div [ class "monitor-workers" ] (List.map (workerNode telemetry yuki) workers)
            ]


workerNode : TelemetryState -> String -> LiveStatus -> Html Msg
workerNode telemetry yuki run =
    let
        children =
            childrenOf run.runId (runsForIncarnation yuki telemetry)
    in
    div [ class "worker-node" ]
        [ div [ class "worker-row" ]
            [ span [ class "rsc-kind" ] [ text "Worker" ]
            , span [ class "worker-objective" ] [ text (Maybe.withDefault "…" run.objective) ]
            , phaseBadge run.phase
            , a [ class "worker-link", href ("/yuki/" ++ yuki ++ "/run/" ++ run.runId) ] [ text "监控 ↗" ]
            ]
        , if List.isEmpty children then
            text ""

          else
            div [ class "run-children" ] (List.map (workerNode telemetry yuki) children)
        ]


runsForIncarnation : String -> TelemetryState -> List LiveStatus
runsForIncarnation yuki telemetry =
    Dict.values telemetry.runs
        |> List.filter (\run -> run.incarnationId == yuki)


childrenOf : String -> List LiveStatus -> List LiveStatus
childrenOf runId runs =
    runs
        |> List.filter (\run -> run.parentRunId == Just runId)
        |> List.sortBy .startedAt


phaseBadge : RunPhase -> Html Msg
phaseBadge phase =
    span
        [ class "phase-badge"
        , classList
            [ ( "phase-running", phase == PhaseRunning )
            , ( "phase-awaiting", phase == PhaseAwaitingTool )
            , ( "phase-compacting", phase == PhaseCompacting )
            , ( "phase-sleeping", phase == PhaseSleeping )
            , ( "phase-cancelling", phase == PhaseCancelling )
            ]
        ]
        [ text (phaseLabel phase) ]


phaseLabel : RunPhase -> String
phaseLabel phase =
    case phase of
        PhaseRunning ->
            "运行"

        PhaseAwaitingTool ->
            "等待工具"

        PhaseCompacting ->
            "压缩上下文"

        PhaseSleeping ->
            "睡眠"

        PhaseCancelling ->
            "取消中"


monitorDeliveriesSection : Posix -> Model -> String -> Html Msg
monitorDeliveriesSection now model yuki =
    section [ class "wb-section" ]
        [ h2 [ class "wb-section-title" ] [ text "交付" ]
        , if List.isEmpty model.deliveries then
            div [ class "now-empty" ]
                [ text (if model.deliveriesPending then "加载中…" else "该 Run 暂无交付") ]

          else
            div [ class "delivery-list" ] (List.map (monitorDeliveryRow now yuki) model.deliveries)
        ]


monitorDeliveryRow : Posix -> String -> DeliveryRecord -> Html Msg
monitorDeliveryRow now yuki record =
    div [ class "delivery-row" ]
        [ span [ class "delivery-kind" ] [ text (kindLabel record.kind) ]
        , span [ class "delivery-title" ] [ text record.title ]
        , a [ class "delivery-thread", href ("/yuki/" ++ yuki ++ "/chat/" ++ record.threadId) ] [ text "对话" ]
        , span [ class "delivery-time" ] [ text (relativeTime now record.at) ]
        ]


monitorChangesSection : Posix -> Model -> String -> Html Msg
monitorChangesSection now model yuki =
    section [ class "wb-section" ]
        [ h2 [ class "wb-section-title" ] [ text "变更" ]
        , if List.isEmpty model.changes then
            div [ class "now-empty" ]
                [ text (if model.changesPending then "加载中…" else "该 Run 暂无变更") ]

          else
            div [ class "change-list" ] (List.map (monitorChangeRow now yuki) model.changes)
        ]


monitorChangeRow : Posix -> String -> FsChangeRecord -> Html Msg
monitorChangeRow now yuki record =
    div [ class "change-row" ]
        [ span [ class "badge op-badge", classList [ ( "op-created", record.op == "created" ), ( "op-modified", record.op == "modified" ), ( "op-deleted", record.op == "deleted" ) ] ]
            [ text (opLabel record.op) ]
        , span [ class "change-path" ] [ text record.path ]
        , span [ class "badge origin-badge origin-tool" ] [ text (originLabel record.origin) ]
        , a [ class "delivery-thread", href ("/yuki/" ++ yuki ++ "/chat/" ++ record.threadId) ] [ text "对话" ]
        , span [ class "change-time" ] [ text (relativeTime now record.at) ]
        ]


originLabel : FsOrigin -> String
originLabel origin =
    case origin of
        OriginTool name _ ->
            name

        OriginGit ->
            "git"


kindLabel : String -> String
kindLabel kind =
    case kind of
        "file_write" ->
            "文件"

        "artifact" ->
            "artifact"

        _ ->
            "答案"


opLabel : String -> String
opLabel op =
    case op of
        "created" ->
            "已创建"

        "modified" ->
            "已修改"

        "deleted" ->
            "已删除"

        _ ->
            op


errorNote : Model -> Html Msg
errorNote model =
    case model.error of
        Just message ->
            div [ class "wb-note-error" ] [ text ("加载失败：" ++ message) ]

        Nothing ->
            text ""


relativeTime : Posix -> Int -> String
relativeTime now stampSeconds =
    Format.formatRelative (Format.elapsedSeconds now stampSeconds)


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


request : String -> String -> String -> Maybe Encode.Value -> String -> Encode.Value
request kind method path body endpoint =
    Encode.object
        ([ ( "kind", Encode.string kind )
         , ( "method", Encode.string method )
         , ( "path", Encode.string path )
         , ( "endpoint", Encode.string endpoint )
         ]
            ++ (case body of
                    Just value ->
                        [ ( "body", value ) ]

                    Nothing ->
                        []
               )
        )
