module Yuki.Task.Update exposing (create, fork, mutate, rename)

import Json.Encode as Encode
import Yuki.Encode as Encoder
import Yuki.State as State
import Yuki.Types exposing (..)


create : String -> Model -> ( Model, Effect )
create title model =
    if State.isBusy model.phase then
        ( { model | taskActionError = Just "请先结束当前运行。" }, None )

    else
        let
            identifier =
                String.left 72 model.incarnationId
                    ++ "-task-"
                    ++ model.runStamp
                    ++ "-"
                    ++ String.fromInt model.nextId
        in
        ( { model
            | nextId = model.nextId + 1
            , notice = Just "正在建立新任务…"
            , taskActionError = Nothing
          }
        , Inspect (Encoder.createTaskRequest model identifier title)
        )


rename : Model -> ( Model, Effect )
rename model =
    let
        title =
            String.trim model.taskTitleDraft
    in
    if String.isEmpty title then
        ( { model | taskActionError = Just "任务名称不能为空。" }, None )

    else
        ( { model | taskActionError = Nothing }
        , Inspect <|
            Encoder.inspectionRequest model
                ("task/rename/" ++ model.threadId)
                "PATCH"
                (Just (Encode.object [ ( "title", Encode.string title ) ]))
                ("threads/" ++ model.threadId)
        )


mutate : String -> String -> Model -> ( Model, Effect )
mutate action identifier model =
    if identifier == model.threadId && State.isBusy model.phase then
        ( { model | taskActionError = Just "运行中不能归档当前任务。" }, None )

    else
        ( { model | taskActionError = Nothing }
        , Inspect <|
            Encoder.inspectionRequest model
                ("task/" ++ action ++ "/" ++ identifier)
                "POST"
                Nothing
                ("threads/" ++ identifier ++ "/" ++ action)
        )


fork : Model -> ( Model, Effect )
fork model =
    if not model.taskReady then
        ( { model | taskActionError = Just "请先选择或建立一项任务。" }, None )

    else if State.isBusy model.phase then
        ( { model | taskActionError = Just "请先结束当前运行。" }, None )

    else
        let
            target =
                String.left 72 model.incarnationId
                    ++ "-fork-"
                    ++ model.runStamp
                    ++ "-"
                    ++ String.fromInt model.nextId

            node =
                String.trim model.forkNodeDraft

            body =
                Encode.object <|
                    [ ( "threadId", Encode.string target ) ]
                        ++ (if String.isEmpty node then
                                []

                            else
                                [ ( "messageId", Encode.string node ) ]
                           )
        in
        ( { model | nextId = model.nextId + 1, taskActionError = Nothing }
        , Inspect <|
            Encoder.inspectionRequest model
                ("task/fork/" ++ target)
                "POST"
                (Just body)
                ("threads/" ++ model.threadId ++ "/fork")
        )
