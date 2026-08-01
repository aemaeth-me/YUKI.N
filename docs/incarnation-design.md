# YUKI.N 分身、记忆与 Prompt 治理

> 状态：新架构**概念权威基线**（领域蓝图）。本文保持项目层面的概念级构思——
> **记忆只是分身治理的一部分，不代表整个 cognition**；概念不被记忆子系统文档覆盖。
>
> 关系：
> - **实现权威**：认知体系与记忆子系统的当前实现见 [`cognition-design.md`](cognition-design.md)
>   （认知总纲）与 [`memory/`](memory/) 系列；未落地的远期对象不在界面中伪装成可用能力。
> - **记忆子系统机制**：印象、工作记忆（睡眠-清醒）、长期记忆（Task Archive）分别见
>   [`memory/01-印象.md`](memory/01-印象.md)、[`memory/02-工作记忆.md`](memory/02-工作记忆.md)、
>   [`memory/03-长期记忆.md`](memory/03-长期记忆.md)、[`memory/04-生命周期.md`](memory/04-生命周期.md)。
> - 本文中 Memory Record / Space / Mount / Living Model / Playbook / Commitment 属
>   领域蓝图中的**可重建派生索引**形态；当前已实现的派生层（LongTerm 记忆库、印象）见
>   `memory/03` 与 `memory/01`。
>
> 范围：本地单用户工具。记忆作用域只描述多个 Yuki 分身之间的内部边界，不涉及多用户、鉴权或对外扩展。

## 一、最高原则

此前虽已写下「transcript 是渲染，memory 是本体」，实现与产品模型仍把 Thread 当成长寿主体。此处修正：

1. **Memory 是本体。**
2. **Yuki 分身是最高持久主体。**
3. **Thread 只是分身承担的一次任务。**
4. **Run 只是一次执行：可直属分身，也可属于任务。**
5. **Operation 是一次 actor / generator 执行的审计宿主。**
6. **Worker / sub-agent 只是某次 Run 的临时执行者。**
7. **Transcript、Prompt 与 Context 都是投影，不是源对象。**

```text
Yuki 分身
  = 规范自我
  + 经验记忆
  + 现实能力
  + 当前承诺
  + 可追溯的自我演化
```

Prompt 负责把这一状态投影给模型；Transcript 负责把一次经历投影给人。二者均可重建，均不可承担身份本体。

---

## 二、迁移前形态（历史背景）

> 本节描述新领域模型落地**之前**的旧形态，用于理解迁移来源。分身体系（Incarnation、
> Task Archive、印象、睡眠-清醒）**现已实现**，当前实现以 `cognition-design.md` 与
> `memory/` 系列为准；以下遗留问题正是新模型逐一解决的问题。

此前系统不是「有自我的分身」，而是：

```text
Runtime
  → ThreadConfig
    → Run
      → 可选 child Run
```

### 2.1 身份不存在

- 没有 `identityId`、`incarnationId` 或持久 Agent 对象；
- `threadId` 同时承担任务、配置、记忆、工作目录与后台任务边界；
- 所谓 Root 仅是 `parentRunId = Nothing` 的 Run；
- child 只是复用同一 Runtime 的另一个 Run。

### 2.2 Prompt 是字符串拼接

现有构造链：

1. `YUKI_SYSTEM_PROMPT` 提供全局字符串，默认空；
2. `ThreadConfig.systemPrompt` 对其整段替换；
3. cwd 上的 `AGENTS.md` 追加到尾部；
4. client system / developer / context 继续转成等权 system message；
5. memory brief 与 candidates 再由 hook 插入。

后果：

- Thread 可以抹掉未来的 Root constitution；
- 无明确层级、版本、来源与冲突规则；
- memory 注入甚至可能排在 Root prompt 之前；
- watcher、compactor 等内部 prompt 仍是源码常量；
- Journal 能看到最终文本，却不能解释每段从何而来。

### 2.3 Memory 过窄又过宽

- `ThreadBrief` 以 Thread 为键：分身无法跨任务形成连续自我；
- `FactStore` 为进程级单一 `facts.jsonl`：所有 Thread 无条件共享；
- Fact 无分身、任务或证据作用域；
- 记忆类型仅有 user / project / preference / decision；
- rolling summary、64 个 flat episodes 与简单关键词检索不足以承载人格与经验。

更严重的是：

- watcher 在模型调用前运行，最终回答常未进入当轮记忆；
- watcher cursor 是消息数量，compaction、fork、child 与并行会破坏它；
- Root 与 child 共用同一 threadId、MemoryState 与 hooks；
- child 的 episode 会写入父 Thread；
- 重启后的 watcher 不从持久 brief 恢复自身状态；
- Transcript 仍是最完整的连续性来源。

### 2.4 Sub-agent 尚非 orchestration

现有 `sub_agent` 只有：

```json
{"prompt": "自由文本"}
```

child：

- 继承父 system prompt；
- 继承父工具闭包与 memory hooks；
- 沿用父 threadId；
- 只有新 runId；
- 没有角色、上下文租约、预算、验收或写回边界；
- 同步阻塞父级直至返回最终文本。

`runtimeDepth > 1` 也不能真正递归委派：child 删除 `sub_agent` 后没有重新注册。

### 2.5 工具使用无行为协议

模型能看到 ToolSpec 的名称、描述与 schema，却不知道：

- 自己是谁、是 Root 还是 child；
- 当前 cwd、剩余预算与委派深度；
- memory 的读写边界；
- 哪些工具已被裁掉及原因；
- 何时应检索、规划、调用工具、委派、复核或停止；
- 同轮调用会串行还是并行。

当前是「看见工具菜单后自由选择」，不是「知道自身能力并管理其使用」。

---

## 三、新领域模型

```text
Root Kernel｜系统平面
├── Root Constitution
├── Prompt Compiler
├── Memory Governance
├── Capability Registry
├── Orchestration Runtime
├── Shared Derived Index
├── Kernel Operations
│   └── Generator Operations｜router / bootstrap / curator / judge
└── Incarnation Registry
    └── Incarnation｜Yuki 分身
        ├── Charter｜规范自我
        ├── Self Model｜经验自我
        ├── Capability Profile｜现实自我
        ├── Task Archive｜全部 Task 的原始长期记忆
        ├── Private Derived Index
        ├── Mounted Derived Packs
        ├── Playbooks
        ├── Commitments / Open Loops
        ├── Prompt Program
        ├── Evaluation Suite
        └── Intents｜进入分身的意图
            ├── Direct Run｜一次询问或即时处理
            ├── Memory Mutation｜记忆纠正
            ├── Evolution Proposal｜自我修改
            └── Task / Thread｜一项工作
                └── Runs｜执行尝试
                    └── Delegations｜临时 Worker 树
```

Root Kernel 位于分身之上，但只是共同根律与控制面，不是日常工作的产品对象。

### 3.1 名称边界

为避免把系统平面、持久身份与一次执行混为一谈：

