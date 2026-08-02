module Yuki.Delivery.Decode exposing (DeliveryPage, deliveryPageDecoder)

import Json.Decode as Decode
import Yuki.Telemetry.Decode exposing (deliveryDecoder)
import Yuki.Telemetry.Types exposing (DeliveryRecord)


type alias DeliveryPage =
    { items : List DeliveryRecord
    , hasMore : Bool
    }


deliveryPageDecoder : Decode.Decoder DeliveryPage
deliveryPageDecoder =
    Decode.map2 DeliveryPage
        (Decode.field "items" (Decode.list deliveryDecoder))
        (Decode.field "hasMore" Decode.bool)
