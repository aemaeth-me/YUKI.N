module Yuki.Inspection.Memory exposing (apply)

import Json.Decode as Decode
import Yuki.Decode as Decoder
import Yuki.Encode as Encoder
import Yuki.Request as Request
import Yuki.Types exposing (..)


apply : List String -> InspectionResult -> Model -> ( Model, Effect )
apply path result model =
    case path of
        [ "activations", identifier ] ->
            rawList identifier "印象唤起" (\value -> { model | impressionActivations = value }) result model

        [ "revisions", identifier ] ->
            rawList identifier "印象修订" (\value -> { model | impressionRevisions = value }) result model

        [ "experiences", identifier ] ->
            rawList identifier "经验事件" (\value -> { model | experiences = value }) result model

        [ "receipts", identifier ] ->
            rawList identifier "读取收据" (\value -> { model | memoryReceipts = value }) result model

        [ "task-archives", identifier ] ->
            archives identifier result model

        [ "task-search", identifier ] ->
            recordSearch identifier result model

        [ "task-search-more", identifier ] ->
            recordSearchMore identifier result model

        [ "task-record", _ ] ->
            recordContext result model

        [ "working", identifier ] ->
            working identifier result model

        [ "sleep", identifier ] ->
            rawList identifier "睡眠周期" (\value -> { model | sleepCycles = value }) result model

        [ "sleep-now", identifier ] ->
            if identifier /= model.threadId then
                ( model, None )

            else if successful result then
                ( { model | sleeping = False, sleepMessage = Just "工作记忆整理已完成。" }
                , Batch [ Request.workingMemory model, Request.sleepCycles model, Request.transcript model ]
                )

            else
                ( { model | sleeping = False, sleepMessage = Just (status result) }, None )

        [ "search", identifier ] ->
            search identifier result model

        [ "remember", identifier ] ->
            mutation identifier "记忆已写入提炼索引，并保留独立 revision。" result model

        [ "detail", _ ] ->
            ( { model
                | memoryDetail =
                    if successful result then
                        Ready result.body

                    else
                        Unavailable (status result)
              }
            , None
            )

        [ "void", identifier ] ->
            if successful result then
                refreshSearch
                    { model
                        | selectedMemory = Nothing
                        , notice = Just "该记忆 revision 已作废；来源记录没有被删除。"
                    }

            else
                ( { model | memoryActionError = Just (status result ++ " · " ++ identifier) }, None )

        _ ->
            ( model, None )


rawList :
    String
    -> String
    -> (Remote (List Decode.Value) -> Model)
    -> InspectionResult
    -> Model
    -> ( Model, Effect )
rawList identifier label set result model =
    if identifier /= model.incarnationId then
        ( model, None )

    else if successful result then
        Decode.decodeValue (Decode.list Decode.value) result.body
            |> Result.map (\values -> ( set (Ready values), None ))
            |> Result.withDefault ( set (Unavailable (label ++ "无法辨认。")), None )

    else if result.status == 404 then
        ( set (Ready []), None )

    else
        ( set (Unavailable (status result)), None )


archives : String -> InspectionResult -> Model -> ( Model, Effect )
archives identifier result model =
    if identifier /= model.incarnationId then
        ( model, None )

    else if successful result then
        Decode.decodeValue (Decode.list Decoder.taskArchiveSummary) result.body
            |> Result.map (\values -> ( { model | taskArchives = Ready values }, None ))
            |> Result.withDefault ( { model | taskArchives = Unavailable "任务记忆目录无法辨认。" }, None )

    else if result.status == 404 then
        ( { model | taskArchives = Ready [] }, None )

    else
        ( { model | taskArchives = Unavailable (status result) }, None )


recordSearch : String -> InspectionResult -> Model -> ( Model, Effect )
recordSearch identifier result model =
    if identifier /= model.incarnationId then
        ( model, None )

    else if successful result then
        Decode.decodeValue Decoder.taskRecordSearch result.body
            |> Result.map (\value -> ( { model | taskRecordSearch = Ready value }, None ))
            |> Result.withDefault ( { model | taskRecordSearch = Unavailable "任务记录搜索无法辨认。" }, None )

    else
        ( { model | taskRecordSearch = Unavailable (status result) }, None )

recordSearchMore : String -> InspectionResult -> Model -> ( Model, Effect )
recordSearchMore identifier result model =
    if identifier /= model.incarnationId then
        ( model, None )

    else if successful result then
        Decode.decodeValue Decoder.taskRecordSearch result.body
            |> Result.map
                (\next ->
                    case model.taskRecordSearch of
                        Ready current ->
                            ( { model | taskRecordSearch = Ready { next | hits = current.hits ++ next.hits } }, None )

                        _ ->
                            ( { model | taskRecordSearch = Ready next }, None )
                )
            |> Result.withDefault ( { model | taskRecordSearch = Unavailable "后续任务记录无法辨认。" }, None )

    else
        ( { model | notice = Just (status result) }, None )


recordContext : InspectionResult -> Model -> ( Model, Effect )
recordContext result model =
    if successful result then
        Decode.decodeValue Decoder.taskRecordContext result.body
            |> Result.map (\value -> ( { model | taskRecordReader = Ready value }, None ))
            |> Result.withDefault ( { model | taskRecordReader = Unavailable "任务记录原文无法辨认。" }, None )

    else
        ( { model | taskRecordReader = Unavailable (status result) }, None )


working : String -> InspectionResult -> Model -> ( Model, Effect )
working identifier result model =
    if identifier /= model.incarnationId then
        ( model, None )

    else if successful result then
        ( { model | workingMemory = Ready result.body }, None )

    else if result.status == 404 then
        ( { model | workingMemory = Unavailable "尚未形成工作记忆。" }, None )

    else
        ( { model | workingMemory = Unavailable (status result) }, None )


search : String -> InspectionResult -> Model -> ( Model, Effect )
search identifier result model =
    if identifier /= model.incarnationId then
        ( model, None )

    else if successful result then
        Decode.decodeValue (Decoder.memorySearch (String.trim model.memoryQuery)) result.body
            |> Result.map (\value -> ( { model | memorySearch = Ready value }, None ))
            |> Result.withDefault ( { model | memorySearch = Unavailable "记忆原文无法辨认。" }, None )

    else
        ( { model | memorySearch = Unavailable (status result) }, None )


mutation : String -> String -> InspectionResult -> Model -> ( Model, Effect )
mutation identifier message result model =
    if identifier /= model.incarnationId then
        ( model, None )

    else if successful result then
        refreshSearch
            { model
                | memoryDraft = ""
                , memoryActionError = Nothing
                , notice = Just message
            }

    else
        ( { model | memoryActionError = Just (status result) }, None )


refreshSearch : Model -> ( Model, Effect )
refreshSearch model =
    let
        query =
            String.trim model.memoryQuery
    in
    ( model
    , if String.isEmpty query then
        None

      else
        Inspect (Encoder.memorySearchRequest model query)
    )


successful : InspectionResult -> Bool
successful result =
    result.status >= 200 && result.status < 300


status : InspectionResult -> String
status result =
    if result.status == 0 then
        Decode.decodeValue Decode.string result.body |> Result.withDefault "网络错误"

    else
        "HTTP " ++ String.fromInt result.status