- **Root Kernel / System Plane**：共同根律、compiler、registry 与治理控制面；不作为 Agent 接任务；
- **Incarnation**：持续存在的分身，是产品主体；
- **Incarnation Coordinator**：某次 Run 中代表该分身工作的根 actor；负责工具、编排、整合与验收；
- **Worker**：Coordinator 临时委派的 actor。

用户所说的「Root 层级 system prompt」落实为 `Root Constitution`。它是每个 Coordinator 与 Worker 的首层公共协议；分身差异由其后的 Charter、Self、Memory 与 Policy 构成。

`incarnationId` 只标识持久分身；Coordinator 与 Worker 使用独立 `actorId`。不得用某次执行者 ID 冒充分身身份。

### 3.2 三种自我

**规范自我**

描述「我应当是谁」：

- 使命与方向；
- 原则与边界；
- 风格与表达；
- 方法倾向；
- 对质量的定义。

存于 versioned Charter。

**经验自我**

描述「我因经历而成为谁」：

- 已知事实；
- 判断与偏好；
- 成功、失败与修正；
- 稳定工作方法；
- 与用户形成的默契；
- 尚未完成的承诺。

存于 Memory。

**现实自我**

描述「我此刻真正能做什么」：

- 当前模型；
- 实际可用工具；
- workspace；
- 预算与限制；
- 活跃任务与 Worker；
- 当前 prompt、memory 与 capability revision。

由 runtime 确定性生成 Self Snapshot。

因此：

- 「我应当怎样做」来自 Charter；
- 「我知道什么」来自带来源的 Memory；
- 「我能做什么」来自实时 Capability Registry；
- 「我正在做什么」来自 Commitments、Thread 与 Run。

这才是可验证的自知。

### 3.3 Intent 不等于 Task

分身首先接收一个 `IntentEnvelope`，而非无条件创建 Thread：

```text
IntentEnvelope
├── id / incarnationId / parentIntentId? / input
├── contextRefs / previousOutcomeRef?
├── receivedAt
└── source

RouteDecision
├── id / intentId
├── route = direct | memory | self | work | system
├── routeReason / confidence
└── targetRef?

IntentTransaction
├── id / incarnationId / intentId / routeDecisionId?
├── status = routing | executing | awaiting_review | committed | failed | cancelled
├── targetRef? / taskId? / runIds
├── memoryReadReceiptId? / contextBuildRefs
├── executionRef = directRun | memoryMutation | evolutionProposal | task | kernelOperation
├── outcomeRef?
├── intentChangeSetId?
├── memoryChangeReceiptId?
├── selfProposalRefs
└── openedAt / closedAt?

IntentChangeSet
├── id / intentTransactionId
├── memoryMutationIds
├── commitmentChangeIds
├── selfProposalIds
└── status
```

路由语义：

| Route | 结果 | 是否创建 Thread |
| --- | --- | --- |
| direct | 无 Task 的 Direct Run；产出一次 answer / inspection / action | 否 |
| memory | Memory Mutation 或纠错提案 | 否 |
| self | Evolution Proposal、Charter 或 Policy patch | 否 |
| work | 新建 Task，或进入已有 Task | 是 |
| system | 进入 Root Kernel 控制面的明确操作 | 否 |

只有满足至少一项时才进入 work：

- 用户明确要求建立或继续一项任务；
- 形成跨当前响应仍有效的目标或承诺；
- 需要可暂停、恢复或后台持续的执行；
- 需要 Work Graph、多个 Worker 或持续维护的工件状态；
- 结果必须经过多轮验收后才闭合。

简单询问、查看状态、纠正记忆、修改倾向、解释 Prompt 与一次性工具动作默认不创建 Task。Direct Run 若在执行中显著扩张，Coordinator 先提出「晋升为 Task」，不静默迁移。

所有五条 route 都由 Intent Transaction 统一收束：

```text
Memory Read Receipt｜本次读取了什么
→ Outcome｜本次得到什么
→ Memory Change Receipt｜Memory、Commitment 与 Self 留下什么
→ close state
```

Direct Run 仍固定 Prompt、Memory、Capability 与 Model snapshot，也写 Experience Event；但其结果只是分身的一次即时输出，不被包装成长期聊天。Intent Transaction 是持久恢复单元，页面状态不得代替它。

`DirectOutcome` 是持久、可检索、可重开的对象，但不形成聊天列表。Intent Transaction 不要求数据库单事务；它必须可由 Experience Events 稳定投影，并在 SSE 断开或进程重启后恢复。

后续追问是新的 Intent，可引用前一 Outcome。连续性仍由 Memory、Commitment 与显式引用承担，而非暗中生长出另一个 Session。

### 3.4 Kernel Operation 不是隐藏 Root Agent

Root Kernel 本身不调用模型。任何需要模型的系统工作都建立显式 Kernel Operation：

```text
Operation
├── operationId
├── ownerKind = coordinator | worker | kernel-generator | curator | evaluator
├── actorId
├── subjectRef = incarnationId | kernelOperationId
├── intentId? / taskId? / runId?
├── parentOperationId?
└── status

KernelOperation
├── id / kind = route | bootstrap | compile-assist | curate | evaluate
├── triggeredByIntentId? / targetIncarnationId?
├── generatorRevisionId
├── inputSnapshotRefs
├── status / resultRef
└── generatorInvocationIds
```

Kernel actor：

- 无持久人格与私有 Memory；
- 不冒充 Incarnation；
- 只读取 Operation 显式输入；
- 使用已登记 generator template；
- 与 Coordinator / Worker 一样完整记录 Prompt、Context、Capability 与 Model snapshot。

Intent Router 是 `route` Operation；创建新分身是 `bootstrap` Operation；Evaluation Judge 是 `evaluate` Operation。`system` route 只能触发具名 Kernel Operation 或确定性控制动作，不能进入一个全局聊天 Agent。

Coordinator、Worker 与所有内部 generator 共用同一条：

```text
Operation → PromptBuild → ContextBuild → ModelInvocationSnapshot
```

用户 Run 是相关 Operations 的执行分组，不是模型调用的唯一宿主。Router、Bootstrap、Curator 与 Judge 可以没有 `runId`，但绝不能没有 `operationId`。

---

## 四、Memory 拓扑（蓝图 vs 已实现）

> 记忆子系统是分身治理的一部分，不是认知的全部（见 `cognition-design.md` §一）。
> 本节区分两层：**canonical memory（已实现）** 与 **derived memory（部分实现，
> 其余为蓝图）**。canonical 机制细节见 `memory/03-长期记忆.md`；已实现的派生层
> （LongTerm 记忆库、印象）见 `memory/03` 与 `memory/01`。Space / Mount / Living
> Model / Playbook / Commitment 属蓝图对象，当前不在界面中伪装为可用能力。

```text
canonical memory = same-incarnation Task Archive
derived memory   = Memory Space / Record / Rollup / Living Model
```

