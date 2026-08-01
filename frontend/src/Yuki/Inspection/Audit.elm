module Yuki.Inspection.Audit exposing (apply)

import Dict
import Json.Decode as Decode
import Yuki.Decode as Decoder
import Yuki.Encode as Encoder
import Yuki.Types exposing (..)


apply : List String -> InspectionResult -> Model -> ( Model, Effect )
apply path result model =
    case path of
        [ "runs" ] ->
            runs result model

        [ "summary", runId ] ->
            decoded
                (Decoder.runSummary)
                (\value -> { model | runSummaries = Dict.insert runId (Ready value) model.runSummaries })
                (\message -> { model | runSummaries = Dict.insert runId (Unavailable message) model.runSummaries })
                "摘要无法辨认。"
                result

        [ "log", runId ] ->
            decoded
                (Decode.list Decoder.journalRow)
                (\rows -> { model | runLogs = Dict.insert runId (Ready rows) model.runLogs })
                (\message -> { model | runLogs = Dict.insert runId (Unavailable message) model.runLogs })
                "运行日志无法辨认。"
                result

        [ "trace", runId ] ->
            decoded
                Decoder.runTrace
                (\value -> { model | runTraces = Dict.insert runId (Ready value) model.runTraces })
                (\message -> { model | runTraces = Dict.insert runId (Unavailable message) model.runTraces })
                "运行轨迹无法辨认。"
                result

        [ "artifacts" ] ->
            decoded
                (Decode.list Decoder.artifact)
                (\values -> { model | artifacts = Ready values })
                (\message -> { model | artifacts = Unavailable message })
                "完整结果索引无法辨认。"
                result

        [ "artifact", identifier ] ->
            decoded
                Decode.string
                (\body -> { model | artifactBodies = Dict.insert identifier (Ready body) model.artifactBodies })
                (\message -> { model | artifactBodies = Dict.insert identifier (Unavailable message) model.artifactBodies })
                "完整结果正文无法辨认。"
                result

        [ "replay", runId ] ->
            ( { model
                | replayReports =
                    Dict.insert runId
                        (if successful result then
                            Ready result.body

                         else
                            Unavailable (status result)
                        )
                        model.replayReports
              }
            , None
            )

        _ ->
            ( model, None )


runs : InspectionResult -> Model -> ( Model, Effect )
runs result model =
    if successful result then
        case Decode.decodeValue (Decode.list Decode.string) result.body of
            Ok runIds ->
                ( { model
                    | auditRuns = Ready runIds
                    , runSummaries = List.foldl (\runId -> Dict.insert runId Loading) Dict.empty runIds
                  }
                , Batch
                    (List.map
                        (\runId ->
                            Inspect <|
                                Encoder.inspectionRequest model
                                    ("audit/summary/" ++ runId)
                                    "GET"
                                    Nothing
                                    ("journal/runs/" ++ runId ++ "/summary")
                        )
                        runIds
                    )
                )

            Err _ ->
                ( { model | auditRuns = Unavailable "运行索引无法辨认。" }, None )

    else
        ( { model | auditRuns = Unavailable (status result) }, None )


decoded :
    Decode.Decoder value
    -> (value -> Model)
    -> (String -> Model)
    -> String
    -> InspectionResult
    -> ( Model, Effect )
decoded decoder accept reject invalid result =
    if successful result then
        Decode.decodeValue decoder result.body
            |> Result.map (accept >> (\next -> ( next, None )))
            |> Result.withDefault ( reject invalid, None )

    else
        ( reject (status result), None )


successful : InspectionResult -> Bool
successful result =
    result.status >= 200 && result.status < 300


status : InspectionResult -> String
status result =
    if result.status == 0 then
        Decode.decodeValue Decode.string result.body |> Result.withDefault "网络错误"

    else
        "HTTP " ++ String.fromInt result.status
