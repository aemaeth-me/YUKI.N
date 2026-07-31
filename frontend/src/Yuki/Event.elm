module Yuki.Event exposing (applyAgent, applyTransport)

import Dict
import Json.Decode as Decode
import Yuki.Request as Request
import Yuki.State as State
import Yuki.Types exposing (..)


applyAgent : AgentEvent -> Model -> ( Model, Effect )
applyAgent event model =
    case event of
        RunStarted threadId runId ->
            if threadId == model.threadId then
                ( { model | phase = Streaming, activeRun = Just runId, error = Nothing }, None )

            else
                ( model, None )

        RunFinished threadId _ ->
            if threadId == model.threadId then
                ( State.completeStreaming
                    { model | phase = Idle, activeRun = Nothing, activeStep = Nothing }
                , Batch [ Request.sessions model, Request.impression model ]
                )

            else
                ( model, None )

        RunError message code ->
            ( State.completeStreaming
                { model
                    | phase = Failed
                    , activeRun = Nothing
                    , activeStep = Nothing
                    , error = Just (runError message code)
                }
            , None
            )

        StepStarted name ->
            ( { model | activeStep = Just name, phase = Streaming }, None )

        StepFinished _ ->
            ( { model | activeStep = Nothing }, None )

        TextStarted identifier ->
            ( State.ensureAssistant identifier model, None )

        TextContent identifier delta ->
            ( State.mapAssistant identifier
                (\assistant -> { assistant | content = assistant.content ++ delta })
                (State.ensureAssistant identifier model)
            , None
            )

        TextEnded identifier ->
            ( State.mapAssistant identifier (\assistant -> { assistant | complete = True }) model, None )

        ReasoningStarted identifier ->
            ( State.ensureReasoning identifier model, None )

        ReasoningContent identifier delta ->
            ( State.mapReasoning identifier
                (\reasoning -> { reasoning | content = reasoning.content ++ delta })
                (State.ensureReasoning identifier model)
            , None
            )

        ReasoningEnded identifier ->
            ( State.mapReasoning identifier (\reasoning -> { reasoning | complete = True }) model, None )

        ToolStarted identifier name parentId ->
            let
                tool =
                    { id = identifier
                    , name = name
                    , arguments = ""
                    , parentMessageId = parentId
                    , stage = ToolStreaming
                    , output = ""
                    , result = Nothing
                    }
            in
            ( parentId
                |> Maybe.map
                    (\messageId ->
                        State.mapAssistant messageId
                            (\assistant ->
                                if List.member identifier assistant.toolCalls then
                                    assistant

                                else
                                    { assistant | toolCalls = assistant.toolCalls ++ [ identifier ] }
                            )
                            { model | tools = Dict.insert identifier tool model.tools }
                    )
                |> Maybe.withDefault { model | tools = Dict.insert identifier tool model.tools }
            , None
            )

        ToolArguments identifier delta ->
            ( State.mapTool identifier
                (\tool -> { tool | arguments = tool.arguments ++ delta })
                (ensureTool identifier model)
            , None
            )

        ToolEnded identifier ->
            let
                waiting =
                    Dict.get identifier model.tools
                        |> Maybe.map (\tool -> tool.name == "request_confirmation")
                        |> Maybe.withDefault False
            in
            ( State.mapTool identifier
                (\tool -> { tool | stage = if waiting then ToolWaiting else ToolStreaming })
                { model | phase = if waiting then AwaitingTool else Streaming }
            , None
            )

        ToolResultReceived messageId callId content ->
            let
                ensured =
                    ensureTool callId model
            in
            ( State.appendMessage messageId
                (ToolMessage { id = messageId, callId = callId, content = content })
                (State.mapTool callId
                    (\tool -> { tool | stage = ToolResolved ToolReturned, result = Just content })
                    { ensured | phase = Streaming }
                )
            , None
            )

        ContextInject content ->
            let
                ( identifier, identified ) =
                    State.freshId "context" model
            in
            ( State.appendMessage identifier
                (NoticeMessage identifier (contextNotice content))
                identified
            , None
            )

        UsageObserved usage ->
            ( { model | usage = Just usage }, None )

        ShellOutput callId delta ->
            ( State.mapTool callId (\tool -> { tool | output = tool.output ++ delta }) model, None )

        ProviderRetry attempt maxAttempts delay reason ->
            let
                ( identifier, identified ) =
                    State.freshId "retry" model
            in
            ( State.appendMessage identifier
                (NoticeMessage identifier
                    ("模型服务重试 "
                        ++ String.fromInt attempt
                        ++ "/"
                        ++ String.fromInt maxAttempts
                        ++ " · "
                        ++ String.fromInt delay
                        ++ "ms · "
                        ++ State.compact reason
                    )
                )
                identified
            , None
            )

        ContextStatus gauge ->
            ( { model | contextGauge = Just gauge }, None )

        ContextCompact before after ->
            let
                ( identifier, identified ) =
                    State.freshId "sleep" model
            in
            ( State.appendMessage identifier
                (NoticeMessage identifier
                    ("工作记忆已整理 · "
                        ++ String.fromInt before
                        ++ " → "
                        ++ String.fromInt after
                        ++ " tokens"
                    )
                )
                identified
            , None
            )

        RunCancelled _ ->
            ( State.completeStreaming { model | phase = Canceled, activeRun = Nothing, activeStep = Nothing }, None )

        SubAgentObserved callId nested ->
            ( applySubAgent callId nested model, None )

        CustomObserved _ ->
            ( model, None )

        IgnoredEvent ->
            ( model, None )


