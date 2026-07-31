module Yuki.View.Self exposing (view)

import Html exposing (Html, button, details, div, form, h1, h2, input, label, p, pre, section, span, summary, text, textarea)
import Html.Attributes as Attr
import Html.Events as Events
import Yuki.Types exposing (..)


view : Model -> Html Msg
view model =
    div [ Attr.class "paper-page self-page" ]
        [ div [ Attr.class "page-intro" ]
            [ h1 [] [ text "自我" ]
            , p [] [ text "这里修改规范自我的来源；记忆描述经历留下的经验，能力描述运行时现实。" ]
            ]
        , section [ Attr.class "self-manifest" ]
            [ selfAspect "规范自我" "应当是谁" model.incarnation.direction
            , selfAspect "经验自我" "因何成为现在" "由带来源的任务记录、长期记忆与印象形成。"
            , selfAspect "现实自我" "当前能做什么" "由当前任务的模型、目录、工具 gate 与上下文预算决定。"
            ]
        , section [ Attr.class "self-editor" ]
            [ div [ Attr.class "section-heading" ]
                [ div []
                    [ span [ Attr.class "eyebrow" ] [ text "Incarnation · 持续主体" ]
                    , h2 [] [ text "身份来源" ]
                    ]
                , span [ Attr.class "revision-label" ] [ text ("revision " ++ String.fromInt model.incarnation.revision) ]
                ]
            , form [ Events.onSubmit SaveSelf ]
                [ label [ Attr.for "self-name" ] [ text "名称" ]
                , input
                    [ Attr.id "self-name"
                    , Attr.value model.selfNameDraft
                    , Events.onInput SelfNameChanged
                    ]
                    []
                , label [ Attr.for "self-direction" ] [ text "方向与方法倾向" ]
                , textarea
                    [ Attr.id "self-direction"
                    , Attr.rows 7
                    , Attr.value model.selfDirectionDraft
                    , Events.onInput SelfDirectionChanged
                    ]
                    []
                , label [ Attr.for "self-impression-model" ] [ text "印象生成模型（可选）" ]
                , input
                    [ Attr.id "self-impression-model"
                    , Attr.value model.selfImpressionModelDraft
                    , Events.onInput SelfImpressionModelChanged
                    ]
                    []
                , model.selfError
                    |> Maybe.map (\message -> p [ Attr.class "inline-error", Attr.attribute "role" "alert" ] [ text message ])
                    |> Maybe.withDefault (text "")
                , div [ Attr.class "self-actions" ]
                    [ p [ Attr.class "prompt-revision" ]
                        [ text
                            (model.incarnation.promptRevision
                                |> Maybe.map ((++) "当前 Prompt · ")
                                |> Maybe.withDefault "尚无激活的 Prompt"
                            )
                        ]
                    , button
                        [ Attr.class "primary"
                        , Attr.type_ "submit"
                        , Attr.disabled model.selfSaving
                        ]
                        [ text (if model.selfSaving then "保存中…" else "保存并生成 Prompt 草案") ]
                    ]
                ]
            ]
        , promptWorkspace model
        , section [ Attr.class "self-lifecycle" ]
            [ span [ Attr.class "eyebrow" ] [ text "生命周期" ]
            , p [] [ text "归档会同时归档这位 Yuki 的活动任务；历史、记忆与来源仍可恢复。" ]
            , if model.archiveYukiConfirm then
                div [ Attr.class "lifecycle-confirm", Attr.attribute "role" "alert" ]
                    [ p [] [ text "确认归档？活动任务会一并归档，但历史与记忆仍可恢复。" ]
                    , button [ Attr.type_ "button", Events.onClick CancelArchiveYuki ] [ text "取消" ]
                    , button [ Attr.class "danger-action", Attr.type_ "button", Events.onClick ConfirmArchiveYuki ] [ text "确认归档" ]
                    ]

              else
                button
                    [ Attr.class "danger-action"
                    , Attr.type_ "button"
                    , Attr.disabled (model.incarnationId == "yuki" || model.selfSaving)
                    , Events.onClick ArchiveYuki
                    ]
                    [ text "归档这位 Yuki" ]
            ]
        ]


promptWorkspace : Model -> Html Msg
promptWorkspace model =
    section [ Attr.class "prompt-workspace" ]
        [ div [ Attr.class "section-heading" ]
            [ div []
                [ span [ Attr.class "eyebrow" ] [ text "可追溯的编译来源" ]
                , h2 [] [ text "Prompt 版本" ]
                ]
            , div [ Attr.class "prompt-buttons" ]
                [ button [ Attr.type_ "button", Events.onClick RefreshPrompts ] [ text "刷新" ]
                , button
                    [ Attr.type_ "button"
                    , Attr.disabled model.generatingPrompt
                    , Events.onClick GeneratePrompt
                    ]
                    [ text (if model.generatingPrompt then "生成中…" else "生成 Charter 草案") ]
                ]
            ]
        , model.promptMessage
            |> Maybe.map (\message -> p [ Attr.class "prompt-message", Attr.attribute "role" "status" ] [ text message ])
            |> Maybe.withDefault (text "")
        , promptEditor model
        , div [ Attr.class "prompt-columns" ]
            [ promptList model False "Yuki Charter / Composite" model.prompts
            , promptList model True "Root Constitution" model.rootPrompts
            ]
        ]


