module Yuki.View.Identity exposing (dialog, rail)

import Html exposing (Html, aside, button, div, form, h2, input, label, p, section, span, text, textarea)
import Html.Attributes as Attr
import Html.Events as Events
import Yuki.State as State
import Yuki.Types exposing (..)


rail : Model -> Html Msg
rail model =
    aside [ Attr.class "identity-rail", Attr.attribute "aria-label" "Yuki" ]
        [ div [ Attr.class "identity-list" ] (activeYukis model)
        , button
            [ Attr.class "identity-add"
            , Attr.type_ "button"
            , Attr.attribute "aria-label" "新建 Yuki"
            , Attr.disabled
                (State.isBusy model.phase
                    || model.selfSaving
                    || model.generatingPrompt
                    || model.activatingPrompt /= Nothing
                    || model.promptEditor /= Nothing
                )
            , Events.onClick OpenYukiForm
            ]
            [ text "+" ]
        , archivedYukis model
        ]


activeYukis : Model -> List (Html Msg)
activeYukis model =
    case model.incarnations of
        Ready values ->
            values
                |> List.filter (\value -> value.status == "active")
                |> List.map (identityButton model)

        _ ->
            [ identityButton model model.incarnation ]


identityButton : Model -> Incarnation -> Html Msg
identityButton model yuki =
    button
        [ Attr.classList [ ( "identity-button", True ), ( "current", yuki.id == model.incarnationId ) ]
        , Attr.type_ "button"
        , Attr.title (yuki.name ++ " · " ++ yuki.direction)
        , Attr.disabled
            (yuki.id == model.incarnationId
                || State.isBusy model.phase
                || model.selfSaving
                || model.generatingPrompt
                || model.activatingPrompt /= Nothing
                || model.promptEditor /= Nothing
            )
        , Events.onClick (SwitchYuki yuki.id)
        ]
        [ span [ Attr.class "identity-mark" ] [ text (initial yuki.name) ]
        , span [ Attr.class "identity-name" ] [ text yuki.name ]
        ]


archivedYukis : Model -> Html Msg
archivedYukis model =
    case model.incarnations of
        Ready values ->
            let
                archived =
                    List.filter (\value -> value.status == "archived") values
            in
            if List.isEmpty archived then
                text ""

            else
                div [ Attr.class "archived-yukis" ]
                    [ button
                        [ Attr.class "identity-archive-toggle"
                        , Attr.type_ "button"
                        , Attr.title "已归档的 Yuki"
                        , Events.onClick ToggleArchivedYukis
                        ]
                        [ text ("·" ++ String.fromInt (List.length archived)) ]
                    , if model.showArchivedYukis then
                        div [ Attr.class "identity-archive-list" ] (List.map (archivedYuki model) archived)

                      else
                        text ""
                    ]

        _ ->
            text ""


archivedYuki : Model -> Incarnation -> Html Msg
archivedYuki model yuki =
    div [ Attr.class "archived-yuki" ]
        [ span [ Attr.class "archived-yuki-name" ] [ text yuki.name ]
        , div [ Attr.class "archived-yuki-actions" ]
            [ button
                [ Attr.type_ "button"
                , Events.onClick (RestoreYuki yuki.id yuki.revision)
                ]
                [ text "恢复" ]
            , button
                [ Attr.class "archived-yuki-delete"
                , Attr.type_ "button"
                , Events.onClick (DeleteYuki yuki.id yuki.revision)
                ]
                [ text "删除" ]
            ]
        , if model.deleteYukiConfirm == Just ( yuki.id, yuki.revision ) then
            div [ Attr.class "delete-yuki-confirm", Attr.attribute "role" "alert" ]
                [ p [] [ text "连同任务与记忆一并删除，不可恢复。" ]
                , div []
                    [ button [ Attr.type_ "button", Events.onClick CancelDeleteYuki ] [ text "取消" ]
                    , button
                        [ Attr.class "danger-action"
                        , Attr.type_ "button"
                        , Events.onClick ConfirmDeleteYuki
                        ]
                        [ text "确认删除" ]
                    ]
                ]

          else
            text ""
        ]


dialog : Model -> Html Msg
dialog model =
    case model.yukiForm of
        Nothing ->
            text ""

        Just draft ->
            div [ Attr.class "modal-backdrop" ]
                [ section
                    [ Attr.class "paper-dialog yuki-dialog"
                    , Attr.attribute "role" "dialog"
                    , Attr.attribute "aria-modal" "true"
                    , Attr.attribute "aria-labelledby" "new-yuki-title"
                    ]
                    [ h2 [ Attr.id "new-yuki-title" ] [ text "新的 Yuki" ]
                    , p [] [ text "一位长期存在、拥有独立方向、记忆与任务的主体。" ]
                    , form [ Events.onSubmit SubmitYukiForm ]
                        [ field "标识" "new-yuki-id" draft.identifier YukiIdChanged False
                        , field "名称" "new-yuki-name" draft.name YukiNameChanged False
                        , label [ Attr.for "new-yuki-direction" ] [ text "方向" ]
                        , textarea
                            [ Attr.id "new-yuki-direction"
                            , Attr.rows 4
                            , Attr.value draft.direction
                            , Events.onInput YukiDirectionChanged
                            ]
                            []
                        , field "印象模型（可选）" "new-yuki-model" draft.impressionModel YukiModelChanged False
                        , draft.error
                            |> Maybe.map (\message -> p [ Attr.class "inline-error" ] [ text message ])
                            |> Maybe.withDefault (text "")
                        , div [ Attr.class "dialog-actions" ]
                            [ button [ Attr.type_ "button", Attr.disabled draft.saving, Events.onClick CloseYukiForm ] [ text "取消" ]
                            , button [ Attr.class "primary", Attr.type_ "submit", Attr.disabled draft.saving ]
                                [ text (if draft.saving then "建立中…" else "建立 Yuki") ]
                            ]
                        ]
                    ]
                ]


field : String -> String -> String -> (String -> Msg) -> Bool -> Html Msg
field labelText identifier value onInput autofocus =
    div [ Attr.class "dialog-field" ]
        [ label [ Attr.for identifier ] [ text labelText ]
        , input
            [ Attr.id identifier
            , Attr.value value
            , Attr.autofocus autofocus
            , Events.onInput onInput
            ]
            []
        ]


initial : String -> String
initial value =
    let
        first =
            String.left 1 (String.trim value)
    in
    if String.isEmpty first then
        "Y"

    else
        first
