# Agent 集群与工作台：Specs

> 权威规格。设计意图见 [`01-设计.md`](01-设计.md)；前端信息架构见
> [`04-前端架构.md`](04-前端架构.md)；任务拆解见
> [`03-任务列表.md`](03-任务列表.md)。本文规定数据模型、持久化、HTTP API、
> 事件、工具 schema、状态机与并发语义。
>
> 标注：**[P1]** / **[P2]** / **[P3]** 表示所属分期；未标注即 P1。

## 一、数据模型

### 1.1 SessionKind（SessionMeta 扩展）

```haskell
data SessionKind = SessionHome | SessionTask
```

- `SessionMeta` 新增 `sessionKind :: SessionKind`。
- JSON：`"kind": "home" | "task"`；**反序列化缺省 `"task"`**，存量
  `sessions/index.json` 零迁移。
- `SessionHome` 约束：
  - 每个 incarnationId 至多一个；id 确定为 `home-<incarnationId>`（幂等）。
  - `archive / restore / fork / delete / import 覆盖` 对该 id 返回
    `400 {error: "home_session_immutable"}`。
  - `home-` 前缀为保留 id：`createSession` 与 `importSession` 拒绝此前缀
    （`reserved thread id`）；Home 只能经 `ensureHomeSession` 产生。
  - `ensureHomeSession` 幂等且自修复：同名存量行的 kind 会被修正为
    `SessionHome`（`ensureSession` 永不降级 Home 为 Task）。
  - `renameSession` 允许（标题仅展示用）。
  - 归档 Yuki 时 Home 不随归档（防止被 400 锁死）；删除 Yuki 时 Home 随
    `deleteSessionsFor` 一并删除。
- `listSessions` 行为不变；任务列表语义由 `GET /threads?kind=` 承担（§2.2）。

### 1.2 DispatchDraft

```text
DispatchDraft
├── dispatchId :: Text                 -- 服务端生成，"dsp-" 前缀
├── incarnationId :: Text
├── source :: DispatchSource
│     = DispatchUser                   -- 用户手动发起
│     | DispatchAgent { runId, callId }-- propose_dispatch 工具发起
├── input :: Text                      -- 用户原始需求描述 / 工具的 reason
├── title :: Text                      -- 可编辑
├── prompt :: Text                     -- 可编辑；confirm 后成为首条任务指令
├── config :: ThreadConfig             -- 可编辑；能力快照，初始 = Home 会话
│                                      -- ThreadConfig 的显式字段（播种），
│                                      -- 用户/Yuki 可改；不得含 incarnationId 覆盖
├── generation :: DispatchGeneration
│     = GeneratedModel { invocationId }-- Invocation 模型起草
│     | GeneratedFallback              -- 回退：title=描述首行截断，prompt=描述原文
│     | GeneratedAgent                 -- Yuki 在工具参数中直接给出
├── status :: DispatchStatus
│     = Draft | Dispatched | Cancelled
├── createdThreadId :: Maybe Text
├── error :: Maybe Text                -- confirm 失败原因（可重试）
├── createdAt / updatedAt :: Integer
└── dispatchedAt :: Maybe Integer
```

持久化：`<dataDir>/dispatches.json`（MVar + atomic file，与既有 store 同构）。

状态机：

```text
        confirm 成功
Draft ───────────────► Dispatched（终态；createdThreadId 必填）
  │  │
  │  └── confirm 失败 ──► Draft（error 填入，可修改后重试）
  └── cancel ──────────► Cancelled（终态）
```

- 仅 `Draft` 可 PATCH / confirm / cancel。
- confirm 是**单次原子步骤**：创建 Thread（meta + config + transcript 首条）
  全部成功才置 `Dispatched`；任一步失败回滚并回填 `error`。
- `DispatchAgent` 草案的 confirm/cancel 同时唤醒等待中的工具调用（§4.2）。

### 1.3 Run 树索引（RunRegistry 扩展）

```haskell
data RunKind = RunHome | RunTask | RunWorker

data RunHandle = RunHandle
  { runHandleThread       :: ThreadId
  , runHandleTaskId       :: Text
  , runHandleIncarnation  :: Text          -- 新增
  , runHandleParent       :: Maybe Text    -- 新增：父 runId（Worker）
  , runHandleKind         :: RunKind       -- 新增
  , runHandleObjective    :: Maybe Text    -- 新增：首条用户输入截断（≤ 120 字符）
  , runHandleStartedAt    :: Integer       -- 新增：POSIX 秒
  , runHandleSteer        :: IORef [ChatMessage]
  , runHandleFollowUp     :: IORef [ChatMessage]
  }
```

