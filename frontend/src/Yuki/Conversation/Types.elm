module Yuki.Conversation.Types exposing (AgentEvent(..), Gauge, Item(..), Msg(..), NoteKind(..), Phase(..), SubState, ToolStage(..), ToolState)

import Json.Decode as Decode


type Phase
    = PhaseIdle
    | PhaseConnecting
    | PhaseStreaming
    | PhaseAwaiting
    | PhaseFailed
    | PhaseCanceled


type alias Gauge =
    { tokens : Int
    , budget : Int
    , willCompact : Bool
    , emergency : Bool
    }


type ToolStage
    = ToolStreaming
    | ToolWaiting
    | ToolDone
    | ToolRejected


type alias ToolState =
    { callId : String
    , name : String
    , arguments : String
    , result : Maybe String
    , stage : ToolStage
    , open : Bool
    }


type alias SubState =
    { callId : String
    , content : String
    , status : String
    , failed : Bool
    , error : Maybe String
    , activity : List String
    , context : Maybe Gauge
    , open : Bool
    }


type NoteKind
    = NoteInfo
    | NoteWarn


type Item
    = UserItem { id : String, content : String }
    | AssistantItem { id : String, content : String, complete : Bool }
    | ReasoningItem { id : String, content : String }
    | ToolItem ToolState
    | ToolResultItem { id : String, callId : String, content : String }
    | SubItem SubState
    | NoteItem { id : String, text : String, kind : NoteKind }


type AgentEvent
    = RunStarted String String
    | RunFinished String String
    | RunError String (Maybe String)
    | RunCancelled String
    | StepStarted String
    | StepFinished String
    | TextStarted String
    | TextContent String String
    | TextEnded String
    | ReasoningStarted String
    | ReasoningContent String String
    | ReasoningEnded String
    | ToolStarted String String (Maybe String)
    | ToolArgs String String
    | ToolEnded String
    | ToolResult String String String
    | Custom String Decode.Value
    | Ignored


type Msg
    = Enter String
    | ChatResult String Int Decode.Value
    | AgentEvent Decode.Value
    | TransportEvent Decode.Value
    | ComposerChanged String
    | Send
    | Retry
    | Reload
    | Tick
