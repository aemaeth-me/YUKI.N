module Yuki.Self.Update exposing
    ( activatePrompt
    , archive
    , create
    , delete
    , generatePrompt
    , mapDraft
    , mapPromptEditor
    , restore
    , save
    , savePromptEdit
    , switch
    )

import Dict
import Json.Encode as Encode
import Yuki.Encode as Encoder
import Yuki.Request as Request
import Yuki.State as State
import Yuki.Types exposing (..)


switch : String -> Model -> ( Model, Effect )
switch identifier model =
    if identifier == model.incarnationId || State.isBusy model.phase || model.selfSaving then
        ( model, None )

    else
        let
            selected =
                case model.incarnations of
                    Ready entries ->
                        entries |> List.filter (\entry -> entry.id == identifier) |> List.head

                    _ ->
                        Nothing

            incarnation =
                Maybe.withDefault
                    { id = identifier
                    , name = identifier
                    , direction = ""
                    , promptRevision = Nothing
                    , impressionModel = Nothing
                    , revision = 0
                    , status = "active"
                    , created = 0
                    , updated = 0
                    }
                    selected

            next =
                { model
                    | incarnationId = identifier
                    , incarnation = incarnation
                    , selfNameDraft = incarnation.name
                    , selfDirectionDraft = incarnation.direction
                    , selfImpressionModelDraft = Maybe.withDefault "" incarnation.impressionModel
                    , archiveYukiConfirm = False
                    , deleteYukiConfirm = Nothing
                    , sessions = Loading
                    , taskReady = False
                    , transcriptLoading = True
                    , messages = Dict.empty
                    , messageOrder = []
                    , tools = Dict.empty
                    , taskTitle = ""
                    , taskTitleDraft = ""
                    , impression = Loading
                    , memorySearch = Ready { snippets = [], query = "" }
                    , memoryReceipts = Loading
                    , experiences = Loading
                    , taskArchives = Loading
                    , workingMemory = Loading
                    , sleepCycles = Loading
                    , prompts = Loading
                    , rootPrompts = Loading
                    , promptEditor = Nothing
                    , capabilities = Loading
                    , taskConfig = Loading
                    , globalConfig = Loading
                    , contextPolicy = Loading
                    , configError = Nothing
                    , tree = Loading
                    , tasksOpen = False
                    , memoryPinned = False
                    , page = Conversation
                    , notice = Nothing
                }
        in
        ( next
        , Batch
            [ PersistIncarnation identifier
            , Request.incarnation next
            , Request.incarnations next
            , Request.sessions next
            , Request.impression next
            , Request.prompts next
            , Request.rootPrompts next
            ]
        )


generatePrompt : Model -> ( Model, Effect )
generatePrompt model =
    if model.generatingPrompt then
        ( model, None )

    else
        ( { model | generatingPrompt = True, promptMessage = Nothing }
        , Inspect <|
            Encoder.inspectionRequest model
                ("prompts/generate/" ++ model.incarnationId)
                "POST"
                (Just
                    (Encode.object
                        [ ( "sourceIntent", Encode.string "manual draft requested from self workspace" )
                        , ( "activate", Encode.bool False )
                        ]
                    )
                )
                ("incarnations/" ++ model.incarnationId ++ "/prompts/generate")
        )


activatePrompt : Bool -> String -> Int -> Model -> ( Model, Effect )
activatePrompt root identifier expected model =
    if model.activatingPrompt /= Nothing then
        ( model, None )

    else
        ( { model | activatingPrompt = Just identifier, promptMessage = Nothing }
        , Inspect <|
            Encoder.inspectionRequest model
                ((if root then "prompts/activate-root/" else "prompts/activate/") ++ identifier)
                "POST"
                (Just (Encode.object [ ( "expectedRevision", Encode.int expected ) ]))
                (if root then
                    "prompts/root/" ++ identifier ++ "/activate"

                 else
                    "incarnations/" ++ model.incarnationId ++ "/prompts/" ++ identifier ++ "/activate"
                )
        )


mapPromptEditor : (PromptEditor -> PromptEditor) -> Model -> Model
mapPromptEditor transform model =
    { model | promptEditor = Maybe.map transform model.promptEditor }


