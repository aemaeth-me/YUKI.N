module Yuki.Dispatch.View exposing (draftEditor)

import Html exposing (..)
import Html.Attributes exposing (class, classList, disabled, placeholder, rows, type_, value)
import Html.Events exposing (onClick, onInput)
import Json.Decode as Decode
import Yuki.Dispatch.Types exposing (..)
import Yuki.Telemetry.Types exposing (DispatchDraft)


draftEditor : (EditorMsg -> msg) -> DraftEditor -> Html msg
draftEditor toMsg editor =
    div
        [ class "draft-editor"
        , classList [ ( "draft-editor-locked", editor.locked ) ]
        ]
        [ div [ class "draft-editor-head" ]
            [ span [ class "draft-editor-title" ] [ text (if editor.locked then lockedLabel editor else "派发任务") ]
            , span [ class "draft-generation" ] [ text (generationLabel editor.draft.generation) ]
            ]
        , div [ class "draft-field" ]
            [ label [] [ text "标题" ]
            , input
                [ class "draft-input"
                , type_ "text"
                , placeholder "任务标题"
                , value editor.title
                , disabled editor.locked
                , onInput (toMsg << TitleChanged)
                ]
                []
            ]
        , div [ class "draft-field" ]
            [ label [] [ text "任务指令" ]
            , textarea
                [ class "draft-textarea"
                , rows 7
                , placeholder "任务 Agent 将看到的首条指令"
                , value editor.prompt
                , disabled editor.locked
                , onInput (toMsg << PromptChanged)
                ]
                []
            ]
        , capabilitySummary editor.draft.config
        , if editor.draft.source == "agent" then
            div [ class "draft-agent-note" ]
                [ text ("由 Yuki 提议 · 原需求：" ++ clip 160 editor.draft.input) ]

          else
            text ""
        , case editor.error of
            Just message ->
                div [ class "draft-error" ] [ text message ]

            Nothing ->
                text ""
        , div [ class "draft-editor-actions" ]
            [ if editor.locked then
                text ""

              else
                button
                    [ class "draft-action draft-action-primary"
                    , disabled editor.saving
                    , onClick (toMsg ConfirmClicked)
                    ]
                    [ text (if editor.saving then "保存中…" else "确认派发") ]
            , if editor.locked then
                text ""

              else
                button
                    [ class "draft-action"
                    , disabled editor.saving
                    , onClick (toMsg CancelClicked)
                    ]
                    [ text "取消" ]
            , if editor.saving then
                span [ class "draft-saving" ] [ text "自动保存中…" ]

              else
                text ""
            ]
        ]


lockedLabel : DraftEditor -> String
lockedLabel editor =
    case editor.draft.status of
        "dispatched" ->
            "已派发"

        "cancelled" ->
            "已取消"

        _ ->
            "已锁定"


capabilitySummary : Decode.Value -> Html msg
capabilitySummary config =
    div [ class "draft-capability" ]
        [ div [ class "draft-capability-title" ] [ text "能力快照" ]
        , div [ class "draft-capability-rows" ]
            (List.map
                (\( name, value ) ->
                    div [ class "draft-capability-row" ]
                        [ span [ class "draft-capability-name" ] [ text name ]
                        , span [ class "draft-capability-value" ] [ text value ]
                        ]
                )
                (capabilityRows config)
            )
        ]

clip : Int -> String -> String
clip length text =
    if String.length text > length then
        String.left length text ++ "…"

    else
        text
