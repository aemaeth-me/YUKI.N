module Yuki.Fleet.State exposing (CreateForm, Effects, Model, Msg(..), init, request, update)

import Json.Decode as Decode
import Json.Encode as Encode


type alias Effects msg =
    { endpoint : String
    , inspect : Encode.Value -> Cmd msg
    , navigate : String -> Cmd msg
    }


type alias CreateForm =
    { id : String
    , name : String
    , direction : String
    , impressionModel : String
    , submitting : Bool
    , error : Maybe String
    }


type alias Model =
    { dialog : Maybe CreateForm }


init : Model
init =
    { dialog = Nothing }


type Msg
    = OpenCreate
    | Close
    | IdChanged String
    | NameChanged String
    | DirectionChanged String
    | ImpressionChanged String
    | Submit
    | Result String Int Decode.Value


update : Effects msg -> Msg -> Model -> ( Model, Cmd msg )
update effects msg model =
    case msg of
        OpenCreate ->
            ( { model | dialog = Just (CreateForm "" "" "" "" False Nothing) }, Cmd.none )

        Close ->
            ( { model | dialog = Nothing }, Cmd.none )

        IdChanged text ->
            ( mapForm (\form -> { form | id = text, error = Nothing }) model, Cmd.none )

        NameChanged text ->
            ( mapForm (\form -> { form | name = text, error = Nothing }) model, Cmd.none )

        DirectionChanged text ->
            ( mapForm (\form -> { form | direction = text, error = Nothing }) model, Cmd.none )

        ImpressionChanged text ->
            ( mapForm (\form -> { form | impressionModel = text, error = Nothing }) model, Cmd.none )

        Submit ->
            case model.dialog of
                Just form ->
                    case validate form of
                        Err message ->
                            ( mapForm (\entry -> { entry | error = Just message }) model, Cmd.none )

                        Ok () ->
                            ( { model | dialog = Just { form | submitting = True, error = Nothing } }
                            , effects.inspect
                                (request "create" "POST" "/incarnations" (Just (createBody form)) effects.endpoint)
                            )

                Nothing ->
                    ( model, Cmd.none )

        Result kind status body ->
            case model.dialog of
                Just form ->
                    if status >= 200 && status < 300 then
                        ( { model | dialog = Nothing }
                        , Cmd.batch
                            [ effects.navigate ("/yuki/" ++ String.trim form.id ++ "/now")
                            , effects.inspect (request "fleet" "GET" "/fleet" Nothing effects.endpoint)
                            ]
                        )

                    else
                        ( { model | dialog = Just { form | submitting = False, error = Just (failureMessage status body) } }
                        , Cmd.none
                        )

                Nothing ->
                    ( model, Cmd.none )


validate : CreateForm -> Result String ()
validate form =
    if not (validId (String.trim form.id)) then
        Err "id 不合法：小写字母开头，可含数字与连字符"

    else if String.isEmpty (String.trim form.name) then
        Err "请输入名称"

    else if String.isEmpty (String.trim form.direction) then
        Err "请输入方向"

    else
        Ok ()


validId : String -> Bool
validId id =
    case String.uncons id of
        Just ( first, rest ) ->
            isLower first && String.length id <= 64 && String.all isAllowed rest

        Nothing ->
            False


isAllowed : Char -> Bool
isAllowed char =
    isLower char || isDigit char || char == '-'


isLower : Char -> Bool
isLower char =
    char >= 'a' && char <= 'z'


isDigit : Char -> Bool
isDigit char =
    char >= '0' && char <= '9'


createBody : CreateForm -> Encode.Value
createBody form =
    Encode.object
        ([ ( "id", Encode.string (String.trim form.id) )
         , ( "name", Encode.string (String.trim form.name) )
         , ( "direction", Encode.string (String.trim form.direction) )
         ]
            ++ optionalImpression form.impressionModel
        )


optionalImpression : String -> List ( String, Encode.Value )
optionalImpression model =
    if String.isEmpty (String.trim model) then
        []

    else
        [ ( "impressionModel", Encode.string (String.trim model) ) ]


mapForm : (CreateForm -> CreateForm) -> Model -> Model
mapForm transform model =
    { model | dialog = Maybe.map transform model.dialog }


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
