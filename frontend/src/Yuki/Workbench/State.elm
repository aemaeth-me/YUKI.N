module Yuki.Workbench.State exposing (Model, Msg(..), Effects, init, update)

import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Encode as Encode
import Time exposing (Posix)
import Yuki.Conversation.State as Conversation
import Yuki.Conversation.Types as ConversationTypes
import Yuki.Dispatch.State as Dispatch
import Yuki.Run.StatusCard as StatusCard
import Yuki.Telemetry.State exposing (TelemetryState)
import Yuki.Telemetry.Types exposing (RunId)
import Yuki.Workbench.Decode exposing (ActivitySnapshot, SessionMeta, activitySnapshotDecoder, sessionMetaDecoder)
import Yuki.Workbench.Types exposing (WorkbenchView(..))


type alias Effects msg =
    { endpoint : String
    , runStamp : String
    , inspect : Encode.Value -> Cmd msg
    , runAgent : Encode.Value -> Cmd msg
    , cancelAgent : Encode.Value -> Cmd msg
    , navigate : String -> Cmd msg
    , telemetry : TelemetryState
    }


type alias Model =
    { activity : Maybe ActivitySnapshot
    , activityError : Maybe String
    , activityIncarnation : Maybe String
    , fetchPending : Bool
    , tasks : Maybe (List SessionMeta)
    , tasksError : Maybe String
    , tasksPending : Bool
    , steerOpen : Dict RunId Bool
    , steerText : Dict RunId String
    , confirmCancel : Dict RunId Bool
    , actionStatus : Dict RunId String
    , now : Posix
    , yuki : Maybe String
    , conversation : Conversation.Model
    , dispatch : Dispatch.Model
    }


init : Model
init =
    { activity = Nothing
    , activityError = Nothing
    , activityIncarnation = Nothing
    , fetchPending = False
    , tasks = Nothing
    , tasksError = Nothing
    , tasksPending = False
    , steerOpen = Dict.empty
    , steerText = Dict.empty
    , confirmCancel = Dict.empty
    , actionStatus = Dict.empty
    , now = Time.millisToPosix 0
    , yuki = Nothing
    , conversation = Conversation.init
    , dispatch = Dispatch.init
    }


type Msg
    = Entered String WorkbenchView
    | ActivityChanged String
    | InspectionResult String Int Decode.Value
    | StatusCard StatusCard.Msg
    | ConversationMsg ConversationTypes.Msg
    | DispatchMsg Dispatch.Msg
    | AgentEvent Decode.Value
    | TransportEvent Decode.Value
    | Tick Posix
    | NoOp


update : Effects msg -> Msg -> Model -> ( Model, Cmd msg )
update effects msg model =
    case msg of
        Entered yuki view ->
            let
                withYuki =
                    { model | yuki = Just yuki }
            in
            case view of
                ViewNow ->
                    if model.fetchPending || model.activityIncarnation == Just yuki then
                        ( withYuki, Cmd.none )

                    else
                        fetchActivity effects yuki withYuki

                ViewTasks ->
                    fetchTasks effects withYuki

                ViewChat maybeThread ->
                    let
                        ( conversation, cmd ) =
                            Conversation.update (conversationEffects effects) (ConversationTypes.Enter yuki maybeThread) withYuki.conversation
                    in
                    ( { withYuki | conversation = conversation }, cmd )

                _ ->
                    ( withYuki, Cmd.none )

        ActivityChanged yuki ->
            if model.fetchPending then
                ( model, Cmd.none )

            else
                fetchActivity effects yuki model

        InspectionResult kind status body ->
            handleResult effects kind status body model

        StatusCard cardMsg ->
            handleCard effects cardMsg model

        ConversationMsg conversationMsg ->
            case conversationMsg of
                ConversationTypes.RequestDispatch ->
                    case model.yuki of
                        Just yuki ->
                            dispatchUpdate effects (Dispatch.OpenInput yuki) model

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    let
                        ( conversation, cmd ) =
                            Conversation.update (conversationEffects effects) conversationMsg model.conversation
                    in
                    ( { model | conversation = conversation }, cmd )

        DispatchMsg dispatchMsg ->
            let
                ( dispatch, cmd ) =
                    Dispatch.update (dispatchEffects effects) dispatchMsg model.dispatch
            in
            ( { model | dispatch = dispatch }, cmd )

        AgentEvent value ->
            let
                ( conversation, cmd ) =
                    Conversation.update (conversationEffects effects) (ConversationTypes.AgentEvent value) model.conversation
            in
            ( { model | conversation = conversation }, cmd )

        TransportEvent value ->
            let
                ( conversation, cmd ) =
                    Conversation.update (conversationEffects effects) (ConversationTypes.TransportEvent value) model.conversation
            in
            ( { model | conversation = conversation }, cmd )

        Tick posix ->
            tick effects posix model

        NoOp ->
            ( model, Cmd.none )


tick : Effects msg -> Posix -> Model -> ( Model, Cmd msg )
tick effects posix model =
    let
        ( conversation, conversationCmd ) =
            Conversation.update (conversationEffects effects) ConversationTypes.Tick model.conversation

        ( dispatch, dispatchCmd ) =
            Dispatch.update (dispatchEffects effects) (Dispatch.SyncLock effects.telemetry.draftStatus) model.dispatch

        ( dispatchTicked, dispatchTickCmd ) =
            Dispatch.update (dispatchEffects effects) Dispatch.Tick dispatch
    in
    ( { model | now = posix, conversation = conversation, dispatch = dispatchTicked }
    , Cmd.batch
        [ conversationCmd
        , dispatchCmd
        , dispatchTickCmd
        ]
    )


