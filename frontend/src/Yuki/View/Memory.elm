module Yuki.View.Memory exposing (page, rail)

import Html exposing (Html, button, details, div, form, h1, h2, input, label, li, option, p, pre, section, select, span, summary, text, ul)
import Html.Attributes as Attr
import Html.Events as Events
import Json.Decode as Decode
import Json.Encode as Encode
import Yuki.Types exposing (..)


rail : Model -> Html Msg
rail model =
    asideRail model <|
        case model.impression of
            Loading ->
                [ p [ Attr.class "margin-note" ] [ text "记忆正在对焦…" ] ]

            Unavailable message ->
                [ p [ Attr.class "margin-note" ] [ text message ] ]

            Ready state ->
                if List.isEmpty state.items then
                    [ p [ Attr.class "margin-note" ] [ text "当前没有可显示的印象。" ] ]

                else
                    List.take 4 state.items |> List.map viewMarginItem


asideRail : Model -> List (Html Msg) -> Html Msg
asideRail model content =
    div [ Attr.class "right-edge" ]
        [ button
            [ Attr.class "edge-rail"
            , Attr.type_ "button"
            , Attr.attribute "aria-expanded" (boolText model.memoryPinned)
            , Attr.attribute "aria-controls" "memory-margin"
            , Events.onClick ToggleMemory
            ]
            [ span [] [ text "记" ], span [] [ text "忆" ] ]
        , section
            [ Attr.class "memory-margin"
            , Attr.id "memory-margin"
            , Attr.attribute "aria-label" "页边记忆"
            ]
            ([ div [ Attr.class "margin-head" ]
                [ span [ Attr.class "eyebrow" ] [ text "当前印象" ]
                , button [ Attr.type_ "button", Events.onClick RefreshMemory ] [ text "刷新" ]
                ]
             ]
                ++ content
                ++ [ button
                        [ Attr.class "margin-more"
                        , Attr.type_ "button"
                        , Events.onClick (SelectPage Memory)
                        ]
                        [ text "进入记忆原文" ]
                   ]
            )
        ]


viewMarginItem : ImpressionItem -> Html Msg
viewMarginItem item =
    articleNote item.label item.intuition


articleNote : String -> String -> Html Msg
articleNote label content =
    div [ Attr.class "margin-item" ]
        [ p [ Attr.class "margin-label" ] [ text label ]
        , p [] [ text content ]
        ]


page : Model -> Html Msg
page model =
    div [ Attr.class "paper-page memory-page" ]
        [ headerBlock "记忆" "不是回放发生过什么，而是看见它留下了什么。"
        , div [ Attr.class "memory-tabs" ]
            [ memoryTab model.memorySection Impressions "印象"
            , memoryTab model.memorySection LongTerm "长期"
            , memoryTab model.memorySection Working "工作记忆与睡眠"
            ]
        , case model.memorySection of
            Impressions ->
                impressionPage model

            LongTerm ->
                longTermPage model

            Working ->
                workingPage model
        ]


memoryTab : MemorySection -> MemorySection -> String -> Html Msg
memoryTab selected target label =
    button
        [ Attr.classList [ ( "active", selected == target ) ]
        , Attr.type_ "button"
        , Events.onClick (SelectMemorySection target)
        ]
        [ text label ]


impressionPage : Model -> Html Msg
impressionPage model =
    div []
        [ section [ Attr.class "memory-section" ]
            [ div [ Attr.class "section-heading" ]
                [ span [ Attr.class "eyebrow" ] [ text "印象" ]
                , button [ Attr.type_ "button", Events.onClick RefreshMemory ] [ text "刷新" ]
                ]
            , viewImpression model.impression
            ]
        , rawHistory "最近激活" model.impressionActivations
        , rawHistory "修订与记忆候选" model.impressionRevisions
        ]


