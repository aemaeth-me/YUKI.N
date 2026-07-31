module Yuki.View.Capabilities exposing (view)

import Html exposing (Html, button, div, form, h1, h2, input, label, li, option, p, pre, section, select, span, text, textarea, ul)
import Html.Attributes as Attr
import Html.Events as Events
import Json.Encode as Encode
import Yuki.Types exposing (..)


view : Model -> Html Msg
view model =
    div [ Attr.class "paper-page capabilities-page" ]
        [ div [ Attr.class "page-intro page-intro-actions" ]
            [ div []
                [ h1 [] [ text "能力" ]
                , p [] [ text "当前任务真正拥有的模型、目录、工具权限与上下文边界。" ]
                ]
            , button [ Attr.type_ "button", Events.onClick RefreshCapabilities ] [ text "刷新实际状态" ]
            ]
        , section [ Attr.class "capability-summary" ]
            [ metric "任务" model.taskTitle
            , metric "上下文" (contextLabel model.contextPolicy)
            , metric "本轮用量" (usageLabel model.usage)
            ]
        , section [ Attr.class "capability-list-section" ]
            [ div [ Attr.class "section-heading" ]
                [ span [ Attr.class "eyebrow" ] [ text "运行时实际暴露" ] ]
            , viewCapabilities model.capabilities
            ]
        , configForm model
        , inheritedConfig model.globalConfig
        , treeView model
        , label [ Attr.class "endpoint-note" ]
            [ text "运行入口"
            , input
                [ Attr.value model.endpoint
                , Attr.attribute "aria-label" "运行入口"
                , Events.onInput EndpointChanged
                ]
                []
            ]
        ]


inheritedConfig : Remote Encode.Value -> Html msg
inheritedConfig remote =
    case remote of
        Loading ->
            quiet "正在读取全局继承来源…"

        Unavailable message ->
            quiet message

        Ready value ->
            Html.details [ Attr.class "global-config-source" ]
                [ Html.summary [] [ text "查看全局继承来源" ]
                , pre [] [ text (Encode.encode 2 value) ]
                ]


metric : String -> String -> Html msg
metric labelText value =
    div [] [ span [ Attr.class "eyebrow" ] [ text labelText ], p [] [ text value ] ]


configForm : Model -> Html Msg
configForm model =
    let
        draft =
            model.configDraft
    in
    section [ Attr.class "config-section" ]
        [ div [ Attr.class "section-heading" ]
            [ div []
                [ span [ Attr.class "eyebrow" ] [ text "附着于当前任务" ]
                , h2 [] [ text "运行配置" ]
                ]
            ]
        , form [ Attr.class "config-form", Events.onSubmit SaveConfig ]
            [ label [] [ text "工作目录" ]
            , div [ Attr.class "choice-row" ]
                [ choice (draft.cwdMode == "inherit") (ConfigCwdModeChanged "inherit") "继承全局"
                , choice (draft.cwdMode == "none") (ConfigCwdModeChanged "none") "不挂载目录"
                , choice (draft.cwdMode == "path") (ConfigCwdModeChanged "path") "指定路径"
                ]
            , input
                [ Attr.placeholder "/absolute/path"
                , Attr.value draft.cwd
                , Attr.disabled (draft.cwdMode /= "path")
                , Events.onInput ConfigCwdChanged
                ]
                []
            , label [] [ text "Provider / 模型 / 推理强度" ]
            , div [ Attr.class "config-triple" ]
                [ providerSelect model.providers draft.provider
                , modelSelect model.providers draft.provider draft.model
                , input
                    [ Attr.placeholder "reasoning effort（留空继承）"
                    , Attr.value draft.reasoningEffort
                    , Events.onInput ConfigEffortChanged
                    ]
                    []
                ]
            , label [] [ text "能力 gate" ]
            , div [ Attr.class "gate-grid" ]
                [ gate "文件系统" "fs" draft.fs
                , gate "Shell" "shell" draft.shell
                , gate "持续记忆" "memory" draft.memory
                ]
            , label [] [ text "上下文策略覆盖" ]
            , div [ Attr.class "config-triple" ]
                [ numberField "预留 token" draft.contextReserveTokens ConfigReserveChanged
                , numberField "保留轮组" draft.contextKeepUnits ConfigKeepChanged
                , numberField "摘要上限" draft.contextSummaryTokens ConfigSummaryChanged
                ]
            , label [ Attr.for "task-system-prompt" ] [ text "任务级 Prompt 覆盖（兼容入口）" ]
            , textarea
                [ Attr.id "task-system-prompt"
                , Attr.rows 5
                , Attr.placeholder "留空使用 Yuki 的激活 Prompt；整段覆盖只用于兼容旧任务。"
                , Attr.value draft.systemPrompt
                , Events.onInput ConfigPromptChanged
                ]
                []
            , model.configError
                |> Maybe.map (\message -> p [ Attr.class "inline-error" ] [ text message ])
                |> Maybe.withDefault (text "")
            , div [ Attr.class "config-actions" ]
                [ p [ Attr.class "quiet" ] [ text "空值表示继承；保存后重新读取运行时实际能力。" ]
                , button [ Attr.class "primary", Attr.type_ "submit", Attr.disabled model.configSaving ]
                    [ text (if model.configSaving then "保存中…" else "保存任务配置") ]
                ]
            ]
        ]


