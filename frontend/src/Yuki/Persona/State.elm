module Yuki.Persona.State exposing (Effects, LifecycleAction(..), Model, Msg(..), Panel, init, request, update)

import Json.Decode as Decode
import Json.Encode as Encode


type alias Effects msg =
    { endpoint : String
    , inspect : Encode.Value -> Cmd msg
    , navigate : String -> Cmd msg
    }


type alias Incarnation =
    { id : String
    , name : String
    , direction : String
    , impressionModel : Maybe String
    , revision : Int
    , status : String
    }


type LifecycleAction
    = Archive
    | Restore
    | Delete


type alias Panel =
    { id : String
    , revision : Int
    , status : String
    , name : String
    , direction : String
    , impressionModel : String
    , loading : Bool
    , saving : Bool
    , error : Maybe String
    , confirming : Maybe LifecycleAction
    , busy : Maybe LifecycleAction
    , lifecycleError : Maybe String
    }


type alias Model =
    { panel : Maybe Panel }


init : Model
init =
    { panel = Nothing }


type Msg
    = Open String
    | Close
    | NameChanged String
    | DirectionChanged String
    | ImpressionChanged String
    | Save
    | Arm LifecycleAction
    | Confirm LifecycleAction
    | Result String Int Decode.Value


update : Effects msg -> Msg -> Model -> ( Model, Cmd msg )
update effects msg model =
    case msg of
        Open yuki ->
            ( { model | panel = Just (Panel yuki 0 "active" "" "" "" True False Nothing Nothing Nothing Nothing) }
            , load effects yuki
            )

        Close ->
            ( { model | panel = Nothing }, Cmd.none )

        NameChanged text ->
            ( mapPanel (\panel -> { panel | name = text, error = Nothing }) model, Cmd.none )

        DirectionChanged text ->
            ( mapPanel (\panel -> { panel | direction = text, error = Nothing }) model, Cmd.none )

        ImpressionChanged text ->
            ( mapPanel (\panel -> { panel | impressionModel = text, error = Nothing }) model, Cmd.none )

        Save ->
            case model.panel of
                Just panel ->
                    if panel.saving || panel.loading || panel.busy /= Nothing then
                        ( model, Cmd.none )

                    else if String.isEmpty (String.trim panel.name) then
                        ( setPanel { panel | error = Just "名称不能为空" } model, Cmd.none )

                    else if String.isEmpty (String.trim panel.direction) then
                        ( setPanel { panel | error = Just "方向不能为空" } model, Cmd.none )

                    else
                        ( setPanel { panel | saving = True, error = Nothing } model
                        , effects.inspect
                            (request "persona/save" "PATCH" ("/incarnations/" ++ panel.id) (Just (patchBody panel)) effects.endpoint)
                        )

                Nothing ->
                    ( model, Cmd.none )

        Arm action ->
            ( mapPanel (\panel -> { panel | confirming = toggleAction action panel.confirming, lifecycleError = Nothing }) model, Cmd.none )

        Confirm action ->
            case model.panel of
                Just panel ->
                    if panel.busy /= Nothing then
                        ( model, Cmd.none )

                    else
                        let
                            ( kind, path ) =
                                lifecycleRequest action panel.id
                        in
                        ( setPanel { panel | busy = Just action, confirming = Nothing, lifecycleError = Nothing } model
                        , effects.inspect (request kind "POST" path (Just (revisionBody panel)) effects.endpoint)
                        )

                Nothing ->
                    ( model, Cmd.none )

        Result kind status body ->
            case String.split "/" kind of
                "load" :: _ ->
                    loadResult status body model

                "save" :: _ ->
                    saveResult effects status body model

                "archive" :: _ ->
                    lifecycleResult effects Archive status body model

                "restore" :: _ ->
                    lifecycleResult effects Restore status body model

                "delete" :: _ ->
                    lifecycleResult effects Delete status body model

                _ ->
                    ( model, Cmd.none )


load : Effects msg -> String -> Cmd msg
load effects yuki =
    effects.inspect (request "persona/load" "GET" ("/incarnations/" ++ yuki ++ "?archived=true") Nothing effects.endpoint)


loadResult : Int -> Decode.Value -> Model -> ( Model, Cmd msg )
loadResult status body model =
    case decodePayload status body incarnationDecoder of
        Ok incarnation ->
            ( mapPanel (refreshedFrom incarnation) model, Cmd.none )

        Err message ->
            ( mapPanel (\panel -> { panel | loading = False, error = Just message }) model, Cmd.none )