longTermPage : Model -> Html Msg
longTermPage model =
    div []
        [ section [ Attr.class "memory-section task-archive-section" ]
            [ div [ Attr.class "section-heading" ]
                [ div []
                    [ span [ Attr.class "eyebrow" ] [ text "Task Archive · 长期记忆原件" ]
                    , p [ Attr.class "section-explain" ] [ text "同一位 Yuki 的任务记录只追加保存；搜索结果可回到完整来源。" ]
                    ]
                , button [ Attr.type_ "button", Events.onClick RefreshTaskArchives ] [ text "刷新目录" ]
                ]
            , taskArchiveSearch model
            , taskRecordReader model
            ]
        , section [ Attr.class "memory-section long-memory" ]
            [ div [ Attr.class "section-heading" ]
                [ div []
                    [ span [ Attr.class "eyebrow" ] [ text "Distilled Index · 可重建索引" ]
                    , p [ Attr.class "section-explain" ] [ text "默认不铺开正文。这里的记录必须保留原始 source refs。" ]
                    ]
                ]
            , form [ Attr.class "memory-search", Events.onSubmit SearchMemory ]
                [ Html.input
                    [ Attr.type_ "search"
                    , Attr.placeholder "grep 原文…"
                    , Attr.value model.memoryQuery
                    , Attr.attribute "aria-label" "检索长期记忆"
                    , Events.onInput MemoryQueryChanged
                    ]
                    []
                , button [ Attr.type_ "submit" ] [ text "查找" ]
                ]
            , rememberForm model
            , viewSearch model model.memorySearch
            , memoryDetail model
            ]
        , rawHistory "读取收据 · 谁在何时使用了哪一版" model.memoryReceipts
        , rawHistory "经验事件 · 提炼过程的来源材料" model.experiences
        ]


workingPage : Model -> Html Msg
workingPage model =
    div []
        [ section [ Attr.class "memory-section working-memory-section" ]
            [ div [ Attr.class "section-heading" ]
                [ div []
                    [ span [ Attr.class "eyebrow" ] [ text "当前短期状态" ]
                    , p [ Attr.class "section-explain" ] [ text "工作记忆属于这位 Yuki 当前承担的任务，不是长期身份。" ]
                    ]
                , button [ Attr.type_ "button", Events.onClick RefreshWorkingMemory ] [ text "刷新" ]
                ]
            , rawRemote "工作记忆" model.workingMemory
            , div [ Attr.class "sleep-action" ]
                [ button
                    [ Attr.class "primary"
                    , Attr.type_ "button"
                    , Attr.disabled (model.sleeping || not model.taskReady)
                    , Events.onClick SleepCurrentTask
                    ]
                    [ text (if model.sleeping then "整理中…" else "让当前任务进入一次睡眠整理") ]
                , model.sleepMessage
                    |> Maybe.map (\message -> p [ Attr.attribute "role" "status" ] [ text message ])
                    |> Maybe.withDefault (text "")
                ]
            ]
        , rawHistory "睡眠周期与遗忘裁决" model.sleepCycles
        ]


headerBlock : String -> String -> Html Msg
headerBlock title description =
    div [ Attr.class "page-intro" ]
        [ h1 [] [ text title ]
        , p [] [ text description ]
        ]


viewImpression : Remote ImpressionState -> Html Msg
viewImpression remote =
    case remote of
        Loading ->
            quiet "正在对焦…"

        Unavailable message ->
            quiet message

        Ready state ->
            if List.isEmpty state.items then
                quiet "尚未形成稳定印象。"

            else
                ul [ Attr.class "impression-list" ] (List.map viewImpressionItem state.items)


viewImpressionItem : ImpressionItem -> Html Msg
viewImpressionItem item =
    li []
        [ div [ Attr.class "impression-title" ]
            [ span [ Attr.class "mark", Attr.attribute "aria-hidden" "true" ] []
            , h2 [] [ text item.label ]
            , span [ Attr.class "strength" ] [ text (strengthLabel item.strength) ]
            ]
        , p [] [ text item.intuition ]
        , if List.isEmpty item.sources then
            text ""

          else
            p [ Attr.class "source" ] [ text ("来源 · " ++ String.join " · " item.sources) ]
        ]


viewSearch : Model -> Remote MemorySearch -> Html Msg
viewSearch model remote =
    case remote of
        Loading ->
            quiet "沿原文查找中…"

        Unavailable message ->
            quiet message

        Ready result ->
            if String.isEmpty result.query then
                text ""

            else if List.isEmpty result.snippets then
                quiet ("没有找到“" ++ result.query ++ "”。")

            else
                div [ Attr.class "memory-results" ] (List.map (viewSnippet model) result.snippets)


