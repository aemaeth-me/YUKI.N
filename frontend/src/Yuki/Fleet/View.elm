module Yuki.Fleet.View exposing (view)

import Dict
import Html exposing (..)
import Html.Attributes exposing (class, classList, href)
import Yuki.Telemetry.State exposing (TelemetryState)
import Yuki.Telemetry.Types exposing (..)


view : TelemetryState -> Html msg
view telemetry =
    div [ class "fleet" ]
        [ h1 [ class "fleet-title" ] [ text "集群总览" ]
        , if List.isEmpty telemetry.fleet then
            div [ class "fleet-empty" ] [ text "还没有 Yuki。创建第一位 Yuki 开始。" ]

          else
            div [ class "fleet-grid" ] (List.map (card telemetry) (sorted telemetry.fleet))
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


card : TelemetryState -> FleetEntry -> Html msg
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


stateBadge : String -> Html msg
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
