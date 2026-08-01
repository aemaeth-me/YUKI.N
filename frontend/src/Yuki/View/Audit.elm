module Yuki.View.Audit exposing (view)

import Dict
import Html exposing (Html, button, details, div, h1, h2, input, p, pre, section, span, summary, text)
import Html.Attributes as Attr
import Html.Events as Events
import Json.Encode as Encode
import String
import Yuki.Types exposing (..)


view : Model -> Html Msg
view model =
    div [ Attr.class "paper-page audit-page" ]
        [ div [ Attr.class "page-intro page-intro-actions" ]
            [ div []
                [ h1 [] [ text "检查" ]
                , p [] [ text "运行、事件、请求响应与完整结果的来源面；它服务于核查，不冒充日常工作入口。" ]
                ]
            , button [ Attr.type_ "button", Events.onClick RefreshAudit ] [ text "刷新索引" ]
            ]
        , input
            [ Attr.class "audit-filter"
            , Attr.type_ "search"
            , Attr.placeholder "筛选 run / task / status…"
            , Attr.value model.auditFilter
            , Events.onInput AuditFilterChanged
            ]
            []
        , div [ Attr.class "audit-layout" ]
            [ section [ Attr.class "run-index" ] [ runIndex model ]
            , section [ Attr.class "run-detail" ] [ runDetail model ]
            ]
        , artifacts model
        ]


runIndex : Model -> Html Msg
runIndex model =
    case model.auditRuns of
        Loading ->
            quiet "正在读取运行索引…"

        Unavailable message ->
            quiet message

        Ready runIds ->
            let
                visible =
                    List.filter (matches model) runIds
            in
            if List.isEmpty visible then
                quiet "没有匹配的运行。"

            else
                div [ Attr.class "run-list" ] (List.map (runCard model) visible)


matches : Model -> String -> Bool
matches model runId =
    let
        query =
            String.toLower (String.trim model.auditFilter)

        haystack =
            case Dict.get runId model.runSummaries of
                Just (Ready item) ->
                    String.join " " [ item.runId, item.threadId, item.status ]

                _ ->
                    runId
    in
    String.isEmpty query || String.contains query (String.toLower haystack)


runCard : Model -> String -> Html Msg
runCard model runId =
    let
        summaryText =
            case Dict.get runId model.runSummaries of
                Just (Ready item) ->
                    runStatus item.status
                        ++ " · "
                        ++ String.fromInt item.turns
                        ++ " 轮 · "
                        ++ String.fromInt item.toolCalls
                        ++ " 工具"

                Just Loading ->
                    "读取摘要…"

                Just (Unavailable _) ->
                    "摘要不可用"

                Nothing ->
                    "等待摘要"
    in
    button
        [ Attr.classList [ ( "run-card", True ), ( "selected", model.selectedRun == Just runId ) ]
        , Attr.type_ "button"
        , Events.onClick (SelectRun runId)
        ]
        [ span [] [ text runId ]
        , span [] [ text summaryText ]
        ]


runDetail : Model -> Html Msg
runDetail model =
    case model.selectedRun of
        Nothing ->
            quiet "选择一次运行查看完整来源链。"

        Just runId ->
            div []
                [ runSummary model runId
                , replay model runId
                , facetNav model
                , runMaterial model runId
                ]

runMaterial : Model -> String -> Html Msg
runMaterial model runId =
    if model.auditFacet == AuditConversation then
        case Dict.get runId model.runTraces of
            Just Loading ->
                quiet "正在整理运行轨迹…"

            Just (Unavailable message) ->
                quiet message

            Just (Ready trace) ->
                if List.isEmpty trace.steps then
                    quiet "这次运行没有可显示的过程材料。"

                else
                    div [ Attr.class "run-trace" ] (List.map traceStep trace.steps)

            Nothing ->
                quiet "尚未读取运行轨迹。"

    else
        case Dict.get runId model.runLogs of
            Just Loading ->
                quiet "正在读取运行日志…"

            Just (Unavailable message) ->
                quiet message

            Just (Ready rows) ->
                div [ Attr.class "journal-rows" ]
                    (rows
                        |> List.filter (facetMatch model.auditFacet)
                        |> List.map journalRow
                    )

            Nothing ->
                quiet "尚未读取日志。"


traceStep : RunTraceStep -> Html Msg
traceStep item =
    div
        [ Attr.classList
            [ ( "trace-step", True )
            , ( "trace-" ++ item.kind, True )
            , ( "is-" ++ item.status, True )
            ]
        ]
        [ span [ Attr.class "trace-mark", Attr.attribute "aria-hidden" "true" ] []
        , div [ Attr.class "trace-copy" ]
            [ div [ Attr.class "trace-heading" ]
                [ span [] [ text item.label ]
                , span [] [ text (traceStatus item.status) ]
                ]
            , if String.isEmpty (String.trim item.detail) then
                text ""

              else
                pre [] [ text item.detail ]
            , if List.isEmpty item.artifactIds then
                text ""

              else
                div [ Attr.class "trace-artifacts" ]
                    (List.map
                        (\identifier ->
                            button
                                [ Attr.type_ "button"
                                , Events.onClick (ToggleArtifact identifier)
                                ]
                                [ text ("完整结果 " ++ identifier) ]
                        )
                        item.artifactIds
                    )
            ]
        ]


