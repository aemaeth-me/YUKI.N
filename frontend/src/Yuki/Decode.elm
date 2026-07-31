module Yuki.Decode exposing
    ( agentEvent
    , incarnation
    , inspectionResult
    , memorySearch
    , promptRevision
    , taskConfig
    , providerEntry
    , contextPolicy
    , taskArchiveSummary
    , taskRecordSearch
    , taskRecordContext
    , runSummary
    , runTrace
    , journalRow
    , artifact
    , impressionState
    , sessions
    , session
    , transcript
    , transportSignal
    )

import Json.Decode as Decode exposing (Decoder)
import Yuki.Types exposing (..)


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
            Decode.map2 ToolArguments
                (Decode.field "toolCallId" Decode.string)
                (Decode.field "delta" Decode.string)

        "TOOL_CALL_END" ->
            Decode.map ToolEnded (Decode.field "toolCallId" Decode.string)

        "TOOL_CALL_RESULT" ->
            Decode.map3 ToolResultReceived
                (Decode.field "messageId" Decode.string)
                (Decode.field "toolCallId" Decode.string)
                (Decode.field "content" Decode.string)

        "CUSTOM" ->
            Decode.field "name" Decode.string
                |> Decode.andThen customDecoder

        _ ->
            Decode.succeed IgnoredEvent


customDecoder : String -> Decoder AgentEvent
customDecoder name =
    let
        optional decoder =
            Decode.oneOf [ decoder, Decode.succeed (CustomObserved name) ]
    in
    case name of
        "context.inject" ->
            optional (Decode.map ContextInject (Decode.at [ "value", "content" ] Decode.string))

        "usage" ->
            optional (Decode.map UsageObserved (Decode.field "value" usage))

        "shell.output" ->
            optional <|
                Decode.map2 ShellOutput
                    (Decode.at [ "value", "callId" ] Decode.string)
                    (Decode.at [ "value", "delta" ] Decode.string)

        "provider.retry" ->
            optional <|
                Decode.map4 ProviderRetry
                    (Decode.at [ "value", "attempt" ] Decode.int)
                    (Decode.at [ "value", "maxAttempts" ] Decode.int)
                    (Decode.at [ "value", "delayMs" ] Decode.int)
                    (Decode.at [ "value", "reason" ] Decode.string)

        "context.status" ->
            optional (Decode.map ContextStatus contextGauge)

        "context.compact" ->
            optional <|
                Decode.map2 ContextCompact
                    (Decode.at [ "value", "beforeTokens" ] Decode.int)
                    (Decode.at [ "value", "afterTokens" ] Decode.int)

        "run.cancelled" ->
            optional (Decode.map RunCancelled (Decode.at [ "value", "runId" ] Decode.string))

        "agent.sub" ->
            optional <|
                Decode.map2 SubAgentObserved
                    (Decode.at [ "value", "callId" ] Decode.string)
                    (Decode.at [ "value", "event" ] Decode.value)

        _ ->
            Decode.succeed (CustomObserved name)


usage : Decoder Usage
usage =
    Decode.map3 Usage
        (Decode.maybe (Decode.field "promptTokens" Decode.int))
        (Decode.maybe (Decode.field "completionTokens" Decode.int))
        (Decode.maybe (Decode.field "cacheHitTokens" Decode.int))


contextGauge : Decoder ContextGauge
contextGauge =
    Decode.map4 ContextGauge
        (Decode.at [ "value", "tokens" ] Decode.int)
        (Decode.at [ "value", "budgetTokens" ] Decode.int)
        (Decode.at [ "value", "willCompact" ] Decode.bool)
        (Decode.at [ "value", "emergency" ] Decode.bool)


transportSignal : Decode.Value -> Result String TransportSignal
transportSignal =
    Decode.decodeValue
        (Decode.field "kind" Decode.string
            |> Decode.andThen
                (\kind ->
                    case kind of
                        "connecting" ->
                            Decode.map TransportConnecting runId

                        "open" ->
                            Decode.map TransportOpen runId

                        "closed" ->
                            Decode.map TransportClosed runId

                        "cancelled" ->
                            Decode.map TransportCancelled runId

                        "error" ->
                            Decode.map2 TransportFailed runId (Decode.field "message" Decode.string)

                        _ ->
                            Decode.fail ("unknown transport event " ++ kind)
                )
        )
        >> Result.mapError Decode.errorToString


