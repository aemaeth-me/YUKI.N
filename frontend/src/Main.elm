port module Main exposing (main)

import Browser
import Browser.Events
import Html
import Json.Decode as Decode
import Json.Encode as Encode
import Yuki.Types exposing (Effect(..), Flags, Model, Msg(..))
import Yuki.Update as Update
import Yuki.View as View


port runAgent : Encode.Value -> Cmd msg


port cancelAgent : Encode.Value -> Cmd msg


port agentEvent : (Decode.Value -> msg) -> Sub msg


port transportEvent : (Decode.Value -> msg) -> Sub msg


port inspect : Encode.Value -> Cmd msg


port inspectionResult : (Decode.Value -> msg) -> Sub msg


port persistThreadId : String -> Cmd msg


port persistIncarnationId : String -> Cmd msg


port exportSessionFile : Encode.Value -> Cmd msg


port chooseSessionImport : () -> Cmd msg


port sessionImportData : (Decode.Value -> msg) -> Sub msg


port copyText : String -> Cmd msg


port followTranscript : () -> Cmd msg


port transcriptFollowChanged : (Bool -> msg) -> Sub msg


main : Program Flags Model Msg
main =
    Browser.element
        { init = Update.init >> withEffect
        , update = \msg model -> Update.update msg model |> withEffect
        , subscriptions = subscriptions
        , view = View.view
        }


withEffect : ( Model, Effect ) -> ( Model, Cmd Msg )
withEffect ( model, effect ) =
    ( model, perform effect )


perform : Effect -> Cmd Msg
perform effect =
    case effect of
        None ->
            Cmd.none

        Batch effects ->
            Cmd.batch (List.map perform effects)

        RunAgent value ->
            runAgent value

        CancelAgent value ->
            cancelAgent value

        Inspect value ->
            inspect value

        PersistThread identifier ->
            persistThreadId identifier

        PersistIncarnation identifier ->
            persistIncarnationId identifier

        ExportSession identifier value ->
            exportSessionFile <|
                Encode.object
                    [ ( "threadId", Encode.string identifier )
                    , ( "bundle", value )
                    ]

        ChooseSessionImport ->
            chooseSessionImport ()

        Copy content ->
            copyText content

        FollowTranscript ->
            followTranscript ()


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ agentEvent AgentEventReceived
        , transportEvent TransportEventReceived
        , inspectionResult InspectionReceived
        , sessionImportData SessionImportReceived
        , transcriptFollowChanged TranscriptFollowChanged
        , Browser.Events.onKeyDown escapeKey
        ]


escapeKey : Decode.Decoder Msg
escapeKey =
    Decode.field "key" Decode.string
        |> Decode.map
            (\key ->
                if key == "Escape" then
                    CloseEdges

                else
                    NoOp
            )
