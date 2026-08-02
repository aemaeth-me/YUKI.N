module Yuki.Workbench.View exposing (view)

import Dict
import Html exposing (..)
import Html.Attributes exposing (class, classList, href)
import Html.Events exposing (onClick)
import Time exposing (Posix)
import Yuki.Changes.View as ChangesView
import Yuki.Conversation.View as Conversation
import Yuki.Delivery.View as DeliveryView
import Yuki.Dispatch.State as DispatchState
import Yuki.Dispatch.View as DispatchView
import Yuki.Run.Monitor as Monitor
import Yuki.Run.StatusCard as StatusCard
import Yuki.Telemetry.State exposing (TelemetryState)
import Yuki.Telemetry.Types exposing (..)
import Yuki.Workbench.Decode exposing (SessionMeta)
import Yuki.Workbench.Format as Format
import Yuki.Workbench.State as State
import Yuki.Workbench.Types exposing (WorkbenchView(..))


view : TelemetryState -> State.Model -> String -> WorkbenchView -> Html State.Msg
view telemetry wb yuki viewName =
    div [ class "workbench" ]
        [ header [ class "wb-header" ]
            [ h1 [ class "wb-title" ] [ text (yukiName telemetry yuki) ]
            , nav [ class "wb-nav" ] (List.map (navLink yuki viewName) navItems)
            ]
        , div [ class "wb-body" ]
            [ case viewName of
                ViewNow ->
                    nowView telemetry wb yuki

                ViewChat maybeThread ->
                    chatView telemetry wb yuki maybeThread

                ViewTasks ->
                    tasksView telemetry wb yuki

                ViewDeliveries ->
                    Html.map State.DeliveryMsg (DeliveryView.view wb.now wb.delivery yuki)

                ViewChanges ->
                    Html.map State.ChangesMsg (ChangesView.view wb.now wb.changes yuki)

                ViewRun runId ->
                    Html.map State.MonitorMsg (Monitor.view telemetry (cardConfig wb yuki) wb.monitor yuki runId)
            ]
        , DispatchView.dialog State.DispatchMsg wb.dispatch
        ]


yukiName : TelemetryState -> String -> String
yukiName telemetry yuki =
    telemetry.fleet
        |> List.filter (\entry -> entry.id == yuki)
        |> List.head
        |> Maybe.map .name
        |> Maybe.withDefault yuki


navItems : List ( String, WorkbenchView, String )
navItems =
    [ ( "now", ViewNow, "现在" )
    , ( "chat", ViewChat Nothing, "主对话" )
    , ( "tasks", ViewTasks, "任务" )
    , ( "deliveries", ViewDeliveries, "交付" )
    , ( "changes", ViewChanges, "变更" )
    ]


navLink : String -> WorkbenchView -> ( String, WorkbenchView, String ) -> Html State.Msg
navLink yuki current ( path, viewName, label ) =
    a
        [ class "wb-nav-link"
        , classList [ ( "is-active", viewName == current ) ]
        , href ("/yuki/" ++ yuki ++ "/" ++ path)
        ]
        [ text label ]


chatView : TelemetryState -> State.Model -> String -> Maybe String -> Html State.Msg
chatView telemetry wb yuki _ =
    Html.map State.ConversationMsg (Conversation.view telemetry wb.conversation yuki)


nowView : TelemetryState -> State.Model -> String -> Html State.Msg
nowView telemetry wb yuki =
    div [ class "now-view" ]
        [ waitingSection wb
        , runSection telemetry wb yuki
        , deliveriesSection wb
        , errorNote wb.activityError
        ]


waitingSection : State.Model -> Html State.Msg
waitingSection wb =
    case Maybe.map .waitingDrafts wb.activity of
        Just drafts ->
            if List.isEmpty drafts then
                text ""

            else
                section [ class "wb-section" ]
                    [ h2 [ class "wb-section-title" ] [ text "等待用户" ]
                    , div [ class "draft-list" ] (List.map draftRow drafts)
                    ]

        Nothing ->
            text ""


draftRow : DispatchDraft -> Html State.Msg
draftRow draft =
    button
        [ class "draft-row draft-row-open"
        , onClick (State.DispatchMsg (DispatchState.OpenDraft draft))
        ]
        [ span [ class "draft-title" ] [ text draft.title ]
        , span [ class "draft-generation" ] [ text (generationLabel draft.generation) ]
        ]


generationLabel : String -> String
generationLabel generation =
    case generation of
        "model" ->
            "由模型起草"

        "agent" ->
            "Agent 提议"

        _ ->
            "原文生成"


runSection : TelemetryState -> State.Model -> String -> Html State.Msg
runSection telemetry wb yuki =
    let
        runs =
            runsForIncarnation yuki telemetry
    in
    section [ class "wb-section" ]
        [ h2 [ class "wb-section-title" ] [ text "活跃 Run" ]
        , if List.isEmpty runs then
            div [ class "now-empty" ] [ text "当前没有进行中的工作" ]

          else
            div [ class "run-tree" ] (List.map (runNode telemetry wb yuki 0) (roots runs))
        ]


