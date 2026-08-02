module Yuki.Run.StatusCard exposing (Config, Msg(..), view)

import Dict exposing (Dict)
import Html exposing (..)
import Html.Attributes exposing (class, classList, href, placeholder, style, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Time exposing (Posix)
import Yuki.Telemetry.Types exposing (..)
import Yuki.Workbench.Format as Format


type Msg
    = SteerInput RunId String
    | SteerToggle RunId
    | SteerSubmit RunId
    | CancelArm RunId
    | CancelConfirm RunId


type alias Config =
    { yuki : String
    , now : Posix
    , wide : Bool
    , steerOpen : Dict RunId Bool
    , steerText : Dict RunId String
    , confirmCancel : Dict RunId Bool
    , actionStatus : Dict RunId String
    }


view : Config -> LiveStatus -> Html Msg
view cfg run =
    article [ class "run-status-card", classList [ ( "run-status-wide", cfg.wide ), ( "run-status-worker", run.kind == RunWorker ) ] ]
        [ div [ class "rsc-head" ]
            [ span [ class "rsc-kind" ] [ text (kindLabel run.kind) ]
            , div [ class "rsc-objective" ] [ text (Maybe.withDefault "…" run.objective) ]
            , phaseBadge run.phase
            ]
        , div [ class "rsc-meta" ]
            [ span [] [ text ("轮次 " ++ String.fromInt run.turn ++ "/" ++ String.fromInt run.maxTurns) ]
            , span [ class "rsc-model" ] [ text run.model ]
            , if run.usagePrompt + run.usageCompletion > 0 then
                span [ class "rsc-usage" ] [ text ("↑ " ++ Format.formatTokens run.usagePrompt ++ " ↓ " ++ Format.formatTokens run.usageCompletion) ]

              else
                text ""
            ]
        , contextBar run.context
        , toolsRow cfg.now run.activeTools
        , div [ class "rsc-stats" ]
            [ span [] [ text ("已耗时 " ++ Format.formatDuration (Format.elapsedSeconds cfg.now run.startedAt)) ]
            , if run.workers > 0 then
                span [] [ text ("Worker ×" ++ String.fromInt run.workers) ]

              else
                text ""
            , span [] [ text ("最近活动：" ++ Maybe.withDefault "—" run.lastActivity) ]
            ]
        , actionsRow cfg run
        ]


kindLabel : RunKind -> String
kindLabel kind =
    case kind of
        RunHome ->
            "主对话"

        RunTask ->
            "任务"

        RunWorker ->
            "Worker"


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


contextBar : Maybe ContextSnapshot -> Html Msg
contextBar context =
    case context of
        Nothing ->
            text ""

        Just snapshot ->
            let
                percent =
                    clamp 0 100 (round ((toFloat snapshot.estimatedTokens / toFloat (max 1 snapshot.budgetTokens)) * 100))
            in
            div [ class "rsc-context" ]
                [ div [ class "rsc-context-track" ]
                    [ div [ class "rsc-context-fill", style "width" (String.fromInt percent ++ "%") ] [] ]
                , span [ class "rsc-context-label" ] [ text (String.fromInt percent ++ "%") ]
                ]


toolsRow : Posix -> List ActiveTool -> Html Msg
toolsRow now tools =
    if List.isEmpty tools then
        text ""

    else
        div [ class "rsc-tools" ] (List.map (toolChip now) tools)


toolChip : Posix -> ActiveTool -> Html Msg
toolChip now tool =
    span [ class "rsc-tool" ]
        [ span [ class "rsc-tool-dot" ] []
        , text (tool.name ++ "（" ++ Format.formatDuration (Format.elapsedSeconds now tool.startedAt) ++ "）")
        ]


actionsRow : Config -> LiveStatus -> Html Msg
actionsRow cfg run =
    div [ class "rsc-actions" ]
        [ a [ class "rsc-action rsc-action-monitor", href ("/yuki/" ++ cfg.yuki ++ "/run/" ++ run.runId) ] [ text "监控" ]
        , if Dict.get run.runId cfg.steerOpen == Just True then
            steerForm cfg run

          else
            button [ class "rsc-action", onClick (SteerToggle run.runId) ] [ text "steer" ]
        , cancelButton cfg run
        , statusNote cfg run
        ]


steerForm : Config -> LiveStatus -> Html Msg
steerForm cfg run =
    form [ class "rsc-steer", onSubmit (SteerSubmit run.runId) ]
        [ input
            [ class "rsc-steer-input"
            , type_ "text"
            , placeholder "输入指令，回车或点发送"
            , value (Maybe.withDefault "" (Dict.get run.runId cfg.steerText))
            , onInput (SteerInput run.runId)
            ]
            []
        , button [ class "rsc-action rsc-steer-send" ] [ text "发送" ]
        , button [ class "rsc-action", onClick (SteerToggle run.runId) ] [ text "收起" ]
        ]


cancelButton : Config -> LiveStatus -> Html Msg
cancelButton cfg run =
    if Dict.get run.runId cfg.confirmCancel == Just True then
        button [ class "rsc-action rsc-cancel-confirm", onClick (CancelConfirm run.runId) ] [ text "确认取消？" ]

    else
        button [ class "rsc-action", onClick (CancelArm run.runId) ] [ text "取消" ]


statusNote : Config -> LiveStatus -> Html Msg
statusNote cfg run =
    case Dict.get run.runId cfg.actionStatus of
        Just message ->
            span [ class "rsc-note" ] [ text message ]

        Nothing ->
            text ""