runId : Decoder String
runId =
    Decode.field "runId" Decode.string


inspectionResult : Decode.Value -> Result String InspectionResult
inspectionResult =
    Decode.decodeValue
        (Decode.map3 InspectionResult
            (Decode.field "kind" Decode.string)
            (Decode.field "status" Decode.int)
            (Decode.field "body" Decode.value)
        )
        >> Result.mapError Decode.errorToString


sessions : Decoder (List SessionMeta)
sessions =
    Decode.list session


session : Decoder SessionMeta
session =
    Decode.map7 SessionMeta
        (Decode.field "id" Decode.string)
        (Decode.oneOf [ Decode.field "title" Decode.string, Decode.succeed "" ])
        (Decode.oneOf [ Decode.field "created" Decode.int, Decode.succeed 0 ])
        (Decode.oneOf [ Decode.field "updated" Decode.int, Decode.succeed 0 ])
        (Decode.oneOf [ Decode.field "archived" Decode.bool, Decode.succeed False ])
        (Decode.maybe (Decode.field "parent" Decode.string))
        (Decode.maybe (Decode.field "forkNode" Decode.string))


incarnation : Decoder Incarnation
incarnation =
    Decode.succeed Incarnation
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "name" Decode.string)
        |> andMap (Decode.oneOf [ Decode.field "direction" Decode.string, Decode.succeed "" ])
        |> andMap (Decode.maybe (Decode.field "promptRevision" Decode.string))
        |> andMap (Decode.maybe (Decode.field "impressionModel" Decode.string))
        |> andMap (Decode.oneOf [ Decode.field "revision" Decode.int, Decode.succeed 0 ])
        |> andMap (Decode.oneOf [ Decode.field "status" Decode.string, Decode.succeed "active" ])
        |> andMap (Decode.oneOf [ Decode.field "created" Decode.int, Decode.succeed 0 ])
        |> andMap (Decode.oneOf [ Decode.field "updated" Decode.int, Decode.succeed 0 ])


andMap : Decoder a -> Decoder (a -> b) -> Decoder b
andMap valueDecoder functionDecoder =
    Decode.map2 (|>) valueDecoder functionDecoder


impressionState : Decoder ImpressionState
impressionState =
    Decode.oneOf
        [ Decode.map3 ImpressionState
            (Decode.oneOf [ Decode.field "revision" Decode.int, Decode.succeed 0 ])
            (Decode.oneOf [ Decode.field "items" (Decode.list impressionItem), Decode.succeed [] ])
            (Decode.oneOf [ Decode.field "updated" Decode.int, Decode.succeed 0 ])
        , Decode.null { revision = 0, items = [], updated = 0 }
        ]


impressionItem : Decoder ImpressionItem
impressionItem =
    Decode.map5 ImpressionItem
        (Decode.oneOf [ Decode.field "id" Decode.string, Decode.succeed "" ])
        (Decode.field "label" Decode.string)
        (Decode.field "intuition" Decode.string)
        (Decode.oneOf [ Decode.field "strength" Decode.float, Decode.succeed 0 ])
        (Decode.oneOf [ Decode.field "sourceMemoryIds" (Decode.list Decode.string), Decode.succeed [] ])


memorySearch : String -> Decoder MemorySearch
memorySearch query =
    Decode.map
        (\snippets_ -> { snippets = snippets_, query = query })
        (Decode.oneOf [ Decode.field "snippets" (Decode.list memorySnippet), Decode.succeed [] ])


memorySnippet : Decoder MemorySnippet
memorySnippet =
    Decode.map5 MemorySnippet
        (Decode.at [ "ref", "id" ] Decode.string)
        (Decode.at [ "ref", "revision" ] Decode.int)
        (Decode.oneOf [ Decode.field "kind" Decode.string, Decode.succeed "memory" ])
        (Decode.field "snippet" Decode.string)
        (Decode.oneOf [ Decode.field "sourceRefs" (Decode.list Decode.string), Decode.succeed [] ])