Task Archive 只追加，默认覆盖同一分身全部 Task，包括已归档 Task；原件不 mount、不跨
分身共享。只有已接受的 user、已提交的 assistant、已提交的 tool result 可成为长期
证据。未完成流只留 Journal。以下 Space、Mount、Record 与 Mutation 全部属于派生层，
可删除后由 Archive 重建。

### 4.1 作用域

| Derived space kind | 内容 | 默认行为 |
| --- | --- | --- |
| Root Shared | 用户跨方向稳定偏好、通用环境、明确共享原则 | 共享库本身不广播；须显式 mount，或由用户标为 universal pinned |
| Incarnation Private | 本方向知识、判断、经验、关系与工作方法 | 当前分身默认读写 |
| Pack Space | 项目或主题记忆包 | 经 Mount 引用，不复制进私有库 |
| Thread Local | 当前任务目标、决定、约束与未决问题 | 任务结束后选择性归纳 |
| Run Scratch | 本次执行的临时状态 | Run 后销毁或归纳 |
| Worker Scratch | 临时 Worker 的工作记忆 | 只提交成果与记忆候选 |

Mounted 不是 Memory Record 的 scope，而是 Space 与 consumer 之间的关系：

```text
MemorySpace
├── spaceId / kind / ownerRef
├── revision / status
├── defaultWritePolicy
└── provenance

MemoryMount
├── mountId / revision
├── consumerRef = incarnationId | taskId | intentTransactionId
├── sourceSpaceId
├── sourceRevisionMode = pinned(revision) | track-active
├── selectionPolicyRef / priority / budget
├── accessMode = read-only | read-write
├── writeDisposition = source | private-overlay | task-overlay | reject
├── overlaySpaceId?
├── effectiveFrom / effectiveTo?
└── status
```

Pack 默认 read-only，新增认识写入分身 private overlay；不得因「使用了某个 Pack」而反向污染 Pack。universal pinned 也由 Kernel 为每个分身物化为可见的 Mount revision，不走隐式全局检索。

Mount 可在分身级长期存在，也可只为某个 Task 或 Intent Transaction 临时建立；创建分身时选择 Pack 不是唯一挂载时机。

一次 Coordinator Run 看到的不是 Archive 正文，而是一个有凭据的派生索引视图：

```text
Memory View
  = Shared Pinned
  + Incarnation Core Pinned
  + Selected Private Records
  + Selected Records from Explicit Mounts
  + Selected Thread Local（仅 work route）
  + Run Scratch
```

Memory View 只可提供 topic、来源锚点与检索 cue；原始事实必须由固定字符串
`memory_grep` 定位，再由有界 `memory_read` 取得。它不得把 Task Archive 正文预载到
开场 context。

```text
MemoryView
├── viewId / incarnationId / intentTransactionId / runId? / asOf
├── topologyRevision / policyRevision / generatorRevision
├── mountSnapshots [mountId / mountRevision / spaceRevision]
├── recordRefs [memoryId / revision / reason / score / tokens]
├── excludedRefs / reasons / excludedSummary
├── query / tokenBudget
├── defaultWriteTarget
└── effectiveHash

MemoryReadReceipt
├── memoryViewId
├── usedRecordRefs / reasons
├── omittedRecordRefs / reasons
└── mountedSpaceSnapshots

MemoryChangeReceipt
├── intentTransactionId
├── proposedMutationIds
├── autoCommittedMutationIds
├── pendingReviewMutationIds
├── rejectedMutationIds
└── supersededMemoryRefs
```

一次调用固定 exact mount、space 与 record revisions。之后 Pack 或 Shared Space 更新，不改变历史 Memory View。

若 `pendingReviewMutationIds` 非空，Intent Transaction 状态为 `awaiting_review`；「已执行完」不等于「所有自我变化已提交」。

### 4.2 记忆类型

- `identity`：稳定自我认识；
- `semantic`：事实、概念、决定与偏好；
- `procedural`：工作方法的证据与候选；
- `relational`：此分身与用户形成的默契；
- `commitment-evidence`：承诺、开放问题与未来动作的形成证据；
- `episode`：一次任务经历的归纳；
- `observation`：尚未晋升为事实的观察；
- `tool-heuristic`：工具有效性、前置条件与失败模式。

普通 Memory 是证据，不是指令。程序性证据只有晋升为 active `PlaybookRevision`，才能稳定改变行为。

两个对象另有独立权威：

```text
Commitment
├── id / incarnationId / objective
├── status = proposed | active | blocked | completed | cancelled
├── sourceEvidenceRefs / taskRefs
├── due? / blockedBy?
└── revision

PlaybookRevision
├── playbookId / revision / name
├── procedure / applicability / stopConditions
├── sourceMemoryRefs / evaluationRefs
└── status = draft | active | retired
```

Memory 保存它们的形成证据与历史归纳；`Commitment` 状态机与 active `PlaybookRevision` 才是权威。Memory Mutation 不得直接冒充承诺完成或行为规则激活。

### 4.3 Distilled Memory Record

```text
MemoryRecord
├── id / spaceId / kind / content
├── sourceArchiveEntryIds
├── createdBy / derivedByRunId / derivedByPromptRevision
├── confidence / salience
├── observedAt / validFrom / validTo
├── supersedes
├── status = candidate | active | disputed | archived | void
├── lastUsedAt / useCount
└── locked
```

纠错写入 `supersedes`，不静默覆盖。它只改变派生索引；Task Archive 原始证据不删，
整组 Memory Record 可重算。

### 4.4 Derived Index Mutation

任何自我管理行为均落为：

```text
MemoryMutation
├── action = propose | add | revise | supersede | archive | promote | move
├── targetMemoryId?
├── targetSpaceId
├── evidenceArchiveEntryIds
├── reason
├── proposerIncarnationId / actorId / runId
├── policyDecision
└── committedAt
```

分身可以自己整理派生索引，但不能无痕改写自己，也不能通过 Mutation 改写 Task
Archive。

### 4.5 Experience Event

长期记忆的 append-only 原件是 Task Archive。ExperienceEvent 是生命周期、operation
与 projection 的审计时间线，不与 Archive 争夺事实本体：

```text
ExperienceEvent
├── eventId / incarnationId
├── taskId? / runId? / delegationId?
├── actorId / actorKind = coordinator | worker | tool | user | curator
├── kind / occurredAt
├── payloadRef
├── causedByEventId?
├── operationId? / modelInvocationId?
└── journalSeq?
```

Transcript、Episode、Rollup、Task Summary 与 derived index 可由 Task Archive、
ExperienceEvent 及 Blob 投影；任何派生物都不得替代 Archive 原件。

### 4.6 归纳循环

```text
accepted / committed Task Archive closure
→ Episode（目标、过程、结果、未决项）
→ Distilled Memory Candidates
→ 去重、冲突与作用域判定
→ 自动提交低风险派生态 / 进入审阅箱
→ Rollup 与 Self Model 更新
```

最终回答必须在 Run close 时先成为 committed assistant archive entry 与
ExperienceEvent，再触发归纳；不能等待下一轮 watcher 才看见。Impression consolidation
只更新 ImpressionState，不生成 Memory / void proposals。

