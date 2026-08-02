module Yuki.Telemetry.State exposing (TelemetryState, apply, init, setConn)

import Dict exposing (Dict)
import Yuki.Telemetry.Types exposing (..)


type alias TelemetryState =
    { runs : Dict RunId LiveStatus
    , fleet : List FleetEntry
    , conn : Connection
    , tick : Dict String Int
    , draftStatus : Dict String String
    }


init : TelemetryState
init =
    { runs = Dict.empty
    , fleet = []
    , conn = ConnOffline
    , tick = Dict.empty
    , draftStatus = Dict.empty
    }


setConn : Connection -> TelemetryState -> TelemetryState
setConn conn state =
    { state | conn = conn }


apply : ActivityFrame -> TelemetryState -> TelemetryState
apply frame state =
    case frame of
        FrameFleet entries runs ->
            { state
                | fleet = entries
                , runs = Dict.fromList (List.map (\run -> ( run.runId, run )) runs)
            }

        FrameStatus status ->
            { state | runs = Dict.insert status.runId status state.runs }

        FrameRunEnd runId _ ->
            { state | runs = Dict.remove runId state.runs }

        FrameDelivery record ->
            { state | tick = bump record.incarnationId state.tick }

        FrameFsChange record ->
            { state | tick = bump record.incarnationId state.tick }

        FrameDraft draft ->
            { state | tick = bump draft.incarnationId state.tick }

        FrameDraftResolved dispatchId status _ ->
            { state | draftStatus = Dict.insert dispatchId status state.draftStatus }

        FramePing ->
            state


bump : String -> Dict String Int -> Dict String Int
bump key dict =
    Dict.update key (Maybe.withDefault 0 >> (+) 1 >> Just) dict