- `withRunRegistrationFor` 扩展为接收完整 `RunDescriptor`；同步 `sub_agent`
  注册 kind=RunWorker、parent=父 runId。
- 注册表易失：进程重启后活跃状态为空，不谎报。

**[P2]** 完成表：

```haskell
data RunCompletion = RunCompletion
  { completionRunId :: Text
  , completionParent :: Maybe Text
  , completionOutcome :: CompletionOutcome   -- Completed | Failed Text | Cancelled
  , completionResult :: Text                 -- 最终文本截断（≤ 4000 字符）
  , completionAt :: Integer
  }
```

- `runAgent` 终局（succeeded / failed / cancelled 三处 conclusion）写入。
- 条目保留至父 Run 注销（父为根时随父注销清除整棵子树）。

### 1.4 LiveStatus（遥测实时投影）

```haskell
data RunPhase
  = PhaseRunning        -- 模型调用或工具执行间隙
  | PhaseAwaitingTool   -- 等待工具结果（含等待用户确认类工具）
  | PhaseCompacting     -- 上下文压缩中
  | PhaseSleeping       -- 睡眠周期中
  | PhaseCancelling     -- 已收到取消，尚未终局

data ActiveTool = ActiveTool
  { activeCallId :: Text, activeToolName :: Text, activeToolAt :: Integer }

data LiveStatus = LiveStatus
  { liveRunId, liveThreadId, liveIncarnation :: Text
  , liveParent :: Maybe Text
  , liveKind :: RunKind
  , livePhase :: RunPhase
  , liveObjective :: Maybe Text
  , liveStartedAt, liveLastEventAt :: Integer
  , liveTurn :: Int                 -- STEP_STARTED 计数
  , liveMaxTurns :: Int
  , liveModel :: Text               -- 实际模型链（含 fallback）
  , liveUsage :: Usage              -- 累计 token（usage 事件）
  , liveContext :: Maybe ContextSnapshot
      -- { estimatedTokens, triggerTokens, ratio }（context.status 事件）
  , liveActiveTools :: [ActiveTool] -- TOOL_CALL_START 未配对 END 者
  , liveWorkers :: Int              -- 活跃子 Worker 数
  , liveLastActivity :: Maybe Text  -- 最近活动结构化摘要（如 "tool:fs_write"）
  }
```

- 由 Telemetry projector 经 `AgentHooks.observeEvent` 逐事件维护；
  `IORef (Map runId LiveStatus)`；Run 注册时建立、终局时移除（移除前广播
  一条终态，§2.5）。
- `liveMaxTurns` / `liveModel` 来自 RunBegin 的 RunSettings 快照。
- phase 推导：`STEP_STARTED`→Running；`TOOL_CALL_START`→AwaitingTool；
  `TOOL_CALL_END` 全部配对→Running；`context.compact`→Compacting；
  `context.sleep`→Sleeping；取消请求→Cancelling。推导规则是投影逻辑，
  不改事件本身。

### 1.5 DeliveryRecord（交付台账）

```haskell
data DeliveryKind = DeliveryAnswer | DeliveryArtifact | DeliveryFileWrite

data DeliveryRecord = DeliveryRecord
  { deliveryId :: Text                    -- "dlv-" 前缀
  , deliveryRunId, deliveryThreadId, deliveryIncarnation :: Text
  , deliveryRunKind :: RunKind
  , deliveryKind :: DeliveryKind
  , deliveryTitle :: Text                 -- 答案摘要(≤200字符) / artifact 描述 / 文件路径
  , deliveryRef :: Text                   -- transcript msgId | artifactId | 相对路径
  , deliveryBytes :: Maybe Int
  , deliveryAt :: Integer
  }
```

- **DeliveryAnswer**：仅根 Run（RunHome / RunTask）正常结束时记录，
  ref=该 assistant message id。
- **DeliveryArtifact**：artifact 溢出创建时记录（任意 Run，含 Worker）。
- **DeliveryFileWrite**：fs 写工具成功时记录（任意 Run），与 §1.6 同源。
- 持久化：`<dataDir>/deliveries.jsonl` 追加；读时按 incarnation/thread 过滤。
- Worker 最终文本不记 Answer（经父 Run 汇报）。

