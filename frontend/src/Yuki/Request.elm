module Yuki.Request exposing (artifacts, auditRuns, capabilities, config, contextPolicy, experiences, globalConfig, incarnation, incarnations, impression, impressionActivations, impressionRevisions, memoryReceipts, prompts, providers, rootPrompts, sessions, sleepCycles, taskArchives, transcript, tree, workingMemory)

import Yuki.Encode as Encoder
import Yuki.Types exposing (Effect(..), Model)


sessions : Model -> Effect
sessions model =
    Inspect <|
        Encoder.inspectionRequest model
            "tasks/list"
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/tasks?archived=true")


transcript : Model -> Effect
transcript model =
    Inspect <|
        Encoder.inspectionRequest model
            ("transcript/" ++ model.threadId)
            "GET"
            Nothing
            ("threads/" ++ model.threadId ++ "/transcript")


incarnation : Model -> Effect
incarnation model =
    Inspect <|
        Encoder.inspectionRequest model
            ("incarnation/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId)


incarnations : Model -> Effect
incarnations model =
    Inspect <|
        Encoder.inspectionRequest model
            "incarnations/list"
            "GET"
            Nothing
            "incarnations?archived=true"


prompts : Model -> Effect
prompts model =
    Inspect <|
        Encoder.inspectionRequest model
            ("prompts/list/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/prompts")


rootPrompts : Model -> Effect
rootPrompts model =
    Inspect <|
        Encoder.inspectionRequest model
            "prompts/root"
            "GET"
            Nothing
            "prompts/root"


impression : Model -> Effect
impression model =
    Inspect <|
        Encoder.inspectionRequest model
            ("impression/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/impression")


impressionActivations : Model -> Effect
impressionActivations model =
    Inspect <|
        Encoder.inspectionRequest model
            ("memory/activations/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/impression/activations?limit=30")


impressionRevisions : Model -> Effect
impressionRevisions model =
    Inspect <|
        Encoder.inspectionRequest model
            ("memory/revisions/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/impression/revisions?limit=30")


taskArchives : Model -> Effect
taskArchives model =
    Inspect <|
        Encoder.inspectionRequest model
            ("memory/task-archives/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/task-records")


workingMemory : Model -> Effect
workingMemory model =
    Inspect <|
        Encoder.inspectionRequest model
            ("memory/working/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/working-memory")


sleepCycles : Model -> Effect
sleepCycles model =
    Inspect <|
        Encoder.inspectionRequest model
            ("memory/sleep/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/sleep-cycles?limit=30")


experiences : Model -> Effect
experiences model =
    Inspect <|
        Encoder.inspectionRequest model
            ("memory/experiences/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/experiences?limit=30")


memoryReceipts : Model -> Effect
memoryReceipts model =
    Inspect <|
        Encoder.inspectionRequest model
            ("memory/receipts/" ++ model.incarnationId)
            "GET"
            Nothing
            ("incarnations/" ++ model.incarnationId ++ "/memory-receipts")


capabilities : Model -> Effect
capabilities model =
    Inspect <|
        Encoder.inspectionRequest model
            ("capabilities/" ++ model.threadId)
            "GET"
            Nothing
            ("config/threads/" ++ model.threadId ++ "/capabilities")


config : Model -> Effect
config model =
    Inspect <|
        Encoder.inspectionRequest model
            ("config/task/" ++ model.threadId)
            "GET"
            Nothing
            ("config/threads/" ++ model.threadId)


globalConfig : Model -> Effect
globalConfig model =
    Inspect <| Encoder.inspectionRequest model "config/global" "GET" Nothing "config"


providers : Model -> Effect
providers model =
    Inspect <| Encoder.inspectionRequest model "config/providers" "GET" Nothing "providers"


contextPolicy : Model -> Effect
contextPolicy model =
    Inspect <|
        Encoder.inspectionRequest model
            ("config/context/" ++ model.threadId)
            "GET"
            Nothing
            ("config/threads/" ++ model.threadId ++ "/context")


tree : Model -> Effect
tree model =
    Inspect <|
        Encoder.inspectionRequest model
            ("config/tree/" ++ model.threadId)
            "GET"
            Nothing
            ("config/threads/" ++ model.threadId ++ "/tree?depth=3")


auditRuns : Model -> Effect
auditRuns model =
    Inspect <| Encoder.inspectionRequest model "audit/runs" "GET" Nothing "journal/runs"


artifacts : Model -> Effect
artifacts model =
    Inspect <| Encoder.inspectionRequest model "audit/artifacts" "GET" Nothing "artifacts"
