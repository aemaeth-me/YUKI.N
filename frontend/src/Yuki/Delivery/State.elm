module Yuki.Delivery.State exposing (ArtifactState(..), Effects, Model, Msg(..), init, update)

import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Encode as Encode
import Yuki.Delivery.Decode exposing (deliveryPageDecoder)
import Yuki.Telemetry.Types exposing (DeliveryRecord)


type alias Effects msg =
    { endpoint : String
    , inspect : Encode.Value -> Cmd msg
    , copyText : String -> Cmd msg
    }


type ArtifactState
    = ArtifactPending
    | ArtifactLoaded String
    | ArtifactFailed String


type alias Model =
    { yuki : Maybe String
    , items : List DeliveryRecord
    , hasMore : Bool
    , pending : Bool
    , error : Maybe String
    , filter : String
    , expanded : Dict String Bool
    , artifacts : Dict String ArtifactState
    }


init : Model
init =
    { yuki = Nothing
    , items = []
    , hasMore = False
    , pending = False
    , error = Nothing
    , filter = "all"
    , expanded = Dict.empty
    , artifacts = Dict.empty
    }


type Msg
    = Enter String
    | ActivityChanged String
    | Result String Int Decode.Value
    | SetFilter String
    | Toggle String
    | Copy String
    | LoadMore


update : Effects msg -> Msg -> Model -> ( Model, Cmd msg )
update effects msg model =
    case msg of
        Enter yuki ->
            if model.yuki == Just yuki && not model.pending && model.error == Nothing then
                ( model, Cmd.none )

            else
                fetch effects yuki (reset model)

        ActivityChanged yuki ->
            if model.yuki == Just yuki && not model.pending then
                fetch effects yuki (reset model)

            else
                ( model, Cmd.none )

        Result kind status body ->
            handleResult effects kind status body model

        SetFilter filter ->
            ( { model | filter = filter }, Cmd.none )

        Toggle id ->
            toggle effects id model

        Copy text ->
            ( model, effects.copyText text )

        LoadMore ->
            case ( model.yuki, model.hasMore, List.reverse model.items ) of
                ( Just yuki, True, last :: _ ) ->
                    if model.pending then
                        ( model, Cmd.none )

                    else
                        ( { model | pending = True }
                        , effects.inspect (request "deliveries/page" "GET" (deliveriesPath yuki (Just last.at)) Nothing effects.endpoint)
                        )

                _ ->
                    ( model, Cmd.none )


reset : Model -> Model
reset model =
    { model | items = [], hasMore = False, error = Nothing }


fetch : Effects msg -> String -> Model -> ( Model, Cmd msg )
fetch effects yuki model =
    ( { model | pending = True, yuki = Just yuki }
    , effects.inspect (request "deliveries" "GET" (deliveriesPath yuki Nothing) Nothing effects.endpoint)
    )


deliveriesPath : String -> Maybe Int -> String
deliveriesPath yuki before =
    "/incarnations/" ++ yuki ++ "/deliveries?limit=50" ++ beforeQuery before


beforeQuery : Maybe Int -> String
beforeQuery before =
    case before of
        Just at ->
            "&before=" ++ String.fromInt at

        Nothing ->
            ""


toggle : Effects msg -> String -> Model -> ( Model, Cmd msg )
toggle effects id model =
    let
        opened =
            not (Dict.get id model.expanded == Just True)

        withExpanded =
            { model | expanded = Dict.insert id opened model.expanded }
    in
    case ( opened, recordOf id model.items ) of
        ( True, Just record ) ->
            if record.kind == "artifact" && needsArtifact id model.artifacts then
                fetchArtifact effects id record.ref withExpanded

            else
                ( withExpanded, Cmd.none )

        _ ->
            ( withExpanded, Cmd.none )


recordOf : String -> List DeliveryRecord -> Maybe DeliveryRecord
recordOf id items =
    List.filter (\record -> record.deliveryId == id) items |> List.head


needsArtifact : String -> Dict String ArtifactState -> Bool
needsArtifact id artifacts =
    case Dict.get id artifacts of
        Just (ArtifactLoaded _) ->
            False

        _ ->
            True


fetchArtifact : Effects msg -> String -> String -> Model -> ( Model, Cmd msg )
fetchArtifact effects id ref model =
    ( { model | artifacts = Dict.insert id ArtifactPending model.artifacts }
    , effects.inspect (request ("artifact/" ++ id) "GET" ("/artifacts/" ++ ref) Nothing effects.endpoint)
    )


handleResult : Effects msg -> String -> Int -> Decode.Value -> Model -> ( Model, Cmd msg )
handleResult effects kind status body model =
    case String.split "/" kind of
        "deliveries" :: rest ->
            if status >= 400 then
                fail status body model

            else
                case Decode.decodeValue deliveryPageDecoder body of
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

        "artifact" :: id :: _ ->
            if status >= 400 then
                ( { model | artifacts = Dict.insert id (ArtifactFailed (failureMessage status body)) model.artifacts }, Cmd.none )

            else
                case Decode.decodeValue Decode.string body of
                    Ok content ->
                        ( { model | artifacts = Dict.insert id (ArtifactLoaded (String.left 20000 content)) model.artifacts }, Cmd.none )

                    Err _ ->
                        ( { model | artifacts = Dict.insert id (ArtifactFailed "内容解码失败") model.artifacts }, Cmd.none )

        _ ->
            ( model, Cmd.none )


fail : Int -> Decode.Value -> Model -> ( Model, Cmd msg )
fail status body model =
    ( { model | pending = False, error = Just (failureMessage status body) }, Cmd.none )


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