### 1.6 FsChangeRecord（FS 变更台账）

```haskell
data FsChangeOp = FsCreated | FsModified | FsDeleted

data FsChangeOrigin
  = OriginTool { toolName :: Text, callId :: Text }
  | OriginGit

data FsChangeRecord = FsChangeRecord
  { fsChangeId :: Text                    -- "fsc-" 前缀
  , fsChangeRunId, fsChangeThreadId, fsChangeIncarnation :: Text
  , fsChangePath :: Text                  -- 相对 cwd（无法相对化时存绝对路径并标记）
  , fsChangeOp :: FsChangeOp
  , fsChangeOrigin :: FsChangeOrigin
  , fsChangeDiff :: Maybe Text            -- 工具写入的 unified diff（≤ 8KB 截断）
  , fsChangeStat :: Maybe Text            -- git 增强的 diff --stat 行
  , fsChangeAt :: Integer
  }
```

- **工具拦截**：装配层包装 fs 写/编辑工具（`workTools` 出口处），成功后按
  参数与结果生成记录；diff 由工具自身已知内容计算（`Domain.Diff.unified`）。
- **git 增强**：根 Run 终局时，cwd 在 git 仓库内 → 只读执行
  `git status --porcelain` 与 `git diff --stat HEAD`（各 3s 超时，失败静默）；
  与既有记录路径求差后补 `OriginGit` 记录（只存 stat 行，不存全文）。
- 非 git 目录且未经工具的修改：**不产生记录**；UI 在该任务上显示
  「shell 造成的变更未经追踪」提示（依据：任务有 shell 工具调用且 cwd 非
  仓库）。
- 持久化：`<dataDir>/fs-changes.jsonl` 追加。

### 1.7 ActivitySnapshot 与 FleetSnapshot

`ActivitySnapshot`（单 Yuki 富化快照，`GET /incarnations/:id/activity`）：

```json
{
  "incarnationId": "yuki",
  "home": { "threadId": "home-yuki", "activeRunId": "r1" },
  "runs": [ LiveStatus… ],                // 该 Yuki 全部活跃 Run（含 Worker）
  "waitingDrafts": [ DispatchDraft… ],    // status=draft
  "recentDeliveries": [ DeliveryRecord… ] // 最近 20 条
}
```

`FleetSnapshot`（集群全量，监控流首帧）：

```json
{
  "incarnations": [
    { "id": "yuki", "name": "…", "state": "active|waiting|idle",
      "activeRuns": 2, "waitingDrafts": 1, "lastDeliveryAt": 1754121600 }
  ],
  "runs": [ LiveStatus… ]                 // 全局活跃 Run
}
```

- `state`：有活跃 Run→active；无活跃但有 draft→waiting；否则 idle。
- 任务标题等元数据由 `GET /threads` 承担，快照不重复。

## 二、HTTP API

### 2.1 Home 会话

```
GET /incarnations/:id/home
→ 200 { "threadId": "home-<id>", "meta": SessionMeta, "config": ThreadConfig }
```

- 幂等：无则创建（kind=home、空 transcript、空 ThreadConfig）。
- `:id` 不存在或已归档 → 404。

### 2.2 任务列表

```
GET /threads?kind=task|home|all   （默认 all，兼容旧客户端）
```

### 2.3 Dispatch

```
POST   /incarnations/:id/dispatches
  body { "input": "<需求描述>" }
  → 202 DispatchDraft（status=draft；生成超时 YUKI_DISPATCH_GENERATE_TIMEOUT=20s，
    失败回退 GeneratedFallback）

GET    /dispatches/:dispatchId                    → 200 | 404
GET    /incarnations/:id/dispatches?status=draft  → 200 [DispatchDraft]
PATCH  /dispatches/:dispatchId
  body { "title"?, "prompt"?, "config"? }         → 200 | 409（非 draft）
POST   /dispatches/:dispatchId/confirm
  → 201 { "threadId": "…" } | 409 | 500 {error}（可重试）
POST   /dispatches/:dispatchId/cancel             → 200 | 409
```

confirm 语义：

1. 校验 draft 状态与 incarnation 存活。
2. 创建 Thread：`sessionKind=task`、`sessionIncarnationId=draft.incarnationId`、
   title=draft.title。
3. 写 `threads-config/<thread>.json` = `draft.config`（原样；与全局/Home 的
   合并发生在每次 Run 的 resolve，与既有语义一致）。