### 4.7 Incarnation Living Model 与 Context Synthesis

原子记录不是分身面向自己的主要读形。系统从 active、disputed 与 open Memory 投影一份当前综合：

```text
IncarnationLivingModel
├── id / incarnationId / revision / asOf
├── status = fresh | stale | rebuilding | failed
├── durableTopologyRevision
├── privateSpaceRevision / durableMountSnapshots
├── playbookRevisionSet / commitmentRevisionSet
├── sourceClosureHash
├── topics
├── claims [content / sourceArchiveEntryIds / confidence]
├── relations [from / relation / to / sourceArchiveEntryIds]
├── disputes [positions / evidence / status]
├── unknowns [question / whyOpen]
├── methods [playbookRef / evidence]
├── commitments [commitmentRef / state]
└── generatorRevisionId / effectiveHash

ContextSynthesis
├── id / intentTransactionId / memoryViewId
├── topic / claims / disputes / unknowns
├── sourceRecordRefs
├── status / generatorRevisionId
└── effectiveHash
```

Incarnation Living Model：

- 是可重建投影，不是新的无来源事实库；
- 每一主张必须引用 Task Archive entry，或引用能继续回溯至 entry 的 Memory Record；
- 明确区分事实、推断、争议与未知；
- 修正落回 Memory Mutation，不直接改写综合文本；
- 只读取 durable private、durable mount、Playbook 与 Commitment revisions；
- 任一输入 revision 变化即置为 `stale`，后台重建成功后才切换 active revision；
- 是 Self Model、首页「当前理解」与 Memory Workspace 的共同来源。

Context Synthesis 则只服务某个 Intent / Task，可包含临时 Mount、Task Local 与 Run evidence。二者共用 Record 与 provenance 体系，但不得声称使用完全相同的 record set。

---

## 五、Prompt 是可编译程序

最终 system prompt 不是 source of truth，而是 immutable Prompt Build。一次真实模型调用还必须拥有完整的 Context Build 与 Model Invocation Snapshot。

### 5.1 源对象

```text
RootConstitution
IncarnationCharter
IncarnationPolicyBundle
SelectedPlaybooks
SelfSnapshot
EnvironmentContract
IntentEnvelope
TaskContract?
RunDirective
CapabilitySnapshot
MemoryView
DelegationSpec?
```

`IncarnationPolicyBundle` 显式包含：

- Memory Policy；
- Capability / Tool Policy；
- Orchestration Policy；
- Self-management Policy；
- Evaluation / Activation Policy。

LLM 可生成结构化 source；确定性 compiler 负责：

- 层级与优先级；
- 冲突检查；
- token 预算；
- 稳定 prefix；
- 来源标记；
- hash 与 snapshot；
- 最终渲染。

模型不能自由发明新的覆盖层。

### 5.2 编译顺序

```text
Prompt Build｜指令程序
  Kernel Invariants
  → Root Constitution @ revision
  → Incarnation Charter @ revision
  → Incarnation Policy Bundle @ revisions
  → Selected Playbooks @ revisions
  → Workspace Instruction Contract @ sources
  → Task Contract @ revision（仅 work route）
  → Run Directive
  → Delegation Spec（仅 Worker）

Context Build｜一次调用的完整有序上下文
  Prompt Build
  → Self Snapshot（Incarnation Manifest + Actor Manifest）
  → Capability Snapshot + Tool Manifest
  → Workspace observations / client context
  → Scoped Memory View @ receipt
  → Route-specific state / compacted evidence
  → Current Input
```

上图的 Prompt Build 适用于 Coordinator / Worker。Kernel Operation 使用更窄的链：

```text
Kernel Invariants
→ Root Constitution @ revision
→ Registered Internal Role Template @ revision
→ Kernel Operation Contract
```

它不隐式读取任何 Incarnation Charter、Private Memory、Commitment 或 Playbook；目标分身数据只能作为 Operation 的 explicit immutable input。

Root Constitution、Charter 与稳定 Policy 组成稳定 prefix；Self、Capability、Memory 与任务状态按 epoch 更新。

Memory 以标明来源的 evidence segment 注入，不与 constitution 混成等权指令。Tool schema、当前消息与 provider role conversion 也属于 Context Build，不得藏在 Prompt Build 之外而不入账。

Route-specific state 必须显式：

```text
direct
  IntentEnvelope
  + explicit contextRefs
  + explicit previousOutcome closure
  + current input

work
  Task Contract
  + task event cursor
  + task-local state
  + current input

kernel operation
  frozen inputSnapshotRefs
```

Direct 不得读取「此分身最近消息」或任何 ambient session cursor。连续追问通过 `parentIntentId / previousOutcomeRef / contextClosureHash` 闭合。

源对象的落位规则：

- `AGENTS.md` 等规范性 workspace 指令进入 Prompt Build；
- 文件状态、目录内容与 client context 等观察性数据进入 Context Build；
- Intent 的规范化目标进入 Run Directive；用户原始输入只作为 Current Input snapshot；
- Incarnation Manifest 是持久投影，Actor Manifest 是当前 Operation 的动态快照；
- Self Snapshot 只引用二者，不包含正在构造的 `contextBuildId`，避免自引用 hash。
- Kernel Operation 不读取 Incarnation Manifest；其 Self Snapshot 只有 KernelActorManifest。

### 5.3 各层生成方式

| 层 | 生成方式 | 修改方式 |
| --- | --- | --- |
| Root Constitution | 极小、人工掌握的根律 | 用户提交；分身只能提案 |
| Capability Contract | 从真实工具 schema、健康状态、workspace 与副作用类型机械生成 | 修改能力源或策略 |
| Incarnation Charter | 根据方向、正反例、约束与初始记忆生成结构化草案 | 用户编辑、锁定；分身提交 patch |
| Policy Bundle | Root Kernel 默认策略与分身方向生成 Memory、Capability、Orchestration、Self-management、Evaluation policy 草案 | 用户编辑、锁定；分身提交 patch |
| Selected Playbooks | 从任务类型、证据与稳定 procedural memory 选择 | 编辑或晋升原 Playbook |
| Self Snapshot | 从 Incarnation、Actor、Memory、Capabilities、Commitments 确定性投影 | 修改源对象 |
| Environment Contract | 从 workspace、AGENTS.md 与挂载生成 | 修改源文件或挂载 |
| Memory View | 派生索引选择 archive anchors，renderer 保留来源与 scope | 编辑派生索引或 Memory Policy |
| Task Contract | 仅从 work route 生成目标、完成条件、约束与开放问题 | 自动版本化；用户可修订 |
| Run Directive | 从 Intent Transaction 与 route-specific state 生成；work 才读取 Task 未完成状态 | 临时、完整记录 |
| Delegation Spec | Coordinator 按固定 schema 生成，runtime 校验 | 临时、完整记录 |
| Internal Prompts | router、compactor、reflection、evaluation 等具名模板 | Root Kernel 工作台修改与测试 |

