module Yuki.Conversation.Update exposing
    ( insertPathReference
    , queue
    , resolveTool
    , retry
    , send
    , updateDraft
    )

import Dict
import Json.Encode as Encode
import Yuki.Encode as Encoder
import Yuki.State as State
import Yuki.Types exposing (..)


updateDraft : String -> Model -> ( Model, Effect )
updateDraft value model =
    case pathReferencePrefix value of
        Nothing ->
            ( { model | draft = value, pathSuggestions = [] }, None )

        Just prefix ->
            ( { model | draft = value, pathSuggestions = [] }
            , Inspect <|
                Encoder.inspectionRequest model
                    ("config/paths/" ++ model.threadId)
                    "POST"
                    (Just (Encode.object [ ( "prefix", Encode.string prefix ) ]))
                    ("config/threads/" ++ model.threadId ++ "/paths")
            )


pathReferencePrefix : String -> Maybe String
pathReferencePrefix value =
    String.indexes "@" value
        |> List.reverse
        |> List.head
        |> Maybe.andThen
            (\index ->
                let
                    suffix =
                        String.dropLeft (index + 1) value

                    boundary =
                        index == 0 || String.all isWhitespace (String.slice (index - 1) index value)
                in
                if boundary && not (String.startsWith "\"" suffix) && not (String.any isWhitespace suffix) then
                    Just suffix

                else
                    Nothing
            )


insertPathReference : String -> String -> String
insertPathReference path draft =
    case pathReferencePrefix draft of
        Nothing ->
            draft

        Just prefix ->
            let
                start =
                    String.length draft - String.length prefix - 1

                reference =
                    if String.any isWhitespace path then
                        "@\"" ++ path ++ "\""

                    else
                        "@" ++ path

                suffix =
                    if String.endsWith "/" path then
                        ""

                    else
                        " "
            in
            String.left start draft ++ reference ++ suffix


isWhitespace : Char -> Bool
isWhitespace char =
    List.member char [ ' ', '\n', '\r', '\t' ]


send : String -> Model -> ( Model, Effect )
send raw model =
    let
        content =
            String.trim raw
    in
    if
        String.isEmpty content
            || not model.taskReady
            || model.transcriptLoading
            || State.isBusy model.phase
            || State.hasPendingTool model
    then
        ( model, None )

    else
        let
            ( identifier, identified ) =
                State.freshId "user" model

            next =
                State.appendMessage identifier (UserMessage identifier content)
                    { identified | draft = "", error = Nothing }
        in
        startRun next


queue : ControlKind -> Model -> ( Model, Effect )
queue kind model =
    let
        content =
            String.trim model.draft
    in
    case model.activeRun of
        Just runId ->
            if String.isEmpty content || not (State.isBusy model.phase) || State.hasPendingTool model then
                ( model, None )

            else
                let
                    ( identifier, identified ) =
                        State.freshId "user" model

                    next =
                        State.appendMessage identifier (UserMessage identifier content)
                            { identified | draft = "", error = Nothing }
                in
                ( next
                , Batch
                    [ Inspect (Encoder.controlRequest next kind runId content)
                    , FollowTranscript
                    ]
                )

        Nothing ->
            ( model, None )


retry : Model -> ( Model, Effect )
retry model =
    model.messageOrder
        |> List.reverse
        |> List.filterMap
            (\identifier ->
                Dict.get identifier model.messages
                    |> Maybe.andThen
                        (\message ->
                            case message of
                                UserMessage _ content ->
                                    Just content

                                _ ->
                                    Nothing
                        )
            )
        |> List.head
        |> Maybe.map (\content -> send content model)
        |> Maybe.withDefault ( model, None )


startRun : Model -> ( Model, Effect )
startRun model =
    let
        runId =
            model.threadId
                ++ "-"
                ++ model.runStamp
                ++ "-run-"
                ++ String.fromInt model.nextId

        next =
            { model
                | phase = Connecting
                , activeRun = Just runId
                , nextId = model.nextId + 1
                , activeStep = Nothing
                , following = True
                , usage = Nothing
            }
    in
    ( next, Batch [ RunAgent (Encoder.runCommand runId next), FollowTranscript ] )


resolveTool : String -> Bool -> Model -> ( Model, Effect )
resolveTool callId approved model =
    case Dict.get callId model.tools of
        Just tool ->
            if tool.name == "request_confirmation" && tool.stage == ToolWaiting then
                let
                    content =
                        Encoder.confirmationDecision approved

                    ( identifier, identified ) =
                        State.freshId "tool-result" model

                    next =
                        State.appendMessage identifier
                            (ToolMessage { id = identifier, callId = callId, content = content })
                            { identified
                                | tools =
                                    Dict.insert callId
                                        { tool
                                            | stage = ToolResolved (if approved then ToolApproved else ToolRejected)
                                            , result = Just content
                                        }
                                        identified.tools
                            }
                in
                startRun next

            else
                ( model, None )

        Nothing ->
            ( model, None )