4. Transcript 追加首条 `ChatUser`（content=draft.prompt；`ChatUser` 不携带
   持久 id，渲染 id 由既有 `tr-N` 派生）。
5. 置 `Dispatched`，记录 `createdThreadId`。
6. **不启动 Run**：前端进入任务视图后按既有 `POST /agent` 流程发起；
   自动发起条件 = transcript 末条为未应答 user message。
7. 失败回滚：已创建的任务行以 archive 软删除（Sessions 无硬删除；归档行
   不进活跃列表，P3 可加物理清理），config 文件与 transcript 物理删除；
   draft 回填 `error` 并保持 `Draft` 可重试。

### 2.4 Activity（快照，初始加载与降级）

```
GET /incarnations/:id/activity   → 200 ActivitySnapshot（§1.7）
GET /fleet                       → 200 FleetSnapshot（§1.7）
```

- 无任何副作用（不触发创建或模型调用）。

### 2.5 监控 SSE 流

```
GET /activity/stream
→ 200 text/event-stream
```

帧格式（自定义 SSE，非 AG-UI）：

```
event: snapshot   data: FleetSnapshot                 -- 连接建立即发送
event: status     data: LiveStatus                    -- 某 Run 状态变化（节流 §5.3）
event: run.end    data: { "runId", "outcome": "completed|failed|cancelled" }
event: delivery   data: DeliveryRecord
event: fschange   data: FsChangeRecord
event: draft      data: DispatchDraft                 -- 新草案（含 propose_dispatch）
event: draft.resolved  data: { "dispatchId", "status", "threadId"? }
```

- ActivityHub（TChan 广播）：projector 与 dispatch store 向 hub 发布；
  每连接 `dupTChan` 消费；慢消费者丢弃（广播语义天然）。
- 连接级心跳：15s 无帧发 `: ping`。
- 该流**不承载** Run 事件正文（消息/工具调用流仍属 `POST /agent` 与
  journal trace）。

### 2.6 交付与变更查询

```
GET /incarnations/:id/deliveries?threadId=&limit=50&before=<ts>
  → 200 { "items": [DeliveryRecord], "hasMore": bool }
GET /incarnations/:id/fs-changes?threadId=&runId=&limit=50&before=<ts>
  → 200 { "items": [FsChangeRecord], "hasMore": bool }
```

- 按时间倒序；`before` 为游标；limit 上限 200。
- diff 全文随记录返回（已截断 ≤ 8KB）；artifact 正文经既有 `GET /artifacts/:id`。

### 2.7 既有端点语义确认（无改动，列出以固定契约）

- `POST /agent`：Home 与任务共用；kind 不改变 run 语义。
- `POST /agent/steer` / `cancel` / `follow-up`：按 runId 寻址，对 Worker
  同样有效。
- `POST /threads/:id/archive|restore|fork`：对 Home id 返回 400。

## 三、AG-UI 事件

### 3.1 新增 CUSTOM 事件（`POST /agent` 流内）

```
dispatch.draft        [P2] Yuki 提议的派发草案；value = DispatchDraft JSON
worker.notice         [P2] 父 Run 流内：异步 Worker 终局通告
  value = { "runId", "parentRunId", "outcome", "summary" }
```

### 3.2 `agent.sub` 扩展（向后兼容）

value 新增可选字段：`"mode": "sync"`、`"objective"`。旧前端忽略；
缺省 `mode="sync"`。异步 Worker **[P2]** 不产生 `agent.sub`。

### 3.3 既有事件不变

`RUN_STARTED.parentRunId`、`context.status`、`usage`、`run.cancelled` 等
语义不变。Telemetry projector 是这些事件的**消费者**，不改变其产生。

## 四、工具规格

### 4.1 同步 `sub_agent`（现状，保留）

schema `{prompt: string}`；同步阻塞；子 Run kind=RunWorker、depth-1、
工具经 `workerDeniedTools` 裁剪；事件 `agent.sub` 包装进父流。
仅改动：注册 RunDescriptor 填充 kind/parent/objective（§1.3）。

### 4.2 `propose_dispatch` **[P2]**

- 可见性：kind ∈ {RunHome, RunTask}；Worker 不可见。
- schema：

```json
{
  "type": "object",
  "properties": {
    "title":  { "type": "string" },
    "prompt": { "type": "string" },
    "reason": { "type": "string" }
  },
  "required": ["title", "prompt"],
  "additionalProperties": false
}
```

