module Yuki.View.Conversation exposing (view)

import Dict
import Html exposing (Html, button, details, div, form, p, pre, section, span, summary, text, textarea)
import Html.Attributes as Attr
import Html.Events as Events
import Json.Decode as Decode
import Markdown
import Yuki.Types exposing (..)


view : Model -> Html Msg
view model =
    div [ Attr.class "conversation-page" ]
        [ section
            [ Attr.class "field"
            , Attr.id "transcript"
            , Attr.attribute "aria-live" "polite"
            , Attr.tabindex 0
            ]
            [ div [ Attr.class "measure transcript" ] (viewTranscript model) ]
        , viewLatest model
        , viewComposer model
        ]


viewTranscript : Model -> List (Html Msg)
viewTranscript model =
    if model.transcriptLoading then
        [ div [ Attr.class "empty-state quiet-state" ]
            [ p [] [ text "正在加载任务…" ] ]
        ]

    else
        let
            ordered =
                model.messageOrder
                    |> List.filterMap (\identifier -> Dict.get identifier model.messages)

            count =
                List.length ordered

            content =
                if List.isEmpty ordered then
                    [ viewEmpty model ]

                else
                    List.indexedMap (\index message -> viewMessage model (depthClass count index) message) ordered
        in
        content
            ++ viewDetachedTools model
            ++ viewRunStatus model
            ++ (model.error
                    |> Maybe.map (\message -> [ viewError message ])
                    |> Maybe.withDefault []
               )


depthClass : Int -> Int -> String
depthClass count index =
    let
        distance =
            count - index
    in
    if distance <= 2 then
        "depth-near"

    else if distance <= 5 then
        "depth-mid"

    else
        "depth-far"


viewEmpty : Model -> Html Msg
viewEmpty model =
    section [ Attr.class "empty-state" ]
        [ p [ Attr.class "empty-title" ]
            [ text <|
                if model.taskReady then
                    "你想从哪里开始。"

                else
                    "先建立一项任务。"
            ]
        , button
            [ Attr.class "first-line"
            , Attr.type_ "button"
            , Events.onClick <|
                if model.taskReady then
                    SubmitPrompt "你现在如何理解自己的方向？"

                else
                    OpenTaskForm
            ]
            [ text <|
                if model.taskReady then
                    "— 写下第一句"

                else
                    "— 新建任务"
            ]
        ]


viewMessage : Model -> String -> Message -> Html Msg
viewMessage model depth message =
    case message of
        UserMessage _ content ->
            div [ Attr.class ("turn you " ++ depth) ]
                [ p [ Attr.class "who" ] [ text "你" ]
                , p [ Attr.class "user-copy" ] [ text content ]
                ]

        SummaryMessage _ content ->
            details [ Attr.class ("aside-block " ++ depth) ]
                [ summary [] [ text "旧上下文 · 兼容投影" ]
                , pre [] [ text content ]
                ]

        ReasoningMessage reasoning ->
            if String.isEmpty reasoning.content then
                text ""

            else
                details [ Attr.class ("aside-block reasoning " ++ depth) ]
                    [ summary []
                        [ text <|
                            if reasoning.complete then
                                "推理过程"

                            else
                                "正在推理…"
                        ]
                    , pre [] [ text reasoning.content ]
                    ]

        AssistantMessage assistant ->
            let
                calls =
                    List.filterMap (\identifier -> Dict.get identifier model.tools) assistant.toolCalls

                copy =
                    if String.isEmpty assistant.content then
                        []

                    else if assistant.complete then
                        [ div [ Attr.class "markdown" ] [ renderMarkdown assistant.content ] ]

                    else
                        [ p [ Attr.class "streaming-copy" ] [ text assistant.content ]
                        , span [ Attr.class "breath", Attr.attribute "aria-label" "仍在书写" ] []
                        ]
            in
            div
                [ Attr.classList
                    [ ( "turn yuki " ++ depth, True )
                    , ( "in-flight", not assistant.complete )
                    ]
                ]
                [ p [ Attr.class "who" ]
                    [ span [ Attr.class "mark", Attr.attribute "aria-hidden" "true" ] []
                    , text "YUKI"
                    ]
                , div [ Attr.class "answer" ] copy
                , viewToolCollection calls
                ]

        ToolMessage result ->
            if Dict.member result.callId model.tools then
                text ""

            else
                details [ Attr.class ("tool orphan-tool " ++ depth) ]
                    [ summary [] [ text ("孤立工具结果 · " ++ result.callId) ]
                    , pre [] [ text result.content ]
                    ]

        SubAgentMessage sub ->
            viewSubAgent depth sub

        NoticeMessage _ content ->
            p [ Attr.class ("aside-line " ++ depth) ] [ text content ]


