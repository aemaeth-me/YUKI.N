module Yuki.Dispatch.Types exposing (DraftEditor, EditorMsg(..), capabilityRows, editorPatch, generationLabel, lockEditor, newEditor, refreshFromDraft)

import Json.Decode as Decode
import Json.Encode as Encode
import Yuki.Telemetry.Types exposing (DispatchDraft)


type alias DraftEditor =
    { draft : DispatchDraft
    , title : String
    , prompt : String
    , dirty : Bool
    , saving : Bool
    , confirming : Bool
    , locked : Bool
    , error : Maybe String
    }


type EditorMsg
    = TitleChanged String
    | PromptChanged String
    | ConfirmClicked
    | CancelClicked


newEditor : DispatchDraft -> DraftEditor
newEditor draft =
    { draft = draft
    , title = draft.title
    , prompt = draft.prompt
    , dirty = False
    , saving = False
    , confirming = False
    , locked = draft.status /= "draft"
    , error = Nothing
    }


refreshFromDraft : DispatchDraft -> DraftEditor -> DraftEditor
refreshFromDraft draft editor =
    { editor
        | draft = draft
        , title = draft.title
        , prompt = draft.prompt
        , dirty = False
        , saving = False
        , locked = draft.status /= "draft"
        , error = Nothing
    }


lockEditor : String -> DraftEditor -> DraftEditor
lockEditor status editor =
    let
        draft =
            editor.draft
    in
    { editor
        | draft = { draft | status = status }
        , locked = True
        , dirty = False
        , saving = False
        , confirming = False
    }


editorPatch : DraftEditor -> Encode.Value
editorPatch editor =
    Encode.object
        [ ( "title", Encode.string editor.title )
        , ( "prompt", Encode.string editor.prompt )
        ]


generationLabel : String -> String
generationLabel generation =
    case generation of
        "model" ->
            "由模型起草"

        "fallback" ->
            "模型不可用，已按原文生成"

        "agent" ->
            "Agent 提议"

        _ ->
            "原文生成"


capabilityRows : Decode.Value -> List ( String, String )
capabilityRows config =
    let
        stringOf field =
            Decode.decodeValue (Decode.field field Decode.string) config |> Result.toMaybe

        gateOf field =
            stringOf field
                |> Maybe.map
                    (\value ->
                        if value == "true" then
                            "开"

                        else
                            "关"
                    )
                |> Maybe.withDefault "继承"

        modelRow =
            stringOf "provider"
                |> Maybe.map
                    (\provider ->
                        "provider / model / effort："
                            ++ provider
                            ++ " · "
                            ++ Maybe.withDefault "默认" (stringOf "model")
                            ++ " · "
                            ++ Maybe.withDefault "默认" (stringOf "reasoningEffort")
                    )
                |> Maybe.withDefault "继承 Yuki 默认模型"

        cwdRow =
            case stringOf "cwdMode" of
                Just "path" ->
                    "指定目录 " ++ Maybe.withDefault "" (stringOf "cwd")

                Just "none" ->
                    "不设工作目录"

                _ ->
                    "继承 Yuki 工作目录"

        contextNumbers =
            [ Maybe.map ((++) "预留 " << String.fromInt) (intOf "contextReserveTokens")
            , Maybe.map ((++) "保留 " << String.fromInt) (intOf "contextKeepUnits")
            , Maybe.map ((++) "摘要 " << String.fromInt) (intOf "contextSummaryTokens")
            ]
                |> List.filterMap identity

        intOf field =
            Decode.decodeValue (Decode.field field Decode.int) config |> Result.toMaybe

        contextRow =
            case contextNumbers of
                [] ->
                    "继承 Yuki 上下文策略"

                _ ->
                    String.join " · " contextNumbers
    in
    [ ( "模型", modelRow )
    , ( "工作目录", cwdRow )
    , ( "文件系统", gateOf "fs" )
    , ( "Shell", gateOf "shell" )
    , ( "记忆", gateOf "memory" )
    , ( "上下文", contextRow )
    ]
