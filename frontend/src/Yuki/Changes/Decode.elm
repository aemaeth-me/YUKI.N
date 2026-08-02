module Yuki.Changes.Decode exposing (FsChangePage, fsChangePageDecoder)

import Json.Decode as Decode
import Yuki.Telemetry.Decode exposing (fsChangeDecoder)
import Yuki.Telemetry.Types exposing (FsChangeRecord)


type alias FsChangePage =
    { items : List FsChangeRecord
    , hasMore : Bool
    }


fsChangePageDecoder : Decode.Decoder FsChangePage
fsChangePageDecoder =
    Decode.map2 FsChangePage
        (Decode.field "items" (Decode.list fsChangeDecoder))
        (Decode.field "hasMore" Decode.bool)
