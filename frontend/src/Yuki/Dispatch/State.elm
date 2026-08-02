module Yuki.Dispatch.State exposing (Dialog(..), Effects, InputState, Model, Msg(..), dialogOpen, init, update)

import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Encode as Encode
import Yuki.Dispatch.Types exposing (..)
import Yuki.Telemetry.Decode as TelemetryDecode
import Yuki.Telemetry.Types exposing (DispatchDraft)


type alias Effects msg =
    { endpoint : String
    , inspect : Encode.Value -> Cmd msg
    , navigate : String -> Cmd msg
    }


type alias Model =
    { dialog : Maybe Dialog
    }


type Dialog
    = InputDialog InputState
    | EditDialog DraftEditor


type alias InputState =
    { yuki : String
    , text : String
    , submitting : Bool
    , error : Maybe String
    }


type Msg
    = OpenInput String
    | OpenDraft DispatchDraft
    | Close
    | InputChanged String
    | CreateSubmitted
    | Editor EditorMsg
    | Result String Int Decode.Value
    | Tick
    | SyncLock (Dict String String)


init : Model
init =
    { dialog = Nothing }


dialogOpen : Model -> Bool
dialogOpen model =
    model.dialog /= Nothing


update : Effects msg -> Msg -> Model -> ( Model, Cmd msg )
update effects msg model =
    case msg of
        OpenInput yuki ->
            ( { model | dialog = Just (InputDialog { yuki = yuki, text = "", submitting = False, error = Nothing }) }, Cmd.none )

        OpenDraft draft ->
            ( { model | dialog = Just (EditDialog (newEditor draft)) }, Cmd.none )

        Close ->
            ( { model | dialog = Nothing }, Cmd.none )

        InputChanged text ->
            ( mapDialog (mapInput (\input -> { input | text = text, error = Nothing })) model, Cmd.none )

        CreateSubmitted ->
            case model.dialog of
                Just (InputDialog input) ->
                    let
                        text =
                            String.trim input.text
                    in
                    if String.isEmpty text then
                        ( mapDialog (mapInput (\entry -> { entry | error = Just "请输入需求描述" })) model, Cmd.none )

                    else
                        ( { model | dialog = Just (InputDialog { input | submitting = True, error = Nothing }) }
                        , effects.inspect
                            (request "dispatch/create" "POST" ("/incarnations/" ++ input.yuki ++ "/dispatches")
                                (Just (Encode.object [ ( "input", Encode.string text ) ]))
                                effects.endpoint
                            )
                        )

                _ ->
                    ( model, Cmd.none )

        Editor editMsg ->
            case model.dialog of
                Just (EditDialog editor) ->
                    handleEditor effects editMsg editor model

                _ ->
                    ( model, Cmd.none )

        Result kind status body ->
            handleResult effects kind status body model

        Tick ->
            autoSave effects model

        SyncLock statuses ->
            ( { model
                | dialog =
                    case model.dialog of
                        Just (EditDialog editor) ->
                            case Dict.get editor.draft.dispatchId statuses of
                                Just status ->
                                    if status == "draft" then
                                        model.dialog

                                    else
                                        Just (EditDialog (lockEditor status editor))

                                Nothing ->
                                    model.dialog

                        other ->
                            other
              }
            , Cmd.none
            )


handleEditor : Effects msg -> EditorMsg -> DraftEditor -> Model -> ( Model, Cmd msg )
handleEditor effects editMsg editor model =
    case editMsg of
        TitleChanged text ->
            ( setDialog (EditDialog { editor | title = text, dirty = True }) model, Cmd.none )

        PromptChanged text ->
            ( setDialog (EditDialog { editor | prompt = text, dirty = True }) model, Cmd.none )

        ConfirmClicked ->
            if editor.locked then
                ( model, Cmd.none )

            else
                let
                    armed =
                        { editor | confirming = True, saving = True, dirty = False }

                    kind =
                        "dispatch/patch/" ++ editor.draft.dispatchId
                in
                ( setDialog (EditDialog armed) model
                , effects.inspect (request kind "PATCH" ("/dispatches/" ++ editor.draft.dispatchId) (Just (editorPatch armed)) effects.endpoint)
                )

        CancelClicked ->
            if editor.locked then
                ( model, Cmd.none )

            else
                let
                    armed =
                        { editor | saving = True, confirming = False }

                    kind =
                        "dispatch/cancel/" ++ editor.draft.dispatchId
                in
                ( setDialog (EditDialog armed) model
                , effects.inspect (request kind "POST" ("/dispatches/" ++ editor.draft.dispatchId ++ "/cancel") Nothing effects.endpoint)
                )