contextNotice : String -> String
contextNotice content =
    if String.contains "[impression cues" content then
        let
            count =
                content
                    |> String.lines
                    |> List.filter (String.startsWith "- ")
                    |> List.length
        in
        "已唤起 "
            ++ String.fromInt count
            ++ " 条非事实印象提示；回答前仍需查证来源。"

    else
        "已加入本轮所需的运行材料。"


applyTransport : TransportSignal -> Model -> ( Model, Effect )
applyTransport signal model =
    case signal of
        TransportConnecting runId ->
            if model.activeRun == Just runId then
                ( { model | phase = Connecting }, None )

            else
                ( model, None )

        TransportOpen runId ->
            if model.activeRun == Just runId then
                ( { model | phase = Streaming }, None )

            else
                ( model, None )

        TransportClosed runId ->
            if model.activeRun == Just runId then
                ( State.completeStreaming { model | phase = Idle, activeRun = Nothing }
                , Batch [ Request.sessions model, Request.impression model ]
                )

            else
                ( model, None )

        TransportCancelled runId ->
            if model.activeRun == Just runId then
                ( State.completeStreaming { model | phase = Canceled, activeRun = Nothing }, None )

            else
                ( model, None )

        TransportFailed runId message ->
            if model.activeRun == Just runId then
                ( State.completeStreaming
                    { model
                        | phase = Failed
                        , activeRun = Nothing
                        , error = Just ("连接运行后端失败。\n" ++ message)
                    }
                , None
                )

            else
                ( model, None )


runError : String -> Maybe String -> String
runError message code =
    case code of
        Just "MAX_TURNS_EXCEEDED" ->
            "运行已停在本机轮次上限。\n" ++ message

        Just "PROVIDER_ERROR" ->
            "模型服务没有完成这次回应。\n" ++ message

        Just "PERSISTENCE_ERROR" ->
            "回应已经发生，但未能完整保存。\n" ++ message

        _ ->
            "运行没有完成。\n" ++ message


type SubEvent
    = SubDelta String
    | SubFailure String
    | SubStatus String
    | SubActivity String
    | SubContext ContextGauge
    | SubIgnored


