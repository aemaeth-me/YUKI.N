module Yuki.SessionList exposing (Effects, Model, Msg(..), init, update, view)

import Html exposing (..)
import Html.Attributes exposing (class, disabled, placeholder, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Json.Decode as Decode
import Json.Encode as Encode
import Yuki.Conversation.Encode as EncodeMsg


type alias ThreadMeta =
    { id : String
    , title : Maybe String
    , kind : String
    , archived : Bool
    }


type alias Model =
    { threads : List ThreadMeta
    , loading : Bool
    , error : Maybe String
    , draft : String
    , creating : Bool
    }


type Msg
    = Entered
    | Result String Int Decode.Value
    | DraftChanged String
    | Create
    | Open String


type alias Effects msg =
    { endpoint : String
    , inspect : Encode.Value -> Cmd msg
    , navigate : String -> Cmd msg
    }


init : Model
init =
    { threads = []
    , loading = False
    , error = Nothing
    , draft = ""
    , creating = False
    }


update : Effects msg -> Msg -> Model -> ( Model, Cmd msg )
update effects msg model =
    case msg of
        Entered ->
            fetch effects model

        Result rest status body ->
            case String.split "/" rest of
                "session" :: "list" :: _ ->
                    handleList status body model

                "session" :: "create" :: _ ->
                    handleCreate effects status body model

                _ ->
                    ( model, Cmd.none )

        DraftChanged text ->
            ( { model | draft = text }, Cmd.none )

        Create ->
            if String.isEmpty (String.trim model.draft) then
                ( model, Cmd.none )

            else
                ( { model | creating = True }
                , effects.inspect
                    (EncodeMsg.request "session/create" "POST" "/threads"
                        (Just (Encode.object [ ( "threadId", Encode.string (String.trim model.draft) ) ]))
                        effects.endpoint
                    )
                )

        Open tid ->
            ( model, effects.navigate ("/threads/" ++ tid) )


fetch : Effects msg -> Model -> ( Model, Cmd msg )
fetch effects model =
    ( { model | loading = True, error = Nothing }
    , effects.inspect (EncodeMsg.request "session/list" "GET" "/threads" Nothing effects.endpoint)
    )


handleList : Int -> Decode.Value -> Model -> ( Model, Cmd msg )
handleList status body model =
    if status >= 200 && status < 300 then
        case Decode.decodeValue (Decode.list threadDecoder) body of
            Ok threads ->
                ( { model | threads = List.filter (not << .archived) threads, loading = False }, Cmd.none )

            Err message ->
                ( { model | loading = False, error = Just (Decode.errorToString message) }, Cmd.none )

    else
        ( { model | loading = False, error = Just (failureMessage status body) }, Cmd.none )


handleCreate : Effects msg -> Int -> Decode.Value -> Model -> ( Model, Cmd msg )
handleCreate effects status body model =
    if status >= 200 && status < 300 then
        case Decode.decodeValue (Decode.field "id" Decode.string) body of
            Ok tid ->
                ( { model | creating = False, draft = "" }, effects.navigate ("/threads/" ++ tid) )

            Err message ->
                ( { model | creating = False, error = Just (Decode.errorToString message) }, Cmd.none )

    else
        ( { model | creating = False, error = Just (failureMessage status body) }, Cmd.none )


threadDecoder : Decode.Decoder ThreadMeta
threadDecoder =
    Decode.map4 ThreadMeta
        (Decode.field "id" Decode.string)
        (Decode.maybe (Decode.field "title" Decode.string))
        (Decode.field "kind" Decode.string)
        (Decode.field "archived" Decode.bool)


failureMessage : Int -> Decode.Value -> String
failureMessage status body =
    case Decode.decodeValue (Decode.field "error" Decode.string) body of
        Ok message ->
            message

        Err _ ->
            "请求失败（" ++ String.fromInt status ++ "）"


view : Effects msg -> Model -> Html Msg
view effects model =
    div [ class "session-page" ]
        [ header [ class "session-head" ] [ span [ class "chat-title" ] [ text "会话" ] ]
        , createForm model
        , errorNote model
        , threadList effects model
        ]


createForm : Model -> Html Msg
createForm model =
    form [ class "session-create", onSubmit Create ]
        [ input
            [ class "session-create-input"
            , placeholder "新线程 ID（字母数字与 - _ .）"
            , value model.draft
            , onInput DraftChanged
            , disabled model.creating
            ]
            []
        , button
            [ class "session-create-button"
            , disabled (String.isEmpty (String.trim model.draft) || model.creating)
            ]
            [ text "创建" ]
        ]


errorNote : Model -> Html Msg
errorNote model =
    case model.error of
        Just message ->
            div [ class "chat-load-error" ] [ text message ]

        Nothing ->
            text ""


threadList : Effects msg -> Model -> Html Msg
threadList effects model =
    if model.loading && List.isEmpty model.threads then
        div [ class "session-empty" ] [ text "加载中…" ]

    else
        case model.threads of
            [] ->
                div [ class "session-empty" ] [ text "还没有会话" ]

            threads ->
                div [ class "session-list" ]
                    (List.map (threadRow effects) threads)


threadRow : Effects msg -> ThreadMeta -> Html Msg
threadRow effects meta =
    div
        [ class "session-row"
        , onClick (Open meta.id)
        ]
        [ span [ class "session-row-title" ] [ text (Maybe.withDefault meta.id meta.title) ]
        , span [ class "session-row-kind" ] [ text (kindLabel meta.kind) ]
        ]


kindLabel : String -> String
kindLabel kind =
    case kind of
        "home" ->
            "主对话"

        _ ->
            "任务"
