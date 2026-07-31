module Yuki.State exposing
    ( appendMessage
    , compact
    , completeStreaming
    , taskName
    , ensureAssistant
    , ensureReasoning
    , freshId
    , hasPendingTool
    , isBusy
    , lastAssistantText
    , mapAssistant
    , mapReasoning
    , mapTool
    , ensureSubAgent
    , mapSubAgent
    , restoreTranscript
    )

import Dict
import Yuki.Types exposing (..)


restoreTranscript : List TranscriptMessage -> Model -> Model
restoreTranscript entries model =
    List.foldl restoreMessage model entries


restoreMessage : TranscriptMessage -> Model -> Model
restoreMessage entry model =
    case entry of
        TranscriptUser identifier content ->
            appendMessage identifier (UserMessage identifier content) model

        TranscriptSummary identifier content ->
            appendMessage identifier (SummaryMessage identifier content) model

        TranscriptReasoning identifier content ->
            appendMessage identifier
                (ReasoningMessage { id = identifier, content = content, complete = True })
                model

        TranscriptAssistant identifier content calls ->
            let
                restored =
                    List.foldl
                        (\call tools ->
                            Dict.insert call.id
                                { id = call.id
                                , name = call.name
                                , arguments = call.arguments
                                , parentMessageId = Just identifier
                                , stage =
                                    if call.name == "request_confirmation" then
                                        ToolWaiting

                                    else
                                        ToolResolved ToolInterrupted
                                , output = ""
                                , result = Nothing
                                }
                                tools
                        )
                        model.tools
                        calls
            in
            appendMessage identifier
                (AssistantMessage
                    { id = identifier
                    , content = content
                    , toolCalls = List.map .id calls
                    , complete = True
                    }
                )
                { model | tools = restored }

        TranscriptToolResult identifier callId content ->
            appendMessage identifier
                (ToolMessage { id = identifier, callId = callId, content = content })
                (mapTool callId
                    (\tool -> { tool | stage = ToolResolved ToolReturned, result = Just content })
                    model
                )


ensureAssistant : String -> Model -> Model
ensureAssistant identifier model =
    if Dict.member identifier model.messages then
        model

    else
        appendMessage identifier
            (AssistantMessage { id = identifier, content = "", toolCalls = [], complete = False })
            model


ensureReasoning : String -> Model -> Model
ensureReasoning identifier model =
    if Dict.member identifier model.messages then
        model

    else
        appendMessage identifier
            (ReasoningMessage { id = identifier, content = "", complete = False })
            model


mapAssistant : String -> (Assistant -> Assistant) -> Model -> Model
mapAssistant identifier transform model =
    { model
        | messages =
            Dict.update identifier
                (Maybe.map
                    (\message ->
                        case message of
                            AssistantMessage assistant ->
                                AssistantMessage (transform assistant)

                            _ ->
                                message
                    )
                )
                model.messages
    }


mapReasoning : String -> (Reasoning -> Reasoning) -> Model -> Model
mapReasoning identifier transform model =
    { model
        | messages =
            Dict.update identifier
                (Maybe.map
                    (\message ->
                        case message of
                            ReasoningMessage reasoning ->
                                ReasoningMessage (transform reasoning)

                            _ ->
                                message
                    )
                )
                model.messages
    }


mapTool : String -> (ToolCall -> ToolCall) -> Model -> Model
mapTool identifier transform model =
    { model | tools = Dict.update identifier (Maybe.map transform) model.tools }


ensureSubAgent : String -> Model -> Model
ensureSubAgent callId model =
    let
        identifier =
            "sub/" ++ callId
    in
    if Dict.member identifier model.messages then
        model

    else
        appendMessage identifier
            (SubAgentMessage
                { id = identifier
                , callId = callId
                , content = ""
                , failed = False
                , error = Nothing
                , status = "等待启动"
                , activity = []
                , context = Nothing
                }
            )
            model


mapSubAgent : String -> (SubAgent -> SubAgent) -> Model -> Model
mapSubAgent callId transform model =
    let
        identifier =
            "sub/" ++ callId
    in
    { model
        | messages =
            Dict.update identifier
                (Maybe.map
                    (\message ->
                        case message of
                            SubAgentMessage sub ->
                                SubAgentMessage (transform sub)

                            _ ->
                                message
                    )
                )
                model.messages
    }


appendMessage : String -> Message -> Model -> Model
appendMessage identifier message model =
    if Dict.member identifier model.messages then
        model

    else
        { model
            | messages = Dict.insert identifier message model.messages
            , messageOrder = model.messageOrder ++ [ identifier ]
        }


completeStreaming : Model -> Model
completeStreaming model =
    { model
        | messages =
            Dict.map
                (\_ message ->
                    case message of
                        AssistantMessage assistant ->
                            AssistantMessage { assistant | complete = True }

                        ReasoningMessage reasoning ->
                            ReasoningMessage { reasoning | complete = True }

                        _ ->
                            message
                )
                model.messages
    }


freshId : String -> Model -> ( String, Model )
freshId prefix model =
    ( prefix ++ "-" ++ model.threadId ++ "-" ++ String.fromInt model.nextId
    , { model | nextId = model.nextId + 1 }
    )


lastAssistantText : Model -> Maybe String
lastAssistantText model =
    model.messageOrder
        |> List.reverse
        |> List.filterMap
            (\identifier ->
                Dict.get identifier model.messages
                    |> Maybe.andThen
                        (\message ->
                            case message of
                                AssistantMessage assistant ->
                                    if String.isEmpty (String.trim assistant.content) then
                                        Nothing

                                    else
                                        Just assistant.content

                                _ ->
                                    Nothing
                        )
            )
        |> List.head


hasPendingTool : Model -> Bool
hasPendingTool model =
    Dict.values model.tools |> List.any (\tool -> tool.stage == ToolWaiting)


isBusy : Phase -> Bool
isBusy phase =
    List.member phase [ Connecting, Streaming, AwaitingTool ]


taskName : SessionMeta -> String
taskName session =
    if String.isEmpty (String.trim session.title) then
        "未命名任务"

    else
        session.title


compact : String -> String
compact =
    String.lines >> String.join " " >> String.words >> String.join " " >> String.left 180
