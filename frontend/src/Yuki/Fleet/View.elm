module Yuki.Fleet.View exposing (view)

import Dict
import Html exposing (..)
import Html.Attributes exposing (class, classList, disabled, href, id, placeholder, rows, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit, stopPropagationOn)
import Json.Decode as Decode
import Yuki.Fleet.State as State
import Yuki.Telemetry.State exposing (TelemetryState)
import Yuki.Telemetry.Types exposing (..)


view : TelemetryState -> State.Model -> Html State.Msg
view telemetry model =
    div [ class "fleet" ]
        [ div [ class "fleet-head" ]
            [ h1 [ class "fleet-title" ] [ text "集群总览" ]
            , button [ class "fleet-new", onClick State.OpenCreate ] [ text "+ 新 Yuki" ]
            ]
        , if List.isEmpty telemetry.fleet then
            div [ class "fleet-empty" ]
                [ span [ class "fleet-empty-text" ] [ text "还没有 Yuki。创建第一位 Yuki 开始。" ]
                , button [ class "fleet-new", onClick State.OpenCreate ] [ text "+ 新 Yuki" ]
                ]

          else
            div [ class "fleet-grid" ] (List.map (card telemetry) (sorted telemetry.fleet))
        , dialog model
        ]


sorted : List FleetEntry -> List FleetEntry
sorted entries =
    List.sortWith order entries


order : FleetEntry -> FleetEntry -> Order
order left right =
    case compare (rank left.state) (rank right.state) of
        EQ ->
            compare (Maybe.withDefault 0 right.lastDeliveryAt) (Maybe.withDefault 0 left.lastDeliveryAt)

        other ->
            other


rank : String -> number
rank state =
    case state of
        "active" ->
            0

        "waiting" ->
            1

        _ ->
            2


card : TelemetryState -> FleetEntry -> Html State.Msg
card telemetry entry =
    let
        runs =
            Dict.values telemetry.runs
                |> List.filter (\run -> run.incarnationId == entry.id)

        headline =
            runs
                |> List.sortBy .startedAt
                |> List.head
    in
    a [ class "yuki-card", classList [ ( "is-active", entry.state == "active" ), ( "is-waiting", entry.state == "waiting" ) ], href ("/yuki/" ++ entry.id ++ "/now") ]
        [ div [ class "yuki-card-head" ]
            [ span [ class "yuki-name" ] [ text entry.name ]
            , stateBadge entry.state
            ]
        , div [ class "yuki-card-body" ]
            [ case headline of
                Just run ->
                    div [ class "yuki-headline" ]
                        [ span [ class "phase-badge" ] [ text (phaseLabel run.phase) ]
                        , span [ class "objective" ] [ text (Maybe.withDefault "…" run.objective) ]
                        ]

                Nothing ->
                    div [ class "yuki-headline yuki-idle" ] [ text "空闲" ]
            , div [ class "yuki-stats" ]
                [ text (String.fromInt entry.activeRuns ++ " 运行 · " ++ String.fromInt (totalWorkers runs) ++ " Worker") ]
            , if entry.waitingDrafts > 0 then
                div [ class "yuki-waiting" ] [ text ("⚠ " ++ String.fromInt entry.waitingDrafts ++ " 份派发草案待确认") ]

              else
                text ""
            ]
        ]


totalWorkers : List LiveStatus -> Int
totalWorkers runs =
    List.sum (List.map .workers runs)


stateBadge : String -> Html State.Msg
stateBadge state =
    span [ class "state-badge", classList [ ( "state-active", state == "active" ), ( "state-waiting", state == "waiting" ) ] ]
        [ text
            (case state of
                "active" ->
                    "活跃"

                "waiting" ->
                    "等待"

                _ ->
                    "空闲"
            )
        ]


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


dialog : State.Model -> Html State.Msg
dialog model =
    case model.dialog of
        Nothing ->
            text ""

        Just createForm ->
            div [ class "draft-dialog-backdrop", id "yuki-create-backdrop", backdropClose State.Close ]
                [ div [ class "draft-dialog" ]
                    [ div [ class "draft-dialog-head" ]
                        [ span [ class "draft-dialog-title" ] [ text "创建新 Yuki" ]
                        , button [ class "draft-dialog-close", onClick State.Close ] [ text "×" ]
                        ]
                    , form [ onSubmit State.Submit ]
                        [ div [ class "draft-field" ]
                            [ label [] [ text "id" ]
                            , input
                                [ class "draft-input"
                                , type_ "text"
                                , placeholder "例如 yuki-assistant"
                                , value createForm.id
                                , disabled createForm.submitting
                                , onInput State.IdChanged
                                ]
                                []
                            , span [ class "draft-helper" ] [ text "小写字母开头，可含数字与连字符" ]
                            ]
                        , div [ class "draft-field" ]
                            [ label [] [ text "名称" ]
                            , input
                                [ class "draft-input"
                                , type_ "text"
                                , placeholder "这位 Yuki 的名字"
                                , value createForm.name
                                , disabled createForm.submitting
                                , onInput State.NameChanged
                                ]
                                []
                            ]
                        , div [ class "draft-field" ]
                            [ label [] [ text "方向" ]
                            , textarea
                                [ class "draft-textarea"
                                , rows 6
                                , placeholder "描述这位 Yuki 的人格方向"
                                , value createForm.direction
                                , disabled createForm.submitting
                                , onInput State.DirectionChanged
                                ]
                                []
                            ]
                        , div [ class "draft-field" ]
                            [ label [] [ text "印象模型（可选）" ]
                            , input
                                [ class "draft-input"
                                , type_ "text"
                                , value createForm.impressionModel
                                , disabled createForm.submitting
                                , onInput State.ImpressionChanged
                                ]
                                []
                            ]
                        , case createForm.error of
                            Just message ->
                                div [ class "draft-error" ] [ text message ]

                            Nothing ->
                                text ""
                        , div [ class "draft-dialog-actions" ]
                            [ button
                                [ class "draft-action draft-action-primary"
                                , disabled (createForm.submitting || not (fillable createForm))
                                ]
                                [ text (if createForm.submitting then "创建中…" else "创建") ]
                            , button [ class "draft-action", type_ "button", onClick State.Close ] [ text "取消" ]
                            ]
                        ]
                    ]
                ]


fillable : State.CreateForm -> Bool
fillable form =
    not (String.isEmpty (String.trim form.id))
        && not (String.isEmpty (String.trim form.name))
        && not (String.isEmpty (String.trim form.direction))


backdropClose : msg -> Html.Attribute msg
backdropClose msg =
    stopPropagationOn "click"
        (Decode.field "target" (Decode.field "id" Decode.string)
            |> Decode.andThen
                (\id ->
                    if id == "yuki-create-backdrop" then
                        Decode.succeed ( msg, True )

                    else
                        Decode.fail "clicked inside dialog"
                )
        )