promptRevision : Decoder PromptRevision
promptRevision =
    Decode.succeed PromptRevision
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.maybe (Decode.field "incarnationId" Decode.string))
        |> andMap (Decode.field "layer" Decode.string)
        |> andMap (Decode.field "sourceIntent" Decode.string)
        |> andMap (Decode.field "content" Decode.string)
        |> andMap (Decode.oneOf [ Decode.field "generatorRevision" Decode.string, Decode.succeed "" ])
        |> andMap (Decode.maybe (Decode.field "modelInvocationRef" Decode.string))
        |> andMap (Decode.maybe (Decode.field "parentRevision" Decode.string))
        |> andMap (Decode.field "ordinal" Decode.int)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (Decode.oneOf [ Decode.field "effectiveHash" Decode.string, Decode.succeed "" ])
        |> andMap (Decode.oneOf [ Decode.field "created" Decode.int, Decode.succeed 0 ])


taskConfig : Decoder TaskConfig
taskConfig =
    Decode.succeed TaskConfig
        |> andMap (Decode.maybe (Decode.field "incarnationId" Decode.string))
        |> andMap (Decode.oneOf [ Decode.field "cwdMode" Decode.string, Decode.succeed "inherit" ])
        |> andMap (Decode.maybe (Decode.field "cwd" Decode.string))
        |> andMap (Decode.maybe (Decode.field "systemPrompt" Decode.string))
        |> andMap (Decode.maybe (Decode.field "provider" Decode.string))
        |> andMap (Decode.maybe (Decode.field "model" Decode.string))
        |> andMap (Decode.maybe (Decode.field "reasoningEffort" Decode.string))
        |> andMap (Decode.maybe (Decode.field "fs" Decode.bool))
        |> andMap (Decode.maybe (Decode.field "shell" Decode.bool))
        |> andMap (Decode.maybe (Decode.field "memory" Decode.bool))
        |> andMap (Decode.maybe (Decode.field "contextReserveTokens" Decode.int))
        |> andMap (Decode.maybe (Decode.field "contextKeepUnits" Decode.int))
        |> andMap (Decode.maybe (Decode.field "contextSummaryTokens" Decode.int))


providerEntry : Decoder ProviderEntry
providerEntry =
    Decode.map7 ProviderEntry
        (Decode.field "name" Decode.string)
        (Decode.field "baseUrl" Decode.string)
        (Decode.field "dialect" Decode.string)
        (Decode.field "defaultModel" Decode.string)
        (Decode.field "keyReady" Decode.bool)
        (Decode.field "models" (Decode.list Decode.string))
        (Decode.field "contextTokens" Decode.int)


contextPolicy : Decoder ContextPolicy
contextPolicy =
    Decode.oneOf
        [ Decode.map7 ContextPolicy
            (Decode.oneOf [ Decode.field "enabled" Decode.bool, Decode.succeed True ])
            (Decode.field "windowTokens" Decode.int)
            (Decode.field "reserveTokens" Decode.int)
            (Decode.field "toolTokens" Decode.int)
            (Decode.field "budgetTokens" Decode.int)
            (Decode.field "keepUnits" Decode.int)
            (Decode.field "summaryTokens" Decode.int)
        , Decode.map
            (\enabled -> ContextPolicy enabled 0 0 0 0 0 0)
            (Decode.field "enabled" Decode.bool)
        ]


taskArchiveSummary : Decoder TaskArchiveSummary
taskArchiveSummary =
    Decode.map7 TaskArchiveSummary
        (Decode.field "incarnationId" Decode.string)
        (Decode.field "taskId" Decode.string)
        (Decode.field "runCount" Decode.int)
        (Decode.field "entryCount" Decode.int)
        (Decode.field "created" Decode.int)
        (Decode.field "updated" Decode.int)
        (Decode.oneOf [ Decode.field "preview" Decode.string, Decode.succeed "" ])


taskRecordSearch : Decoder TaskRecordSearch
taskRecordSearch =
    Decode.succeed TaskRecordSearch
        |> andMap (Decode.field "query" Decode.string)
        |> andMap (Decode.field "mode" Decode.string)
        |> andMap (Decode.field "caseSensitive" Decode.bool)
        |> andMap (Decode.field "scannedTasks" Decode.int)
        |> andMap (Decode.field "scannedEntries" Decode.int)
        |> andMap (Decode.oneOf [ Decode.field "matchedEntries" Decode.int, Decode.succeed 0 ])
        |> andMap (Decode.oneOf [ Decode.field "totalHits" Decode.int, Decode.succeed 0 ])
        |> andMap (Decode.oneOf [ Decode.field "returnedHits" Decode.int, Decode.field "hits" (Decode.list Decode.value) |> Decode.map List.length ])
        |> andMap (Decode.oneOf [ Decode.field "offset" Decode.int, Decode.succeed 0 ])
        |> andMap (Decode.oneOf [ Decode.field "limit" Decode.int, Decode.succeed 40 ])
        |> andMap (Decode.maybe (Decode.field "nextOffset" Decode.int))
        |> andMap (Decode.oneOf [ Decode.field "hasMore" Decode.bool, Decode.field "truncated" Decode.bool ])
        |> andMap (Decode.field "truncated" Decode.bool)
        |> andMap (Decode.field "hits" (Decode.list taskRecordHit))


