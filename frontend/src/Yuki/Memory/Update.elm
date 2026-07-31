module Yuki.Memory.Update exposing
    ( close
    , closeRecord
    , continueTask
    , draftChanged
    , expandRecord
    , kindChanged
    , open
    , openRecord
    , queryChanged
    , recordCaseChanged
    , recordQueryChanged
    , recordTaskChanged
    , refresh
    , refreshArchives
    , refreshWorking
    , remember
    , search
    , searchRecords
    , searchMoreRecords
    , selectSection
    , sleep
    , visibilityChanged
    , void
    )

import Json.Encode as Encode
import Yuki.Encode as Encoder
import Yuki.Inspection as Inspection
import Yuki.Request as Request
import Yuki.State as State
import Yuki.Types exposing (..)


queryChanged : String -> Model -> ( Model, Effect )
queryChanged value model =
    ( { model | memoryQuery = value }, None )


search : Model -> ( Model, Effect )
search model =
    let
        query =
            String.trim model.memoryQuery
    in
    if String.isEmpty query then
        ( model, None )

    else
        ( { model | memorySearch = Loading }, Inspect (Encoder.memorySearchRequest model query) )


draftChanged : String -> Model -> ( Model, Effect )
draftChanged value model =
    ( { model | memoryDraft = value, memoryActionError = Nothing }, None )


kindChanged : String -> Model -> ( Model, Effect )
kindChanged value model =
    ( { model | memoryKind = value }, None )


visibilityChanged : String -> Model -> ( Model, Effect )
visibilityChanged value model =
    ( { model | memoryVisibility = value }, None )


remember : Model -> ( Model, Effect )
remember model =
    let
        content =
            String.trim model.memoryDraft
    in
    if String.isEmpty content then
        ( { model | memoryActionError = Just "记忆正文不能为空。" }, None )

    else
        ( { model | memoryActionError = Nothing }
        , Inspect <|
            Encoder.inspectionRequest model
                ("memory/remember/" ++ model.incarnationId)
                "POST"
                (Just
                    (Encode.object
                        [ ( "visibility", Encode.string model.memoryVisibility )
                        , ( "kind", Encode.string model.memoryKind )
                        , ( "content", Encode.string content )
                        , ( "keywords", Encode.list Encode.string [] )
                        , ( "sourceRefs", Encode.list Encode.string [] )
                        ]
                    )
                )
                ("incarnations/" ++ model.incarnationId ++ "/memories")
        )


open : String -> Int -> Model -> ( Model, Effect )
open identifier revision model =
    ( { model | selectedMemory = Just ( identifier, revision ), memoryDetail = Loading }
    , Inspect <|
        Encoder.inspectionRequest model
            ("memory/detail/" ++ identifier)
            "GET"
            Nothing
            ("incarnations/"
                ++ model.incarnationId
                ++ "/memories/"
                ++ identifier
                ++ "?revision="
                ++ String.fromInt revision
            )
    )


close : Model -> ( Model, Effect )
close model =
    ( { model | selectedMemory = Nothing }, None )


void : String -> Int -> Model -> ( Model, Effect )
void identifier revision model =
    ( model
    , Inspect <|
        Encoder.inspectionRequest model
            ("memory/void/" ++ identifier)
            "POST"
            (Just (Encode.object [ ( "expectedRevision", Encode.int revision ) ]))
            ("incarnations/" ++ model.incarnationId ++ "/memories/" ++ identifier ++ "/void")
    )


refresh : Model -> ( Model, Effect )
refresh model =
    ( { model | impression = Loading, impressionActivations = Loading, impressionRevisions = Loading }
    , Batch
        [ Request.impression model
        , Request.impressionActivations model
        , Request.impressionRevisions model
        ]
    )


selectSection : MemorySection -> Model -> ( Model, Effect )
selectSection section model =
    let
        selected =
            { model | memorySection = section }
    in
    case section of
        Impressions ->
            ( selected
            , Batch
                [ Request.impression selected
                , Request.impressionActivations selected
                , Request.impressionRevisions selected
                ]
            )

        LongTerm ->
            ( selected
            , Batch
                [ Request.taskArchives selected
                , Request.memoryReceipts selected
                , Request.experiences selected
                ]
            )

        Working ->
            ( selected, Batch [ Request.workingMemory selected, Request.sleepCycles selected ] )


refreshArchives : Model -> ( Model, Effect )
refreshArchives model =
    ( { model | taskArchives = Loading }, Request.taskArchives model )


recordQueryChanged : String -> Model -> ( Model, Effect )
recordQueryChanged value model =
    ( { model | taskRecordQuery = value, selectedTaskRecord = Nothing }, None )


