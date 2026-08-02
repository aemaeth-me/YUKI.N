module Yuki.Workbench.Decode exposing (ActivitySnapshot, SessionMeta, activitySnapshotDecoder, sessionMetaDecoder)

import Json.Decode as Decode exposing (Decoder)
import Yuki.Telemetry.Decode as TelemetryDecode
import Yuki.Telemetry.Types exposing (..)


type alias SnapshotHome =
    { threadId : String
    , activeRunId : Maybe String
    }


type alias ActivitySnapshot =
    { incarnationId : String
    , home : Maybe SnapshotHome
    , runs : List LiveStatus
    , waitingDrafts : List DispatchDraft
    , recentDeliveries : List DeliveryRecord
    }


type alias SessionMeta =
    { id : String
    , title : String
    , incarnationId : String
    , created : Int
    , updated : Int
    , archived : Bool
    , kind : String
    }


activitySnapshotDecoder : Decoder ActivitySnapshot
activitySnapshotDecoder =
    Decode.succeed ActivitySnapshot
        |> decodeAndMap (Decode.field "incarnationId" Decode.string)
        |> decodeAndMap (Decode.field "home" (Decode.maybe homeDecoder))
        |> decodeAndMap (Decode.field "runs" (Decode.list TelemetryDecode.liveStatusDecoder))
        |> decodeAndMap (Decode.field "waitingDrafts" (Decode.list TelemetryDecode.draftDecoder))
        |> decodeAndMap (Decode.field "recentDeliveries" (Decode.list TelemetryDecode.deliveryDecoder))


homeDecoder : Decoder SnapshotHome
homeDecoder =
    Decode.map2 SnapshotHome
        (Decode.field "threadId" Decode.string)
        (Decode.field "activeRunId" (Decode.maybe Decode.string))


sessionMetaDecoder : Decoder SessionMeta
sessionMetaDecoder =
    Decode.succeed SessionMeta
        |> decodeAndMap (Decode.field "id" Decode.string)
        |> decodeAndMap (Decode.field "title" Decode.string)
        |> decodeAndMap (Decode.field "incarnationId" Decode.string)
        |> decodeAndMap (Decode.field "created" Decode.int)
        |> decodeAndMap (Decode.field "updated" Decode.int)
        |> decodeAndMap (Decode.field "archived" Decode.bool)
        |> decodeAndMap (Decode.field "kind" Decode.string)


decodeAndMap : Decoder a -> Decoder (a -> b) -> Decoder b
decodeAndMap value build =
    Decode.map2 (<|) build value