handleResult : Effects msg -> String -> Int -> Decode.Value -> Model -> ( Model, Cmd msg )
handleResult effects kind status body model =
    case String.split "/" kind of
        "create" :: _ ->
            case decodePayload status body TelemetryDecode.draftDecoder of
                Ok draft ->
                    ( { model | dialog = Just (EditDialog (newEditor draft)) }, Cmd.none )

                Err message ->
                    ( mapDialog (mapInput (\input -> { input | submitting = False, error = Just message })) model, Cmd.none )

        "patch" :: dispatchId :: _ ->
            case model.dialog of
                Just (EditDialog editor) ->
                    if editor.draft.dispatchId == dispatchId then
                        case decodePayload status body TelemetryDecode.draftDecoder of
                            Ok draft ->
                                let
                                    refreshed =
                                        refreshFromDraft draft editor
                                in
                                if refreshed.confirming then
                                    let
                                        confirmKind =
                                            "dispatch/confirm/" ++ dispatchId
                                    in
                                    ( { model | dialog = Just (EditDialog refreshed) }
                                    , effects.inspect (request confirmKind "POST" ("/dispatches/" ++ dispatchId ++ "/confirm") Nothing effects.endpoint)
                                    )

                                else
                                    ( { model | dialog = Just (EditDialog refreshed) }, Cmd.none )

                            Err message ->
                                ( { model | dialog = Just (EditDialog { editor | saving = False, confirming = False, error = Just message }) }, Cmd.none )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        "confirm" :: dispatchId :: _ ->
            case model.dialog of
                Just (EditDialog editor) ->
                    if editor.draft.dispatchId == dispatchId then
                        if status >= 200 && status < 300 then
                            case Decode.decodeValue (Decode.field "threadId" Decode.string) body of
                                Ok threadId ->
                                    ( { model | dialog = Nothing }
                                    , effects.navigate ("/yuki/" ++ editor.draft.incarnationId ++ "/chat/" ++ threadId)
                                    )

                                Err _ ->
                                    ( setDialog (EditDialog { editor | confirming = False, saving = False, error = Just "确认响应缺少 threadId" }) model, Cmd.none )

                        else
                            ( setDialog (EditDialog { editor | confirming = False, saving = False, error = Just (failureMessage status body) }) model, Cmd.none )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        "cancel" :: dispatchId :: _ ->
            case model.dialog of
                Just (EditDialog editor) ->
                    if editor.draft.dispatchId == dispatchId then
                        if status >= 200 && status < 300 then
                            ( { model | dialog = Nothing }, Cmd.none )

                        else
                            ( setDialog (EditDialog { editor | saving = False, error = Just (failureMessage status body) }) model, Cmd.none )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


autoSave : Effects msg -> Model -> ( Model, Cmd msg )
autoSave effects model =
    case model.dialog of
        Just (EditDialog editor) ->
            if editor.dirty && not editor.saving && not editor.locked then
                let
                    armed =
                        { editor | saving = True, dirty = False }

                    kind =
                        "dispatch/patch/" ++ editor.draft.dispatchId
                in
                ( { model | dialog = Just (EditDialog armed) }
                , effects.inspect (request kind "PATCH" ("/dispatches/" ++ editor.draft.dispatchId) (Just (editorPatch armed)) effects.endpoint)
                )

            else
                ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


mapDialog : (Dialog -> Dialog) -> Model -> Model
mapDialog transform model =
    { model | dialog = Maybe.map transform model.dialog }


setDialog : Dialog -> Model -> Model
setDialog dialog model =
    { model | dialog = Just dialog }


mapInput : (InputState -> InputState) -> Dialog -> Dialog
mapInput transform dialog =
    case dialog of
        InputDialog input ->
            InputDialog (transform input)

        other ->
            other


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