taskRecordHit : Decoder TaskRecordHit
taskRecordHit =
    Decode.succeed TaskRecordHit
        |> andMap (Decode.field "entryId" Decode.string)
        |> andMap (Decode.field "taskId" Decode.string)
        |> andMap (Decode.field "runId" Decode.string)
        |> andMap (Decode.field "seq" Decode.int)
        |> andMap (Decode.field "kind" Decode.string)
        |> andMap (Decode.field "sourceId" Decode.string)
        |> andMap (Decode.maybe (Decode.field "toolName" Decode.string))
        |> andMap (Decode.maybe (Decode.field "callId" Decode.string))
        |> andMap (Decode.oneOf [ Decode.field "evidenceClass" Decode.string, Decode.succeed "unknown" ])
        |> andMap (Decode.oneOf [ Decode.field "sourceCompleteness" Decode.string, Decode.succeed "unknown-source" ])
        |> andMap (Decode.oneOf [ Decode.field "artifactIds" (Decode.list Decode.string), Decode.succeed [] ])
        |> andMap (Decode.field "lineNumber" Decode.int)
        |> andMap (Decode.field "matchOffset" Decode.int)
        |> andMap (Decode.oneOf [ Decode.field "entryMatchIndex" Decode.int, Decode.succeed 1 ])
        |> andMap (Decode.oneOf [ Decode.field "entryMatchCount" Decode.int, Decode.succeed 1 ])
        |> andMap (Decode.field "excerpt" Decode.string)
        |> andMap (Decode.field "created" Decode.int)


taskRecordContext : Decoder TaskRecordContext
taskRecordContext =
    Decode.map3 TaskRecordContext
        (Decode.field "taskId" Decode.string)
        (Decode.field "anchorEntryId" Decode.string)
        (Decode.field "entries" (Decode.list taskRecordEntry))


taskRecordEntry : Decoder TaskRecordEntry
taskRecordEntry =
    Decode.succeed TaskRecordEntry
        |> andMap (Decode.field "entryId" Decode.string)
        |> andMap (Decode.field "taskId" Decode.string)
        |> andMap (Decode.field "runId" Decode.string)
        |> andMap (Decode.field "seq" Decode.int)
        |> andMap (Decode.field "kind" Decode.string)
        |> andMap (Decode.field "sourceId" Decode.string)
        |> andMap (Decode.maybe (Decode.field "toolName" Decode.string))
        |> andMap (Decode.maybe (Decode.field "callId" Decode.string))
        |> andMap (Decode.oneOf [ Decode.field "evidenceClass" Decode.string, Decode.succeed "unknown" ])
        |> andMap (Decode.oneOf [ Decode.field "sourceCompleteness" Decode.string, Decode.succeed "unknown-source" ])
        |> andMap (Decode.oneOf [ Decode.field "artifactIds" (Decode.list Decode.string), Decode.succeed [] ])
        |> andMap (Decode.field "content" Decode.string)
        |> andMap (Decode.field "contentOffset" Decode.int)
        |> andMap (Decode.field "contentTotal" Decode.int)
        |> andMap (Decode.field "truncatedBefore" Decode.bool)
        |> andMap (Decode.field "truncatedAfter" Decode.bool)
        |> andMap (Decode.field "created" Decode.int)