用户只需定义方向、修订生成结果；不必手写每层 prompt。

### 5.4 Prompt Generator Registry

「生成 prompt」本身也必须是可治理对象，不能退化为散落在源码中的隐藏字符串。

```text
PromptGenerator
├── id / outputKind / version
├── engine = deterministic | model-assisted
├── inputSchema / outputSchema
├── templateRevisionId
├── invariants / validators
├── evaluationSuiteId
├── owner = kernel | incarnation
└── status = draft | active | retired
```

`templateRevisionId` 对 model-assisted generator 必填；deterministic generator 明确记为 `none`，并记录代码 revision。

Root Kernel 的 Generator Registry 至少包含：

| Generator | 输入 | 输出 | 方式 |
| --- | --- | --- | --- |
| Intent Router | 当前输入、显式目标、active commitments | direct / memory / self / work / system + 理由 | model-assisted + route validation |
| Change Scope Classifier | 用户纠正、当前 source graph | 最低充分修改层级 | model-assisted + authority validation |
| Incarnation Bootstrap | 方向、正反例、mounts | Charter、Policy、Playbook、Evaluation proposals | model-assisted + schema validation |
| Charter Draft | 方向、正反例、边界、memory seeds | 结构化 Charter proposal | model-assisted + schema validation |
| Policy Draft | Kernel defaults、方向、能力与风险 | versioned Policy Bundle proposal | model-assisted + schema validation |
| Self Snapshot | Charter、Memory、Capabilities、Commitments | 有来源的 Self Manifest | deterministic |
| Incarnation Living Model | durable Memory topology、争议、Playbooks、Commitments | 有来源的持久 Current Synthesis | model-assisted + citation validation |
| Context Synthesis | 某次 Memory View、临时 state | Intent / Task 局部综合 | model-assisted + citation validation |
| Capability Contract | ToolSpec、health、workspace、policy | 实际能力契约 | deterministic |
| Archive Query | 当前意图显式给出的 literal query、scope、预算 | 精确 Task / Run / Entry anchors | deterministic fixed-string grep |
| Archive Renderer | 精确 archive entry、offset / chars / neighbors | 有界 evidence window | deterministic |
| Derived Curator | Archive Evidence、旧索引、policy | add / supersede / stale / conflict index proposals | model-assisted + archive citation validation |
| Task Contract | 当前意图、相关承诺、Memory View | 目标、完成条件、约束、开放问题 | model-assisted + schema validation |
| Work Graph | Task Contract、Capability、Policy | 可验证的执行图 | model-assisted + graph validation |
| Delegation Spec | Work node、lease、budget、policy | Worker 契约 | deterministic skeleton + model-assisted content |
| Context Compactor | Experience slice、artifact refs、budget | 有来源的 evidence projection | model-assisted + loss checks |
| Reflection | Archive / Experience closure、旧 Self | Derived-index / Evolution proposals | model-assisted + evidence validation |
| Evaluation Scenario | Charter / Policy change、历史失败 | versioned regression cases | model-assisted + deduplication |
| Evaluation Judge | frozen case、candidate output、rubric | evidence-bearing verdict | model-assisted + deterministic checks |
| Prompt Renderer | 所有已解析 source block | Effective Prompt Build | deterministic |
| Provider Renderer | Context Build、provider contract | wire request | deterministic |

任何 model-assisted generator 使用的 system prompt 都是 `PromptTemplate @ revision`：

- 在 Root Kernel Prompt Studio 可见；
- 与普通 Prompt Build 一样保留输入 snapshot、输出、hash 与测试；
- 不允许成为未登记的源码常量；
- 分身可提出修改，但不能静默替换 active revision。

硬不变量：**任何模型调用都必须引用一个已登记且不可空的 PromptTemplate revision。** watcher、compactor、router、curator、judge 与 Coordinator / Worker 无例外。

因此能继续追问：

```text
这段 prompt 为何存在？
→ 来自哪个 source block？
→ source block 由哪个 generator 产生？
→ generator 当时使用哪个 template revision 与输入？
→ 它通过了哪些验证后被激活？
```

### 5.5 Bootstrap 边界

Prompt 治理必须在有限处停止递归，并禁止自我验收：

1. **Kernel Invariants** 由 runtime 代码保证，例如作用域、不可变 Build、工具授权与写回边界；
2. **Root Constitution 初版** 与 **Generator Template 初版** 随系统提供，短小、版本化、用户可审计；
3. generator、validator、evaluation suite、judge 与 activation policy 形成一张有向无环依赖图；
4. 一个 Change Set 不得同时修改候选及用于批准该候选的 validator、suite、judge 或 activation policy；
5. 候选只能由变更前已 active 的依赖版本验证；新评估器最早在下一 Change Set 中评估别的候选；
6. generator 不得在同一次 Run 中修改自身 active revision 后立即使用；
7. activation 分为 stage → evaluate → activate；任一步均可中止或回滚；
8. 历史 revision 永不因新版本而重写；
9. Bootstrap 候选只由预先 active 的 onboarding suite 与用户原始正反例验收；Bootstrap 自己生成的 Evaluation proposal 先进入 staged，最早用于下一 Change Set；
10. Change Set 冻结完整传递依赖闭包；activate 以 `expectedActiveRevisionSet` 做 compare-and-swap，过期评估不得覆盖新 active revision；
11. Evaluation 在 frozen fixture、禁止长期 Memory 写入且禁止外部副作用的 sandbox 中运行；副作用 receipt 必须为空。

用户无需从空白手写根 prompt；系统也不能声称自己从无来源地「自动长出」根律。

### 5.6 Prompt 对象

```text
PromptTemplate
  id / layerKind / schema / generatorVersion

PromptRevision
  promptId / version / structuredSource
  generatedBy / parentVersions
  manualPatch / lockedFields
  rationale / hash / status

GeneratorRevision
  generatorId / version / dependencies
  engine / implementationRef = templateRevisionId | codeRevision
  inputSchema / outputSchema / hash / status

ValidatorRevision / EvaluationSuiteRevision / ActivationPolicyRevision
  id / version / dependencies / source / hash / status

ChangeSet
  candidateRevisionIds
  frozenDependencyClosure
  frozenValidatorIds / evaluationSuiteIds / judgeRevisionId
  activationPolicyRevisionId
  expectedActiveRevisionSet
  results / status

GeneratorInvocation
  id / operationId / generatorRevisionId / implementationRef
  immutableInputRefs / modelInvocationId?
  immutableOutputRef / validationRunIds

ValidationRun
  id / candidateRef / validatorRevisionId
  immutableInputRefs / result / evidenceRefs

EvaluationRun
  id / changeSetId / suiteRevisionId / judgeRevisionId
  frozenFixtureRefs / sandboxPolicyRevision
  modelInvocationIds / result / sideEffectReceipt

PromptBuild
  buildId / subjectRef = incarnationId | kernelOperationId
  operationId / actorId / taskId? / runId?
  orderedRevisionIds / compilerRevision
  effectiveText / effectiveHash

ContextBuild
  contextBuildId / promptBuildId / operationId / runId? / invocationSeq
  orderedSegments [
    order / authority / providerRole / kind
    sourceRef / revision / contentRef / hash / tokenCount
  ]
  memoryViewId / capabilitySnapshotId / toolManifestSnapshotRef
  explicitContextRefs / previousOutcomeClosureRef? / contextClosureHash
  taskEventCursor? / compactionBuildId?
  workspaceSnapshotRefs / clientContextSnapshotRefs
  currentInputSnapshotRef
  contextCompilerRevision / effectiveContentRef / effectiveHash

ModelInvocationSnapshot
  invocationId / contextBuildId
  modelSnapshot / parameters
  providerAdapterRevision
  renderedRequestRef / renderedRequestHash
  responseRef
```

