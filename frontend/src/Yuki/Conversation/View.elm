module Yuki.Conversation.View exposing (view)

import Html exposing (..)
import Html.Attributes exposing (class, classList, disabled, placeholder, rows, style, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Json.Decode as Decode
import Markdown
import Yuki.Conversation.State as State
import Yuki.Conversation.Types exposing (..)
import Yuki.Conversation.Types as Types
import Yuki.Dispatch.Types as Dispatch
import Yuki.Dispatch.View as DispatchView
import Yuki.Telemetry.State exposing (TelemetryState)


view : TelemetryState -> State.Model -> String -> Html Types.Msg
view telemetry model yuki =
    div [ class "chat-panel" ]
        [ header [ class "chat-head" ]
            [ span [ class "chat-title" ] [ text (chatTitle model) ]
            , button [ class "chat-dispatch-button", onClick Types.RequestDispatch ] [ text "派发任务" ]
            ]
        , otherSessionNote telemetry model
        , loadingNote model
        , statusLine model
        , transcriptView model
        , composer telemetry model
        ]


chatTitle : State.Model -> String
chatTitle model =
    case model.threadId of
        Just tid ->
            if String.startsWith "home-" tid then
                "主对话"

            else
                "任务对话"

        Nothing ->
            "主对话"


otherSessionNote : TelemetryState -> State.Model -> Html Types.Msg
otherSessionNote telemetry model =
    if model.activeRun == Nothing && State.hasRunForThread telemetry model.threadId then
        div [ class "chat-other-session" ] [ text "该对话正在另一会话中执行" ]

    else
        text ""


loadingNote : State.Model -> Html Types.Msg
loadingNote model =
    case model.loadError of
        Just message ->
            div [ class "chat-load-error" ]
                [ span [] [ text message ]
                , button [ class "chat-action", onClick Types.Reload ] [ text "重新加载" ]
                ]

        Nothing ->
            text ""


statusLine : State.Model -> Html Types.Msg
statusLine model =
    div [ class "chat-status" ]
        [ case model.phase of
            PhaseConnecting ->
                span [ class "chat-phase" ] [ text "连接中…" ]

            PhaseStreaming ->
                span [ class "chat-phase" ] [ text "运行中…" ]

            PhaseAwaiting ->
                span [ class "chat-phase" ] [ text "等待确认…" ]

            _ ->
                text ""
        , gaugeLine model.gauge
        ]


gaugeLine : Maybe Gauge -> Html Types.Msg
gaugeLine gauge =
    case gauge of
        Just g ->
            let
                percent =
                    clamp 0 100 (round ((toFloat g.tokens / toFloat (max 1 g.budget)) * 100))
            in
            div [ class "chat-gauge" ]
                [ div [ class "chat-gauge-track" ]
                    [ div [ class "chat-gauge-fill", style "width" (String.fromInt percent ++ "%") ] [] ]
                , span [ class "chat-gauge-label" ]
                    [ text (String.fromInt percent ++ "% · " ++ formatTokens g.tokens)
                    , if g.willCompact then
                        span [ class "chat-gauge-warn" ] [ text " 即将压缩" ]

                      else
                        text ""
                    ]
                ]

        Nothing ->
            text ""


formatTokens : Int -> String
formatTokens tokens =
    if tokens >= 10000 then
        String.fromInt (tokens // 1000) ++ "k tokens"

    else
        String.fromInt tokens ++ " tokens"


transcriptView : State.Model -> Html Types.Msg
transcriptView model =
    div [ class "chat-transcript" ]
        (if List.isEmpty model.items then
            [ div [ class "chat-empty" ]
                [ text
                    (if model.loading || model.resolvingHome then
                        "加载中…"

                     else
                        "开始对话吧"
                    )
                ]
            ]

         else
            List.map itemView model.items
        )


itemView : Item -> Html Types.Msg
itemView item =
    case item of
        UserItem message ->
            div [ class "chat-bubble chat-bubble-user" ]
                [ span [ class "chat-bubble-who" ] [ text "你" ]
                , div [ class "chat-bubble-text" ] [ text message.content ]
                ]

        AssistantItem assistant ->
            div
                [ class "chat-bubble chat-bubble-assistant"
                , classList [ ( "chat-bubble-streaming", not assistant.complete ) ]
                ]
                [ span [ class "chat-bubble-who" ] [ text "Yuki" ]
                , if String.isEmpty assistant.content then
                    text ""

                  else
                    Markdown.toHtml [] assistant.content
                ]

        ReasoningItem reasoning ->
            details [ class "chat-reasoning" ]
                [ summary [] [ text "推理过程" ]
                , pre [ class "chat-reasoning-content" ] [ text reasoning.content ]
                ]

        ToolItem tool ->
            if tool.name == "request_confirmation" then
                confirmationCard tool

            else
                details [ class "chat-tool" ]
                    [ summary []
                        [ span [ class "chat-tool-name" ] [ text tool.name ]
                        , span [ class "chat-tool-state" ] [ text (toolStateLabel tool.stage) ]
                        ]
                    , if String.isEmpty tool.arguments then
                        text ""

                      else
                        pre [ class "chat-tool-args" ] [ text (clip 600 tool.arguments) ]
                    , case tool.result of
                        Just content ->
                            pre [ class "chat-tool-result" ] [ text (clip 800 content) ]

                        Nothing ->
                            text ""
                    ]

        ToolResultItem _ ->
            text ""

        SubItem sub ->
            subCard sub

        DraftCardItem editor ->
            div [ class "chat-draft-card" ]
                [ Html.map (cardMsg editor.draft.dispatchId) (DispatchView.draftEditor identity editor)
                ]

        NoteItem noteItem ->
            div
                [ class "chat-note"
                , classList [ ( "chat-note-warn", noteItem.kind == NoteWarn ) ]
                ]
                [ text noteItem.text ]


cardMsg : String -> Dispatch.EditorMsg -> Types.Msg
cardMsg dispatchId edit =
    case edit of
        Dispatch.TitleChanged text ->
            Types.CardTitleChanged dispatchId text

        Dispatch.PromptChanged text ->
            Types.CardPromptChanged dispatchId text

        Dispatch.ConfirmClicked ->
            Types.CardConfirm dispatchId

        Dispatch.CancelClicked ->
            Types.CardCancel dispatchId


confirmationCard : ToolState -> Html Types.Msg
confirmationCard tool =
    let
        args =
            decodeConfirmationArgs tool.arguments
    in
    div
        [ class "chat-confirm"
        , classList [ ( "chat-confirm-done", tool.stage /= ToolWaiting ) ]
        ]
        [ div [ class "chat-confirm-title" ] [ text (Maybe.withDefault "请求确认" args.title) ]
        , div [ class "chat-confirm-details" ] [ text (Maybe.withDefault "" args.details) ]
        , if tool.stage == ToolWaiting then
            div [ class "chat-confirm-actions" ]
                [ button [ class "chat-action chat-action-approve", onClick (Types.ResolveConfirm tool.callId True) ] [ text "确认" ]
                , button [ class "chat-action chat-action-reject", onClick (Types.ResolveConfirm tool.callId False) ] [ text "取消" ]
                ]

          else if tool.stage == ToolDone then
            div [ class "chat-confirm-done-note" ] [ text "已处理" ]

          else
            text ""
        ]


decodeConfirmationArgs : String -> { title : Maybe String, details : Maybe String }
decodeConfirmationArgs raw =
    case Decode.decodeString
        (Decode.map2
            (\title details -> { title = title, details = details })
            (Decode.maybe (Decode.field "title" Decode.string))
            (Decode.maybe (Decode.field "details" Decode.string))
        )
        raw
    of
        Ok args ->
            args

        Err _ ->
            { title = Nothing, details = Nothing }


toolStateLabel : ToolStage -> String
toolStateLabel stage =
    case stage of
        ToolStreaming ->
            "进行中"

        ToolWaiting ->
            "等待确认"

        ToolDone ->
            "完成"

        ToolRejected ->
            "已拒绝"


subCard : SubState -> Html Types.Msg
subCard sub =
    details [ class "chat-sub" ]
        [ summary []
            [ span [ class "chat-sub-name" ] [ text "子代理" ]
            , span [ class "chat-sub-state" ] [ text sub.status ]
            ]
        , div [ class "chat-sub-body" ]
            [ if String.isEmpty sub.content then
                text ""

              else
                Markdown.toHtml [] sub.content
            , case sub.error of
                Just message ->
                    div [ class "chat-sub-error" ] [ text message ]

                Nothing ->
                    text ""
            , if List.isEmpty sub.activity then
                text ""

              else
                div [ class "chat-sub-activity" ] [ text (String.join " · " sub.activity) ]
            , gaugeLine sub.context
            ]
        ]


composer : TelemetryState -> State.Model -> Html Types.Msg
composer telemetry model =
    let
        running =
            model.activeRun /= Nothing

        waitingConfirm =
            State.hasWaitingTool model.items

        blockedByOther =
            not running && State.hasRunForThread telemetry model.threadId
    in
    div [ class "chat-composer" ]
        [ if running then
            form [ class "chat-steer", onSubmit Types.SteerSubmitted ]
                [ input
                    [ class "chat-steer-input"
                    , type_ "text"
                    , value model.steerDraft
                    , onInput Types.SteerChanged
                    , placeholder "运行中 — 输入将作为指令（steer）"
                    ]
                    []
                , button [ class "chat-action chat-action-send" ] [ text "发送" ]
                , button [ class "chat-action chat-action-cancel", type_ "button", onClick Types.CancelRun ] [ text "取消运行" ]
                ]

          else if waitingConfirm then
            div [ class "chat-waiting" ] [ text "等待你确认上方的请求" ]

          else if blockedByOther then
            div [ class "chat-waiting" ] [ text "该对话正在另一会话中执行" ]

          else
            form [ class "chat-write", onSubmit Types.Send ]
                [ textarea
                    [ class "chat-write-input"
                    , rows 3
                    , value model.draft
                    , onInput Types.ComposerChanged
                    , placeholder "给 Yuki 留言…"
                    , sendOnEnter Types.Send
                    ]
                    []
                , div [ class "chat-write-actions" ]
                    [ span [ class "chat-write-hint" ] [ text "Enter 发送 · Shift+Enter 换行" ]
                    , button
                        [ class "chat-action chat-action-send"
                        , disabled (String.isEmpty (String.trim model.draft))
                        ]
                        [ text "发送" ]
                    ]
                ]
        , case model.error of
            Just message ->
                div [ class "chat-error" ]
                    [ pre [] [ text message ]
                    , button [ class "chat-action chat-action-retry", onClick Types.Retry ] [ text "重试" ]
                    ]

            Nothing ->
                if model.phase == PhaseCanceled then
                    div [ class "chat-error" ] [ text "该次运行已取消" ]

                else
                    text ""
        ]


clip : Int -> String -> String
clip length text =
    if String.length text > length then
        String.left length text ++ "…"

    else
        text


sendOnEnter : msg -> Html.Attribute msg
sendOnEnter msg =
    Html.Events.on "keydown"
        (Decode.map2 Tuple.pair
            (Decode.field "key" Decode.string)
            (Decode.field "shiftKey" Decode.bool)
            |> Decode.andThen
                (\( key, shift ) ->
                    if key == "Enter" && not shift then
                        Decode.succeed msg

                    else
                        Decode.fail "not enter"
                )
        )
