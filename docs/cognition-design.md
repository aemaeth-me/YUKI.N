# YUKI.N 认知体系：清醒、睡眠、长期记忆与印象

> 状态：实现权威；当前实现映射于 2026-07-28 复核。
>
> 本文覆盖 `docs/memory-design.md` 中 Thread 本位的 briefing / watcher 方案，并细化
> `docs/incarnation-design.md` 的 Memory 与 Context 部分。冲突时以本文为准。

## 一、判据

YUKI.N 的产品主体是一个有方向的 **Incarnation**，不是 thread。

```text
Incarnation
├── Self：方向、风格、能力与可修改的 Prompt
├── Impression：独立、模型驱动的潜意识
├── Long-term Memory
│   ├── Task Archive：原始、结构化、不可变的经历本体
│   └── Distilled Index：可由原件重建的提炼索引
└── Work
    ├── Task A
    │   └── Context Epochs：这项工作此刻的短期记忆
    └── Task B
        └── Context Epochs
```

四条最高原则：

1. transcript 是证据与投影，不是产品本体。
2. context window 是工作中的短期记忆；compact 的产品语义是睡眠。
3. 长期记忆的原件是同一分身全部 Task 的结构化档案；它是能力，不是开场材料。
   除非主动回查，正文不得自动进入主模型上下文。
4. 印象独立于长短期记忆。它只给直觉线索，不冒充事实，也不替主模型完成回忆。

持久底座与派生模型解耦：Task Archive、Experience、Blob 与 WorkingMemory 在
`settingsDataDir` 下始终启用；Distilled Index、Impression 与其他 synthesis 均可删除
后重建。没有 impression / curator model 时，只停用相应派生，不得令档案原件与工作态
消失。

## 二、三个不可混用的对象

### 2.1 Short-term Context

短期记忆属于某个分身正在进行的一项工作。它保存当前目标、近因果链、尚未闭合的
动作与必要证据，寿命短、容量硬受限。

它不是：

- 分身人格；
- 长期事实库；
- thread 全量 transcript；
- 每次运行开场都重放的摘要。

### 2.2 Long-term Memory

长期记忆的本体是 **Task Archive**：按分身、Task、Run 与稳定 entry id 组织的原始结构化
记录。它覆盖同一分身的全部 Task，包括 UI 中已归档的 Task；归档只改变工作列表状态，
不改变记忆可检索性。

可成为长期证据的提交边界只有：

- 已接受的用户输入；
- 已提交的 assistant 结果；
- 已提交的工具结果。

instruction、tool call、reasoning 与 WakePacket 若为保持因果链而随闭包保存，只是审计
辅项，不能独立冒充已确认事实。尚未闭合的流式 delta、半截 reasoning 与部分工具输出
只留在 Run Journal；不得提前发布为 Task Archive 记录。

主模型只得到 `memory_grep` / `memory_read` 的能力说明，不自动得到档案正文。
`memory_grep` 只能检索当前分身；原始 Task Archive 不 mount、不跨分身共享。任何
Memory Record、摘要、rollup、Living Model 或 Distilled Index 都只是可重建投影，
不得替代或反向改写原件。

### 2.3 Impression

印象是分身的潜意识状态，由专门模型维护。它包含倾向、熟悉感、警觉、反复出现的
关系与可能相关的回忆入口。

印象激活只可输出：

- 一句直觉提示；
- 建议的固定字符串检索式；
- 可能相关的 Task / archive 引用；
- 置信度与理由。

它不得把 Task Archive 正文原样注入，不得宣称线索为事实，不得直接执行工具，也不得
产生新的 memory / void mutation proposal。

## 三、睡眠协议

### 3.1 术语

睡眠不是 sub-agent，不创建新主体，也不结束任务。

```text
Awake(epoch n)
→ Sleep：冻结当前 epoch 与触发原因
→ Dream：专门模型提出遗忘与继续方案
→ Forget：确定性移出旧 segment，原文仍在本机 Payload / Experience
→ Wake：写成受预算约束的 WakePacket，连同近期因果尾形成 epoch n+1
→ Continue：同一任务继续
```

睡眠产物统一称 **WakePacket**。不得称为 Impression；后者专指潜意识系统。

### 3.2 遗忘优先

Dream 的第一问不是“应记住什么”，而是：

1. 哪些内容已经完成其作用；
2. 哪些推理、尝试、重复输出可退出工作记忆；
3. 哪些细节即使以后需要，也可经 artifact 或 Task Archive grep/read 回取；
4. 遗忘每一类内容为何不会破坏继续工作。