recordTaskChanged : String -> Model -> ( Model, Effect )
recordTaskChanged value model =
    ( { model
        | taskRecordTask =
            if String.isEmpty (String.trim value) then
                Nothing

            else
                Just value
        , selectedTaskRecord = Nothing
      }
    , None
    )


recordCaseChanged : Bool -> Model -> ( Model, Effect )
recordCaseChanged value model =
    ( { model | taskRecordCaseSensitive = value }, None )


searchRecords : Model -> ( Model, Effect )
searchRecords model =
    let
        query =
            String.trim model.taskRecordQuery
    in
    if String.isEmpty query then
        ( model, None )

    else
        ( { model | taskRecordSearch = Loading, selectedTaskRecord = Nothing }
        , Inspect <|
            Encoder.inspectionRequest model
                ("memory/task-search/" ++ model.incarnationId)
                "POST"
                (Just
                    (Encode.object
                        ([ ( "query", Encode.string query )
                         , ( "caseSensitive", Encode.bool model.taskRecordCaseSensitive )
                         , ( "limit", Encode.int 40 )
                         ]
                            ++ (model.taskRecordTask
                                    |> Maybe.map (\taskId -> [ ( "taskId", Encode.string taskId ) ])
                                    |> Maybe.withDefault []
                               )
                        )
                    )
                )
                ("incarnations/" ++ model.incarnationId ++ "/task-records/search")
        )

searchMoreRecords : Model -> ( Model, Effect )
searchMoreRecords model =
    case model.taskRecordSearch of
        Ready current ->
            case current.nextOffset of
                Nothing ->
                    ( model, None )

                Just offset ->
                    ( model
                    , Inspect <|
                        Encoder.inspectionRequest model
                            ("memory/task-search-more/" ++ model.incarnationId)
                            "POST"
                            (Just
                                (Encode.object
                                    ([ ( "query", Encode.string current.query )
                                     , ( "caseSensitive", Encode.bool current.caseSensitive )
                                     , ( "limit", Encode.int current.limit )
                                     , ( "offset", Encode.int offset )
                                     ]
                                        ++ (model.taskRecordTask
                                                |> Maybe.map (\taskId -> [ ( "taskId", Encode.string taskId ) ])
                                                |> Maybe.withDefault []
                                           )
                                    )
                                )
                            )
                            ("incarnations/" ++ model.incarnationId ++ "/task-records/search")
                    )

        _ ->
            ( model, None )


openRecord : TaskRecordHit -> Model -> ( Model, Effect )
openRecord hit model =
    ( { model | selectedTaskRecord = Just hit, taskRecordReader = Loading }
    , Inspect <|
        Encoder.inspectionRequest model
            ("memory/task-record/" ++ hit.entryId)
            "GET"
            Nothing
            ("incarnations/"
                ++ model.incarnationId
                ++ "/task-records/"
                ++ hit.entryId
                ++ "?offset="
                ++ String.fromInt hit.matchOffset
                ++ "&chars=6000"
            )
    )


expandRecord : Model -> ( Model, Effect )
expandRecord model =
    case model.selectedTaskRecord of
        Nothing ->
            ( model, None )

        Just hit ->
            ( { model | taskRecordReader = Loading }
            , Inspect <|
                Encoder.inspectionRequest model
                    ("memory/task-record/" ++ hit.entryId)
                    "GET"
                    Nothing
                    ("incarnations/"
                        ++ model.incarnationId
                        ++ "/task-records/"
                        ++ hit.entryId
                        ++ "?before=8&after=8&offset="
                        ++ String.fromInt hit.matchOffset
                        ++ "&chars=16000"
                    )
            )


closeRecord : Model -> ( Model, Effect )
closeRecord model =
    ( { model
        | selectedTaskRecord = Nothing
        , taskRecordReader = Ready { taskId = "", anchorEntryId = "", entries = [] }
      }
    , None
    )


continueTask : String -> Model -> ( Model, Effect )
continueTask =
    Inspection.switchTask


refreshWorking : Model -> ( Model, Effect )
refreshWorking model =
    ( { model | workingMemory = Loading, sleepCycles = Loading }
    , Batch [ Request.workingMemory model, Request.sleepCycles model ]
    )


sleep : Model -> ( Model, Effect )
sleep model =
    if model.sleeping || State.isBusy model.phase || not model.taskReady then
        ( model, None )

    else
        ( { model | sleeping = True, sleepMessage = Nothing }
        , Inspect <|
            Encoder.inspectionRequest model
                ("memory/sleep-now/" ++ model.threadId)
                "POST"
                (Just (Encode.object [ ( "reason", Encode.string "manual sleep requested from memory workspace" ) ]))
                ("threads/" ++ model.threadId ++ "/sleep")
        )