viewSnippet : Model -> MemorySnippet -> Html Msg
viewSnippet model snippet =
    div [ Attr.class "memory-snippet probe" ]
        [ div [ Attr.class "snippet-meta" ]
            [ span [] [ text snippet.kind ]
            , span [] [ text ("r" ++ String.fromInt snippet.revision) ]
            ]
        , p [] [ text snippet.snippet ]
        , if List.isEmpty snippet.sources then
            text ""

          else
            p [ Attr.class "source" ] [ text ("原始出处 · " ++ String.join " · " snippet.sources) ]
        , div [ Attr.class "memory-snippet-actions" ]
            [ button [ Attr.type_ "button", Events.onClick (OpenMemory snippet.id snippet.revision) ] [ text "查看完整版本" ]
            , button [ Attr.type_ "button", Events.onClick (VoidMemory snippet.id snippet.revision) ] [ text "作废此 revision" ]
            ]
        ]


rememberForm : Model -> Html Msg
rememberForm model =
    details [ Attr.class "remember-form" ]
        [ summary [] [ text "写入一条明确记忆" ]
        , form [ Events.onSubmit RememberMemory ]
             [ div [ Attr.class "remember-meta" ]
                 [ div [ Attr.class "remember-field" ]
                     [ label [ Attr.for "memory-kind" ] [ text "记忆类型" ]
                     , select [ Attr.id "memory-kind", Attr.value model.memoryKind, Events.onInput MemoryKindChanged ]
                         [ option [ Attr.value "semantic" ] [ text "事实 / 判断" ]
                         , option [ Attr.value "identity" ] [ text "自我认识" ]
                         , option [ Attr.value "procedural" ] [ text "方法经验" ]
                         , option [ Attr.value "relational" ] [ text "协作默契" ]
                         , option [ Attr.value "observation" ] [ text "待验证观察" ]
                         ]
                     ]
                 , div [ Attr.class "remember-field" ]
                     [ label [ Attr.for "memory-visibility" ] [ text "作用域" ]
                     , select [ Attr.id "memory-visibility", Attr.value model.memoryVisibility, Events.onInput MemoryVisibilityChanged ]
                         [ option [ Attr.value "private" ] [ text "当前 Yuki 私有" ]
                         , option [ Attr.value "shared" ] [ text "共享候选" ]
                         ]
                     ]
                 ]
            , input
                [ Attr.placeholder "写下记忆正文；系统会为它建立独立版本与来源收据。"
                , Attr.value model.memoryDraft
                , Events.onInput MemoryDraftChanged
                ]
                []
            , model.memoryActionError
                |> Maybe.map (\message -> p [ Attr.class "inline-error" ] [ text message ])
                |> Maybe.withDefault (text "")
            , button [ Attr.type_ "submit" ] [ text "写入索引" ]
            ]
        ]


memoryDetail : Model -> Html Msg
memoryDetail model =
    case model.selectedMemory of
        Nothing ->
            text ""

        Just ( identifier, revision ) ->
            section [ Attr.class "memory-detail" ]
                [ div [ Attr.class "section-heading" ]
                    [ span [ Attr.class "eyebrow" ] [ text (identifier ++ " · r" ++ String.fromInt revision) ]
                    , button [ Attr.type_ "button", Events.onClick CloseMemory ] [ text "关闭" ]
                    ]
                , rawRemote "记忆版本" model.memoryDetail
                ]


taskArchiveSearch : Model -> Html Msg
taskArchiveSearch model =
    div [ Attr.class "task-record-workspace" ]
        [ form [ Attr.class "task-record-search", Events.onSubmit SearchTaskRecords ]
            [ select
                [ Attr.value (Maybe.withDefault "" model.taskRecordTask)
                , Events.onInput TaskRecordTaskChanged
                ]
                (option [ Attr.value "" ] [ text "全部任务" ] :: taskOptions model.taskArchives)
            , input
                [ Attr.type_ "search"
                , Attr.placeholder "按原文字面搜索…"
                , Attr.value model.taskRecordQuery
                , Events.onInput TaskRecordQueryChanged
                ]
                []
            , label [ Attr.class "case-toggle" ]
                [ input
                    [ Attr.type_ "checkbox"
                    , Attr.checked model.taskRecordCaseSensitive
                    , Events.onCheck TaskRecordCaseChanged
                    ]
                    []
                , text "区分大小写"
                ]
            , button [ Attr.type_ "submit" ] [ text "查找原件" ]
            ]
        , viewTaskSearch model model.taskRecordSearch
        ]


