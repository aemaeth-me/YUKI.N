module Yuki.Telemetry.Decode exposing (deliveryDecoder, draftDecoder, fleetEntryDecoder, frameDecoder, liveStatusDecoder)

import Json.Decode as Decode exposing (Decoder)
import Yuki.Telemetry.Types exposing (..)


frameDecoder : Decoder ActivityFrame
frameDecoder =
    Decode.field "kind" Decode.string |> Decode.andThen byKind


byKind : String -> Decoder ActivityFrame
byKind kind =
    case kind of
        "snapshot" ->
            Decode.map2 FrameFleet
                (Decode.field "data" (Decode.field "incarnations" (Decode.list fleetEntryDecoder)))
                (Decode.field "data" (Decode.field "runs" (Decode.list liveStatusDecoder)))

        "status" ->
            Decode.map FrameStatus (Decode.field "data" liveStatusDecoder)

        "run.end" ->
            Decode.map2 FrameRunEnd
                (Decode.field "data" (Decode.field "runId" Decode.string))
                (Decode.field "data" (Decode.field "outcome" Decode.string))

        "delivery" ->
            Decode.map FrameDelivery (Decode.field "data" deliveryDecoder)

        "fschange" ->
            Decode.map FrameFsChange (Decode.field "data" fsChangeDecoder)

        "draft" ->
            Decode.map FrameDraft (Decode.field "data" draftDecoder)

        "draft.resolved" ->
            Decode.map3 FrameDraftResolved
                (Decode.field "data" (Decode.field "dispatchId" Decode.string))
                (Decode.field "data" (Decode.field "status" Decode.string))
                (Decode.field "data" (Decode.maybe (Decode.field "threadId" Decode.string)))

        _ ->
            Decode.succeed FramePing


runKindDecoder : Decoder RunKind
runKindDecoder =
    Decode.string
        |> Decode.map
            (\kind ->
                case kind of
                    "home" ->
                        RunHome

                    "worker" ->
                        RunWorker

                    _ ->
                        RunTask
            )


phaseDecoder : Decoder RunPhase
phaseDecoder =
    Decode.string
        |> Decode.map
            (\phase ->
                case phase of
                    "awaiting-tool" ->
                        PhaseAwaitingTool

                    "compacting" ->
                        PhaseCompacting

                    "sleeping" ->
                        PhaseSleeping

                    "cancelling" ->
                        PhaseCancelling

                    _ ->
                        PhaseRunning
            )


activeToolDecoder : Decoder ActiveTool
activeToolDecoder =
    Decode.map3 ActiveTool
        (Decode.field "callId" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "startedAt" Decode.int)


contextDecoder : Decoder ContextSnapshot
contextDecoder =
    Decode.map3 ContextSnapshot
        (Decode.field "estimatedTokens" Decode.int)
        (Decode.field "budgetTokens" Decode.int)
        (Decode.field "windowTokens" Decode.int)


liveStatusDecoder : Decoder LiveStatus
liveStatusDecoder =
    Decode.succeed LiveStatus
        |> decodeAndMap (Decode.field "runId" Decode.string)
        |> decodeAndMap (Decode.field "threadId" Decode.string)
        |> decodeAndMap (Decode.field "incarnationId" Decode.string)
        |> decodeAndMap (Decode.field "parentRunId" (Decode.maybe Decode.string))
        |> decodeAndMap (Decode.field "kind" runKindDecoder)
        |> decodeAndMap (Decode.field "phase" phaseDecoder)
        |> decodeAndMap (Decode.field "objective" (Decode.maybe Decode.string))
        |> decodeAndMap (Decode.field "startedAt" Decode.int)
        |> decodeAndMap (Decode.field "lastEventAt" Decode.int)
        |> decodeAndMap (Decode.field "turn" Decode.int)
        |> decodeAndMap (Decode.field "maxTurns" Decode.int)
        |> decodeAndMap (Decode.field "model" Decode.string)
        |> decodeAndMap (Decode.field "usage" (Decode.field "promptTokens" Decode.int))
        |> decodeAndMap (Decode.field "usage" (Decode.field "completionTokens" Decode.int))
        |> decodeAndMap (Decode.maybe (Decode.field "context" contextDecoder))
        |> decodeAndMap (Decode.field "activeTools" (Decode.list activeToolDecoder))
        |> decodeAndMap (Decode.field "workers" Decode.int)
        |> decodeAndMap (Decode.field "lastActivity" (Decode.maybe Decode.string))


