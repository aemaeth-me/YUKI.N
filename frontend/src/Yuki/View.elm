module Yuki.View exposing (view)

import Html exposing (Html, div, p, text)
import Html.Attributes as Attr
import Yuki.Types exposing (..)
import Yuki.View.Capabilities as Capabilities
import Yuki.View.Conversation as Conversation
import Yuki.View.Audit as Audit
import Yuki.View.Edges as Edges
import Yuki.View.Identity as Identity
import Yuki.View.Memory as Memory
import Yuki.View.Self as Self
import Yuki.View.Tasks as Tasks


view : Model -> Html Msg
view model =
    div
        [ Attr.classList
            [ ( "paper", True )
            , ( "memory-pinned", model.memoryPinned )
            , ( "tasks-open", model.tasksOpen )
            ]
        ]
        [ div [ Attr.class "wordmark" ] [ text "YUKI.N" ]
        , Identity.rail model
        , Edges.top model
        , mainView model
        , Memory.rail model
        , Edges.presence model
        , Tasks.dialog model
        , Identity.dialog model
        , viewNotice model.notice
        ]


mainView : Model -> Html Msg
mainView model =
    case model.page of
        Conversation ->
            Conversation.view model

        Tasks ->
            Tasks.view model

        Memory ->
            Memory.page model

        Capabilities ->
            Capabilities.view model

        Self ->
            Self.view model

        Audit ->
            Audit.view model


viewNotice : Maybe String -> Html Msg
viewNotice maybeNotice =
    maybeNotice
        |> Maybe.map (\message -> p [ Attr.class "paper-notice", Attr.attribute "role" "status" ] [ text message ])
        |> Maybe.withDefault (text "")