只有完成遗忘裁决后，才生成最小 continuation。

### 3.3 WakePacket

```text
WakePacket
  id
  incarnationId
  taskId
  runId?
  baseEpochId
  trigger = soft_limit | provider_overflow | manual | self_requested | suspend
  continuation
  activeItems[]
  openLoops[]
  forgotten[]
    subject
    reason
    sourceSegmentIds[]
  retainedSegmentIds[]
  payloadRef
  generatorRevision
  invocationRef
  createdAt
```

`continuation` 只陈述醒来后下一步如何接续；`activeItems` 只容纳仍在工作的目标、约束、
决定与失败；`forgotten` 是主要审计面。

### 3.4 Context Segment 与 Epoch

不再以 `[ChatMessage]` 的数组位置充当身份。

```text
ContextSegment
  id
  kind = instruction | user | assistant | tool_call | tool_result | wake_packet
  authority = kernel | user | agent | tool | derived
  sourceRef
  contentRef
  causalGroup
  turnGroup
  createdAt

ContextEpoch
  id
  incarnationId
  taskId
  parentEpochId?
  revision
  segments[]
  activeTokenEstimate
  wakePacketId?
  effectiveHash
```

工具调用与结果共享 `causalGroup`，不可拆开；同一次 assistant 输出的正文与全部
工具调用共享 `turnGroup`，投影时必须合为一条 assistant message。WakePacket 是
`derived` evidence，不能借 `ChatSystem` 的传输形态获得 Kernel 权威。

ContextEpoch 是 WorkingMemory 的有界执行投影；WorkingMemory checkpoint 另保存
focus、open loops、provisional claims 与 Experience cursor。模型调用所需的窗口裁剪
不得推进 cursor；完整 Sleep 才建立 checkpoint 并形成新的 Wake epoch。

### 3.5 事务边界

Sleep 必须以 epoch CAS 发布：

- 冻结 `baseEpochId`；
- Dream、校验与 Wake fit 全部完成后才提交；
- base 已变化则返回 stale，不覆盖新状态；
- 失败、取消或预算不足时仍保持旧 epoch；
- 自动 Sleep 失败时显式令当前 run 失败；禁止静默退回普通摘要 compact；
- provider overflow 只允许一次 emergency sleep，禁止循环。

旧 `POST /threads/:id/compact` 只作兼容适配器，语义等同 manual sleep。

所有已接受 / 已提交原文先进入不可变 Blob 与 Task Archive closure。仍被 archive、
epoch、journal 或 artifact ref 引用的 Blob 不得按数量逐出；旧 FNV artifact id 只作为
alias，不再作为新对象身份。

## 四、长期记忆协议

### 4.1 原件

```text
TaskArchiveEntry
  id
  incarnationId
  taskId
  runId
  sequence
  kind = user | assistant | tool_result | causal_audit
  sourceId
  contentRef
  contentHash
  parentId?
  callId?
  toolName?
  createdAt
```

Task Archive 只追加，不修订。纠错通过后续被接受 / 提交的记录表达；旧证据保留。
Task 的 active / archived 状态不参与 archive ownership，也不缩小默认检索范围。

### 4.2 能力

主模型可调用：

- `memory_grep(query, taskId?, kinds?, caseSensitive?, limit?)`
- `memory_read(entryId, offset?, chars?, before?, after?)`

`memory_grep` 是确定性的固定字符串扫描，不做 embedding、语义改写或隐藏 query
扩写；未指定 `taskId` 时扫描当前分身全部 Task，包括已归档 Task。它只返回稳定
task / run / entry 锚点与受限 excerpt。

`memory_read` 只接受精确 entry id，并按字符切片及前后条数读取有界窗口；若需更多正文，
必须用显式 offset 继续读取。两者结果作为普通工具证据进入当前 context。未调用时，
档案正文不占主模型 token；只 grep 未 read 时，也不得把 excerpt 外的内容当作已回忆。

### 4.3 提炼索引

```text
DistilledRecord
  id
  incarnationId
  kind
  content
  sourceEntryIds[]
  derivedBy
  revision
  status = active | stale | void
```

Distilled Record、Memory Record、rollup 与 Living Model 都是方便检索和理解的索引。
每项必须回指 Task Archive entry；整个索引可以丢弃并由档案重建。其 revise / void
只改变派生读形，不删除历史，也不成为一条平行的长期记忆本体。