runSummary : Decoder RunSummary
runSummary =
    Decode.succeed RunSummary
        |> andMap (Decode.field "runId" Decode.string)
        |> andMap (Decode.field "threadId" Decode.string)
        |> andMap (Decode.field "entryCount" Decode.int)
        |> andMap (Decode.field "turns" Decode.int)
        |> andMap (Decode.field "toolCalls" Decode.int)
        |> andMap (Decode.field "agentEvents" Decode.int)
        |> andMap (Decode.field "apiRequests" Decode.int)
        |> andMap (Decode.at [ "usage", "prompt" ] Decode.int)
        |> andMap (Decode.at [ "usage", "completion" ] Decode.int)
        |> andMap (Decode.at [ "usage", "cacheHit" ] Decode.int)
        |> andMap (Decode.field "memoryCalls" Decode.int)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (Decode.field "firstSeq" Decode.int)
        |> andMap (Decode.field "lastSeq" Decode.int)
        |> andMap (Decode.maybe (Decode.field "firstTime" Decode.int))
        |> andMap (Decode.maybe (Decode.field "lastTime" Decode.int))

runTrace : Decoder RunTrace
runTrace =
    Decode.map4 RunTrace
        (Decode.field "runId" Decode.string)
        (Decode.field "threadId" Decode.string)
        (Decode.field "status" Decode.string)
        (Decode.field "steps" (Decode.list runTraceStep))


runTraceStep : Decoder RunTraceStep
runTraceStep =
    Decode.succeed RunTraceStep
        |> andMap (Decode.field "seq" Decode.int)
        |> andMap (Decode.maybe (Decode.field "time" Decode.int))
        |> andMap (Decode.field "kind" Decode.string)
        |> andMap (Decode.field "label" Decode.string)
        |> andMap (Decode.field "detail" Decode.string)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (Decode.maybe (Decode.field "callId" Decode.string))
        |> andMap (Decode.field "artifactIds" (Decode.list Decode.string))


journalRow : Decoder JournalRow
journalRow =
    Decode.succeed JournalRow
        |> andMap (Decode.field "seq" Decode.int)
        |> andMap (Decode.field "scope" (Decode.list Decode.string))
        |> andMap (Decode.field "kind" Decode.string)
        |> andMap (Decode.maybe (Decode.field "time" Decode.int))
        |> andMap (Decode.maybe (Decode.field "event" Decode.value))
        |> andMap (Decode.maybe (Decode.field "request" Decode.value))
        |> andMap (Decode.maybe (Decode.field "input" Decode.value))
        |> andMap (Decode.maybe (Decode.field "name" Decode.string))
        |> andMap (Decode.maybe (Decode.field "arguments" Decode.string))
        |> andMap (Decode.maybe (Decode.field "outcome" Decode.value))


artifact : Decoder ArtifactMeta
artifact =
    Decode.map5 ArtifactMeta
        (Decode.field "id" Decode.string)
        (Decode.field "toolName" Decode.string)
        (Decode.oneOf [ Decode.field "preview" Decode.string, Decode.succeed "" ])
        (Decode.field "chars" Decode.int)
        (Decode.field "time" Decode.int)


transcript : Decoder (List TranscriptMessage)
transcript =
    Decode.field "messages" (Decode.list (Decode.maybe transcriptMessage))
        |> Decode.map (List.filterMap identity)


transcriptMessage : Decoder TranscriptMessage
transcriptMessage =
    Decode.field "role" Decode.string
        |> Decode.andThen
            (\role ->
                case role of
                    "user" ->
                        Decode.map2 TranscriptUser idField contentField

                    "developer" ->
                        Decode.map2 TranscriptSummary idField contentField

                    "system" ->
                        Decode.map2 TranscriptSummary idField contentField

                    "reasoning" ->
                        Decode.map2 TranscriptReasoning idField contentField

                    "assistant" ->
                        Decode.map3 TranscriptAssistant
                            idField
                            contentField
                            (Decode.oneOf [ Decode.field "toolCalls" (Decode.list transcriptTool), Decode.succeed [] ])

                    "tool" ->
                        Decode.map3 TranscriptToolResult
                            idField
                            (Decode.oneOf [ Decode.field "toolCallId" Decode.string, Decode.succeed "" ])
                            contentField

                    _ ->
                        Decode.fail ("unknown transcript role " ++ role)
            )


transcriptTool : Decoder TranscriptTool
transcriptTool =
    Decode.map3 TranscriptTool
        (Decode.field "id" Decode.string)
        (Decode.at [ "function", "name" ] Decode.string)
        (Decode.oneOf [ Decode.at [ "function", "arguments" ] Decode.string, Decode.succeed "" ])


idField : Decoder String
idField =
    Decode.field "id" Decode.string


contentField : Decoder String
contentField =
    Decode.oneOf [ Decode.field "content" Decode.string, Decode.succeed "" ]