taskOptions : Remote (List TaskArchiveSummary) -> List (Html Msg)
taskOptions remote =
    case remote of
        Ready archives ->
            List.map
                (\archive ->
                    option [ Attr.value archive.taskId ]
                        [ text
                            (archive.taskId
                                ++ " · "
                                ++ String.fromInt archive.entryCount
                                ++ " 条"
                            )
                        ]
                )
                archives

        _ ->
            []


viewTaskSearch : Model -> Remote TaskRecordSearch -> Html Msg
viewTaskSearch model remote =
    case remote of
        Loading ->
            quiet "正在扫描任务原件…"

        Unavailable message ->
            quiet message

        Ready result ->
            if String.isEmpty result.query then
                archiveCatalog model model.taskArchives

            else if List.isEmpty result.hits then
                quiet ("没有找到“" ++ result.query ++ "”。")

            else
                div [ Attr.class "task-record-results" ]
                    ([ p [ Attr.class "search-stats" ]
                        [ text
                            ("候选 "
                                ++ String.fromInt result.scannedEntries
                                ++ " 条记录 · 实际命中 "
                                ++ String.fromInt result.matchedEntries
                                ++ " 条 / "
                                ++ String.fromInt result.totalHits
                                ++ " 处 · 已显示 "
                                ++ String.fromInt (List.length result.hits)
                            )
                        ]
                     ]
                        ++ List.map taskRecordHit result.hits
                        ++ (if result.hasMore then
                                [ button
                                    [ Attr.class "task-record-more"
                                    , Attr.type_ "button"
                                    , Events.onClick SearchMoreTaskRecords
                                    ]
                                    [ text
                                        ("继续显示（还剩 "
                                            ++ String.fromInt (max 0 (result.totalHits - result.offset - result.returnedHits))
                                            ++ " 处）"
                                        )
                                    ]
                                ]

                            else
                                []
                           )
                    )


archiveCatalog : Model -> Remote (List TaskArchiveSummary) -> Html Msg
archiveCatalog model remote =
    case remote of
        Loading ->
            quiet "正在读取任务记忆目录…"

        Unavailable message ->
            quiet message

        Ready archives ->
            if List.isEmpty archives then
                quiet "尚无任务记录原件。"

            else
                div [ Attr.class "archive-catalog" ] (List.map (archiveRow model) archives)


archiveRow : Model -> TaskArchiveSummary -> Html Msg
archiveRow model archive =
    div [ Attr.class "archive-row" ]
        [ div []
            [ p [ Attr.class "archive-id" ] [ text archive.taskId ]
            , p [] [ text archive.preview ]
            , p [ Attr.class "source" ]
                [ text
                    (String.fromInt archive.runCount
                        ++ " 次运行 · "
                        ++ String.fromInt archive.entryCount
                        ++ " 条记录"
                    )
                ]
            ]
        , button [ Attr.type_ "button", Events.onClick (ContinueArchivedTask archive.taskId) ] [ text "继续任务" ]
        ]


taskRecordHit : TaskRecordHit -> Html Msg
taskRecordHit hit =
    button
        [ Attr.class "task-record-hit"
        , Attr.type_ "button"
        , Events.onClick (OpenTaskRecord hit)
        ]
        [ span [ Attr.class "snippet-meta" ]
            [ text
                (hit.kind
                    ++ " · "
                    ++ hit.taskId
                    ++ " · 第 "
                    ++ String.fromInt hit.lineNumber
                    ++ " 行"
                    ++ " · 本记录第 "
                    ++ String.fromInt hit.entryMatchIndex
                    ++ "/"
                    ++ String.fromInt hit.entryMatchCount
                    ++ " 处"
                )
            ]
        , p [] [ text hit.excerpt ]
        , p [ Attr.classList [ ( "source", True ), ( "source-warning", hit.sourceCompleteness == "unknown-source" || hit.sourceCompleteness == "truncated-record" ) ] ]
            [ text
                (evidenceLabel hit.evidenceClass
                    ++ " · "
                    ++ completenessLabel hit.sourceCompleteness
                    ++ artifactLabel hit.artifactIds
                )
            ]
        ]