每次 Run 固定其 Prompt Build；每次模型调用另建 Context Build 与 Model Invocation Snapshot。后续修改不改变历史，任一 wire request 均可由 snapshot 解释并在允许时重放。

`hash` 只校验内容，不保存内容。所有易变输入——workspace 文件、client context、current input、tool schema、compaction 结果与最终 request——必须在调用前落为 content-addressed immutable snapshot；只有 hash 而无可解引用 `contentRef` 不满足重放。

### 5.7 编辑语义

- Effective Prompt 只读；
- 点击某段进入其 source block；
- 编辑自动生成块会产生用户 override；
- 可只重生成一个块；
- 可锁定字段或整块；
- 显示 source / effective / diff / history / tests；
- 任意一句均能回答「为何在这里」；
- 支持 activate、rollback 与影响范围预览。

### 5.8 优先级

1. Kernel invariants；
2. 当前用户明确要求；
3. 用户锁定的分身规则；
4. 当前有效 Charter、Policy 与 Task Contract；
5. Procedural Memory；
6. 普通 Memory 与推断。

---

## 六、Root Constitution

Root Constitution 不应无限膨胀，只规定跨分身不变的行为协议。

至少包括：

1. 启动时读取 Self Snapshot，不从 Transcript 猜身份；
2. 只依据 Capability Registry 声称能力；
3. 按作用域检索、写入与提升 Memory；
4. 判断直接执行、使用工具或委派 Worker；
5. 要求 Coordinator 为 Worker 生成完整 Delegation Spec；
6. Coordinator 对 Worker 结果负有整合与验证责任；
7. 发现重复失败、prompt 漂移或能力缺口时生成 Evolution Proposal；
8. 所有 prompt、memory 与自我修改均保留 provenance；
9. 不静默修改 Root Constitution、Charter、锁定块或跨分身 Memory；
10. 依据 Actor Manifest 区分 Coordinator 与 Worker；Worker 只服从当前 Spec、Lease 与 Grant；
11. 不把 direct / memory / self route 偷换成 Thread；
12. 完成前检查目标、证据、未决项与写回，并产出 Outcome 与 receipts。

Prompt 只能规定「何时、为何」。真实能力必须由 runtime 提供：

```text
self.inspect
intent.inspect / intent.outcome / intent.close
memory.search / memory.explain / memory.propose / memory.correct
capabilities.list / capabilities.health
delegate.spawn / list / send / amend / wait / cancel / collect
delegate.accept / reject / merge
prompt.explain / prompt.propose / prompt.test
evolution.commit / rollback
```

---

## 七、自知

持久分身拥有可审计的 Incarnation Manifest：

```text
IncarnationManifest
├── incarnationId / name / mission
├── charterRevision / selfModelRevision
├── privateMemorySpaceId / mountedSpaceIds
├── policyRevisions / playbookRevisions
├── capabilityProfileRevision
├── commitments
└── currentLivingModelRevision
```

每个 Coordinator 与 Worker 另收到动态 Actor Manifest：

```text
ActorManifest
├── actorId / incarnationId / incarnationName / actorKind
├── parentActorId? / lineage
├── charterRevision / policyRevisions
├── operationId / promptBuildId
├── intentId / taskId? / runId
├── memory read scopes / write target
├── actual capabilities / unavailable reasons
├── orchestration limits / execution policy
├── current commitments
└── self-management mode
```

本次 Self Snapshot 由两者合成。Actor 不能用临时状态改写 Incarnation Manifest，也不能把继承到的分身身份误认为自己的持久 actor 身份。

Kernel actor 使用独立 `KernelActorManifest`，只包含 operation、generator、capability grant 与依赖 revision；没有 incarnationId、Charter、私有 Memory 或 Commitments。

分身应能据实回答：

- 我是谁；
- 我为何形成这种做事方式；
- 哪些记忆正在影响我；
- 当前 prompt 如何生成；
- 我真正拥有哪些工具；
- 我正在承担什么；
- 我为何委派或没有委派。

未知必须明确为未知，不以模型自述补空。

---

## 八、自动编排

自动 orchestration 由三层共同决定：

- Root Constitution：通用判断协议；
- Incarnation Policy：此分身的委派与验证倾向；
- Runtime：并发、预算、深度、取消、错误隔离与生命周期。

### 8.1 委派判据

适合委派：

- 可拆为相互独立的子目标；
- 需要不同角色或独立验证；
- 子任务需隔离大量上下文；
- 并行收益显著；
- 有清晰的交付与验收。

不宜委派：

- 工作简单；
- 强顺序依赖；
- 共享可变状态过多；
- 协调成本高于执行成本；
- Coordinator 无法验证结果。

### 8.2 Delegation Spec 与 Invocation

先生成无 Prompt 回指的契约，再由 compiler 生成 Worker Build：

```text
MemoryLease
├── id / memoryViewId / exactRecordRefs
├── mode = read-only | read-and-propose
├── tokenBudget / expiresAt / revokedAt?
└── issuerActorId

ToolGrant
├── id / capabilitySnapshotId
├── exactToolRevisionRefs
├── call / cost / side-effect limits
├── expiresAt / revokedAt?
└── issuerActorId

DelegationSpec
├── id / revision / workGraphId / workGraphRevision / nodeId
├── parentRunId / incarnationId / coordinatorActorId
├── role / objective / whyDelegated
├── inputs / contextRefs
├── memoryLeaseId / toolGrantId
├── deliverables / outputSchema
├── acceptanceChecks
├── dependencies
├── budget / deadline
├── mayDelegate / maxChildDepth
└── stopConditions / escalationPath

DelegationAmendment
├── id / previousSpecRevision / newSpecRevision
├── changedFields / reason / proposerActorId
└── effectiveFromAttempt

DelegationInvocation
├── id / delegationSpecId / workerActorId
├── attempt / retryOf? / resumeFrom?
├── promptBuildId / contextBuildId
├── capabilitySnapshotId / modelSnapshot
├── status = spawned | running | failed | cancelled | expired | submitted
├── cancelReason? / expiredAt?
└── timestamps

WorkerSubmission
├── id / delegationInvocationId / nodeId
├── deliverableRefs / evidenceRefs
├── risks / unresolved
└── memoryCandidates

WorkerExecutionReceipt
├── invocationId
├── actualMemoryReadRefs
├── actualToolInvocationRefs
├── proposedWriteRefs
└── lease / grant violations

AcceptanceAttempt
├── id / submissionId / nodeId
├── frozenAcceptanceChecks
├── evaluatorRevisionRefs
└── validation / evaluation run refs

AcceptanceDecision
├── id / acceptanceAttemptId / submissionId / nodeId
├── evaluatorActorId / checkResults
├── status = accepted | revision_requested | rejected
└── reason / evidenceRefs

MergeDecision
├── id / nodeId / acceptedSubmissionId
├── mergedByActorId / targetRefs
├── conflictResolution
├── status = merged | partially_merged | not_merged
└── committedAt?

WritebackReceipt
├── mergeDecisionId
├── resultRefs / artifactRefs
├── taskEventRefs
└── derivedIndexProposalRefs
```

