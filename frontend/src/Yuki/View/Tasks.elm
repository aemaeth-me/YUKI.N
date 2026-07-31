module Yuki.View.Tasks exposing (dialog, view)

import Html exposing (Html, button, div, form, h1, h2, input, label, p, section, span, text)
import Html.Attributes as Attr
import Html.Events as Events
import Yuki.State as State
import Yuki.Types exposing (..)


view : Model -> Html Msg
view model =
    div [ Attr.class "paper-page tasks-page" ]
        [ div [ Attr.class "page-intro page-intro-actions" ]
            [ div []
                [ h1 [] [ text "任务" ]
                , p [] [ text "每项任务是一段可恢复的持久工作；运行和对话属于任务，记忆与自我属于 Yuki。" ]
                ]
            , div [ Attr.class "page-actions" ]
                [ button [ Attr.type_ "button", Events.onClick ImportTaskRequested ] [ text "导入" ]
                , button [ Attr.class "primary", Attr.type_ "button", Events.onClick OpenTaskForm ] [ text "新任务" ]
                ]
            ]
        , viewError model.taskActionError
        , section [ Attr.class "task-workspace" ]
            [ div [ Attr.class "task-index" ] [ taskList model ]
            , div [ Attr.class "task-detail" ] (taskDetail model)
            ]
        ]


taskList : Model -> Html Msg
taskList model =
    case model.sessions of
        Loading ->
            quiet "正在读取任务…"

        Unavailable message ->
            quiet message

        Ready sessions ->
            let
                active =
                    List.filter (not << .archived) sessions

                archived =
                    List.filter .archived sessions
            in
            div []
                [ div [ Attr.class "task-list" ] (List.map (taskRow model False) active)
                , if List.isEmpty archived then
                    text ""

                  else
                    div [ Attr.class "archived-tasks" ]
                        [ button
                            [ Attr.class "text-action"
                            , Attr.type_ "button"
                            , Events.onClick ToggleArchivedTasks
                            ]
                            [ text
                                ((if model.showArchivedTasks then
                                    "收起"

                                  else
                                    "已归档"
                                 )
                                    ++ " · "
                                    ++ String.fromInt (List.length archived)
                                )
                            ]
                        , if model.showArchivedTasks then
                            div [ Attr.class "task-list" ] (List.map (taskRow model True) archived)

                          else
                            text ""
                        ]
                ]


taskRow : Model -> Bool -> SessionMeta -> Html Msg
taskRow model archived task =
    div [ Attr.classList [ ( "task-row", True ), ( "current", model.taskReady && task.id == model.threadId ) ] ]
        [ button
            [ Attr.class "task-select"
            , Attr.type_ "button"
            , Attr.disabled (archived || (model.taskReady && task.id == model.threadId) || State.isBusy model.phase)
            , Events.onClick (SwitchTask task.id)
            ]
            [ span [ Attr.class "task-row-title" ] [ text (State.taskName task) ]
            , span [ Attr.class "task-row-meta" ]
                [ text
                    (task.parent
                        |> Maybe.map (\_ -> "分叉任务")
                        |> Maybe.withDefault (shortId task.id)
                    )
                ]
            ]
        , if archived then
            button [ Attr.class "row-action", Attr.type_ "button", Events.onClick (RestoreTask task.id) ] [ text "恢复" ]

          else
            button
                [ Attr.class "row-action"
                , Attr.type_ "button"
                , Attr.disabled (task.id == model.threadId && State.isBusy model.phase)
                , Events.onClick (ArchiveTask task.id)
                ]
                [ text "归档" ]
        ]