saveResult : Effects msg -> Int -> Decode.Value -> Model -> ( Model, Cmd msg )
saveResult effects status body model =
    case model.panel of
        Just panel ->
            if status >= 200 && status < 300 then
                case Decode.decodeValue (Decode.field "incarnation" incarnationDecoder) body of
                    Ok incarnation ->
                        ( mapPanel (clearError << refreshedFrom incarnation) model, Cmd.none )

                    Err _ ->
                        ( setPanel { panel | saving = False, error = Just "保存响应缺少 incarnation 字段" } model, Cmd.none )

            else if status == 409 then
                ( setPanel { panel | saving = False, error = Just "已被并发修改，表单已刷新，请重试" } model
                , load effects panel.id
                )

            else
                ( setPanel { panel | saving = False, error = Just (failureMessage status body) } model, Cmd.none )

        Nothing ->
            ( model, Cmd.none )


lifecycleResult : Effects msg -> LifecycleAction -> Int -> Decode.Value -> Model -> ( Model, Cmd msg )
lifecycleResult effects action status body model =
    case model.panel of
        Just panel ->
            if status >= 200 && status < 300 then
                case action of
                    Delete ->
                        ( { model | panel = Nothing }, effects.navigate "/fleet" )

                    Archive ->
                        case Decode.decodeValue incarnationDecoder body of
                            Ok incarnation ->
                                ( mapPanel (clearLifecycle << refreshedFrom incarnation) model, Cmd.none )

                            Err _ ->
                                ( setPanel { panel | busy = Nothing, lifecycleError = Just "响应缺少 incarnation 字段" } model, Cmd.none )

                    Restore ->
                        case Decode.decodeValue incarnationDecoder body of
                            Ok incarnation ->
                                ( mapPanel (clearLifecycle << refreshedFrom incarnation) model, Cmd.none )

                            Err _ ->
                                ( setPanel { panel | busy = Nothing, lifecycleError = Just "响应缺少 incarnation 字段" } model, Cmd.none )

            else
                ( setPanel { panel | busy = Nothing, lifecycleError = Just (failureMessage status body) } model, Cmd.none )

        Nothing ->
            ( model, Cmd.none )


refreshedFrom : Incarnation -> Panel -> Panel
refreshedFrom incarnation panel =
    { panel
        | id = incarnation.id
        , revision = incarnation.revision
        , status = incarnation.status
        , name = incarnation.name
        , direction = incarnation.direction
        , impressionModel = Maybe.withDefault "" incarnation.impressionModel
        , loading = False
        , saving = False
        , busy = Nothing
        , confirming = Nothing
    }


clearError : Panel -> Panel
clearError panel =
    { panel | error = Nothing }


clearLifecycle : Panel -> Panel
clearLifecycle panel =
    { panel | lifecycleError = Nothing }


toggleAction : LifecycleAction -> Maybe LifecycleAction -> Maybe LifecycleAction
toggleAction action confirming =
    if confirming == Just action then
        Nothing

    else
        Just action


lifecycleRequest : LifecycleAction -> String -> ( String, String )
lifecycleRequest action id =
    case action of
        Archive ->
            ( "persona/archive", "/incarnations/" ++ id ++ "/archive" )

        Restore ->
            ( "persona/restore", "/incarnations/" ++ id ++ "/restore" )

        Delete ->
            ( "persona/delete", "/incarnations/" ++ id ++ "/delete" )


patchBody : Panel -> Encode.Value
patchBody panel =
    Encode.object
        ([ ( "expectedRevision", Encode.int panel.revision )
         , ( "name", Encode.string (String.trim panel.name) )
         , ( "direction", Encode.string (String.trim panel.direction) )
         ]
            ++ optionalImpression panel.impressionModel
        )


revisionBody : Panel -> Encode.Value
revisionBody panel =
    Encode.object [ ( "expectedRevision", Encode.int panel.revision ) ]


optionalImpression : String -> List ( String, Encode.Value )
optionalImpression model =
    if String.isEmpty (String.trim model) then
        []

    else
        [ ( "impressionModel", Encode.string (String.trim model) ) ]


incarnationDecoder : Decode.Decoder Incarnation
incarnationDecoder =
    Decode.map6 Incarnation
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "direction" Decode.string)
        (Decode.field "impressionModel" (Decode.maybe Decode.string))
        (Decode.field "revision" Decode.int)
        (Decode.field "status" Decode.string)


mapPanel : (Panel -> Panel) -> Model -> Model
mapPanel transform model =
    { model | panel = Maybe.map transform model.panel }


setPanel : Panel -> Model -> Model
setPanel panel model =
    { model | panel = Just panel }


decodePayload : Int -> Decode.Value -> Decode.Decoder a -> Result String a
decodePayload status body decoder =
    if status >= 400 then
        Err (failureMessage status body)

    else
        case Decode.decodeValue decoder body of
            Ok value ->
                Ok value

            Err error ->
                Err (Decode.errorToString error)


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