applySubAgent : String -> Decode.Value -> Model -> Model
applySubAgent callId nested model =
    let
        change transform =
            model
                |> State.ensureSubAgent callId
                |> State.mapSubAgent callId transform
    in
    case classifySubEvent nested of
        SubDelta delta ->
            change (\sub -> { sub | content = sub.content ++ delta, status = "正在汇报" })

        SubFailure message ->
            change (\sub -> { sub | failed = True, error = Just message, status = "失败" })

        SubStatus status ->
            change (\sub -> { sub | status = status })

        SubActivity activity ->
            change (\sub -> { sub | activity = pushActivity activity sub.activity })

        SubContext gauge ->
            change (\sub -> { sub | context = Just gauge })

        SubIgnored ->
            model


classifySubEvent : Decode.Value -> SubEvent
classifySubEvent nested =
    case Decode.decodeValue (Decode.field "type" Decode.string) nested of
        Ok "TEXT_MESSAGE_CONTENT" ->
            Decode.decodeValue (Decode.field "delta" Decode.string) nested
                |> Result.map SubDelta
                |> Result.withDefault SubIgnored

        Ok "RUN_ERROR" ->
            Decode.decodeValue (Decode.field "message" Decode.string) nested
                |> Result.map SubFailure
                |> Result.withDefault (SubFailure "子代理运行失败。")

        Ok "RUN_STARTED" ->
            SubStatus "运行中"

        Ok "RUN_FINISHED" ->
            SubStatus "完成"

        Ok "STEP_STARTED" ->
            Decode.decodeValue (Decode.field "stepName" Decode.string) nested
                |> Result.map (SubActivity << (++) "阶段 · ")
                |> Result.withDefault SubIgnored

        Ok "TOOL_CALL_START" ->
            Decode.decodeValue (Decode.field "toolCallName" Decode.string) nested
                |> Result.map (SubActivity << (++) "调用 · ")
                |> Result.withDefault SubIgnored

        Ok "CUSTOM" ->
            classifySubCustom nested

        _ ->
            SubIgnored


classifySubCustom : Decode.Value -> SubEvent
classifySubCustom nested =
    case Decode.decodeValue (Decode.field "name" Decode.string) nested of
        Ok "context.status" ->
            Decode.decodeValue subContextGauge nested
                |> Result.map SubContext
                |> Result.withDefault SubIgnored

        Ok "provider.retry" ->
            Decode.decodeValue
                (Decode.map2
                    (\attempt maximum ->
                        SubActivity
                            ("模型服务重试 "
                                ++ String.fromInt attempt
                                ++ "/"
                                ++ String.fromInt maximum
                            )
                    )
                    (Decode.at [ "value", "attempt" ] Decode.int)
                    (Decode.at [ "value", "maxAttempts" ] Decode.int)
                )
                nested
                |> Result.withDefault SubIgnored

        Ok "context.compact" ->
            Decode.decodeValue
                (Decode.map2
                    (\before after ->
                        SubActivity
                            ("工作记忆整理 "
                                ++ String.fromInt before
                                ++ " → "
                                ++ String.fromInt after
                            )
                    )
                    (Decode.at [ "value", "beforeTokens" ] Decode.int)
                    (Decode.at [ "value", "afterTokens" ] Decode.int)
                )
                nested
                |> Result.withDefault SubIgnored

        _ ->
            SubIgnored


subContextGauge : Decode.Decoder ContextGauge
subContextGauge =
    Decode.map4 ContextGauge
        (Decode.at [ "value", "tokens" ] Decode.int)
        (Decode.at [ "value", "budgetTokens" ] Decode.int)
        (Decode.at [ "value", "willCompact" ] Decode.bool)
        (Decode.at [ "value", "emergency" ] Decode.bool)


pushActivity : String -> List String -> List String
pushActivity item activity =
    List.take 8 (item :: List.filter ((/=) item) activity)


ensureTool : String -> Model -> Model
ensureTool identifier model =
    if Dict.member identifier model.tools then
        model

    else
        { model
            | tools =
                Dict.insert identifier
                    { id = identifier
                    , name = "unknown_tool"
                    , arguments = ""
                    , parentMessageId = Nothing
                    , stage = ToolStreaming
                    , output = ""
                    , result = Nothing
                    }
                    model.tools
        }