viewSubAgent : String -> SubAgent -> Html Msg
viewSubAgent depth sub =
    let
        opened =
            if sub.status == "运行中" || sub.status == "正在汇报" || sub.failed then
                [ Attr.attribute "open" "" ]

            else
                []
    in
    details
        (Attr.classList
            [ ( "sub-agent probe " ++ depth, True )
            , ( "failed", sub.failed )
            ]
            :: opened
        )
        [ summary []
            [ span [ Attr.class "sub-agent-name" ] [ text "子代理" ]
            , span [ Attr.class "sub-agent-state" ] [ text sub.status ]
            ]
        , div [ Attr.class "sub-agent-body" ]
            ([ if String.isEmpty (String.trim sub.content) then
                p [ Attr.class "quiet" ] [ text "尚无可读输出。" ]

               else
                div [ Attr.class "markdown" ] [ renderMarkdown sub.content ]
             , sub.context
                |> Maybe.map
                    (\gauge ->
                        p [ Attr.class "sub-agent-context" ]
                            [ text
                                ("上下文 "
                                    ++ String.fromInt gauge.tokens
                                    ++ " / "
                                    ++ String.fromInt gauge.budget
                                )
                            ]
                    )
                |> Maybe.withDefault (text "")
             ]
                ++ List.map (\activity -> p [ Attr.class "sub-agent-activity" ] [ text activity ]) sub.activity
                ++ (sub.error
                        |> Maybe.map (\message -> [ p [ Attr.class "sub-agent-error" ] [ text message ] ])
                        |> Maybe.withDefault []
                   )
            )
        ]


renderMarkdown : String -> Html msg
renderMarkdown =
    Markdown.toHtmlWith
        { githubFlavored = Just { tables = True, breaks = False }
        , defaultHighlighting = Nothing
        , sanitize = True
        , smartypants = False
        }
        []


viewTool : ToolCall -> Html Msg
viewTool tool =
    let
        waiting =
            tool.name == "request_confirmation" && tool.stage == ToolWaiting

        open =
            if waiting then
                [ Attr.attribute "open" "" ]

            else
                []

        result =
            tool.result
                |> Maybe.map
                    (\content ->
                        [ details [ Attr.class "tool-material" ]
                            [ summary [] [ text "结果" ]
                            , pre [] [ text content ]
                            ]
                        ]
                    )
                |> Maybe.withDefault []

        output =
            if String.isEmpty tool.output then
                []

            else
                [ details [ Attr.class "tool-material", Attr.attribute "open" "" ]
                    [ summary [] [ text "实时输出" ]
                    , pre [] [ text tool.output ]
                    ]
                ]

        decision =
            if waiting then
                [ div [ Attr.class "tool-decisions" ]
                    [ button
                        [ Attr.type_ "button", Events.onClick (ResolveTool tool.id False) ]
                        [ text "拒绝" ]
                    , button
                        [ Attr.class "primary-decision"
                        , Attr.type_ "button"
                        , Events.onClick (ResolveTool tool.id True)
                        ]
                        [ text "允许并继续" ]
                    ]
                ]

            else
                []
    in
    details (Attr.class ("tool probe " ++ toolStageClass tool.stage) :: open)
        [ summary []
            [ span [ Attr.class "tool-verb" ] [ text (toolVerb tool.name) ]
            , span [ Attr.class "tool-target" ] [ text (toolTarget tool.name tool.arguments) ]
            , span [ Attr.class "tool-state" ] [ text (toolStageLabel tool.stage) ]
            ]
        , div [ Attr.class "tool-body" ]
            ([ if String.isEmpty (String.trim tool.arguments) then
                text ""

               else
                details [ Attr.class "tool-material" ]
                    [ summary [] [ text "参数" ]
                    , pre [] [ text tool.arguments ]
                    ]
             ]
                ++ output
                ++ result
                ++ decision
            )
        ]


viewToolCollection : List ToolCall -> Html Msg
viewToolCollection tools =
    let
        active =
            List.filter isToolActive tools

        completed =
            List.filter (not << isToolActive) tools

        completedView =
            if List.isEmpty completed then
                text ""

            else if List.isEmpty active && List.length completed <= 3 then
                div [ Attr.class "tool-stack" ] (List.map viewTool completed)

            else
                viewToolHistory "已完成" completed
    in
    if List.isEmpty tools then
        text ""

    else
        div [ Attr.class "tool-collection" ]
            [ if List.isEmpty active then
                text ""

              else
                div [ Attr.class "tool-stack active-tools" ] (List.map viewTool active)
            , completedView
            ]


