module Yuki.Encode exposing
    ( cancelCommand
    , confirmationDecision
    , controlRequest
    , createTaskRequest
    , inspectionRequest
    , memorySearchRequest
    , runCommand
    )

import Dict exposing (Dict)
import Json.Encode as Encode
import Yuki.Types exposing (..)


runCommand : String -> Model -> Encode.Value
runCommand runId model =
    Encode.object
        [ ( "endpoint", Encode.string (String.trim model.endpoint) )
        , ( "runId", Encode.string runId )
        , ( "input"
          , Encode.object
                [ ( "threadId", Encode.string model.threadId )
                , ( "runId", Encode.string runId )
                , ( "state", Encode.object [] )
                , ( "messages", Encode.list identity (encodedHistory model) )
                , ( "tools", Encode.list identity [ confirmationTool ] )
                , ( "context", Encode.list identity [] )
                , ( "forwardedProps"
                  , Encode.object
                        [ ( "client", Encode.string "yuki-n-paper-elm" )
                        , ( "protocolInspector", Encode.bool True )
                        ]
                  )
                ]
          )
        ]


cancelCommand : String -> Model -> Encode.Value
cancelCommand runId model =
    Encode.object
        [ ( "endpoint", Encode.string (String.trim model.endpoint) )
        , ( "runId", Encode.string runId )
        ]


inspectionRequest : Model -> String -> String -> Maybe Encode.Value -> String -> Encode.Value
inspectionRequest model kind method maybeBody path =
    Encode.object <|
        [ ( "endpoint", Encode.string (String.trim model.endpoint) )
        , ( "kind", Encode.string kind )
        , ( "method", Encode.string method )
        , ( "path", Encode.string path )
        ]
            ++ Maybe.withDefault [] (Maybe.map (\body -> [ ( "body", body ) ]) maybeBody)


controlRequest : Model -> ControlKind -> String -> String -> Encode.Value
controlRequest model kind runId content =
    inspectionRequest model
        ("control/" ++ controlName kind ++ "/" ++ runId)
        "POST"
        (Just
            (Encode.object
                [ ( "runId", Encode.string runId )
                , ( "text", Encode.string content )
                ]
            )
        )
        ("agent/" ++ controlName kind)


controlName : ControlKind -> String
controlName kind =
    case kind of
        Steer ->
            "steer"

        FollowUp ->
            "follow-up"


createTaskRequest : Model -> String -> String -> Encode.Value
createTaskRequest model identifier title =
    inspectionRequest model
        ("tasks/create/" ++ identifier)
        "POST"
        (Just
            (Encode.object
                [ ( "threadId", Encode.string identifier )
                , ( "title"
                  , if String.isEmpty (String.trim title) then
                        Encode.null

                    else
                        Encode.string (String.trim title)
                  )
                , ( "incarnationId", Encode.string model.incarnationId )
                ]
            )
        )
        "threads"


memorySearchRequest : Model -> String -> Encode.Value
memorySearchRequest model query =
    inspectionRequest model
        ("memory/search/" ++ model.incarnationId)
        "POST"
        (Just
            (Encode.object
                [ ( "action", Encode.string "grep" )
                , ( "incarnationId", Encode.string model.incarnationId )
                , ( "query", Encode.string query )
                , ( "limit", Encode.int 20 )
                ]
            )
        )
        ("incarnations/" ++ model.incarnationId ++ "/memories/search")


confirmationDecision : Bool -> String
confirmationDecision approved =
    Encode.encode 0 <|
        Encode.object
            [ ( "approved", Encode.bool approved )
            , ( "decision", Encode.string (if approved then "approved" else "rejected") )
            ]


encodedHistory : Model -> List Encode.Value
encodedHistory model =
    model.messageOrder
        |> List.filterMap (\identifier -> Dict.get identifier model.messages)
        |> List.filterMap (encodeMessage model.tools)


encodeMessage : Dict String ToolCall -> Message -> Maybe Encode.Value
encodeMessage tools message =
    case message of
        UserMessage identifier content ->
            Just <|
                Encode.object
                    [ ( "id", Encode.string identifier )
                    , ( "role", Encode.string "user" )
                    , ( "content", Encode.string content )
                    ]

        SummaryMessage identifier content ->
            Just <|
                Encode.object
                    [ ( "id", Encode.string identifier )
                    , ( "role", Encode.string "developer" )
                    , ( "name", Encode.string "context-summary" )
                    , ( "content", Encode.string content )
                    ]

        ReasoningMessage reasoning ->
            Just <|
                Encode.object
                    [ ( "id", Encode.string reasoning.id )
                    , ( "role", Encode.string "reasoning" )
                    , ( "content", Encode.string reasoning.content )
                    ]

        AssistantMessage assistant ->
            Just <|
                Encode.object
                    [ ( "id", Encode.string assistant.id )
                    , ( "role", Encode.string "assistant" )
                    , ( "content"
                      , if String.isEmpty assistant.content then
                            Encode.null

                        else
                            Encode.string assistant.content
                      )
                    , ( "toolCalls"
                      , assistant.toolCalls
                            |> List.filterMap (\identifier -> Dict.get identifier tools)
                            |> Encode.list encodeToolCall
                      )
                    ]

        ToolCallMessage identifier ->
            Dict.get identifier tools
                |> Maybe.map
                    (\tool ->
                        Encode.object
                            [ ( "id"
                              , Encode.string ("tool-" ++ tool.id)
                              )
                            , ( "role", Encode.string "assistant" )
                            , ( "content", Encode.null )
                            , ( "toolCalls", Encode.list encodeToolCall [ tool ] )
                            ]
                    )

        ToolMessage result ->
            Just <|
                Encode.object
                    [ ( "id", Encode.string result.id )
                    , ( "role", Encode.string "tool" )
                    , ( "content", Encode.string result.content )
                    , ( "toolCallId", Encode.string result.callId )
                    ]

        SubAgentMessage _ ->
            Nothing

        NoticeMessage _ _ ->
            Nothing


encodeToolCall : ToolCall -> Encode.Value
encodeToolCall tool =
    Encode.object
        [ ( "id", Encode.string tool.id )
        , ( "type", Encode.string "function" )
        , ( "function"
          , Encode.object
                [ ( "name", Encode.string tool.name )
                , ( "arguments"
                  , Encode.string <|
                        if String.isEmpty tool.arguments then
                            "{}"

                        else
                            tool.arguments
                  )
                ]
          )
        ]


confirmationTool : Encode.Value
confirmationTool =
    Encode.object
        [ ( "name", Encode.string "request_confirmation" )
        , ( "description", Encode.string "Ask the user to approve or reject a consequential action before continuing." )
        , ( "parameters"
          , Encode.object
                [ ( "type", Encode.string "object" )
                , ( "properties"
                  , Encode.object
                        [ ( "title", Encode.object [ ( "type", Encode.string "string" ) ] )
                        , ( "details", Encode.object [ ( "type", Encode.string "string" ) ] )
                        ]
                  )
                , ( "required", Encode.list Encode.string [ "title", "details" ] )
                , ( "additionalProperties", Encode.bool False )
                ]
          )
        ]
