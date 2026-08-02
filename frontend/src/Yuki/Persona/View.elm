module Yuki.Persona.View exposing (dialog)

import Html exposing (..)
import Html.Attributes exposing (class, classList, disabled, id, placeholder, rows, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit, stopPropagationOn)
import Json.Decode as Decode
import Yuki.Persona.State as State exposing (LifecycleAction(..))


dialog : (State.Msg -> msg) -> State.Model -> Html msg
dialog toMsg model =
    Html.map toMsg (dialogView model)


dialogView : State.Model -> Html State.Msg
dialogView model =
    case model.panel of
        Nothing ->
            text ""

        Just panel ->
            div [ class "draft-dialog-backdrop", id "persona-backdrop", backdropClose State.Close ]
                [ div [ class "draft-dialog" ]
                    [ div [ class "draft-dialog-head" ]
                        [ span [ class "draft-dialog-title" ] [ text "人格" ]
                        , button [ class "draft-dialog-close", onClick State.Close ] [ text "×" ]
                        ]
                    , div [ class "persona-id-row" ]
                        [ span [ class "persona-id" ] [ text panel.id ]
                        , statusBadge panel.status
                        ]
                    , if panel.loading then
                        div [ class "persona-loading" ] [ text "加载中…" ]

                      else
                        form [ onSubmit State.Save ]
                            [ div [ class "draft-field" ]
                                [ label [] [ text "名称" ]
                                , input
                                    [ class "draft-input"
                                    , type_ "text"
                                    , value panel.name
                                    , disabled (panel.saving || panel.busy /= Nothing)
                                    , onInput State.NameChanged
                                    ]
                                    []
                                ]
                            , div [ class "draft-field" ]
                                [ label [] [ text "方向" ]
                                , textarea
                                    [ class "draft-textarea"
                                    , rows 6
                                    , value panel.direction
                                    , disabled (panel.saving || panel.busy /= Nothing)
                                    , onInput State.DirectionChanged
                                    ]
                                    []
                                ]
                            , div [ class "draft-field" ]
                                [ label [] [ text "印象模型（可选）" ]
                                , input
                                    [ class "draft-input"
                                    , type_ "text"
                                    , value panel.impressionModel
                                    , disabled (panel.saving || panel.busy /= Nothing)
                                    , onInput State.ImpressionChanged
                                    ]
                                    []
                                ]
                            , case panel.error of
                                Just message ->
                                    div [ class "draft-error" ] [ text message ]

                                Nothing ->
                                    text ""
                            , div [ class "draft-dialog-actions" ]
                                [ button
                                    [ class "draft-action draft-action-primary"
                                    , disabled (panel.saving || panel.busy /= Nothing || not (fillable panel))
                                    ]
                                    [ text (if panel.saving then "保存中…" else "保存") ]
                                , button
                                    [ class "draft-action"
                                    , type_ "button"
                                    , disabled (panel.busy /= Nothing)
                                    , onClick State.Close
                                    ]
                                    [ text "关闭" ]
                                ]
                            , lifecycleRow panel
                            , case panel.lifecycleError of
                                Just message ->
                                    div [ class "draft-error" ] [ text message ]

                                Nothing ->
                                    text ""
                            ]
                    ]
                ]


fillable : State.Panel -> Bool
fillable panel =
    not (String.isEmpty (String.trim panel.name))
        && not (String.isEmpty (String.trim panel.direction))


statusBadge : String -> Html State.Msg
statusBadge status =
    span
        [ class "state-badge"
        , classList
            [ ( "state-active", status == "active" )
            , ( "state-archived", status == "archived" )
            ]
        ]
        [ text (if status == "archived" then "已归档" else "活跃") ]


lifecycleRow : State.Panel -> Html State.Msg
lifecycleRow panel =
    div [ class "persona-lifecycle" ]
        [ span [ class "persona-lifecycle-label" ] [ text "生命周期" ]
        , div [ class "persona-lifecycle-actions" ]
            [ if panel.status == "active" then
                lifecycleButton State.Archive "归档" "确认归档？" panel

              else
                text ""
            , if panel.status == "archived" then
                lifecycleButton State.Restore "恢复" "确认恢复？" panel

              else
                text ""
            , if panel.status == "archived" then
                lifecycleButton State.Delete "删除" "删除这位 Yuki 及其全部对话与记忆" panel

              else
                text ""
            ]
        ]


lifecycleButton : State.LifecycleAction -> String -> String -> State.Panel -> Html State.Msg
lifecycleButton action label confirmLabel panel =
    let
        armed =
            panel.confirming == Just action

        busy =
            panel.busy == Just action
    in
    button
        [ class "draft-action persona-lifecycle-action"
        , type_ "button"
        , classList
            [ ( "persona-lifecycle-danger", action == State.Delete )
            , ( "persona-lifecycle-armed", armed )
            ]
        , disabled (panel.busy /= Nothing)
        , onClick (if armed then State.Confirm action else State.Arm action)
        ]
        [ text
            (if busy then
                "处理中…"

             else if armed then
                confirmLabel

             else
                label
            )
        ]


backdropClose : msg -> Html.Attribute msg
backdropClose msg =
    stopPropagationOn "click"
        (Decode.field "target" (Decode.field "id" Decode.string)
            |> Decode.andThen
                (\id ->
                    if id == "persona-backdrop" then
                        Decode.succeed ( msg, True )

                    else
                        Decode.fail "clicked inside dialog"
                )
        )