viewToolHistory : String -> List ToolCall -> Html Msg
viewToolHistory label tools =
    details [ Attr.class "tool-history" ]
        [ summary []
            [ span [] [ text (label ++ " " ++ String.fromInt (List.length tools) ++ " 次工具调用") ]
            , span [ Attr.class "tool-history-action" ] [ text "展开" ]
            ]
        , div [ Attr.class "tool-stack" ] (List.map viewTool tools)
        ]


isToolActive : ToolCall -> Bool
isToolActive tool =
    case tool.stage of
        ToolStreaming ->
            True

        ToolWaiting ->
            True

        ToolResolved ToolRejected ->
            True

        ToolResolved ToolInterrupted ->
            True

        ToolResolved _ ->
            False


viewDetachedTools : Model -> List (Html Msg)
viewDetachedTools model =
    let
        referenced =
            model.messages
                |> Dict.values
                |> List.concatMap
                    (\message ->
                        case message of
                            AssistantMessage assistant ->
                                assistant.toolCalls

                            _ ->
                                []
                    )
        detached =
            model.tools
                |> Dict.values
                |> List.filter (\tool -> not (List.member tool.id referenced))
    in
    if List.isEmpty detached then
        []

    else
        [ details [ Attr.class "tool-history detached-tools" ]
            [ summary []
                [ span [] [ text ("已恢复 " ++ String.fromInt (List.length detached) ++ " 条工具记录") ]
                , span [ Attr.class "tool-history-action" ] [ text "展开" ]
                ]
            , p [ Attr.class "tool-history-note" ] [ text "这些记录无法关联到原消息。" ]
            , div [ Attr.class "tool-stack" ] (List.map viewTool detached)
            ]
        ]


toolVerb : String -> String
toolVerb name =
    case name of
        "shell" ->
            "运行"

        "shell_bg" ->
            "后台运行"

        "fs_read" ->
            "读取"

        "fs_write" ->
            "写入"

        "fs_edit" ->
            "编辑"

        "fs_list" ->
            "浏览"

        "fs_grep" ->
            "搜索"

        "sub_agent" ->
            "委派"

        "memory_grep" ->
            "检索记忆"

        "memory_read" ->
            "读取记忆"

        "artifact_read" ->
            "读取工件"

        "fs_glob" ->
            "匹配文件"

        "request_confirmation" ->
            "请求确认"

        _ ->
            String.replace "_" " " name


toolTarget : String -> String -> String
toolTarget name arguments =
    let
        keys =
            case name of
                "shell" ->
                    [ "command" ]

                "shell_bg" ->
                    [ "command" ]

                "memory_grep" ->
                    [ "query" ]

                "memory_read" ->
                    [ "entryId", "id" ]

                "artifact_read" ->
                    [ "id" ]

                "request_confirmation" ->
                    [ "message", "prompt", "reason" ]

                _ ->
                    [ "path", "query", "pattern", "id", "entryId", "prefix" ]

        decoder =
            keys
                |> List.map (\key -> Decode.field key Decode.string)
                |> Decode.oneOf
    in
    Decode.decodeString decoder arguments
        |> Result.toMaybe
        |> Maybe.map compactTarget
        |> Maybe.withDefault
            (if String.isEmpty (String.trim arguments) then
                ""

             else
                "查看参数"
            )


compactTarget : String -> String
compactTarget =
    String.lines
        >> String.join " "
        >> String.words
        >> String.join " "
        >> String.left 120


toolStageLabel : ToolStage -> String
toolStageLabel stage =
    case stage of
        ToolStreaming ->
            "进行中"

        ToolWaiting ->
            "等待确认"

        ToolResolved ToolRejected ->
            "已拒绝"

        ToolResolved ToolInterrupted ->
            "已中断"

        ToolResolved ToolApproved ->
            "已允许"

        ToolResolved ToolReturned ->
            "完成"


toolStageClass : ToolStage -> String
toolStageClass stage =
    case stage of
        ToolStreaming ->
            "working"

        ToolWaiting ->
            "waiting"

        ToolResolved ToolRejected ->
            "rejected"

        ToolResolved ToolInterrupted ->
            "interrupted"

        ToolResolved _ ->
            "done"


viewError : String -> Html Msg
viewError message =
    div [ Attr.class "turn error-turn depth-near", Attr.attribute "role" "alert" ]
        [ p [ Attr.class "who" ] [ text "运行失败" ]
        , p [] [ text message ]
        ]


