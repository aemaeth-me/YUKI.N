module Yuki.Workbench.Types exposing (WorkbenchView(..))


type WorkbenchView
    = ViewNow
    | ViewChat (Maybe String)
    | ViewTasks
    | ViewDeliveries
    | ViewChanges
    | ViewRun String