Impression 不负责生成、接纳或作废这些记录。旧
`memoryProposals` / `voidProposals` 字段仅为历史 JSON 与审计 UI 兼容；新 revision
必须写空数组。

## 五、印象体系

### 5.1 持久潜意识

每个分身拥有独立的 `ImpressionState`：

```text
ImpressionState
  incarnationId
  revision
  items[]
    id
    label
    intuition
    strength
    sourceMemoryIds[]      # legacy JSON 名；值为 Task / archive refs
    sourceExperienceRefs[]
    updatedAt
  generatorRevision
  effectiveHash
```

items 是模型管理的紧凑潜意识，不是人工标签库。每次 revision 保存 before / after、
输入闭包、模型调用与理由，可回滚。

### 5.2 激活

每个用户 Intent 到来、主模型首次调用之前：

1. 取当前分身 ImpressionState；
2. 取 Task Archive 的受限目录 / entry catalog，而非把正文交给主模型；
3. 取当前 Intent；
4. 调用专门的 impression activation generator；
5. 校验并生成最多数条 cue；
6. 把 cue 以非权威、可见标记注入主模型。

```text
ImpressionCue
  hint
  suggestedQuery?
  memoryIds[]             # legacy JSON 名；值为 Task / archive refs
  confidence
  reason
```

渲染必须写明：

> 这是直觉线索，不是已回忆的事实；若与当前工作相关，先用固定字符串
> memory_grep 定位，再用有界 memory_read 核对。

### 5.3 沉淀

任务运行收束后，consolidation generator 读取：

- 上一版 ImpressionState；
- 本次已提交的 Task Archive / Experience 受限闭包；
- 本次显式 memory_grep / memory_read 证据；
- 当前 Task Archive 受限目录。

它只可提出完整的新 ImpressionState。`sourceMemoryIds` 保留为兼容字段，但只能引用本
分身 Task / archive catalog；`memoryProposals` 与 `voidProposals` 必须为空。它不能
改变 Task Archive、提炼索引、Charter、Root Prompt、工具许可或别的分身。

### 5.4 模型与失败

activation 与 consolidation 使用专门模型 profile；缺省可与 memory model 同模型，但
Invocation 身份必须不同。

模型失败时：

- activation 无 cue 继续主任务，不伪造直觉；
- consolidation 保留上一 revision，不丢状态；
- 非法 JSON、越界 archive ref、非空 memory / void proposal、超预算均形成显式失败审计；
- 不以硬编码关键词 fallback 生成印象。

## 六、Prompt 与自知

### 6.1 编译顺序

```text
Root Constitution revision
→ Incarnation Manifest
→ Composite Incarnation Charter revision
→ Task-local instruction / AGENTS.md
→ Impression Cues
→ WakePacket / Recent Causal Tail
→ Current Input
```

持久 Prompt 层刻意只有两层：Root 与 Composite Charter。Working Style、判断倾向、
Capability / Tool Policy、Memory Policy 与 Self-management 都是 Charter 内的具名段，
由同一次生成得到，避免多个低频小层各自漂移。Task、Workspace 与 Worker 指令是有来源
的局部后代，不反向定义分身。工具 schema 作为模型请求的独立 capability plane 发送，
不伪装成 system prompt。

Root 必须定义：

- 当前主体是 Incarnation，thread 只是任务容器；
- 何时自动拆解并并行委派 sub-agent；
- 何时主动用工具，而不是口头假装执行；
- 长期记忆必须先 literal grep、再 bounded read，方可作为事实使用；
- impression cue 必须经同一 grep/read 链验证；
- 可在工作中请求 sleep；
- 分身可审视并维护自己的非 Kernel 层。

### 6.2 可生成、可审计、可修改

用户只需提供分身的方向与少量约束。Prompt generator 读取当前生效 Root，生成一份
包含 Working Style、判断倾向、Capability / Tool Policy、Memory Policy、
Self-management 与边界的 Composite Charter 初稿。Root 与 Charter revision 均保存：

```text
PromptRevision
  id
  layer
  sourceIntent
  content
  generatorRevision
  modelInvocationRef?
  parentRevision?
  status = draft | active | retired
  effectiveHash
```

前端默认编辑生成结果，不要求用户逐层手写。编辑只产生 draft，Root 与 Charter 都须
显式激活；Root 以当前 active ordinal 做 CAS，Charter 以 Incarnation revision 做 CAS。
`parentRevision` 必须同 owner、同 layer，故审计谱系不能跨层伪接。每次内部模型调用在
journal 中保存实际请求、generator revision、provider/model 与 attempt scope。

