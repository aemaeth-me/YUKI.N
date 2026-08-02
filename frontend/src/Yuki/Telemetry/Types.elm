module Yuki.Telemetry.Types exposing (..)

import Json.Decode as Decode


type alias RunId =
    String


type RunKind
    = RunHome
    | RunTask
    | RunWorker


type RunPhase
    = PhaseRunning
    | PhaseAwaitingTool
    | PhaseCompacting
    | PhaseSleeping
    | PhaseCancelling


type alias ActiveTool =
    { callId : String
    , name : String
    , startedAt : Int
    }


type alias ContextSnapshot =
    { estimatedTokens : Int
    , budgetTokens : Int
    , windowTokens : Int
    }


type alias LiveStatus =
    { runId : RunId
    , threadId : String
    , incarnationId : String
    , parentRunId : Maybe RunId
    , kind : RunKind
    , phase : RunPhase
    , objective : Maybe String
    , startedAt : Int
    , lastEventAt : Int
    , turn : Int
    , maxTurns : Int
    , model : String
    , usagePrompt : Int
    , usageCompletion : Int
    , context : Maybe ContextSnapshot
    , activeTools : List ActiveTool
    , workers : Int
    , lastActivity : Maybe String
    }


type alias FleetEntry =
    { id : String
    , name : String
    , state : String
    , activeRuns : Int
    , waitingDrafts : Int
    , lastDeliveryAt : Maybe Int
    }


type alias DeliveryRecord =
    { deliveryId : String
    , runId : RunId
    , threadId : String
    , incarnationId : String
    , runKind : RunKind
    , kind : String
    , title : String
    , ref : String
    , bytes : Maybe Int
    , at : Int
    }


type FsOrigin
    = OriginTool String String
    | OriginGit


type alias FsChangeRecord =
    { fsChangeId : String
    , runId : RunId
    , threadId : String
    , incarnationId : String
    , path : String
    , op : String
    , origin : FsOrigin
    , diff : Maybe String
    , stat : Maybe String
    , at : Int
    }


type alias DispatchDraft =
    { dispatchId : String
    , incarnationId : String
    , source : String
    , input : String
    , title : String
    , prompt : String
    , config : Decode.Value
    , generation : String
    , status : String
    , createdThreadId : Maybe String
    , error : Maybe String
    , createdAt : Int
    , updatedAt : Int
    }


type ActivityFrame
    = FrameFleet (List FleetEntry) (List LiveStatus)
    | FrameStatus LiveStatus
    | FrameRunEnd RunId String
    | FrameDelivery DeliveryRecord
    | FrameFsChange FsChangeRecord
    | FrameDraft DispatchDraft
    | FrameDraftResolved String String (Maybe String)
    | FramePing


type Connection
    = ConnLive
    | ConnDegraded
    | ConnOffline
