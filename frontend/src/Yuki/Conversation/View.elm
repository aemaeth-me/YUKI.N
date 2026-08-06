module Yuki.Conversation.View exposing (view)

import Html exposing (..)
import Html.Attributes exposing (class, classList, disabled, placeholder, rows, style, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Json.Decode as Decode
import Markdown
import Yuki.Conversation.State as State
import Yuki.Conversation.Types exposing (..)
import Yuki.Conversation.Types as Types


view : State.Model -> String -> Html Types.Msg
view model yuki =
    div [ class "chat-panel" ]
        [ header [ class "chat-head" ]
            [ span [ class "chat-title" ] [ text (chatTitle model) ]
            ]
        , loadingNote model
        , statusLine model
        , transcriptView model
        , composer model
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
                    (if model.loading then
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

        NoteItem noteItem ->
            div
                [ class "chat-note"
                , classList [ ( "chat-note-warn", noteItem.kind == NoteWarn ) ]
                ]
                [ text noteItem.text ]


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


composer : State.Model -> Html Types.Msg
composer model =
    div [ class "chat-composer" ]
        [ if model.activeRun /= Nothing then
            div [ class "chat-waiting" ] [ text "运行中…" ]

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