runsForIncarnation : String -> TelemetryState -> List LiveStatus
runsForIncarnation yuki telemetry =
    Dict.values telemetry.runs
        |> List.filter (\run -> run.incarnationId == yuki)


roots : List LiveStatus -> List LiveStatus
roots runs =
    runs
        |> List.filter (\run -> run.parentRunId == Nothing)
        |> List.sortBy .startedAt


childrenOf : String -> List LiveStatus -> List LiveStatus
childrenOf runId runs =
    runs
        |> List.filter (\run -> run.parentRunId == Just runId)
        |> List.sortBy .startedAt


runNode : TelemetryState -> State.Model -> String -> Int -> LiveStatus -> Html State.Msg
runNode telemetry wb yuki depth run =
    let
        children =
            childrenOf run.runId (runsForIncarnation yuki telemetry)
    in
    div [ class "run-node", classList [ ( "run-node-child", depth > 0 ) ] ]
        [ Html.map State.StatusCard (StatusCard.view (cardConfig wb yuki) run)
        , if List.isEmpty children then
            text ""

          else
            div [ class "run-children" ] (List.map (runNode telemetry wb yuki (depth + 1)) children)
        ]


cardConfig : State.Model -> String -> StatusCard.Config
cardConfig wb yuki =
    { yuki = yuki
    , now = wb.now
    , wide = False
    , steerOpen = wb.steerOpen
    , steerText = wb.steerText
    , confirmCancel = wb.confirmCancel
    , actionStatus = wb.actionStatus
    }


deliveriesSection : State.Model -> Html State.Msg
deliveriesSection wb =
    case Maybe.map .recentDeliveries wb.activity of
        Just deliveries ->
            if List.isEmpty deliveries then
                text ""

            else
                section [ class "wb-section" ]
                    [ h2 [ class "wb-section-title" ] [ text "最近交付" ]
                    , div [ class "delivery-list" ] (List.map (deliveryRow wb.now) (List.take 5 deliveries))
                    ]

        Nothing ->
            text ""


deliveryRow : Posix -> DeliveryRecord -> Html State.Msg
deliveryRow now record =
    div [ class "delivery-row" ]
        [ span [ class "delivery-kind" ] [ text (deliveryKindLabel record.kind) ]
        , span [ class "delivery-title" ] [ text record.title ]
        , span [ class "delivery-time" ] [ text (relativeTime now record.at) ]
        ]


deliveryKindLabel : String -> String
deliveryKindLabel kind =
    case kind of
        "file_write" ->
            "文件"

        "artifact" ->
            "构件"

        _ ->
            "答案"


relativeTime : Posix -> Int -> String
relativeTime now stampSeconds =
    Format.formatRelative (Format.elapsedSeconds now stampSeconds)


errorNote : Maybe String -> Html State.Msg
errorNote error =
    case error of
        Just message ->
            div [ class "wb-note-error" ] [ text ("快照加载失败：" ++ message) ]

        Nothing ->
            text ""


tasksView : TelemetryState -> State.Model -> String -> Html State.Msg
tasksView telemetry wb yuki =
    section [ class "wb-section" ]
        [ h2 [ class "wb-section-title" ] [ text "任务" ]
        , case wb.tasks of
            Nothing ->
                div [ class "now-empty" ] [ text (if wb.tasksPending then "加载中…" else "尚未加载") ]

            Just tasks ->
                let
                    mine =
                        List.filter (\meta -> meta.incarnationId == yuki) tasks
                            |> List.sortWith (\left right -> compare right.updated left.updated)

                    activeThreads =
                        activeThreadIds telemetry
                in
                if List.isEmpty mine then
                    div [ class "now-empty" ] [ text "该 Yuki 还没有任务" ]

                else
                    div [ class "wb-task-list" ] (List.map (taskRow wb.now activeThreads) mine)
        , errorNote wb.tasksError
        ]


activeThreadIds : TelemetryState -> List String
activeThreadIds telemetry =
    Dict.values telemetry.runs |> List.map .threadId


taskRow : Posix -> List String -> SessionMeta -> Html State.Msg
taskRow now activeThreads meta =
    a
        [ class "wb-task-row wb-task-row-link"
        , href ("/yuki/" ++ meta.incarnationId ++ "/chat/" ++ meta.id)
        ]
        [ span [ class "wb-task-row-title" ] [ text meta.title ]
        , div [ class "wb-task-row-meta" ]
            [ if List.member meta.id activeThreads then
                span [ class "badge badge-active" ] [ text "运行中" ]

              else
                text ""
            , if meta.archived then
                span [ class "badge badge-archived" ] [ text "已归档" ]

              else
                text ""
            , span [ class "wb-task-row-time" ] [ text (relativeTime now meta.updated) ]
            ]
        ]