fleetEntryDecoder : Decoder FleetEntry
fleetEntryDecoder =
    Decode.map6 FleetEntry
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "state" Decode.string)
        (Decode.field "activeRuns" Decode.int)
        (Decode.field "waitingDrafts" Decode.int)
        (Decode.field "lastDeliveryAt" (Decode.maybe Decode.int))


deliveryDecoder : Decoder DeliveryRecord
deliveryDecoder =
    Decode.map7 DeliveryRecord
        (Decode.field "id" Decode.string)
        (Decode.field "runId" Decode.string)
        (Decode.field "threadId" Decode.string)
        (Decode.field "incarnationId" Decode.string)
        (Decode.field "runKind" runKindDecoder)
        (Decode.field "kind" Decode.string)
        (Decode.field "title" Decode.string)
        |> Decode.andThen
            (\build ->
                Decode.map3 build
                    (Decode.field "ref" Decode.string)
                    (Decode.field "bytes" (Decode.maybe Decode.int))
                    (Decode.field "at" Decode.int)
            )


originDecoder : Decoder FsOrigin
originDecoder =
    Decode.field "kind" Decode.string
        |> Decode.andThen
            (\kind ->
                case kind of
                    "tool" ->
                        Decode.map2 OriginTool
                            (Decode.field "toolName" Decode.string)
                            (Decode.field "callId" Decode.string)

                    _ ->
                        Decode.succeed OriginGit
            )


fsChangeDecoder : Decoder FsChangeRecord
fsChangeDecoder =
    Decode.succeed FsChangeRecord
        |> decodeAndMap (Decode.field "id" Decode.string)
        |> decodeAndMap (Decode.field "runId" Decode.string)
        |> decodeAndMap (Decode.field "threadId" Decode.string)
        |> decodeAndMap (Decode.field "incarnationId" Decode.string)
        |> decodeAndMap (Decode.field "path" Decode.string)
        |> decodeAndMap (Decode.field "op" Decode.string)
        |> decodeAndMap (Decode.field "origin" originDecoder)
        |> decodeAndMap (Decode.field "diff" (Decode.maybe Decode.string))
        |> decodeAndMap (Decode.field "stat" (Decode.maybe Decode.string))
        |> decodeAndMap (Decode.field "at" Decode.int)


draftDecoder : Decoder DispatchDraft
draftDecoder =
    Decode.succeed DispatchDraft
        |> decodeAndMap (Decode.field "dispatchId" Decode.string)
        |> decodeAndMap (Decode.field "incarnationId" Decode.string)
        |> decodeAndMap (Decode.field "source" (Decode.field "type" Decode.string))
        |> decodeAndMap (Decode.field "input" Decode.string)
        |> decodeAndMap (Decode.field "title" Decode.string)
        |> decodeAndMap (Decode.field "prompt" Decode.string)
        |> decodeAndMap (Decode.field "config" Decode.value)
        |> decodeAndMap (Decode.field "generation" (Decode.field "type" Decode.string))
        |> decodeAndMap (Decode.field "status" Decode.string)
        |> decodeAndMap (Decode.field "createdThreadId" (Decode.maybe Decode.string))
        |> decodeAndMap (Decode.field "error" (Decode.maybe Decode.string))
        |> decodeAndMap (Decode.field "createdAt" Decode.int)
        |> decodeAndMap (Decode.field "updatedAt" Decode.int)


decodeAndMap : Decoder a -> Decoder (a -> b) -> Decoder b
decodeAndMap value build =
    Decode.map2 (<|) build value
