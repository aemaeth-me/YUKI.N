module Yuki.Delivery.View exposing (view)

import Dict
import Html exposing (..)
import Html.Attributes exposing (class, classList, href)
import Html.Events exposing (onClick)
import Time exposing (Posix)
import Yuki.Delivery.State as State
import Yuki.Telemetry.Types exposing (DeliveryRecord)
import Yuki.Workbench.Format as Format


view : Posix -> State.Model -> String -> Html State.Msg
view now model yuki =
    div [ class "wb-section" ]
        [ h2 [ class "wb-section-title" ] [ text "交付" ]
        , div [ class "wb-toolbar" ] (List.map (filterChip model.filter) filterChips)
        , if List.isEmpty (visibleItems model) then
            div [ class "now-empty" ]
                [ text
                    (if model.pending then
                        "加载中…"

                     else if List.isEmpty model.items then
                        "还没有交付记录"

                     else
                        "该类型暂无交付"
                    )
                ]

          else
            div [ class "delivery-list" ] (List.map (deliveryRow now model yuki) (visibleItems model))
        , moreButton model
        , errorNote model.error
        ]


visibleItems : State.Model -> List DeliveryRecord
visibleItems model =
    List.filter (matchesFilter model.filter) model.items


matchesFilter : String -> DeliveryRecord -> Bool
matchesFilter filter record =
    filter == "all" || record.kind == filter


filterChips : List ( String, String )
filterChips =
    [ ( "all", "全部" )
    , ( "answer", "答案" )
    , ( "file_write", "文件" )
    , ( "artifact", "artifact" )
    ]


filterChip : String -> ( String, String ) -> Html State.Msg
filterChip current ( kind, label ) =
    button
        [ class "chip"
        , classList [ ( "chip-active", current == kind ) ]
        , onClick (State.SetFilter kind)
        ]
        [ text label ]


deliveryRow : Posix -> State.Model -> String -> DeliveryRecord -> Html State.Msg
deliveryRow now model yuki record =
    let
        id =
            record.deliveryId

        open =
            Dict.get id model.expanded == Just True
    in
    div [ class "delivery-card" ]
        [ button [ class "delivery-row", onClick (State.Toggle id) ]
            [ span [ class "delivery-kind" ] [ text (kindLabel record.kind) ]
            , span [ class "delivery-title" ] [ text record.title ]
            , span [ class "delivery-bytes" ] [ text (bytesLabel record.bytes) ]
            , span [ class "delivery-time" ] [ text (relativeTime now record.at) ]
            ]
        , div [ class "delivery-meta" ]
            [ a [ class "delivery-thread", href ("/yuki/" ++ yuki ++ "/chat/" ++ record.threadId) ] [ text "所属对话 ↗" ]
            , span [ class "delivery-hint" ] [ text (if open then "收起" else "展开") ]
            ]
        , if open then
            div [ class "delivery-expand" ] [ expanded model record ]

          else
            text ""
        ]


expanded : State.Model -> DeliveryRecord -> Html State.Msg
expanded model record =
    case record.kind of
        "answer" ->
            div [ class "delivery-answer" ]
                [ p [] [ text "这条交付来自对话中的回答，点击进入对应位置。" ]
                , a [ class "rsc-action rsc-action-monitor", href ("/yuki/" ++ record.incarnationId ++ "/chat/" ++ record.threadId) ] [ text "在对话中查看" ]
                ]

        "file_write" ->
            div [ class "delivery-file" ]
                [ span [ class "delivery-path" ] [ text record.ref ]
                , button [ class "delivery-copy", onClick (State.Copy record.ref) ] [ text "复制路径" ]
                ]

        "artifact" ->
            artifactView model record

        _ ->
            text ""


artifactView : State.Model -> DeliveryRecord -> Html State.Msg
artifactView model record =
    let
        id =
            record.deliveryId
    in
    case Dict.get id model.artifacts of
        Just (State.ArtifactLoaded content) ->
            pre [ class "artifact-content" ] [ text content ]

        Just (State.ArtifactFailed message) ->
            div [ class "wb-note-error" ] [ text ("artifact 加载失败：" ++ message) ]

        _ ->
            div [ class "artifact-pending" ] [ text "加载 artifact 内容…" ]


moreButton : State.Model -> Html State.Msg
moreButton model =
    if model.hasMore then
        button [ class "wb-more", onClick State.LoadMore ]
            [ text (if model.pending then "加载中…" else "加载更多") ]

    else
        text ""


errorNote : Maybe String -> Html State.Msg
errorNote error =
    case error of
        Just message ->
            div [ class "wb-note-error" ] [ text ("交付加载失败：" ++ message) ]

        Nothing ->
            text ""


kindLabel : String -> String
kindLabel kind =
    case kind of
        "file_write" ->
            "文件"

        "artifact" ->
            "artifact"

        _ ->
            "答案"


bytesLabel : Maybe Int -> String
bytesLabel bytes =
    case bytes of
        Just size ->
            Format.formatBytes size

        Nothing ->
            ""


relativeTime : Posix -> Int -> String
relativeTime now stampSeconds =
    Format.formatRelative (Format.elapsedSeconds now stampSeconds)
