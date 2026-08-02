module Yuki.Changes.Diff exposing (Kind(..), Line, parse, render)

import Html exposing (..)
import Html.Attributes exposing (class)


type Kind
    = DiffAdd
    | DiffRemove
    | DiffContext
    | DiffHeader
    | DiffNote


type alias Line =
    { kind : Kind
    , text : String
    }


parse : String -> List Line
parse raw =
    String.lines raw |> List.map classify


classify : String -> Line
classify line =
    if String.startsWith "+++" line || String.startsWith "---" line || String.startsWith "@@" line then
        { kind = DiffHeader, text = line }

    else if String.startsWith "\\" line then
        { kind = DiffNote, text = line }

    else if String.startsWith "+" line then
        { kind = DiffAdd, text = line }

    else if String.startsWith "-" line then
        { kind = DiffRemove, text = line }

    else
        { kind = DiffContext, text = line }


render : List Line -> Html msg
render lines =
    pre [ class "diff" ] (List.map lineView lines)


lineView : Line -> Html msg
lineView line =
    div [ class (kindClass line.kind) ] [ text line.text ]


kindClass : Kind -> String
kindClass kind =
    case kind of
        DiffAdd ->
            "diff-line diff-add"

        DiffRemove ->
            "diff-line diff-remove"

        DiffContext ->
            "diff-line diff-context"

        DiffHeader ->
            "diff-line diff-header"

        DiffNote ->
            "diff-line diff-note"