Worker 默认：

- 继承 Kernel invariants；
- 只取得相关 Charter 片段；
- 获得只读 Memory Lease；
- 工具集合不宽于父级；
- 拥有独立 scratch 与 cursor；
- 不能直接写入 Task Archive 或修改 prompt；
- 返回成果、证据、风险与 Derived Index Proposals；
- 是否可继续委派由 spec 明示。

`delegate.send` 只能追加不改变契约的 steering note。objective、tool grant、memory lease、deliverable 或 acceptance 的任何变化均创建 Delegation Amendment 与新 Spec revision；不得用普通消息暗改。

反复出现且需要独立长期记忆的角色，应被显式提升为新分身，而非伪装成永久 Worker。

### 8.3 Work Graph

Coordinator 先生成结构化 Work Graph：

```text
node / objective / dependencies
mode = coordinator | worker
deliverable / acceptance
status / evidence
```

Scheduler 据图并行；Coordinator 负责整合。不能仅靠同轮多个 tool call 偶然并发。

Worker `submitted` 只表示交付已到达，不等于 node 完成。Work node 只有在 AcceptanceDecision 为 `accepted`、MergeDecision 为 `merged` 且 WritebackReceipt 已提交后才进入 `completed`；失败、拒绝、部分合并与要求修订均保留独立状态。

---

## 九、工具认知

ToolSpec 只说明函数形状；分身需要 Capability：

```text
Capability
├── id / availability / health
├── preconditions
├── sideEffectClass
├── latency / cost
├── verificationMethod
├── preferredFor / avoidFor
└── failureHistory
```

Coordinator 的工具循环：

```text
理解意图
→ 检索相关记忆
→ 判断是否需要直接观察
→ 选择能力
→ 执行
→ 验证结果
→ 记录工具经验
→ 决定继续、委派或收束
```

分身的 `tool-heuristic` Memory 可形成方向性倾向，例如研究分身偏好交叉验证，工程分身偏好先读、后改、再测试。

---

## 十、自我管理

自我管理不是任意改写 prompt，而是：

```text
自检
→ 提案
→ 评估
→ 版本提交
→ 观察效果
→ 可回滚
```

### 10.1 分身可自行维护

- semantic / episodic memory；
- 摘要、索引、标签与检索权重；
- 冲突、陈旧与重复候选；
- open loops 与 commitments；
- 工具经验；
- prompt、Charter 与 orchestration policy 的修改提案；
- 能力缺口与新分身提案。

### 10.2 默认可自动提交

- 可重建的摘要与索引；
- 标签、权重与低风险归档；
- 有直接证据的事实候选；
- Run scratch 的清理；
- 明确完成的 open loop 状态。

### 10.3 默认进入审阅箱

- Root Constitution 变化；
- Charter 变化；
- Procedural Memory 晋升；
- 工具与编排策略变化；
- 跨分身分享或移动；
- 记忆删除与重大纠错；
- 临时 Worker 持久化为新分身。

用户可为某类提案调整自动提交规则，但所有变化仍版本化、可撤回。

### 10.4 Evolution Proposal

```text
EvolutionProposal
├── target
├── before / after diff
├── trigger / evidence
├── expectedBehaviorChange
├── regressionTests
├── evaluationResult
├── proposer
└── status
```

---

## 十一、核心循环

```text
激活分身
→ 读取 Self Snapshot
→ 接收意图
→ 写 IntentEnvelope 并打开 IntentTransaction
→ route Operation 生成可见 RouteDecision
├─ direct → optional literal memory_grep → bounded memory_read → Direct Run → Outcome
├─ memory → 接受纠正 → Archive append → optional Derived Index Mutation → Outcome
├─ self → Evolution Proposal → Outcome
├─ system → 具名 Root Kernel Operation → Outcome
└─ work → 新建 / 继续 Task
           → Task Contract 与 Run Snapshot
           → Work Graph
           → 自行处理 / 工具 / Worker
           → 执行、监控、整合与验收
→ 提交 accepted user / assistant / tool-result Task Archive closure
→ 写入 Experience Events
→ 归纳 Episode 与 Derived Index Proposals
→ 生成 MemoryChangeReceipt 与 Commitment ChangeSet
→ 检查漂移、失败模式与能力缺口
→ 生成并测试 Evolution Proposals
→ 自动提交低风险变化，或以 awaiting_review 保持事务
→ committed / failed / cancelled 后关闭
```

---

## 十二、审计模型

现有 Journal 可保留为执行证据；新增领域事件：

```text
incarnation.activated
prompt.build
context.build / model.invoked
prompt.proposed / activated / rolled_back
archive.committed / grep / read
derived_memory.view
derived_memory.proposed / committed / superseded
capability.snapshot
orchestration.decision
delegation.spawned / updated / completed
self.reflection
evolution.proposed / evaluated / committed
```

每个模型请求必须可追溯至：

```text
Operation
+ PromptBuild
+ ContextBuild
+ ModelInvocationSnapshot
```

每次 archive commit、派生 memory、prompt、Charter 与 policy 变化必须可追溯至
evidence、reason 与 revision。

审计不是原始 JSON 瀑布，而是回答：

- 此次行为由哪些自我规则与记忆影响；
- 当时真正可用的能力是什么；
- 为什么创建这些 Worker；
- 哪些变化由此次经历产生；
- 哪个 revision 改变了后续行为。

---

## 十三、不变式

1. `Incarnation` 是最高持久主体；Thread 必须带 `incarnationId`。
2. Task Archive 跨同一分身全部任务，含已归档 Task；Task 状态不改变长期记忆可见性。
3. 原始 Archive 不跨分身、不 mount；Shared Derived Index 必须显式 mount，禁止无 scope
   全局检索。