traceStatus : String -> String
traceStatus status =
    case status of
        "completed" ->
            "完成"

        "failed" ->
            "失败"

        "running" ->
            "进行中"

        _ ->
            status


runStatus : String -> String
runStatus status =
    case status of
        "finished" ->
            "完成"

        "open" ->
            "进行中"

        "error" ->
            "失败"

        _ ->
            status


replay : Model -> String -> Html Msg
replay model runId =
    div [ Attr.class "replay-check" ]
        [ button [ Attr.type_ "button", Events.onClick (ReplayRun runId) ] [ text "重放核验" ]
        , case Dict.get runId model.replayReports of
            Nothing ->
                text ""

            Just Loading ->
                span [] [ text "正在重放…" ]

            Just (Unavailable message) ->
                span [ Attr.class "inline-error" ] [ text message ]

            Just (Ready report) ->
                pre [] [ text (Encode.encode 2 report) ]
        ]


runSummary : Model -> String -> Html Msg
runSummary model runId =
    case Dict.get runId model.runSummaries of
        Just (Ready item) ->
            div [ Attr.class "run-summary" ]
                [ metric "任务" item.threadId
                , metric "状态" (runStatus item.status)
                , metric "模型轮次" (String.fromInt item.turns)
                , metric "工具调用" (String.fromInt item.toolCalls)
                , metric "模型请求" (String.fromInt item.apiRequests)
                , metric "原始事件" (String.fromInt item.agentEvents)
                , metric "耗时" (duration item.firstTime item.lastTime)
                , metric "输入 / 输出 token" (String.fromInt item.usagePrompt ++ " / " ++ String.fromInt item.usageCompletion)
                ]

        _ ->
            text ""


metric : String -> String -> Html msg
metric label value =
    div [] [ span [] [ text label ], p [] [ text value ] ]


duration : Maybe Int -> Maybe Int -> String
duration first last =
    Maybe.map2 (\start finish -> String.fromInt (max 0 (finish - start)) ++ " s") first last
        |> Maybe.withDefault "—"


facetNav : Model -> Html Msg
facetNav model =
    div [ Attr.class "audit-facets" ]
        [ facet model.auditFacet AuditConversation "过程"
        , facet model.auditFacet AuditEvents "事件"
        , facet model.auditFacet AuditApi "API"
        , facet model.auditFacet AuditEntries "全部条目"
        ]


facet : AuditFacet -> AuditFacet -> String -> Html Msg
facet selected target label =
    button
        [ Attr.classList [ ( "active", selected == target ) ]
        , Attr.type_ "button"
        , Events.onClick (SelectAuditFacet target)
        ]
        [ text label ]


facetMatch : AuditFacet -> JournalRow -> Bool
facetMatch selectedFacet row =
    case selectedFacet of
        AuditConversation ->
            False

        AuditEvents ->
            row.kind == "agent.event"

        AuditApi ->
            row.kind == "api.request" || row.kind == "model.request"

        AuditEntries ->
            True


journalRow : JournalRow -> Html msg
journalRow row =
    details [ Attr.class "journal-row" ]
        [ summary []
            [ span [] [ text ("#" ++ String.fromInt row.seq) ]
            , span [] [ text row.kind ]
            , span [] [ text (String.join " / " row.scope) ]
            ]
        , pre [] [ text (rowPayload row) ]
        ]


rowPayload : JournalRow -> String
rowPayload row =
    [ row.event, row.request, row.input, row.outcome ]
        |> List.filterMap identity
        |> List.head
        |> Maybe.map (Encode.encode 2)
        |> Maybe.withDefault
            (String.join "\n"
                (List.filter (not << String.isEmpty)
                    [ Maybe.withDefault "" row.name
                    , Maybe.withDefault "" row.arguments
                    ]
                )
            )


artifacts : Model -> Html Msg
artifacts model =
    section [ Attr.class "artifact-section" ]
        [ div [ Attr.class "section-heading" ]
            [ div []
                [ span [ Attr.class "eyebrow" ] [ text "来源材料" ]
                , h2 [] [ text "完整结果" ]
                ]
            ]
        , case model.artifacts of
            Loading ->
                quiet "正在读取完整结果索引…"

            Unavailable message ->
                quiet message

            Ready values ->
                if List.isEmpty values then
                     quiet "尚无保存的完整结果。"

                else
                    div [ Attr.class "artifact-list" ] (List.map (artifact model) values)
        ]


artifact : Model -> ArtifactMeta -> Html Msg
artifact model item =
    let
        opened =
            if Dict.member item.id model.artifactBodies then
                [ Attr.attribute "open" "" ]

            else
                []
    in
    details
        (Attr.class "artifact" :: opened)
        [ summary []
            [ button [ Attr.type_ "button", Events.onClick (ToggleArtifact item.id) ]
                [ text (item.toolName ++ " · " ++ item.id ++ " · " ++ String.fromInt item.chars ++ " chars") ]
            ]
        , case Dict.get item.id model.artifactBodies of
            Just Loading ->
                quiet "正在读取正文…"

            Just (Unavailable message) ->
                quiet message

            Just (Ready body) ->
                pre [] [ text body ]

            Nothing ->
                p [] [ text item.preview ]
        ]


quiet : String -> Html msg
quiet message =
    p [ Attr.class "quiet" ] [ text message ]