### 6.3 自我管理

分身拥有：

- `self_inspect`：读取自身方向、Prompt revision、能力、印象与记忆统计；
- `self_update`：修改自身非 Kernel 层，并生成 revision；
- `sleep`：请求在下一次模型思考前睡眠；
- Task Archive 的只读 memory tools。

Root 与审计数据不可由分身自行删除。

sub-agent / worker 使用独立 scratch、Experience cursor 与 WorkingMemory frame。它可
读取委派时授予的 archive lease，但不得运行父分身的 impression consolidation，也
不得推进父 checkpoint；只有被接受的 writeback 才进入父状态。

## 七、运行次序

```text
User Intent
→ resolve Incarnation + optional Task
→ compile Prompt snapshot
→ activate Impression
→ build Context Epoch projection
→ main model
→ tools / optional parallel sub-agents
→ optional Sleep → Wake → continue
→ outcome
→ commit Task Archive / append Experience
→ consolidate Impression
```

顺序不允许交换：

- long-term memory 不得在 activation 之前自动注入；
- consolidation 不得在主任务之前改写潜意识；
- sleep 不得把未闭合流发布到 Task Archive；
- transcript 保存不得成为 epoch 提交的权威。

Run 收束的硬顺序：

```text
final payload 持久化
→ accepted user / committed assistant / committed tool results 写入 Task Archive
→ Experience outcome
→ WorkingMemory projector / epoch commit
→ transcript 等只读投影
→ run.terminated
→ RUN_FINISHED { experienceCursor, workingRevision, epochId }
```

界面收到完成事件时，相关持久投影必须已经可读。

## 八、统一 Invocation

Prompt generator、Dream、impression activation / consolidation 走统一的 Invocation
层；主模型沿既有 Run journal 记录。内部 Invocation 记录：

```text
kind + invocationId + generator revision
→ exact ModelRequest / rendered API request
→ attempt(provider/model)
→ streamed events / finish
→ schema validation
→ committed revision or explicit failure Experience
```

生成器调用固定 `tools=[]`；结构化输出有独立 output cap 与 timeout。每个模型至多两次
传输 attempt，再按 fallback 链前进；schema 校验失败显式失败，不以代码 fallback 或
关键词规则补造结果。

Replay 对已提交的 Sleep 与 Impression revision 读取记录结果，不再次调用模型。

## 九、产品界面

### 9.1 一级信息架构

打开应用先看到一个分身。

```text
Incarnation Rail
└── Current Incarnation
    ├── 此刻
    ├── 记忆
    ├── 工作
    ├── 能力
    └── 自我
```

thread / task 只出现在「工作」与当前 Intent 的归属信息中，不再占据页头主语。

### 9.2 此刻

- 当前分身方向与状态；
- 当前 Intent；
- 当前任务（若有）；
- impression cue 的可见但安静提示；
- 对话与工具流；
- 短期记忆占用；
- “让 Yuki 睡一觉”。

睡眠确认文案必须说“将主动遗忘什么”，不能再说“整理摘要”。

### 9.3 记忆

默认落在印象，而非 facts 表。

三个并列视图：

1. **印象**：当前潜意识、最近激活、cue→grep→read 的链；
2. **长期**：Task Archive 原件与可重建提炼索引；空白搜索框起步，显式 grep 后显示，
   命中后再 bounded read；
3. **睡眠**：当前 epoch、历次 forgotten / reason、WakePacket 与 payload 引用。

不得把三者放进一个“记忆摘要”卡片。

### 9.4 工作

- 按分身过滤任务；
- thread title、状态、最后活动；
- 进入任务后查看运行与审计；
- 创建任务时默认归属当前分身。

### 9.5 自我

- 方向；
- 生成的 Working Style；
- 编译 Prompt 图与实际快照；
- 自我修改历史；
- impression model profile；
- Task Archive 的分身边界与提炼索引来源。

## 十、HTTP 投影

