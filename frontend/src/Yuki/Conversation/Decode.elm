module Yuki.Conversation.Decode exposing (agentEvent, eventThread, transcript)

import Json.Decode as Decode exposing (Decoder)
import Yuki.Conversation.Types exposing (..)


eventThread : Decode.Value -> Maybe String
eventThread raw =
    Decode.decodeValue (Decode.field "threadId" Decode.string) raw
        |> Result.toMaybe


agentEvent : Decode.Value -> Result String AgentEvent
agentEvent raw =
    Decode.decodeValue (Decode.field "type" Decode.string) raw
        |> Result.mapError Decode.errorToString
        |> Result.andThen
            (\kind ->
                Decode.decodeValue (eventDecoder kind) raw
                    |> Result.mapError Decode.errorToString
            )


eventDecoder : String -> Decoder AgentEvent
eventDecoder kind =
    case kind of
        "RUN_STARTED" ->
            Decode.map2 RunStarted
                (Decode.field "threadId" Decode.string)
                (Decode.field "runId" Decode.string)

        "RUN_FINISHED" ->
            Decode.map2 RunFinished
                (Decode.field "threadId" Decode.string)
                (Decode.field "runId" Decode.string)

        "RUN_ERROR" ->
            Decode.map2 RunError
                (Decode.field "message" Decode.string)
                (Decode.maybe (Decode.field "code" Decode.string))

        "RUN_CANCELLED" ->
            Decode.map RunCancelled (Decode.field "runId" Decode.string)

        "STEP_STARTED" ->
            Decode.map StepStarted (Decode.field "stepName" Decode.string)

        "STEP_FINISHED" ->
            Decode.map StepFinished (Decode.field "stepName" Decode.string)

        "TEXT_MESSAGE_START" ->
            Decode.map TextStarted (Decode.field "messageId" Decode.string)

        "TEXT_MESSAGE_CONTENT" ->
            Decode.map2 TextContent
                (Decode.field "messageId" Decode.string)
                (Decode.field "delta" Decode.string)

        "TEXT_MESSAGE_END" ->
            Decode.map TextEnded (Decode.field "messageId" Decode.string)

        "REASONING_START" ->
            Decode.map ReasoningStarted (Decode.field "messageId" Decode.string)

        "REASONING_MESSAGE_START" ->
            Decode.map ReasoningStarted (Decode.field "messageId" Decode.string)

        "REASONING_MESSAGE_CONTENT" ->
            Decode.map2 ReasoningContent
                (Decode.field "messageId" Decode.string)
                (Decode.field "delta" Decode.string)

        "REASONING_MESSAGE_END" ->
            Decode.map ReasoningEnded (Decode.field "messageId" Decode.string)

        "REASONING_END" ->
            Decode.map ReasoningEnded (Decode.field "messageId" Decode.string)

        "TOOL_CALL_START" ->
            Decode.map3 ToolStarted
                (Decode.field "toolCallId" Decode.string)
                (Decode.field "toolCallName" Decode.string)
                (Decode.maybe (Decode.field "parentMessageId" Decode.string))

        "TOOL_CALL_ARGS" ->
            Decode.map2 ToolArgs
                (Decode.field "toolCallId" Decode.string)
                (Decode.field "delta" Decode.string)

        "TOOL_CALL_END" ->
            Decode.map ToolEnded (Decode.field "toolCallId" Decode.string)

        "TOOL_CALL_RESULT" ->
            Decode.map3 ToolResult
                (Decode.field "messageId" Decode.string)
                (Decode.field "toolCallId" Decode.string)
                (Decode.field "content" Decode.string)

        "CUSTOM" ->
            Decode.map2 Custom
                (Decode.field "name" Decode.string)
                (Decode.field "value" Decode.value)

        _ ->
            Decode.succeed Ignored


transcript : Decoder (List Item)
transcript =
    Decode.field "messages" (Decode.list (Decode.maybe transcriptMessage))
        |> Decode.map (List.filterMap identity)


transcriptMessage : Decoder Item
transcriptMessage =
    Decode.field "role" Decode.string
        |> Decode.andThen
            (\role ->
                case role of
                    "user" ->
                        Decode.map2 userItem idField contentField

                    "assistant" ->
                        Decode.map3 assistantItem
                            idField
                            contentField
                            (Decode.oneOf [ Decode.field "toolCalls" (Decode.list Decode.value), Decode.succeed [] ])

                    "reasoning" ->
                        Decode.map2 reasoningItem idField contentField

                    "tool" ->
                        Decode.map3 toolNote idField (Decode.oneOf [ Decode.field "toolCallId" Decode.string, Decode.succeed "" ]) contentField

                    "developer" ->
                        Decode.map3 developerNote idField (Decode.oneOf [ Decode.field "name" Decode.string, Decode.succeed "" ]) contentField

                    "system" ->
                        Decode.map2 summaryNote idField contentField

                    _ ->
                        Decode.fail ("unknown transcript role " ++ role)
            )


userItem : String -> String -> Item
userItem id content =
    UserItem { id = id, content = content }


assistantItem : String -> String -> List Decode.Value -> Item
assistantItem id content _ =
    AssistantItem { id = id, content = content, complete = True }


reasoningItem : String -> String -> Item
reasoningItem id content =
    ReasoningItem { id = id, content = content }


toolNote : String -> String -> String -> Item
toolNote id callId content =
    NoteItem { id = id, text = "工具结果" ++ callSuffix callId ++ " · " ++ clip 240 content, kind = NoteInfo }


callSuffix : String -> String
callSuffix callId =
    if String.isEmpty callId then
        ""

    else
        "（" ++ callId ++ "）"


developerNote : String -> String -> String -> Item
developerNote id name content =
    NoteItem
        { id = id
        , text =
            (case name of
                "context-summary" ->
                    "上下文摘要已整理"

                "wake-packet" ->
                    "唤醒包"

                _ ->
                    "系统说明"
            )
                ++ " · "
                ++ clip 120 content
        , kind = NoteInfo
        }


summaryNote : String -> String -> Item
summaryNote id content =
    NoteItem { id = id, text = "上下文摘要已整理 · " ++ clip 120 content, kind = NoteInfo }


clip : Int -> String -> String
clip limit content =
    if String.length content > limit then
        String.left limit content ++ "…"

    else
        content


idField : Decoder String
idField =
    Decode.field "id" Decode.string


contentField : Decoder String
contentField =
    Decode.oneOf [ Decode.field "content" Decode.string, Decode.succeed "" ]
