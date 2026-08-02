port module Main exposing (main)

import Browser
import Browser.Navigation as Nav
import Html exposing (..)
import Html.Attributes exposing (class, classList, href)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Url exposing (Url)
import Url.Parser as Parser exposing ((</>), Parser)
import Yuki.Fleet.View as Fleet
import Yuki.Telemetry.Decode as TelemetryDecode
import Yuki.Telemetry.State as TelemetryState exposing (TelemetryState)
import Yuki.Telemetry.Types exposing (..)


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


type WorkbenchView
    = ViewNow
    | ViewChat
    | ViewTasks
    | ViewDeliveries
    | ViewChanges


type alias Model =
    { nav : Nav.Key
    , route : Route
    , telemetry : TelemetryState
    , lastYuki : String
    }


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | ActivityFrameReceived Decode.Value
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
    ( { nav = nav
      , route = parse url
      , telemetry = TelemetryState.init
      , lastYuki = flags.incarnationId
      }
    , Cmd.none
    )


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
        ]


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        LinkClicked (Browser.Internal url) ->
            ( model, Nav.pushUrl model.nav (Url.toString url) )

        LinkClicked (Browser.External href) ->
            ( model, Nav.load href )

        UrlChanged url ->
            ( { model | route = parse url }, Cmd.none )

        ActivityFrameReceived value ->
            case Decode.decodeValue connDecoder value of
                Ok conn ->
                    ( { model | telemetry = TelemetryState.setConn conn model.telemetry }, Cmd.none )

                Err _ ->
                    case Decode.decodeValue TelemetryDecode.frameDecoder value of
                        Ok frame ->
                            ( { model | telemetry = TelemetryState.apply frame model.telemetry }, Cmd.none )

                        Err _ ->
                            ( model, Cmd.none )

        NoOp ->
            ( model, Cmd.none )


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


subscriptions : Model -> Sub Msg
subscriptions _ =
    activityEvent ActivityFrameReceived


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
            div [ class "workbench" ]
                [ h1 [] [ text yuki ]
                , p [] [ text (viewLabel viewName ++ " 视图即将上线") ]
                ]


viewLabel : WorkbenchView -> String
viewLabel viewName =
    case viewName of
        ViewNow ->
            "现在"

        ViewChat ->
            "主对话"

        ViewTasks ->
            "任务"

        ViewDeliveries ->
            "交付"

        ViewChanges ->
            "变更"