```text
GET/POST          /incarnations
GET/PATCH         /incarnations/:id
POST              /incarnations/:id/archive

GET/POST          /prompts/root
POST              /prompts/root/:promptId/activate
GET/POST          /incarnations/:id/prompts
POST              /incarnations/:id/prompts/generate
POST              /incarnations/:id/prompts/:promptId/activate

GET               /incarnations/:id/impression
GET               /incarnations/:id/impression/activations
GET               /incarnations/:id/impression/revisions

GET               /incarnations/:id/task-records
POST              /incarnations/:id/task-records/search
GET               /incarnations/:id/task-records/:entryId

GET/POST          /incarnations/:id/memories                  # derived / legacy index
POST              /incarnations/:id/memories/search           # derived / legacy index
GET               /incarnations/:id/memories/:memoryId        # derived / legacy index
POST              /incarnations/:id/memories/:memoryId/void   # derived / legacy index
GET               /incarnations/:id/memory-receipts           # derived / legacy index

GET               /incarnations/:id/working-memory
GET               /incarnations/:id/sleep-cycles
GET               /incarnations/:id/experiences
POST              /threads/:taskId/sleep
POST              /threads/:taskId/compact   # compatibility adapter
GET               /threads/:taskId/context-epochs
```

有既存对象的 mutation 使用 expected revision / epoch；stale 返回 `409`。Task Archive
只追加，没有 revision mutation。`/memories` 仍保留用于旧提炼记录与兼容 UI，不是原件
读写协议。

## 十一、迁移

已落地的迁移顺序：

1. 冻结旧 `[thread brief]`、`[memory candidates]` 注入链，不再扩展。
2. 建 Incarnation、PromptRevision、Task Archive、Impression、ContextEpoch 与 Sleep store。
3. 默认创建 `yuki` 分身；现有 task 按配置迁入相应分身。
4. 旧 transcript 按 accepted / committed 边界幂等迁入结构化 Task Archive；无法可靠
   判断边界的片段标为 legacy audit，不提升为事实。
5. 旧 facts / LongMemory 保留为 derived legacy index，并尽量回指 archive entry；
   无法回指者标记来源缺失，不得冒充原件。
6. 旧 rolling summaries 只迁为 legacy Experience，不迁成印象。
7. 上线 literal `memory_grep` → bounded `memory_read`、新 Root protocol、模型驱动
   impression 与 Sleep CAS。
8. 旧 compact endpoint 转成 manual sleep adapter；transcript 退为兼容投影。
9. 前端切为 Incarnation-first，并隐藏任务级 legacy memory 开关。

迁移 ledger 必须幂等；旧文件保留到新记录验收后。迁移还必须显式检测旧
`sanitizeThreadId` 造成的 `a.b` / `a-b` 路径碰撞，不得猜测覆盖。

## 十二、不变式与验收

### 不变式

1. 两个分身的 Task Archive 与 ImpressionState 不互见；Task 归档不改变 archive 可见性。
2. 未调用 `memory_grep` 时，Task Archive 正文不进入主模型请求。
3. cue 必须带“非事实”标记；事实采用必须经过 literal grep 与 bounded read。
4. Sleep 主要记录 forgotten；WakePacket 不是长期记忆，也不是 ImpressionState。
5. 同一任务可经历多个 epoch，睡醒后继续，不新建 thread。
6. Dream / impression / prompt generator 均无工具与越权写权限。
7. 新 ImpressionRevision 的 `memoryProposals` / `voidProposals` 恒为空。
8. 每个 Prompt、模型调用、archive commit、派生索引变化、睡眠与 impression revision
   均可追溯。
9. transcript 与全部提炼索引可删除后，Incarnation、Task Archive、Impression 与
   Task state 仍成立。

### 验收场景

- 在任务中触发 soft limit：先出现 Sleep，审计展示遗忘项，随后同一 run 继续。
- 手动请求 sleep：若有可遗忘内容，生成新 epoch；若无，明确保持清醒。
- 新任务提到旧方向：印象提示可能相关的 grep，不直接泄露旧记录正文。
- 主模型忽略 cue：任务仍可正常完成。
- 主模型采用 cue：先 literal `memory_grep`，再 bounded `memory_read`，方把核对内容
  作为证据使用。
- 已归档 Task 的原文仍可由其分身 grep/read；其他分身不可命中。
- grep 命中超大 entry 时，read 只返回请求切片，继续读取必须显式推进 offset。
- 两个分身输入同一 Intent：因 Charter、Task Archive 与 ImpressionState 不同而表现不同。
- impression model 失败：无 cue、主任务继续、上一潜意识 revision 不变。
- impression model 返回非空 memory / void proposals：consolidation 明确失败，不提交 revision。
- stale manual sleep：返回冲突，不覆盖正在运行的新 epoch。
- 审计可从 cue 追到 activation invocation、Task Archive catalog、后续 grep/read 与最终回答。
