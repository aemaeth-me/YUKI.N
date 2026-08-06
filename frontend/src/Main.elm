port module Main exposing (main)

import Browser
import Browser.Navigation as Nav
import Html exposing (..)
import Html.Attributes exposing (class, href)
import Json.Decode as Decode
import Json.Encode as Encode
import Url exposing (Url)
import Url.Parser as Parser exposing ((</>), Parser)
import Yuki.Conversation.State as Conversation
import Yuki.Conversation.Types as ConversationTypes
import Yuki.Conversation.View as ConversationView
import Yuki.SessionList as Sessions


port runAgent : Encode.Value -> Cmd msg


port agentEvent : (Decode.Value -> msg) -> Sub msg


port transportEvent : (Decode.Value -> msg) -> Sub msg


port inspect : Encode.Value -> Cmd msg


port inspectionResult : (Decode.Value -> msg) -> Sub msg


port persistThreadId : String -> Cmd msg


port persistIncarnationId : String -> Cmd msg


port copyText : String -> Cmd msg


port exportSessionFile : Encode.Value -> Cmd msg


port chooseSessionImport : () -> Cmd msg


port sessionImportData : (Decode.Value -> msg) -> Sub msg


port followTranscript : () -> Cmd msg


port transcriptFollowChanged : (Bool -> msg) -> Sub msg


type alias Flags =
    { endpoint : String
    , incarnationId : String
    , runStamp : String
    }


type Route
    = RouteSessions
    | RouteChat String


type alias Model =
    { nav : Nav.Key
    , route : Route
    , endpoint : String
    , runStamp : String
    , sessions : Sessions.Model
    , conversation : Conversation.Model
    }


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | AgentEventReceived Decode.Value
    | TransportEventReceived Decode.Value
    | InspectionResult Decode.Value
    | SessionListMsg Sessions.Msg
    | ConversationMsg ConversationTypes.Msg
    | NoOp


main : Program Flags Model Msg
main =
    Browser.application
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        , onUrlRequest = LinkClicked
        , onUrlChange = UrlChanged
        }


init : Flags -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url nav =
    onRoute
        { nav = nav
        , route = parse url
        , endpoint = flags.endpoint
        , runStamp = flags.runStamp
        , sessions = Sessions.init
        , conversation = Conversation.init
        }
        (parse url)


parse : Url -> Route
parse url =
    Parser.parse routeParser url |> Maybe.withDefault RouteSessions


routeParser : Parser (Route -> Route) Route
routeParser =
    Parser.oneOf
        [ Parser.map RouteSessions Parser.top
        , Parser.map RouteSessions (Parser.s "threads")
        , Parser.map RouteChat (Parser.s "threads" </> Parser.string)
        ]


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        LinkClicked (Browser.Internal url) ->
            ( model, Nav.pushUrl model.nav (Url.toString url) )

        LinkClicked (Browser.External url) ->
            ( model, Nav.load url )

        UrlChanged url ->
            onRoute model (parse url)

        AgentEventReceived value ->
            conversationUpdate (ConversationTypes.AgentEvent value) model

        TransportEventReceived value ->
            conversationUpdate (ConversationTypes.TransportEvent value) model

        InspectionResult value ->
            case Decode.decodeValue resultEnvelope value of
                Err _ ->
                    ( model, Cmd.none )

                Ok ( kind, status, body ) ->
                    case String.split "/" kind of
                        "session" :: _ ->
                            sessionUpdate (Sessions.Result kind status body) model

                        "chat" :: _ ->
                            conversationUpdate (ConversationTypes.ChatResult kind status body) model

                        _ ->
                            ( model, Cmd.none )

        SessionListMsg sessionMsg ->
            sessionUpdate sessionMsg model

        ConversationMsg convMsg ->
            conversationUpdate convMsg model

        NoOp ->
            ( model, Cmd.none )


onRoute : Model -> Route -> ( Model, Cmd Msg )
onRoute model route =
    case route of
        RouteSessions ->
            sessionUpdate Sessions.Entered { model | route = route }

        RouteChat tid ->
            conversationUpdate (ConversationTypes.Enter tid)
                { model | route = route, conversation = Conversation.init }


sessionUpdate : Sessions.Msg -> Model -> ( Model, Cmd Msg )
sessionUpdate sessionMsg model =
    let
        ( sessions, cmd ) =
            Sessions.update (sessionEffects model) sessionMsg model.sessions
    in
    ( { model | sessions = sessions }, cmd )


conversationUpdate : ConversationTypes.Msg -> Model -> ( Model, Cmd Msg )
conversationUpdate convMsg model =
    let
        ( conversation, cmd ) =
            Conversation.update (conversationEffects model) convMsg model.conversation
    in
    ( { model | conversation = conversation }, cmd )


sessionEffects : Model -> Sessions.Effects Msg
sessionEffects model =
    { endpoint = model.endpoint
    , inspect = inspect
    , navigate = Nav.pushUrl model.nav
    }


conversationEffects : Model -> Conversation.Effects Msg
conversationEffects model =
    { endpoint = model.endpoint
    , runStamp = model.runStamp
    , inspect = inspect
    , runAgent = runAgent
    , navigate = Nav.pushUrl model.nav
    }


resultEnvelope : Decode.Decoder ( String, Int, Decode.Value )
resultEnvelope =
    Decode.map3 (\kind status body -> ( kind, status, body ))
        (Decode.field "kind" Decode.string)
        (Decode.field "status" Decode.int)
        (Decode.field "body" Decode.value)


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ agentEvent AgentEventReceived
        , transportEvent TransportEventReceived
        , inspectionResult InspectionResult
        , sessionImportData (\_ -> NoOp)
        , transcriptFollowChanged (\_ -> NoOp)
        ]


view : Model -> Browser.Document Msg
view model =
    { title = "YUKI.N"
    , body =
        [ div [ class "app-shell" ]
            [ topBar
            , div [ class "app-body" ] [ pageView model ]
            ]
        ]
    }


topBar : Html Msg
topBar =
    header [ class "top-bar" ]
        [ a [ class "brand", href "/threads" ] [ text "YUKI.N" ]
        ]


pageView : Model -> Html Msg
pageView model =
    case model.route of
        RouteSessions ->
            Html.map SessionListMsg (Sessions.view (sessionEffects model) model.sessions)

        RouteChat _ ->
            Html.map ConversationMsg (ConversationView.view model.conversation "")