taskRecordReader : Model -> Html Msg
taskRecordReader model =
    case model.selectedTaskRecord of
        Nothing ->
            text ""

        Just hit ->
            section [ Attr.class "task-record-reader" ]
                [ div [ Attr.class "section-heading" ]
                    [ div []
                        [ span [ Attr.class "eyebrow" ] [ text "来源原文" ]
                        , h2 [] [ text hit.entryId ]
                        ]
                    , button [ Attr.type_ "button", Events.onClick CloseTaskRecord ] [ text "关闭" ]
                    ]
                , case model.taskRecordReader of
                    Loading ->
                        quiet "正在读取来源窗口…"

                    Unavailable message ->
                        quiet message

                    Ready context ->
                        div []
                            (List.map taskRecordEntry context.entries
                                ++ [ button [ Attr.type_ "button", Events.onClick ExpandTaskRecord ] [ text "扩大来源窗口" ] ]
                            )
                ]


taskRecordEntry : TaskRecordEntry -> Html msg
taskRecordEntry entry =
    div [ Attr.class "task-record-entry" ]
        [ p [ Attr.class "snippet-meta" ]
            [ text
                (entry.kind
                    ++ " · seq "
                    ++ String.fromInt entry.seq
                    ++ " · run "
                    ++ entry.runId
                    ++ " · "
                    ++ evidenceLabel entry.evidenceClass
                )
            ]
        , pre [] [ text entry.content ]
        , p [ Attr.classList [ ( "source", True ), ( "source-warning", entry.sourceCompleteness == "unknown-source" || entry.sourceCompleteness == "truncated-record" ) ] ]
            [ text
                (completenessLabel entry.sourceCompleteness
                    ++ " · 内容位置 "
                    ++ String.fromInt entry.contentOffset
                    ++ " / "
                    ++ String.fromInt entry.contentTotal
                    ++ artifactLabel entry.artifactIds
                )
            ]
        ]


evidenceLabel : String -> String
evidenceLabel value =
    case value of
        "source" ->
            "直接来源"

        "derived" ->
            "模型表述"

        "process" ->
            "过程记录"

        _ ->
            "来源未分类"


completenessLabel : String -> String
completenessLabel value =
    case value of
        "complete-record" ->
            "记录完整"

        "artifact-backed" ->
            "可追溯到完整结果"

        "truncated-record" ->
            "仅保存了截断内容"

        "unknown-source" ->
            "无法确认来源完整性"

        _ ->
            "完整性未知"


artifactLabel : List String -> String
artifactLabel identifiers =
    if List.isEmpty identifiers then
        ""

    else
        " · 完整结果 " ++ String.join "、" identifiers


rawHistory : String -> Remote (List Encode.Value) -> Html Msg
rawHistory title remote =
    section [ Attr.class "memory-section raw-history" ]
        [ span [ Attr.class "eyebrow" ] [ text title ]
        , case remote of
            Loading ->
                quiet "正在读取来源…"

            Unavailable message ->
                quiet message

            Ready values ->
                if List.isEmpty values then
                    quiet "尚无记录。"

                else
                    div [] (List.map rawRecord values)
        ]


rawRemote : String -> Remote Encode.Value -> Html Msg
rawRemote title remote =
    case remote of
        Loading ->
            quiet ("正在读取" ++ title ++ "…")

        Unavailable message ->
            quiet message

        Ready value ->
            rawRecord value


rawRecord : Encode.Value -> Html msg
rawRecord value =
    details [ Attr.class "raw-memory probe" ]
        [ summary [] [ text (rawLabel value) ]
        , pre [] [ text (Encode.encode 2 value) ]
        ]


rawLabel : Encode.Value -> String
rawLabel value =
    case
        Decode.decodeValue
            (Decode.oneOf
                [ Decode.field "reason" Decode.string
                , Decode.field "trigger" Decode.string
                , Decode.field "id" Decode.string
                , Decode.field "status" Decode.string
                ]
            )
            value
    of
        Ok label ->
            label

        Err _ ->
            "查看来源与版本"


strengthLabel : Float -> String
strengthLabel strength =
    if strength >= 0.8 then
        "稳定"

    else if strength >= 0.5 then
        "形成中"

    else
        "微弱"


quiet : String -> Html Msg
quiet message =
    p [ Attr.class "quiet" ] [ text message ]


boolText : Bool -> String
boolText value =
    if value then
        "true"

    else
        "false"
