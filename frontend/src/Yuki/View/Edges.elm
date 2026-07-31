module Yuki.View.Edges exposing (presence, top)

import Html exposing (Html, button, div, nav, p, span, text)
import Html.Attributes as Attr
import Html.Events as Events
import Yuki.Types exposing (..)


top : Model -> Html Msg
top model =
    div [ Attr.class "top-edge" ]
        [ span [ Attr.class "top-edge-hint", Attr.attribute "aria-hidden" "true" ] [ text "上沿 · 页面" ]
        , nav [ Attr.class "top-nav", Attr.attribute "aria-label" "纸面去处" ]
            [ navButton model.page Conversation "对话"
            , navButton model.page Tasks "任务"
            , navButton model.page Memory "记忆"
            , navButton model.page Capabilities "能力"
            , navButton model.page Self "自我"
            , navButton model.page Audit "检查"
            ]
        ]


navButton : Page -> Page -> String -> Html Msg
navButton selected target label =
    button
        [ Attr.classList [ ( "active", selected == target ) ]
        , Attr.type_ "button"
        , Attr.attribute "aria-current" (if selected == target then "page" else "false")
        , Events.onClick (SelectPage target)
        ]
        [ text label ]


presence : Model -> Html Msg
presence model =
    div [ Attr.class "presence-wrap" ]
        [ button
            [ Attr.class "presence"
            , Attr.type_ "button"
            , Attr.attribute "aria-expanded" (boolText model.tasksOpen)
            , Attr.attribute "aria-controls" "task-switcher"
            , Events.onClick ToggleTasks
            ]
            [ span [ Attr.class "mark", Attr.attribute "aria-hidden" "true" ] []
            , span [] [ text (model.incarnation.name ++ " · " ++ presenceLabel model) ]
            ]
        , div
            [ Attr.class "context-switcher"
            , Attr.id "task-switcher"
            , Attr.attribute "aria-label" "任务"
            ]
            [ div [ Attr.class "context-head" ]
                [ div []
                    [ span [ Attr.class "eyebrow" ] [ text "任务" ]
                    , p [] [ text "一项可继续、分叉或归档的持久工作。" ]
                    ]
                , button [ Attr.type_ "button", Events.onClick CreateTask ] [ text "新任务" ]
                ]
            , contextList model
            ]
        ]


contextList : Model -> Html Msg
contextList model =
    case model.sessions of
        Loading ->
            p [ Attr.class "quiet" ] [ text "正在读取任务…" ]

        Unavailable message ->
            p [ Attr.class "quiet" ] [ text message ]

        Ready sessions ->
            let
                active =
                    List.filter (\session -> not session.archived) sessions
            in
            if List.isEmpty active then
                p [ Attr.class "quiet" ] [ text "还没有任务。" ]

            else
                div [ Attr.class "context-list" ] (List.map (contextButton model.threadId) active)


contextButton : String -> SessionMeta -> Html Msg
contextButton current session =
    button
        [ Attr.classList [ ( "current", current == session.id ) ]
        , Attr.type_ "button"
        , Attr.disabled (current == session.id)
        , Events.onClick (SwitchTask session.id)
        ]
        [ span [] [ text (if String.isEmpty (String.trim session.title) then "未命名任务" else session.title) ]
        , span [ Attr.class "context-time" ] [ text (shortId session.id) ]
        ]


presenceLabel : Model -> String
presenceLabel model =
    if model.tasksOpen then
        "选择任务"

    else
        "当前任务"


shortId : String -> String
shortId identifier =
    if String.length identifier <= 16 then
        identifier

    else
        String.left 7 identifier ++ "…" ++ String.right 6 identifier


boolText : Bool -> String
boolText value =
    if value then
        "true"

    else
        "false"
