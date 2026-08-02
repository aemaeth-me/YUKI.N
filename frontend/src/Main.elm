port module Main exposing (main)

import Browser
import Browser.Navigation as Nav
import Dict
import Html exposing (..)
import Html.Attributes exposing (class, href)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Time
import Url exposing (Url)
import Url.Parser as Parser exposing ((</>), Parser)
import Yuki.Fleet.View as Fleet
import Yuki.Telemetry.Decode as TelemetryDecode
import Yuki.Telemetry.State as TelemetryState exposing (TelemetryState)
import Yuki.Telemetry.Types exposing (..)
import Yuki.Workbench.State as Workbench
import Yuki.Workbench.Types exposing (WorkbenchView(..))
import Yuki.Workbench.View as WorkbenchView


port runAgent : Encode.Value -> Cmd msg


port cancelAgent : Encode.Value -> Cmd msg


port agentEvent : (Decode.Value -> msg) -> Sub msg


port transportEvent : (Decode.Value -> msg) -> Sub msg


port inspect : Encode.Value -> Cmd msg


port inspectionResult : (Decode.Value -> msg) -> Sub msg


port persistIncarnationId : String -> Cmd msg


port persistThreadId : String -> Cmd msg


port exportSessionFile : Encode.Value -> Cmd msg


port chooseSessionImport : () -> Cmd msg


port sessionImportData : (Decode.Value -> msg) -> Sub msg


port copyText : String -> Cmd msg


port followTranscript : () -> Cmd msg


port transcriptFollowChanged : (Bool -> msg) -> Sub msg


port activityEvent : (Decode.Value -> msg) -> Sub msg


type alias Flags =
    { endpoint : String
    , incarnationId : String
    , runStamp : String
    }


type Route
    = RouteFleet
    | RouteWorkbench String WorkbenchView


type alias Model =
    { nav : Nav.Key
    , route : Route
    , telemetry : TelemetryState
    , endpoint : String
    , workbench : Workbench.Model
    }


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | ActivityFrameReceived Decode.Value
    | InspectionResult Decode.Value
    | Tick Time.Posix
    | WorkbenchMsg Workbench.Msg
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
    let
        route =
            parse url
    in
    onRoute
        { nav = nav
        , route = route
        , telemetry = TelemetryState.init
        , endpoint = flags.endpoint
        , workbench = Workbench.init
        }
        route


parse : Url -> Route
parse url =
    Parser.parse routeParser url |> Maybe.withDefault RouteFleet


routeParser : Parser (Route -> Route) Route
routeParser =
    Parser.oneOf
        [ Parser.map RouteFleet Parser.top
        , Parser.map RouteFleet (Parser.s "fleet")
        , Parser.map RouteWorkbench (Parser.s "yuki" </> Parser.string </> viewParser)
        ]


viewParser : Parser (WorkbenchView -> a) a
viewParser =
    Parser.oneOf
        [ Parser.map ViewNow Parser.top
        , Parser.map ViewNow (Parser.s "now")
        , Parser.map ViewChat (Parser.s "chat")
        , Parser.map ViewTasks (Parser.s "tasks")
        , Parser.map ViewDeliveries (Parser.s "deliveries")
        , Parser.map ViewChanges (Parser.s "changes")
        , Parser.map ViewRun (Parser.s "run" </> Parser.string)
        ]


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        LinkClicked (Browser.Internal url) ->
            ( model, Nav.pushUrl model.nav (Url.toString url) )

        LinkClicked (Browser.External href) ->
            ( model, Nav.load href )

        UrlChanged url ->
            onRoute model (parse url)

        ActivityFrameReceived value ->
            case Decode.decodeValue connDecoder value of
                Ok conn ->
                    ( { model | telemetry = TelemetryState.setConn conn model.telemetry }, Cmd.none )

                Err _ ->
                    case Decode.decodeValue TelemetryDecode.frameDecoder value of
                        Ok frame ->
                            let
                                before =
                                    model.telemetry

                                after =
                                    TelemetryState.apply frame before
                            in
                            tickRefetch { model | telemetry = after } before after

                        Err _ ->
                            ( model, Cmd.none )

        InspectionResult value ->
            case Decode.decodeValue resultEnvelope value of
                Ok ( kind, status, body ) ->
                    workbenchUpdate (Workbench.InspectionResult kind status body) model

                Err _ ->
                    ( model, Cmd.none )

        Tick posix ->
            workbenchUpdate (Workbench.Tick posix) model

        WorkbenchMsg wbMsg ->
            workbenchUpdate wbMsg model

        NoOp ->
            ( model, Cmd.none )


onRoute : Model -> Route -> ( Model, Cmd Msg )
onRoute model route =
    case route of
        RouteFleet ->
            ( { model | route = route }, Cmd.none )

        RouteWorkbench yuki viewName ->
            workbenchUpdate (Workbench.Entered yuki viewName) { model | route = route }


tickRefetch : Model -> TelemetryState -> TelemetryState -> ( Model, Cmd Msg )
tickRefetch model before after =
    case model.route of
        RouteWorkbench yuki ViewNow ->
            if Dict.get yuki before.tick /= Dict.get yuki after.tick then
                workbenchUpdate (Workbench.ActivityChanged yuki) model

            else
                ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


workbenchUpdate : Workbench.Msg -> Model -> ( Model, Cmd Msg )
workbenchUpdate msg model =
    let
        ( workbench, cmd ) =
            Workbench.update (effects model) msg model.workbench
    in
    ( { model | workbench = workbench }, cmd )


effects : Model -> Workbench.Effects Msg
effects model =
    { endpoint = model.endpoint
    , inspect = inspect
    }


connDecoder : Decoder Connection
connDecoder =
    Decode.field "kind" Decode.string
        |> Decode.andThen
            (\kind ->
                if kind == "__conn" then
                    Decode.field "data"
                        (Decode.string
                            |> Decode.map
                                (\state ->
                                    case state of
                                        "live" ->
                                            ConnLive

                                        "degraded" ->
                                            ConnDegraded

                                        _ ->
                                            ConnOffline
                                )
                        )

                else
                    Decode.fail "not a connection frame"
            )


resultEnvelope : Decoder ( String, Int, Decode.Value )
resultEnvelope =
    Decode.map3 (\kind status body -> ( kind, status, body ))
        (Decode.field "kind" Decode.string)
        (Decode.field "status" Decode.int)
        (Decode.field "body" Decode.value)


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ activityEvent ActivityFrameReceived
        , Time.every 1000 Tick
        ]


view : Model -> Browser.Document Msg
view model =
    { title = "YUKI.N"
    , body =
        [ div [ class "app-shell" ]
            [ topBar model
            , div [ class "app-body" ] [ pageView model ]
            ]
        ]
    }


topBar : Model -> Html Msg
topBar model =
    header [ class "top-bar" ]
        [ a [ class "brand", href "/fleet" ] [ text "YUKI.N" ]
        , connBadge model.telemetry.conn
        ]


connBadge : Connection -> Html Msg
connBadge conn =
    case conn of
        ConnLive ->
            span [ class "conn-badge conn-live" ] [ text "● 实时" ]

        ConnDegraded ->
            span [ class "conn-badge conn-degraded" ] [ text "◐ 已降级" ]

        ConnOffline ->
            span [ class "conn-badge conn-offline" ] [ text "○ 离线" ]


pageView : Model -> Html Msg
pageView model =
    case model.route of
        RouteFleet ->
            Fleet.view model.telemetry

        RouteWorkbench yuki viewName ->
            Html.map WorkbenchMsg (WorkbenchView.view model.telemetry model.workbench yuki viewName)
