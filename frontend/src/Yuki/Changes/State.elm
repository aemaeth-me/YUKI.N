module Yuki.Changes.State exposing (Effects, Model, Msg(..), init, update)

import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Encode as Encode
import Yuki.Changes.Decode exposing (fsChangePageDecoder)
import Yuki.Telemetry.Types exposing (FsChangeRecord)
import Yuki.Workbench.Decode exposing (SessionMeta, sessionMetaDecoder)


type alias Effects msg =
    { endpoint : String
    , inspect : Encode.Value -> Cmd msg
    }


type alias Model =
    { yuki : Maybe String
    , threads : List SessionMeta
    , threadsError : Maybe String
    , threadFilter : Maybe String
    , items : List FsChangeRecord
    , hasMore : Bool
    , pending : Bool
    , error : Maybe String
    , expanded : Dict String Bool
    }


init : Model
init =
    { yuki = Nothing
    , threads = []
    , threadsError = Nothing
    , threadFilter = Nothing
    , items = []
    , hasMore = False
    , pending = False
    , error = Nothing
    , expanded = Dict.empty
    }


type Msg
    = Enter String
    | ActivityChanged String
    | Result String Int Decode.Value
    | SetThread (Maybe String)
    | Toggle String
    | LoadMore


update : Effects msg -> Msg -> Model -> ( Model, Cmd msg )
update effects msg model =
    case msg of
        Enter yuki ->
            if model.yuki == Just yuki && not model.pending && model.error == Nothing then
                ( model, Cmd.none )

            else
                ( { model | yuki = Just yuki, items = [], hasMore = False, pending = True, error = Nothing }
                , Cmd.batch
                    [ effects.inspect (request "changes" "GET" (changesPath yuki model.threadFilter) Nothing effects.endpoint)
                    , effects.inspect (request "changes/threads" "GET" "/threads?kind=task" Nothing effects.endpoint)
                    ]
                )

        ActivityChanged yuki ->
            if model.yuki == Just yuki && not model.pending then
                ( { model | items = [], hasMore = False, pending = True, error = Nothing }
                , effects.inspect (request "changes" "GET" (changesPath yuki model.threadFilter) Nothing effects.endpoint)
                )

            else
                ( model, Cmd.none )

        Result kind status body ->
            handleResult effects kind status body model

        SetThread maybeThread ->
            case model.yuki of
                Just yuki ->
                    if model.pending then
                        ( model, Cmd.none )

                    else
                        ( { model | threadFilter = maybeThread, items = [], hasMore = False, pending = True, error = Nothing }
                        , effects.inspect (request "changes" "GET" (changesPath yuki maybeThread) Nothing effects.endpoint)
                        )

                Nothing ->
                    ( model, Cmd.none )

        Toggle id ->
            let
                opened =
                    not (Dict.get id model.expanded == Just True)
            in
            ( { model | expanded = Dict.insert id opened model.expanded }, Cmd.none )

        LoadMore ->
            case ( model.yuki, model.hasMore, List.reverse model.items ) of
                ( Just yuki, True, last :: _ ) ->
                    if model.pending then
                        ( model, Cmd.none )

                    else
                        ( { model | pending = True }
                        , effects.inspect (request "changes/page" "GET" (changesPath yuki model.threadFilter ++ beforeQuery last.at) Nothing effects.endpoint)
                        )

                _ ->
                    ( model, Cmd.none )


changesPath : String -> Maybe String -> String
changesPath yuki threadFilter =
    "/incarnations/" ++ yuki ++ "/fs-changes?limit=50" ++ threadQuery threadFilter


threadQuery : Maybe String -> String
threadQuery maybeThread =
    case maybeThread of
        Just tid ->
            "&threadId=" ++ tid

        Nothing ->
            ""


beforeQuery : Int -> String
beforeQuery at =
    "&before=" ++ String.fromInt at


handleResult : Effects msg -> String -> Int -> Decode.Value -> Model -> ( Model, Cmd msg )
handleResult effects kind status body model =
    case String.split "/" kind of
        "changes" :: "threads" :: _ ->
            if status >= 400 then
                ( { model | threadsError = Just (failureMessage status body) }, Cmd.none )

            else
                case Decode.decodeValue (Decode.list sessionMetaDecoder) body of
                    Ok threads ->
                        ( { model | threads = threads, threadsError = Nothing }, Cmd.none )

                    Err message ->
                        ( { model | threadsError = Just (Decode.errorToString message) }, Cmd.none )

        "changes" :: rest ->
            if status >= 400 then
                ( { model | pending = False, error = Just (failureMessage status body) }, Cmd.none )

            else
                case Decode.decodeValue fsChangePageDecoder body of
                    Ok page ->
                        let
                            append =
                                rest == [ "page" ]
                        in
                        ( { model
                            | items = if append then model.items ++ page.items else page.items
                            , hasMore = page.hasMore
                            , pending = False
                            , error = Nothing
                          }
                        , Cmd.none
                        )

                    Err message ->
                        ( { model | pending = False, error = Just (Decode.errorToString message) }, Cmd.none )

        _ ->
            ( model, Cmd.none )


failureMessage : Int -> Decode.Value -> String
failureMessage status body =
    case Decode.decodeValue (Decode.field "error" Decode.string) body of
        Ok message ->
            message

        Err _ ->
            case Decode.decodeValue Decode.string body of
                Ok message ->
                    message

                Err _ ->
                    "请求失败（HTTP " ++ String.fromInt status ++ "）"


request : String -> String -> String -> Maybe Encode.Value -> String -> Encode.Value
request kind method path body endpoint =
    Encode.object
        ([ ( "kind", Encode.string kind )
         , ( "method", Encode.string method )
         , ( "path", Encode.string path )
         , ( "endpoint", Encode.string endpoint )
         ]
            ++ (case body of
                    Just value ->
                        [ ( "body", value ) ]

                    Nothing ->
                        []
               )
        )