- 执行：
  1. 创建 DispatchDraft（source=DispatchAgent{runId, callId}，
     generation=GeneratedAgent，config=当前 Run 解析所得 ThreadConfig 的
     显式字段子集）。
  2. 经 run emit 推 `dispatch.draft`；dispatch store 向 ActivityHub 发布
     `draft` 帧（集群级可见）。
  3. **阻塞等待裁决**：轮询 draft store（500ms），超时
     `YUKI_DISPATCH_CONFIRM_TIMEOUT`（默认 600s）。
  4. 确认 → 返回 `{"threadId":"…","status":"dispatched"}`；
     取消/超时 → `ToolOutcome "dispatch proposal rejected: <reason>"`
     （isError=True）。
  5. run 被取消时阻塞随线程终止，draft 滞留 `draft`，用户仍可手动裁决。

### 4.3 异步 Worker 工具组 **[P2]**

注册条件同 `sub_agent`（`runtimeDepth > 0` 注入）。

**`sub_agent_spawn`** `{prompt, objective?}` → `{agentId, status:"running"}`
- forkIO 启动子 Run：kind=RunWorker、parent=当前 runId、depth-1、工具裁剪
  同同步路径、同 threadId；journal scope `[parent, sub]`。
- 子 Run 事件**不转发**父流；状态经 Telemetry（它自己的 observeEvent 链
  仍接同一 Telemetry store）。
- 并行上限 `YUKI_SUBAGENT_MAX_PARALLEL`（默认 4），超出返回
  `ToolOutcome "worker parallel limit reached" isError=True`。

**`sub_agent_send`** `{agentId, text}` → `{delivered:true}`
- `steerRun registry agentId (ChatUser text)`；仅本 Run 派生的 Worker。

**`sub_agent_status`** `{agentId}` → `{status:"running"} | {status, result, outcome}`
- 读注册表 + 完成表；仅本 Run 派生的 Worker。

**`sub_agent_list`** `{}` → `{workers:[{agentId,status,objective?,startedAt}]}`

**`sub_agent_wait`** `{agentIds:[…], timeoutSeconds?=300}` →
`{results:[{agentId,status,result?}], timedOut:[…]}`
- 上限 3600s；轮询完成表 500ms；仅本 Run 派生的 Worker。

**`sub_agent_cancel`** `{agentId}` → `{cancelled:true}`

**完成通知注入**：异步子 Run 终局时向父 Run steering 队列注入：

```text
ChatSystem "[worker <subRunId> <outcome>] <objective 或 prompt 首行>\n<结果截断 2000 字符>"
```

同时经 Telemetry 广播 `run.end`（父已终止则跳过注入，级联取消先行）。

### 4.4 工具可见性矩阵

| 工具 | 主 Agent | 任务 Agent | Worker |
| --- | --- | --- | --- |
| `sub_agent`（同步） | ✓ | ✓ | depth>1 时 ✓ |
| `sub_agent_*` 族 [P2] | ✓ | ✓ | depth>1 时 ✓ |
| `propose_dispatch` [P2] | ✓ | ✓ | ✗ |
| `memory_remember/void`、`self_update`、`sleep` | ✓ | ✓ | ✗（现状） |

- `workerDeniedTools` 集合加入 `propose_dispatch`；`sub_agent_*` 族与
  `sub_agent` 同受 depth 控制。

### 4.5 fs 写工具包装（Telemetry 接入）

- 在 `workTools` 装配出口包装写类工具（write / edit / 删除类）：成功时向
  Telemetry 报告 `{runId, threadId, incarnationId, path, op, diff}`。
- 包装必须 fail-open：记录失败不影响工具结果。
- shell 工具**不**拦截（无法判定副作用），由 git 增强覆盖（§1.6）。

## 五、并发与生命周期语义

### 5.1 注册与注销

- 每个 Run（根/Worker）启动即注册 RunDescriptor + 建立 LiveStatus；
  终止即注销（bracket）。
- **[P2]** 注销前写完成表；异步 Worker 终局 → 注入父 steering；
  父 Run 终局 → 级联取消未完成子 Run（递归）→ 清理子树完成表。

### 5.2 Telemetry 生命周期

- projector 经 hooks 链接入每个 Run（与 cognition hooks 并列，Semigroup
  组合）；纯消费事件，永不阻断 run。