4. Prompt 是编译产物；source、generator、validator、evaluation 与 activation policy 全部 versioned。
5. 每次请求固定 Operation、Prompt Build、Context Build 与 Model Invocation Snapshot。
6. 每次自我修改都有 evidence、reason、diff 与 rollback。
7. Change Set 不能修改用于验收自身的 validator、suite、judge 或 activation policy。
8. 任何模型调用都必须拥有 operationId，并引用已登记的 PromptTemplate revision。
9. 最终回答在 Run close 时进入 committed assistant archive entry 与 ExperienceEvent；
   未完成流只留 Journal。
10. Transcript 由事件投影，不再是 fork、export 或续接的权威本体。
11. 有活引用的 Artifact 不得被数量上限物理逐出。
12. Worker 的 cursor、scratch、memory view 与 writeback 独立。
13. Worker 不直接写 Task Archive；只有 accepted / merged writeback 由 Coordinator 提交。
14. Coordinator 对委派结果负有验证与整合责任。
15. 未知能力、未知记忆与未知状态必须明确为未知。
16. 分身能解释自己的有效 Prompt、Context、Memory View、Capabilities 与 Commitments。
17. Direct、Memory、Self 与 System route 不得为适配 Session API 伪造 Thread。
18. 每个 Intent 都有可由事件恢复的 Intent Transaction；页面状态不是权威。
19. memory 事实取回固定为 literal `memory_grep` 后 bounded `memory_read`；派生 Memory
   View 固定 exact Mount、Space 与 Record revisions。
20. Context 中任何易变输入都有 immutable contentRef；hash 不代替内容快照。
21. Commitment 状态机与 active PlaybookRevision 是权威；Task Archive 保存原始证据，
   Memory Record 只是派生索引。
22. Worker submitted / process completed 不等于 Work node completed；必须 accepted、merged 且 writeback 已记录。

---

## 十四、迁移顺序

### M0：Kernel bootstrap 与审计底座

- 建立 Operation、actorId 与 content-addressed immutable payload store；
- 建立 ExperienceEvent envelope；
- 建立最小 PromptTemplate / Revision store；
- 建立 Prompt Build、Context Build 与 Model Invocation Snapshot 管线；
- 登记并冻结 Router、Bootstrap、Curator 与 Judge 的初始模板；
- 旧执行路径先接入 snapshot；在此阶段完成前，不启用任何新的 model-assisted route。

验收：系统中的每次模型调用都有 operationId、已登记 template revision 与可解引用的完整 request snapshot。

### M1：持久主体、Intent 与 Memory topology

- 新增 `Incarnation`、`incarnationId`、Incarnation / Actor Manifests；
- 新增 IntentEnvelope、IntentTransaction 与 `taskId = Nothing` 的 Run 数据模型；
- 新增不可变 Task Archive、literal grep / bounded read；再新增可重建的
  MemorySpace、Mount、View、Record、Mutation 与 Read / Change Receipts；
- Thread、Run 与 ArtifactRef provenance 挂入身份树；
- final answer 在 close 时写 ExperienceEvent；child 使用独立 cursor 与 scratch；
- 创建 `default-yuki` 承接现有 Thread，拆分 Persona defaults 与 Task overrides；
- Router 先用确定性规则或 M0 已登记的 frozen template；Direct 模型执行仍待 M2。

Legacy migration：

- 以 versioned、idempotent MigrationLedger 记录 source、target、状态、失败恢复与重新分类；
- Transcript 仅把可判定的 accepted user / committed assistant / committed tool result
  转为 Archive entry；未完成流与其他 Journal 内容只转为 LegacyExperienceEvent 或
  LegacyEvidenceRef；
- 无法定位来源的 Fact 标记 `provenanceQuality = unresolved`；
- global Facts 进入隔离的 `legacy-import` space，仅挂载给 `default-yuki`，待逐条分类；
- 累计且缺最终回答的 ThreadBrief 只成为低置信 candidate，不成为 active episode truth；
- Artifact blob 保持全局 content-addressed 去重，以 ArtifactRef 关联 incarnation / task / run；
- 旧 Thread system prompt 保存为 task-level legacy source block，不推断 Charter。

### M2：完整 Prompt compiler 与新执行路径

- 建立 Root Constitution、Charter、Policy、Playbook、Task、Worker 与 internal role templates；
- 所有源码硬编码 prompt 进入 revision store；
- 实现 Generator DAG、GeneratorInvocation、ValidationRun、EvaluationRun 与 CAS activation；
- 完成 source map、token budget、sandbox evaluation 与 replay；
- Thread prompt 从整段覆盖改为 task-level source block；
- 只有通过上述验收后，启用 model-assisted Intent Router、Bootstrap 与 Direct Run。

### M3：Self 与治理

- 生成 Self Snapshot；
- 建立 Incarnation Living Model、Context Synthesis、Memory Receipts、Prompt Studio 与 Evolution Proposal；
- 实现 inspect、propose、test、activate 与 rollback；
- 建立行为正例、反例和回归场景。

### M4：Orchestration 与 Capability

- 用 Delegation Spec / Invocation 替代自由文本 `sub_agent`；
- 增加 spawn、list、send、wait、cancel、collect；
- 建立 Work Graph 与 scheduler；
- Capability 从实时工具生成并记录健康与验证方法；
- Coordinator 与 Worker 均获得准确 Self Manifest。

### M5：产品界面

- 顶层改为 Yuki 分身；
- Memory 成为主工作面；
- Thread / Run 退入分身的 Work；
- Prompt、Memory 与自我演化均可审计、修改、测试与回滚。

---

## 十五、验收场景

- A 的 Task Archive（包括已归档 Task），B 不得检索；
- 重启、新 Thread 后，A 仍保持方向、风格与关键记忆；
- 询问「你是谁、知道什么、能做什么、正在做什么」，回答与 registry 一致；
- 有明确并行收益的复杂任务自动委派，简单任务不委派；
- Worker 只取得 Delegation Spec 指定的 memory 与 tools；
- Worker 不能直接写 Task Archive；
- 任意有效 prompt 段均可追溯来源；
- 修改 Charter 只影响新 Run，旧 Run 可完整还原；
- 新事实推翻旧事实时保留证据链；
- 重复失败产生带证据与测试的改进提案，而非暗改自身；
- Transcript 与全部 Distilled Index 丢失后，仍可由 Task Archive、ExperienceEvent 与
  Artifact 重建产品状态。
- cue 被采用时必须先 literal grep，再 bounded read；只命中 excerpt 不等于读过原文。
- 一次简单询问、记忆纠正或自我修改不会创建隐藏 Thread。
- Direct Intent 刷新或重启后从 IntentTransaction 恢复 receipts、Outcome 与待审变化；
- Router、Bootstrap、Curator 与 Judge 的模型调用均有 Kernel Operation 与 GeneratorInvocation；
- Bootstrap 与 generator 变更不能使用同一 Change Set 新造的评估器自证；
- Worker 交付只有 accepted、merged 与 writeback 后才关闭 Work node。

最终产品不是「管理很多对话的 Agent UI」，而是：

**管理几个持续存在、各自记得、各自成形、能工作也能反省的 Yuki。**
