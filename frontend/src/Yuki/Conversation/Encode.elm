module Yuki.Conversation.Encode exposing (cancelRunRequest, confirmationDecision, confirmationTool, draftCancelRequest, draftConfirmRequest, draftPatchRequest, encodeItems, request, runCommand, steerRequest)

import Json.Encode as Encode
import Yuki.Conversation.Types exposing (Item(..), ToolState)
import Yuki.Dispatch.Types exposing (DraftEditor)


runCommand : String -> String -> String -> List Item -> Encode.Value
runCommand endpoint runId threadId items =
    Encode.object
        [ ( "endpoint", Encode.string endpoint )
        , ( "runId", Encode.string runId )
        , ( "input"
          , Encode.object
                [ ( "threadId", Encode.string threadId )
                , ( "runId", Encode.string runId )
                , ( "state", Encode.object [] )
                , ( "messages", Encode.list identity (encodeItems items) )
                , ( "tools", Encode.list identity [ confirmationTool ] )
                , ( "context", Encode.list identity [] )
                , ( "forwardedProps"
                  , Encode.object
                        [ ( "client", Encode.string "yuki-n-workbench-elm" )
                        , ( "protocolInspector", Encode.bool True )
                        ]
                  )
                ]
          )
        ]


cancelRunRequest : String -> String -> Encode.Value
cancelRunRequest endpoint runId =
    Encode.object
        [ ( "endpoint", Encode.string endpoint )
        , ( "runId", Encode.string runId )
        ]


steerRequest : String -> String -> String -> String -> Encode.Value
steerRequest endpoint runId text kind =
    request kind "POST" "/agent/steer" (Just (Encode.object [ ( "runId", Encode.string runId ), ( "text", Encode.string text ) ])) endpoint


draftPatchRequest : String -> DraftEditor -> String -> Encode.Value
draftPatchRequest endpoint editor kind =
    request kind "PATCH" ("/dispatches/" ++ editor.draft.dispatchId)
        (Just (Encode.object [ ( "title", Encode.string editor.title ), ( "prompt", Encode.string editor.prompt ) ]))
        endpoint


draftConfirmRequest : String -> String -> String -> Encode.Value
draftConfirmRequest endpoint dispatchId kind =
    request kind "POST" ("/dispatches/" ++ dispatchId ++ "/confirm") Nothing endpoint


draftCancelRequest : String -> String -> String -> Encode.Value
draftCancelRequest endpoint dispatchId kind =
    request kind "POST" ("/dispatches/" ++ dispatchId ++ "/cancel") Nothing endpoint


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


confirmationDecision : Bool -> String
confirmationDecision approved =
    Encode.encode 0 <|
        Encode.object
            [ ( "approved", Encode.bool approved )
            , ( "decision", Encode.string (if approved then "approved" else "rejected") )
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


type alias Envelope =
    { id : String
    , content : String
    , toolCalls : List Encode.Value
    }


type Acc
    = Assistant Envelope
    | Plain Encode.Value


encodeItems : List Item -> List Encode.Value
encodeItems items =
    List.foldl step [] items
        |> List.map valueOf
        |> List.reverse


valueOf : Acc -> Encode.Value
valueOf acc =
    case acc of
        Assistant envelope ->
            Encode.object
                [ ( "id", Encode.string envelope.id )
                , ( "role", Encode.string "assistant" )
                , ( "content"
                  , if String.isEmpty envelope.content then
                        Encode.null

                    else
                        Encode.string envelope.content
                  )
                , ( "toolCalls", Encode.list identity envelope.toolCalls )
                ]

        Plain value ->
            value


step : Item -> List Acc -> List Acc
step item acc =
    case item of
        UserItem message ->
            Plain
                (Encode.object
                    [ ( "id", Encode.string message.id )
                    , ( "role", Encode.string "user" )
                    , ( "content", Encode.string message.content )
                    ]
                )
                :: acc

        AssistantItem assistant ->
            Assistant { id = assistant.id, content = assistant.content, toolCalls = [] } :: acc

        ReasoningItem reasoning ->
            Plain
                (Encode.object
                    [ ( "id", Encode.string reasoning.id )
                    , ( "role", Encode.string "reasoning" )
                    , ( "content", Encode.string reasoning.content )
                    ]
                )
                :: acc

        ToolItem tool ->
            case acc of
                Assistant envelope :: rest ->
                    Assistant { envelope | toolCalls = envelope.toolCalls ++ [ encodeToolCall tool ] } :: rest

                _ ->
                    Assistant { id = "tool-" ++ tool.callId, content = "", toolCalls = [ encodeToolCall tool ] } :: acc

        ToolResultItem result ->
            Plain
                (Encode.object
                    [ ( "id", Encode.string result.id )
                    , ( "role", Encode.string "tool" )
                    , ( "content", Encode.string result.content )
                    , ( "toolCallId", Encode.string result.callId )
                    ]
                )
                :: acc

        DraftCardItem _ ->
            acc

        NoteItem _ ->
            acc

        SubItem _ ->
            acc


encodeToolCall : ToolState -> Encode.Value
encodeToolCall tool =
    Encode.object
        [ ( "id", Encode.string tool.callId )
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