- LiveStatus 更新即向 ActivityHub 发布；hub 无订阅者时丢弃。
- 终局钩子顺序：交付记录（Answer）→ git 增强（FsChanges）→ 完成表
  **[P2]** → 广播 `run.end` → 注销。
- 所有遥测写入 fail-open：异常只记 stderr，不影响 run 结局。

### 5.3 推送节流

- 同一 runId 的 `status` 帧 200ms 合并（保留最新）；`delivery` /
  `fschange` / `draft` 帧不节流（追加语义，不可丢）。
- `run.end` 必须最后发送且不可被合并掉。

### 5.4 SSE 写入所有权

- `POST /agent` 连接只有一个写者：该 Run 的 emit 闭包。异步 Worker
  **禁止**持有父 emit。
- `/activity/stream` 连接只有 hub 消费者一个写者。
- `worker.notice` / `dispatch.draft` 等流内事件由父 Run 自身在轮次边界
  发出。

### 5.5 重启语义

- RunRegistry / LiveStatus / ActivityHub 易失：重启后活跃为空。
- DispatchDraft、deliveries.jsonl、fs-changes.jsonl 持久：重启后可查。
- `source=agent` 的滞留 draft 由用户手动裁决。

## 六、前端规格（协议层）

信息架构、视图与组件规格见 [`04-前端架构.md`](04-前端架构.md)。本节只
固定协议层：

- **端口**：新增 `activityStream` 端口（EventSource 连 `/activity/stream`，
  自动重连）；`POST /agent` 维持 fetch SSE 手工解析。所有非 SSE 调用维持
  既有 `inspect` 通道。
- **解码**：SessionMeta.kind、DispatchDraft、LiveStatus、DeliveryRecord、
  FsChangeRecord、ActivitySnapshot、FleetSnapshot、监控流六种帧、`agent.sub`
  扩展字段。未知 CUSTOM 事件与未知监控帧**必须降级为忽略**，不得破坏
  整体流。
- **时钟**：监控流驱动「已耗时」等秒级显示，前端本地插值，不要求后端
  高频推送。
- **降级**：监控流连接失败 → 回退 3s 轮询 `GET /fleet` +
  `GET /incarnations/:id/activity`，并在界面标记「实时连接已降级」。

## 七、配置项

| 环境变量 | 默认 | 语义 |
| --- | --- | --- |
| `YUKI_SUBAGENT_DEPTH` | 1 | 现状：委派深度 |
| `YUKI_SUBAGENT_MAX_PARALLEL` **[P2]** | 4 | 单 Run 活跃异步 Worker 上限 |
| `YUKI_DISPATCH_CONFIRM_TIMEOUT` **[P2]** | 600（秒） | `propose_dispatch` 等待裁决超时 |
| `YUKI_DISPATCH_GENERATE_TIMEOUT` | 20（秒） | 草案模型起草超时，超时回退 |
| `YUKI_TELEMETRY_GIT` | 1（开） | git 增强开关；0 关闭 |
| `YUKI_TELEMETRY_GIT_TIMEOUT` | 3（秒） | git status/diff 超时 |
| `YUKI_TELEMETRY_DIFF_BYTES` | 8192 | FS 变更 diff 截断上限 |

## 八、兼容与迁移

- `sessions/index.json`：无 `kind` 字段 → 全部视为 `task`；零迁移。
- 新文件（均为追加/新建，不影响存量）：
  `<dataDir>/dispatches.json`、`deliveries.jsonl`、`fs-changes.jsonl`。
- 旧前端：不认识 kind / telemetry / dispatch 端点，行为与现状一致（新
  后端配旧前端时 Home 以普通会话形态出现，可聊天但归档被 400 拒绝；
  接受此降级）。
- Journal：`RunSettings` 快照不变。**[P2]** `Experience` 的 `delegationId`
  开始填充（同步/异步委派均填 spawn 的 callId；无委派仍为 Nothing）。
- Golden 测试：新事件不进入既有 golden 路径；`agent.sub` 新字段为可选，
  若现状为全等比对需为 `agent.sub` 增加字段宽容。
- 遥测台账可整体删除：只损失「交付/变更」历史视图，不影响任何 run 与
  记忆功能。

## 九、明确不规定（留给 P3）

- Delegation Spec 结构化契约（deliveries / acceptance / budget）。
- Work Graph 与调度器；跨 Run 的全局并行治理。
- activity / 遥测的历史维度与重建工具。
- Worker → 新 Yuki 的晋升。