dispatchEffects : Effects msg -> Dispatch.Effects msg
dispatchEffects effects =
    { endpoint = effects.endpoint
    , inspect = effects.inspect
    , navigate = effects.navigate
    }


conversationEffects : Effects msg -> Conversation.Effects msg
conversationEffects effects =
    { endpoint = effects.endpoint
    , runStamp = effects.runStamp
    , inspect = effects.inspect
    , runAgent = effects.runAgent
    , cancelAgent = effects.cancelAgent
    , navigate = effects.navigate
    , telemetry = effects.telemetry
    }


fetchActivity : Effects msg -> String -> Model -> ( Model, Cmd msg )
fetchActivity effects yuki model =
    ( { model | fetchPending = True, activityIncarnation = Just yuki, activityError = Nothing }
    , effects.inspect (request "activity" "GET" ("/incarnations/" ++ yuki ++ "/activity") Nothing effects.endpoint)
    )


fetchTasks : Effects msg -> Model -> ( Model, Cmd msg )
fetchTasks effects model =
    if model.tasksPending then
        ( model, Cmd.none )

    else
        ( { model | tasksPending = True, tasksError = Nothing }
        , effects.inspect (request "tasks" "GET" "/threads?kind=task" Nothing effects.endpoint)
        )


handleResult : Effects msg -> String -> Int -> Decode.Value -> Model -> ( Model, Cmd msg )
handleResult effects kind status body model =
    case String.split "/" kind of
        "activity" :: _ ->
            case decodePayload status body activitySnapshotDecoder of
                Ok snapshot ->
                    ( { model | activity = Just snapshot, fetchPending = False }, Cmd.none )

                Err message ->
                    ( { model | activityError = Just message, fetchPending = False }, Cmd.none )

        "tasks" :: _ ->
            case decodePayload status body (Decode.list sessionMetaDecoder) of
                Ok tasks ->
                    ( { model | tasks = Just tasks, tasksPending = False }, Cmd.none )

                Err message ->
                    ( { model | tasksError = Just message, tasksPending = False }, Cmd.none )

        "chat" :: rest ->
            conversationUpdate effects (ConversationTypes.ChatResult (String.join "/" rest) status body) model

        "dispatch" :: rest ->
            dispatchUpdate effects (Dispatch.Result (String.join "/" rest) status body) model

        "steer" :: rest ->
            finishAction (String.join "/" rest) "已发送" status body model

        "cancel" :: rest ->
            finishAction (String.join "/" rest) "已请求取消" status body model

        _ ->
            ( model, Cmd.none )


conversationUpdate : Effects msg -> ConversationTypes.Msg -> Model -> ( Model, Cmd msg )
conversationUpdate effects conversationMsg model =
    let
        ( conversation, cmd ) =
            Conversation.update (conversationEffects effects) conversationMsg model.conversation
    in
    ( { model | conversation = conversation }, cmd )


dispatchUpdate : Effects msg -> Dispatch.Msg -> Model -> ( Model, Cmd msg )
dispatchUpdate effects dispatchMsg model =
    let
        ( dispatch, cmd ) =
            Dispatch.update (dispatchEffects effects) dispatchMsg model.dispatch
    in
    ( { model | dispatch = dispatch }, cmd )


finishAction : RunId -> String -> Int -> Decode.Value -> Model -> ( Model, Cmd msg )
finishAction runId okText status body model =
    let
        message =
            if status >= 200 && status < 300 then
                okText

            else
                failureMessage status body
    in
    ( { model
        | actionStatus = Dict.insert runId message model.actionStatus
        , confirmCancel = Dict.remove runId model.confirmCancel
      }
    , Cmd.none
    )


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


handleCard : Effects msg -> StatusCard.Msg -> Model -> ( Model, Cmd msg )
handleCard effects cardMsg model =
    case cardMsg of
        StatusCard.SteerInput runId text ->
            ( { model | steerText = Dict.insert runId text model.steerText }, Cmd.none )

        StatusCard.SteerToggle runId ->
            ( { model | steerOpen = toggleKey runId model.steerOpen }, Cmd.none )

        StatusCard.SteerSubmit runId ->
            case Dict.get runId model.steerText |> Maybe.map String.trim of
                Just text ->
                    if String.isEmpty text then
                        ( model, Cmd.none )

                    else
                        ( { model
                            | steerOpen = Dict.remove runId model.steerOpen
                            , steerText = Dict.remove runId model.steerText
                          }
                        , effects.inspect
                            (request ("steer/" ++ runId) "POST" "/agent/steer"
                                (Just (Encode.object [ ( "runId", Encode.string runId ), ( "text", Encode.string text ) ]))
                                effects.endpoint
                            )
                        )

                Nothing ->
                    ( model, Cmd.none )

        StatusCard.CancelArm runId ->
            ( { model | confirmCancel = toggleKey runId model.confirmCancel }, Cmd.none )

        StatusCard.CancelConfirm runId ->
            ( { model | confirmCancel = Dict.remove runId model.confirmCancel }
            , effects.inspect
                (request ("cancel/" ++ runId) "POST" "/agent/cancel"
                    (Just (Encode.object [ ( "runId", Encode.string runId ) ]))
                    effects.endpoint
                )
            )


toggleKey : String -> Dict String Bool -> Dict String Bool
toggleKey key dict =
    Dict.update key (\current -> Just (current /= Just True)) dict


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