taskDetail : Model -> List (Html Msg)
taskDetail model =
    case currentTask model of
        Nothing ->
            [ quiet "选择一项任务，或建立新任务。" ]

        Just task ->
            [ span [ Attr.class "eyebrow" ] [ text "当前任务" ]
            , h2 [] [ text (State.taskName task) ]
            , p [ Attr.class "task-id" ] [ text task.id ]
            , form [ Attr.class "rename-task", Events.onSubmit RenameTask ]
                [ label [ Attr.for "task-title" ] [ text "名称" ]
                , input
                    [ Attr.id "task-title"
                    , Attr.value model.taskTitleDraft
                    , Events.onInput TaskTitleChanged
                    ]
                    []
                , button
                    [ Attr.type_ "submit"
                    , Attr.disabled (String.isEmpty (String.trim model.taskTitleDraft))
                    ]
                    [ text "保存" ]
                ]
            , div [ Attr.class "task-provenance" ]
                [ provenance "创建" (String.fromInt task.created)
                , provenance "更新" (String.fromInt task.updated)
                , provenance "上游任务" (Maybe.withDefault "—" task.parent)
                , provenance "分叉节点" (Maybe.withDefault "—" task.forkNode)
                ]
            , section [ Attr.class "task-operations" ]
                [ div []
                    [ span [ Attr.class "eyebrow" ] [ text "分叉" ]
                    , p [] [ text "留空节点会从当前完整记录分叉；填写 message id 可从指定因果节点分叉。" ]
                    ]
                , input
                    [ Attr.placeholder "message id（可选）"
                    , Attr.value model.forkNodeDraft
                    , Events.onInput ForkNodeChanged
                    ]
                    []
                , button
                    [ Attr.type_ "button"
                    , Attr.disabled (State.isBusy model.phase)
                    , Events.onClick ForkTask
                    ]
                    [ text "建立分叉任务" ]
                ]
            , div [ Attr.class "task-footer-actions" ]
                [ button [ Attr.type_ "button", Events.onClick (SelectPage Conversation) ] [ text "回到对话" ]
                , button [ Attr.type_ "button", Events.onClick ExportTask ] [ text "导出任务" ]
                ]
            ]


dialog : Model -> Html Msg
dialog model =
    if model.taskFormOpen then
        div [ Attr.class "modal-backdrop", Attr.attribute "role" "presentation" ]
            [ section
                [ Attr.class "paper-dialog"
                , Attr.attribute "role" "dialog"
                , Attr.attribute "aria-modal" "true"
                , Attr.attribute "aria-labelledby" "new-task-title"
                ]
                [ h2 [ Attr.id "new-task-title" ] [ text "新任务" ]
                , p [] [ text "任务保存局部工作过程；它不会创建另一位 Yuki。" ]
                , form [ Events.onSubmit SubmitTaskForm ]
                    [ label [ Attr.for "new-task-name" ] [ text "名称（可稍后修改）" ]
                    , input
                        [ Attr.id "new-task-name"
                        , Attr.autofocus True
                        , Attr.value model.taskFormTitle
                        , Events.onInput TaskFormTitleChanged
                        ]
                        []
                    , div [ Attr.class "dialog-actions" ]
                        [ button [ Attr.type_ "button", Events.onClick CloseTaskForm ] [ text "取消" ]
                        , button [ Attr.class "primary", Attr.type_ "submit" ] [ text "建立任务" ]
                        ]
                    ]
                ]
            ]

    else
        text ""


currentTask : Model -> Maybe SessionMeta
currentTask model =
    case model.sessions of
        Ready sessions ->
            sessions
                |> List.filter (\task -> task.id == model.threadId && not task.archived)
                |> List.head

        _ ->
            Nothing


provenance : String -> String -> Html msg
provenance label value =
    div [] [ span [] [ text label ], p [] [ text value ] ]


viewError : Maybe String -> Html msg
viewError maybeMessage =
    maybeMessage
        |> Maybe.map (\message -> p [ Attr.class "inline-error", Attr.attribute "role" "alert" ] [ text message ])
        |> Maybe.withDefault (text "")


quiet : String -> Html msg
quiet message =
    p [ Attr.class "quiet" ] [ text message ]


shortId : String -> String
shortId identifier =
    if String.length identifier <= 18 then
        identifier

    else
        String.left 8 identifier ++ "…" ++ String.right 7 identifier