promptList : Model -> Bool -> String -> Remote (List PromptRevision) -> Html Msg
promptList model root title remote =
    section [ Attr.class "prompt-list" ]
        [ h2 [] [ text title ]
        , case remote of
            Loading ->
                p [ Attr.class "quiet" ] [ text "正在读取版本…" ]

            Unavailable message ->
                p [ Attr.class "quiet" ] [ text message ]

            Ready revisions ->
                if List.isEmpty revisions then
                    p [ Attr.class "quiet" ] [ text "尚无版本。" ]

                else
                    div [] (List.map (promptRevision model root) revisions)
        ]


promptRevision : Model -> Bool -> PromptRevision -> Html Msg
promptRevision model root revision =
    details [ Attr.classList [ ( "prompt-entry", True ), ( "active", revision.status == "active" ) ] ]
        [ summary []
            [ span [] [ text ("r" ++ String.fromInt revision.ordinal ++ " · " ++ statusLabel revision.status) ]
            , span [ Attr.class "prompt-hash" ] [ text (String.left 10 revision.effectiveHash) ]
            ]
        , div [ Attr.class "prompt-entry-body" ]
            [ p [ Attr.class "prompt-source" ] [ text revision.sourceIntent ]
            , pre [] [ text revision.content ]
            , p [ Attr.class "prompt-lineage" ]
                [ text
                    ("parent · "
                        ++ Maybe.withDefault "—" revision.parentRevision
                        ++ " · generator · "
                        ++ revision.generatorRevision
                        ++ " · invocation · "
                        ++ Maybe.withDefault "—" revision.modelInvocationRef
                    )
                ]
            , div [ Attr.class "prompt-entry-actions" ]
                [ button [ Attr.type_ "button", Events.onClick (BeginPromptEdit root revision) ] [ text "基于此版本修改" ]
                , if revision.status == "active" then
                    text ""

                  else
                    button
                        [ Attr.type_ "button"
                        , Attr.disabled (model.activatingPrompt /= Nothing)
                        , Events.onClick
                            (if root then
                                ActivateRootPrompt revision.id (activeRootOrdinal model.rootPrompts)

                             else
                                ActivatePrompt revision.id
                            )
                        ]
                        [ text "激活" ]
                ]
            ]
        ]


promptEditor : Model -> Html Msg
promptEditor model =
    case model.promptEditor of
        Nothing ->
            text ""

        Just editor ->
            form [ Attr.class "prompt-editor", Events.onSubmit SavePromptEdit ]
                [ div [ Attr.class "section-heading" ]
                    [ h2 [] [ text (if editor.root then "修改 Root Prompt" else "修改 Yuki Prompt") ]
                    , button [ Attr.type_ "button", Attr.disabled editor.saving, Events.onClick CancelPromptEdit ] [ text "关闭" ]
                    ]
                , label [ Attr.for "prompt-source" ] [ text "修改说明" ]
                , input
                    [ Attr.id "prompt-source"
                    , Attr.value editor.sourceIntent
                    , Events.onInput PromptSourceChanged
                    ]
                    []
                , label [ Attr.for "prompt-content" ] [ text "Prompt 正文" ]
                , textarea
                    [ Attr.id "prompt-content"
                    , Attr.rows 18
                    , Attr.value editor.content
                    , Events.onInput PromptContentChanged
                    ]
                    []
                , button [ Attr.class "primary", Attr.type_ "submit", Attr.disabled editor.saving ]
                    [ text (if editor.saving then "保存中…" else "保存为新草案") ]
                ]


activeRootOrdinal : Remote (List PromptRevision) -> Int
activeRootOrdinal remote =
    case remote of
        Ready revisions ->
            revisions
                |> List.filter (\revision -> revision.status == "active")
                |> List.head
                |> Maybe.map .ordinal
                |> Maybe.withDefault 0

        _ ->
            0


statusLabel : String -> String
statusLabel status =
    case status of
        "active" ->
            "生效"

        "draft" ->
            "草案"

        "retired" ->
            "已退役"

        _ ->
            status


selfAspect : String -> String -> String -> Html msg
selfAspect title relation content =
    div []
        [ span [ Attr.class "eyebrow" ] [ text relation ]
        , h2 [] [ text title ]
        , p [] [ text content ]
        ]