savePromptEdit : Model -> ( Model, Effect )
savePromptEdit model =
    case model.promptEditor of
        Nothing ->
            ( model, None )

        Just editor ->
            if
                editor.saving
                    || String.isEmpty (String.trim editor.sourceIntent)
                    || String.isEmpty (String.trim editor.content)
            then
                ( { model | promptMessage = Just "修改说明与 Prompt 正文都不能为空。" }, None )

            else
                ( mapPromptEditor (\value -> { value | saving = True }) model
                , Inspect <|
                    Encoder.inspectionRequest model
                        (if editor.root then "prompts/edit-root" else "prompts/edit/" ++ model.incarnationId)
                        "POST"
                        (Just
                            (Encode.object
                                [ ( "sourceIntent", Encode.string (String.trim editor.sourceIntent) )
                                , ( "content", Encode.string editor.content )
                                , ( "parentRevision", Encode.string editor.baseId )
                                ]
                            )
                        )
                        (if editor.root then
                            "prompts/root"

                         else
                            "incarnations/" ++ model.incarnationId ++ "/prompts"
                        )
                )


save : Model -> ( Model, Effect )
save model =
    let
        name =
            String.trim model.selfNameDraft

        direction =
            String.trim model.selfDirectionDraft
    in
    if String.isEmpty name || String.isEmpty direction then
        ( { model | selfError = Just "名称与方向都不能为空。" }, None )

    else
        ( { model | selfSaving = True, selfError = Nothing }
        , Inspect <|
            Encoder.inspectionRequest model
                ("yuki/update/" ++ model.incarnationId)
                "PATCH"
                (Just
                    (Encode.object
                        [ ( "expectedRevision", Encode.int model.incarnation.revision )
                        , ( "name", Encode.string name )
                        , ( "direction", Encode.string direction )
                        , ( "impressionModel"
                          , if String.isEmpty (String.trim model.selfImpressionModelDraft) then
                                Encode.null

                            else
                                Encode.string (String.trim model.selfImpressionModelDraft)
                          )
                        ]
                    )
                )
                ("incarnations/" ++ model.incarnationId)
        )


mapDraft : (YukiDraft -> YukiDraft) -> Model -> Model
mapDraft transform model =
    { model | yukiForm = Maybe.map transform model.yukiForm }


create : Model -> ( Model, Effect )
create model =
    case model.yukiForm of
        Nothing ->
            ( model, None )

        Just draft ->
            if
                draft.saving
                    || List.any (String.isEmpty << String.trim) [ draft.identifier, draft.name, draft.direction ]
            then
                ( mapDraft (\value -> { value | error = Just "标识、名称与方向都不能为空。" }) model, None )

            else
                ( mapDraft (\value -> { value | saving = True, error = Nothing }) model
                , Inspect <|
                    Encoder.inspectionRequest model
                        ("yuki/create/" ++ String.trim draft.identifier)
                        "POST"
                        (Just
                            (Encode.object
                                [ ( "id", Encode.string (String.trim draft.identifier) )
                                , ( "name", Encode.string (String.trim draft.name) )
                                , ( "direction", Encode.string (String.trim draft.direction) )
                                , ( "impressionModel"
                                  , if String.isEmpty (String.trim draft.impressionModel) then
                                        Encode.null

                                    else
                                        Encode.string (String.trim draft.impressionModel)
                                  )
                                ]
                            )
                        )
                        "incarnations"
                )


archive : Model -> ( Model, Effect )
archive model =
    if model.incarnationId == "yuki" || State.isBusy model.phase then
        ( { model | selfError = Just "默认 Yuki 或正在运行的 Yuki 不能归档。" }, None )

    else
        ( { model | selfSaving = True, selfError = Nothing }
        , Inspect <|
            Encoder.inspectionRequest model
                ("yuki/archive/" ++ model.incarnationId)
                "POST"
                (Just (Encode.object [ ( "expectedRevision", Encode.int model.incarnation.revision ) ]))
                ("incarnations/" ++ model.incarnationId ++ "/archive")
        )


restore : String -> Int -> Model -> ( Model, Effect )
restore identifier revision model =
    ( model
    , Inspect <|
        Encoder.inspectionRequest model
            ("yuki/restore/" ++ identifier)
            "POST"
            (Just (Encode.object [ ( "expectedRevision", Encode.int revision ) ]))
            ("incarnations/" ++ identifier ++ "/restore")
    )


delete : String -> Int -> Model -> ( Model, Effect )
delete identifier revision model =
    ( { model | deleteYukiConfirm = Nothing, selfSaving = True }
    , Inspect <|
        Encoder.inspectionRequest model
            ("yuki/delete/" ++ identifier)
            "POST"
            (Just (Encode.object [ ( "expectedRevision", Encode.int revision ) ]))
            ("incarnations/" ++ identifier ++ "/delete")
    )
