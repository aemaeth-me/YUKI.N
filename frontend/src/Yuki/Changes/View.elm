module Yuki.Changes.View exposing (view)

import Dict
import Html exposing (..)
import Html.Attributes exposing (class, classList, href, value)
import Html.Events exposing (onClick, onInput)
import Time exposing (Posix)
import Yuki.Changes.Diff as Diff
import Yuki.Changes.State as State
import Yuki.Telemetry.Types exposing (FsChangeRecord, FsOrigin(..))
import Yuki.Workbench.Decode exposing (SessionMeta)
import Yuki.Workbench.Format as Format


view : Posix -> State.Model -> String -> Html State.Msg
view now model yuki =
    div [ class "wb-section" ]
        [ h2 [ class "wb-section-title" ] [ text "变更" ]
        , div [ class "wb-toolbar" ]
            [ select
                [ class "wb-select"
                , value (Maybe.withDefault "" model.threadFilter)
                , onInput (\tid -> State.SetThread (if tid == "" then Nothing else Just tid))
                ]
                (option [ value "" ] [ text "全部任务" ] :: List.map threadOption (threadsFor yuki model.threads))
            , case model.threadsError of
                Just message ->
                    span [ class "wb-note-error" ] [ text ("任务列表加载失败：" ++ message) ]

                Nothing ->
                    text ""
            ]
        , if List.isEmpty model.items then
            div [ class "now-empty" ]
                [ text (if model.pending then "加载中…" else "还没有变更记录") ]

          else
            div [ class "change-list" ] (List.map (changeRow now model yuki) model.items)
        , moreButton model
        , errorNote model.error
        ]


threadsFor : String -> List SessionMeta -> List SessionMeta
threadsFor yuki threads =
    List.filter (\meta -> meta.incarnationId == yuki) threads
        |> List.sortWith (\left right -> compare right.updated left.updated)


threadOption : SessionMeta -> Html State.Msg
threadOption meta =
    option [ value meta.id ] [ text meta.title ]


changeRow : Posix -> State.Model -> String -> FsChangeRecord -> Html State.Msg
changeRow now model yuki record =
    let
        id =
            record.fsChangeId

        open =
            Dict.get id model.expanded == Just True
    in
    div [ class "change-card" ]
        [ button [ class "change-row", onClick (State.Toggle id) ]
            [ opBadge record.op
            , span [ class "change-path" ] [ text record.path ]
            , originBadge record.origin
            , span [ class "change-time" ] [ text (relativeTime now record.at) ]
            ]
        , div [ class "delivery-meta" ]
            [ a [ class "delivery-thread", href ("/yuki/" ++ yuki ++ "/chat/" ++ record.threadId) ] [ text "所属对话 ↗" ]
            , span [ class "delivery-hint" ] [ text (if open then "收起" else "展开") ]
            ]
        , if open then
            div [ class "change-expand" ] [ diffView record ]

          else
            text ""
        ]


diffView : FsChangeRecord -> Html State.Msg
diffView record =
    case record.diff of
        Just diff ->
            Diff.render (Diff.parse diff)

        Nothing ->
            case record.origin of
                OriginGit ->
                    div [ class "change-git-note" ]
                        [ (case record.stat of
                            Just stat ->
                                p [ class "change-stat" ] [ text stat ]

                            Nothing ->
                                text ""
                          )
                        , p [] [ text "由 git 补记，内容以工作区为准" ]
                        ]

                _ ->
                    div [ class "change-git-note" ] [ p [] [ text "无差异内容" ] ]


opBadge : String -> Html State.Msg
opBadge op =
    span
        [ class "badge op-badge"
        , classList
            [ ( "op-created", op == "created" )
            , ( "op-modified", op == "modified" )
            , ( "op-deleted", op == "deleted" )
            ]
        ]
        [ text (opLabel op) ]


opLabel : String -> String
opLabel op =
    case op of
        "created" ->
            "已创建"

        "modified" ->
            "已修改"

        "deleted" ->
            "已删除"

        _ ->
            op


originBadge : FsOrigin -> Html State.Msg
originBadge origin =
    case origin of
        OriginTool name _ ->
            span [ class "badge origin-badge origin-tool" ] [ text name ]

        OriginGit ->
            span [ class "badge origin-badge origin-git" ] [ text "git" ]


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
            div [ class "wb-note-error" ] [ text ("变更加载失败：" ++ message) ]

        Nothing ->
            text ""


relativeTime : Posix -> Int -> String
relativeTime now stampSeconds =
    Format.formatRelative (Format.elapsedSeconds now stampSeconds)