providerSelect : Remote (List ProviderEntry) -> String -> Html Msg
providerSelect remote current =
    select [ Attr.value current, Events.onInput ConfigProviderChanged ] <|
        option [ Attr.value "" ] [ text "继承 provider" ]
            :: (case remote of
                    Ready entries ->
                        List.map
                            (\entry ->
                                option
                                    [ Attr.value entry.name, Attr.disabled (not entry.keyReady) ]
                                    [ text (entry.name ++ if entry.keyReady then "" else "（缺少 key）") ]
                            )
                            entries

                    _ ->
                        []
               )


modelSelect : Remote (List ProviderEntry) -> String -> String -> Html Msg
modelSelect remote provider current =
    let
        models =
            case remote of
                Ready entries ->
                    entries
                        |> List.filter (\entry -> entry.name == provider)
                        |> List.head
                        |> Maybe.map .models
                        |> Maybe.withDefault []

                _ ->
                    []
    in
    if List.isEmpty models then
        input
            [ Attr.placeholder "模型（留空继承）"
            , Attr.value current
            , Events.onInput ConfigModelChanged
            ]
            []

    else
        select [ Attr.value current, Events.onInput ConfigModelChanged ]
            (option [ Attr.value "" ] [ text "继承默认模型" ]
                :: List.map (\name -> option [ Attr.value name ] [ text name ]) models
            )


choice : Bool -> Msg -> String -> Html Msg
choice selected msg labelText =
    button
        [ Attr.classList [ ( "selected", selected ) ]
        , Attr.type_ "button"
        , Events.onClick msg
        ]
        [ text labelText ]


gate : String -> String -> Maybe Bool -> Html Msg
gate labelText key value =
    div []
        [ p [] [ text labelText ]
        , div [ Attr.class "choice-row" ]
            [ choice (value == Nothing) (ConfigGateChanged key Nothing) "继承"
            , choice (value == Just True) (ConfigGateChanged key (Just True)) "允许"
            , choice (value == Just False) (ConfigGateChanged key (Just False)) "关闭"
            ]
        ]


numberField : String -> String -> (String -> Msg) -> Html Msg
numberField placeholder value onInput =
    input
        [ Attr.type_ "number"
        , Attr.min "1"
        , Attr.placeholder placeholder
        , Attr.value value
        , Events.onInput onInput
        ]
        []


treeView : Model -> Html Msg
treeView model =
    section [ Attr.class "tree-section" ]
        [ div [ Attr.class "section-heading" ]
            [ div []
                [ span [ Attr.class "eyebrow" ] [ text "工作目录" ]
                , h2 [] [ text "路径快照" ]
                ]
            , button [ Attr.type_ "button", Events.onClick RefreshTree ] [ text "刷新" ]
            ]
        , case model.tree of
            Loading ->
                quiet "正在读取目录…"

            Unavailable message ->
                quiet message

            Ready Nothing ->
                quiet "当前任务没有挂载工作目录。"

            Ready (Just paths) ->
                if List.isEmpty paths then
                    quiet "目录为空。"

                else
                    pre [ Attr.class "tree-material" ] [ text (String.join "\n" (List.take 400 paths)) ]
        ]


viewCapabilities : Remote (List String) -> Html Msg
viewCapabilities remote =
    case remote of
        Loading ->
            quiet "正在确认实际能力…"

        Unavailable message ->
            quiet message

        Ready names ->
            if List.isEmpty names then
                quiet "当前任务没有暴露额外能力。"

            else
                ul [ Attr.class "capability-list" ] (List.map capability names)


capability : String -> Html msg
capability name =
    li []
        [ span [ Attr.class "mark", Attr.attribute "aria-hidden" "true" ] []
        , div []
            [ p [ Attr.class "capability-name" ] [ text (humanize name) ]
            , p [ Attr.class "capability-id" ] [ text name ]
            ]
        ]


humanize : String -> String
humanize name =
    case name of
        "fs" ->
            "本机文件"

        "shell" ->
            "本机命令"

        "memory" ->
            "持续记忆"

        "sub_agent" ->
            "子代理委派"

        _ ->
            name |> String.replace "_" " "


contextLabel : Remote ContextPolicy -> String
contextLabel remote =
    case remote of
        Ready policy ->
            if policy.enabled then
                String.fromInt policy.budgetTokens ++ " tokens"

            else
                "未启用"

        Loading ->
            "读取中"

        Unavailable _ ->
            "不可用"


usageLabel : Maybe Usage -> String
usageLabel maybeUsage =
    case maybeUsage of
        Nothing ->
            "尚未发生"

        Just usage ->
            "入 " ++ token usage.prompt ++ " · 出 " ++ token usage.completion ++ " · 命中 " ++ token usage.cacheHit


token : Maybe Int -> String
token =
    Maybe.map String.fromInt >> Maybe.withDefault "—"


quiet : String -> Html msg
quiet message =
    p [ Attr.class "quiet" ] [ text message ]
