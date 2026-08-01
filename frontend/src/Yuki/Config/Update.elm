module Yuki.Config.Update exposing (emptyDraft, load, mapDraft, save, setGate)

import Json.Encode as Encode
import Yuki.Encode as Encoder
import Yuki.Request as Request
import Yuki.Types exposing (..)


emptyDraft : ConfigDraft
emptyDraft =
    { cwdMode = "inherit"
    , cwd = ""
    , systemPrompt = ""
    , provider = ""
    , model = ""
    , reasoningEffort = ""
    , fs = Nothing
    , shell = Nothing
    , memory = Nothing
    , contextReserveTokens = ""
    , contextKeepUnits = ""
    , contextSummaryTokens = ""
    }


load : Model -> Effect
load model =
    Batch
        [ Request.capabilities model
        , Request.config model
        , Request.globalConfig model
        , Request.providers model
        , Request.contextPolicy model
        , Request.tree model
        ]


mapDraft : (ConfigDraft -> ConfigDraft) -> Model -> Model
mapDraft transform model =
    { model | configDraft = transform model.configDraft, configError = Nothing }


setGate : String -> Maybe Bool -> ConfigDraft -> ConfigDraft
setGate gate value draft =
    case gate of
        "fs" ->
            { draft | fs = value }

        "shell" ->
            { draft | shell = value }

        "memory" ->
            { draft | memory = value }

        _ ->
            draft


save : Model -> ( Model, Effect )
save model =
    if model.configSaving then
        ( model, None )

    else if invalidContextValue 1 model.configDraft.contextReserveTokens
        || invalidContextValue 1 model.configDraft.contextKeepUnits
        || invalidContextValue 96 model.configDraft.contextSummaryTokens
    then
        ( { model | configError = Just "上下文策略必须填写有效的正整数；摘要上限不能低于 96。" }, None )

    else
        ( { model | configSaving = True, configError = Nothing }
        , Inspect <|
            Encoder.inspectionRequest model
                ("config/save/" ++ model.threadId)
                "PUT"
                (Just (encode model.incarnationId model.configDraft))
                ("config/threads/" ++ model.threadId)
            )


invalidContextValue : Int -> String -> Bool
invalidContextValue minimum value =
    if String.isEmpty (String.trim value) then
        False

    else
        case String.toInt (String.trim value) of
            Just number ->
                number < minimum

            Nothing ->
                True


encode : String -> ConfigDraft -> Encode.Value
encode incarnationId draft =
    let
        nullableString value =
            if String.isEmpty (String.trim value) then
                Encode.null

            else
                Encode.string (String.trim value)

        nullableBool =
            Maybe.map Encode.bool >> Maybe.withDefault Encode.null

        nullableInt =
            String.trim >> String.toInt >> Maybe.map Encode.int >> Maybe.withDefault Encode.null

        cwd =
            if draft.cwdMode == "path" then
                nullableString draft.cwd

            else
                Encode.null
    in
    Encode.object
        [ ( "incarnationId", Encode.string incarnationId )
        , ( "cwdMode", Encode.string draft.cwdMode )
        , ( "cwd", cwd )
        , ( "systemPrompt", nullableString draft.systemPrompt )
        , ( "provider", nullableString draft.provider )
        , ( "model", nullableString draft.model )
        , ( "reasoningEffort", nullableString draft.reasoningEffort )
        , ( "fs", nullableBool draft.fs )
        , ( "shell", nullableBool draft.shell )
        , ( "memory", nullableBool draft.memory )
        , ( "contextReserveTokens", nullableInt draft.contextReserveTokens )
        , ( "contextKeepUnits", nullableInt draft.contextKeepUnits )
        , ( "contextSummaryTokens", nullableInt draft.contextSummaryTokens )
        ]