viewRunStatus : Model -> List (Html Msg)
viewRunStatus model =
    let
        status =
            case model.phase of
                Idle ->
                    Nothing

                Connecting ->
                    Just "正在连接模型服务…"

                Streaming ->
                    Just
                        (model.activeStep
                            |> Maybe.map (\_ -> "正在执行任务步骤…")
                            |> Maybe.withDefault "模型正在处理请求…"
                        )

                AwaitingTool ->
                    Just "等待你确认工具请求…"

                Canceled ->
                    Just "运行已中止；已生成的内容仍保留在任务中。"

                Failed ->
                    Nothing
    in
    status
        |> Maybe.map
            (\label ->
                [ div
                    [ Attr.classList
                        [ ( "run-progress", True )
                        , ( "waiting", model.phase == AwaitingTool )
                        , ( "canceled", model.phase == Canceled )
                        ]
                    , Attr.attribute "role" "status"
                    ]
                    [ span [ Attr.class "run-progress-dot", Attr.attribute "aria-hidden" "true" ] []
                    , text label
                    ]
                ]
            )
        |> Maybe.withDefault []


viewComposer : Model -> Html Msg
viewComposer model =
    let
        busy =
            isBusy model.phase

        blocked =
            model.transcriptLoading || not model.taskReady || hasPendingTool model
    in
    section [ Attr.class "write" ]
        [ form [ Attr.class "write-inner", Events.onSubmit Submit ]
            [ textarea
                [ Attr.class "write-line"
                , Attr.attribute "aria-label" "对 YUKI 说"
                , Attr.placeholder
                    (if blocked then
                        "请先处理上方等待确认的请求…"

                     else if not model.taskReady then
                        "建立任务后再开始…"

                     else if busy then
                        "补充当前请求，或加入下一轮…"

                     else
                        "…"
                    )
                , Attr.value model.draft
                , Attr.rows 1
                , Attr.disabled blocked
                , Events.onInput DraftChanged
                , submitOnEnter
                ]
                []
            , viewPathSuggestions model.pathSuggestions
            , div [ Attr.class "write-meta" ]
                [ span [ Attr.class "write-hint" ]
                    [ text <|
                        if busy then
                            "回车引导当前 · Shift+回车换行"

                        else
                            "回车发送 · Shift+回车换行"
                    ]
                , viewComposerActions model
                ]
            ]
        ]


viewPathSuggestions : List String -> Html Msg
viewPathSuggestions paths =
    if List.isEmpty paths then
        text ""

    else
        div [ Attr.class "path-suggestions", Attr.attribute "aria-label" "路径补全" ]
            (List.take 8 paths
                |> List.map
                    (\path ->
                        button
                            [ Attr.type_ "button"
                            , Events.onClick (InsertPath path)
                            ]
                            [ text path ]
                    )
            )


submitOnEnter : Html.Attribute Msg
submitOnEnter =
    Events.custom "keydown" <|
        Decode.map2
            (\key shift ->
                if key == "Enter" && not shift then
                    { message = Submit, stopPropagation = True, preventDefault = True }

                else
                    { message = NoOp, stopPropagation = False, preventDefault = False }
            )
            (Decode.field "key" Decode.string)
            (Decode.field "shiftKey" Decode.bool)


viewComposerActions : Model -> Html Msg
viewComposerActions model =
    if isBusy model.phase then
        div [ Attr.class "write-actions" ]
            [ button
                [ Attr.type_ "button"
                , Attr.disabled (String.isEmpty (String.trim model.draft))
                , Events.onClick (Queue Steer)
                ]
                [ text "引导当前" ]
            , button
                [ Attr.type_ "button"
                , Attr.disabled (String.isEmpty (String.trim model.draft))
                , Events.onClick (Queue FollowUp)
                ]
                [ text "下一轮" ]
            , button [ Attr.type_ "button", Events.onClick Cancel ] [ text "中止" ]
            ]

    else
        div [ Attr.class "write-actions" ]
            [ button [ Attr.type_ "button", Events.onClick RetryLast ] [ text "重新生成" ]
            , button [ Attr.type_ "button", Events.onClick CopyLast ] [ text "复制" ]
            , button
                [ Attr.class "send"
                , Attr.type_ "submit"
                , Attr.disabled (String.isEmpty (String.trim model.draft) || model.transcriptLoading || not model.taskReady)
                ]
                [ text "发送" ]
            ]


viewLatest : Model -> Html Msg
viewLatest model =
    if model.following then
        text ""

    else
        button
            [ Attr.class "latest"
            , Attr.type_ "button"
            , Events.onClick ScrollLatest
            ]
            [ text "跳到最新" ]


hasPendingTool : Model -> Bool
hasPendingTool model =
    Dict.values model.tools |> List.any (\tool -> tool.stage == ToolWaiting)


isBusy : Phase -> Bool
isBusy phase =
    List.member phase [ Connecting, Streaming, AwaitingTool ]
