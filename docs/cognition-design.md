# YUKI.N 认知体系设计

> 状态：认知体系权威文档。2026-08-01 基于 `memory/` 系列与实现源码重写。
>
> 关系：
> - **记忆子系统**：印象、工作记忆（睡眠-清醒）、长期记忆（Task Archive）的机制细节见
>   [`memory/`](memory/) 系列——本文件只描述记忆在整个认知体系中的位置与边界，不重复细节。
> - **分身与 Prompt 治理**：以 [`incarnation-design.md`](incarnation-design.md) 为概念权威。
> - **前端**：以 [`frontend-redesign.md`](frontend-redesign.md) 为界面基线。
> - 历史实现说明已归档到仓库外 `docs-archive/`，不再作为权威。

## 一、定位：Memory 是认知体系的一个子系统

认知体系不是"记忆系统"，而是有方向、会执行、能自知、能演化的运行时。**记忆是它的一部分**：

```text
Cognition
├── Incarnation 治理      → 分身、方向、Prompt（见 incarnation-design.md）
├── 执行回路              → run / tools / journal / replay / sub-agent
├── 上下文编译            → Context Epoch 投影、窗口裁剪
├── Memory 子系统         → 见 memory/ 系列
│   ├── 印象 Impression   → 潜意识线索（memory/01）
│   ├── 工作记忆          → 睡眠-清醒循环、WakePacket（memory/02）
│   ├── 长期记忆          → Task Archive + 提炼索引（memory/03）
│   └── 生命周期          → 钩子、并发、恢复、审计（memory/04）
└── 自知与自我管理        → self_inspect / self_update
```

四个最高原则（跨子系统的约束）：

1. **transcript 是证据与投影，不是产品本体。** 产品主体是有方向的 Incarnation。
2. **context window 是工作中的短期记忆**；compact 的产品语义是睡眠（memory/02）。
3. **长期记忆的原件是同一分身全部 Task 的结构化档案**；它是**能力**，不是开场材料——
   除非主动回查，正文不得自动进入主模型上下文（memory/03）。
4. **印象独立于长短期记忆**，只给直觉线索，不冒充事实，也不替主模型完成回忆（memory/01）。

持久底座与派生模型解耦：Task Archive、Experience、Blob 与 WorkingMemory 在
`settingsDataDir` 下始终启用；Distilled Index、Impression 与其他 synthesis 均可删除后重建。
没有 impression / curator model 时，只停用相应派生，不得令档案原件与工作态消失。

## 二、记忆在认知中的三个对象

记忆子系统内部有三个不可混用的对象（机制细节见 memory/ 系列）：

| 对象 | 定义 | 权威文档 |
|---|---|---|
| **短期上下文 Short-term Context** | 某分身正在进行的一项工作的当前目标、近因果链、未闭合动作与必要证据；寿命短、容量硬受限 | memory/02 |
| **长期记忆 Long-term Memory** | 本体是 Task Archive：按分身×Task×Run×entry 组织的原始结构化记录，覆盖同一分身全部 Task | memory/03 |
| **印象 Impression** | 分身的潜意识状态：倾向、显著性、反复出现的关系与可能相关的回忆入口 | memory/01 |

边界约束（对每个对象都成立）：

- 短期上下文**不是**：分身人格、长期事实库、thread 全量 transcript、每次开场重放的摘要。
- 长期证据的提交边界只有：**已接受的用户输入、已提交的 assistant 结果、已提交的工具结果**。
  instruction / tool call / reasoning / WakePacket 若随闭包保存，只是因果审计辅项，不能独立
  冒充已确认事实；未闭合的流式 delta、半截 reasoning 只留在 Run Journal。
- 印象激活只可输出：直觉提示、建议的固定串检索式、可能相关的 Task/archive 引用、置信度与理由。
  不得注入档案正文、不得宣称线索为事实、不得执行工具、不得产生 memory/void mutation proposal。

## 三、睡眠协议（工作记忆的认知语义）

> 机制细节、状态机与校验见 memory/02。此处只记认知层面的定义与不变式。

睡眠**不是** sub-agent，不创建新主体，也不结束任务。它是"先遗忘的工作记忆维护"：

```text
Awake(epoch n)
→ Sleep：冻结当前 epoch 与触发原因
→ Dream：专门模型提出遗忘与继续方案
→ Forget：确定性移出旧 segment，原文仍在本机 Payload / Experience
→ Wake：写成受预算约束的 WakePacket，连同近期因果尾形成 epoch n+1
→ Continue：同一任务继续
```

- 睡眠产物统一称 **WakePacket**，不得称为 Impression（后者专指潜意识系统，memory/01）。
- **遗忘优先**：Dream 的第一问不是"应记住什么"，而是"哪些已完成、哪些可退出、哪些可经
  artifact / grep / read 回取、为何遗忘不破坏继续"。
- `continuation` 只陈述醒来如何接续；`activeItems` 只容纳仍在工作的目标与约束；
  `forgotten` 是主要审计面。
- ContextEpoch 是 WorkingMemory 的有界执行投影；模型调用所需的窗口裁剪**不得推进 cursor**，
  完整 Sleep 才建立 checkpoint 并形成新的 Wake epoch（memory/02 状态机）。
- **事务边界**：Sleep 以 epoch CAS 发布；base 已变化则 stale；失败/取消/预算不足保持旧 epoch；
  自动 Sleep 失败显式令当前 run 失败，禁止静默退回普通摘要 compact；provider overflow 只允许
  一次 emergency sleep，禁止循环。

## 四、长期记忆协议（记忆作为能力）

> 数据结构、追加语义、grep/read 细节、证据分类见 memory/03。此处只记协议级定义。

主模型只得到 `memory_grep` / `memory_read` 的能力说明，不自动得到档案正文：

- `memory_grep(query, taskId?, kinds?, caseSensitive?, limit?)`：确定性的固定字符串扫描，
  不做 embedding、语义改写或隐藏扩写；默认扫描当前分身全部 Task（含已归档），但**默认排除当前任务**
  （其 transcript 已在上下文里）；返回稳定 task/run/entry 锚点与受限 excerpt。
- `memory_read(entryId, offset?, chars?, before?, after?)`：只接受精确 entry id，读有界窗口；
  更多正文必须显式推进 offset。
- 结果作为普通工具证据进入 context；未调用时不占 token；只 grep 未 read 时，不得把 excerpt
  以外的内容当作已回忆。

提炼索引（Distilled Record / Memory Record / rollup / Living Model）都是方便检索与理解的
索引：每项回指 Task Archive entry；整个索引可丢弃并由档案重建；revise/void 只改派生读形，
不删除历史，不成为平行的长期记忆本体。**印象不负责生成/接纳/作废这些记录**。

## 五、Prompt 与自知（认知的执行面）

> 分身的领域模型与三种自我见 incarnation-design.md。此处记编译次序与自我管理。

编译顺序（从稳定到易变）：

```text
Root Constitution revision
→ Incarnation Manifest
→ Composite Incarnation Charter revision
→ Task-local instruction / AGENTS.md
→ Impression Cues（memory/01）
→ WakePacket / Recent Causal Tail（memory/02）
→ Current Input
```

- 持久 Prompt 层刻意只有两层：**Root 与 Composite Charter**。Working Style、判断倾向、
  Capability/Tool Policy、Memory Policy 与 Self-management 都是 Charter 内的具名段，
  由同一次生成得到，避免多个低频小层漂移。
- Root 必须定义：主体是 Incarnation；何时委派 sub-agent；何时主动用工具；长期记忆必须先
  literal grep、再 bounded read 方可作为事实；cue 必须经同一 grep/read 链验证；可请求 sleep；
  分身可审视并维护自己的非 Kernel 层。
- 编辑只产生 draft，Root 与 Charter 都须显式激活；`parentRevision` 必须同 owner、同 layer。

自我管理工具：`self_inspect`（读自身方向/Prompt/印象/记忆统计）、`self_update`（改非 Kernel 层，
生成 revision）、`sleep`、Task Archive 只读工具。Root 与审计数据不可由分身自行删除。

sub-agent / worker 使用独立 scratch、Experience cursor 与 WorkingMemory frame；可读委派授予的
archive lease，但不得运行父分身的 impression consolidation，也不得推进父 checkpoint。

## 六、运行次序

```text
User Intent
→ resolve Incarnation + optional Task
→ compile Prompt snapshot
→ activate Impression（memory/01）
→ build Context Epoch projection（memory/02）
→ main model
→ tools / optional parallel sub-agents
→ optional Sleep → Wake → continue
→ outcome
→ commit Task Archive / append Experience（memory/03）
→ consolidate Impression（memory/01）
```

顺序不允许交换：长期记忆不得在 activation 之前自动注入；consolidation 不得在主任务之前改写
潜意识；sleep 不得把未闭合流发布到 Task Archive；transcript 保存不得成为 epoch 提交的权威。

Run 收束硬顺序：

```text
final payload 持久化
→ accepted / committed 内容写入 Task Archive
→ Experience outcome
→ WorkingMemory projector / epoch commit
→ transcript 等只读投影
→ run.terminated
→ RUN_FINISHED { experienceCursor, workingRevision, epochId }
```

## 七、统一 Invocation

Prompt generator、Dream、impression activation / consolidation 走统一 Invocation 层
（kind + generator revision + 精确请求 + attempt + 校验 + 提交/失败审计）。生成器调用固定
`tools=[]`；结构化输出有独立 cap 与 timeout；每个模型至多两次传输 attempt，再按 fallback 链
前进；schema 校验失败显式失败，不以后代码 fallback 补造结果。Replay 对已提交的 Sleep 与
Impression revision 读取记录结果，不再次调用模型。

## 八、产品界面（认知的可观测面）

> 前端细节见 frontend-redesign.md；此处只记与记忆/认知相关的结构要求。

- 一级信息架构：Incarnation Rail → 此刻 / 记忆 / 工作 / 能力 / 自我。
- **记忆页严格拆成「印象 / 长期 / 睡眠」三视图**（memory/01、memory/03、memory/02），
  默认落在印象；长期记忆空白搜索框起步，显式 grep 后显示，命中后再 bounded read；
  睡眠展示当前 epoch、历次 forgotten/reason 与 WakePacket。不得把三者放进一个"记忆摘要"卡片。
- 睡眠确认文案必须说"将主动遗忘什么"，不能再说"整理摘要"。

## 九、HTTP 投影与迁移

记忆相关的 HTTP 面与迁移顺序以 memory/04（生命周期）为权威；本文件不重复。要点：
有既存对象的 mutation 使用 expected revision/epoch，stale 返回 `409`；Task Archive 只追加，
没有 revision mutation；`/memories` 仅保留旧提炼记录与兼容 UI，不是原件读写协议。

## 十、不变式（认知级）

1. 两个分身的 Task Archive 与 ImpressionState 不互见；Task 归档不改变 archive 可见性。
2. 未调用 `memory_grep` 时，Task Archive 正文不进入主模型请求。
3. cue 必须带"非事实"标记；事实采用必须经过 literal grep 与 bounded read。
4. Sleep 主要记录 forgotten；WakePacket 不是长期记忆，也不是 ImpressionState。
5. 同一任务可经历多个 epoch，睡醒后继续，不新建 thread。
6. Dream / impression / prompt generator 均无工具与越权写权限。
7. 新 ImpressionRevision 的 `memoryProposals` / `voidProposals` 恒为空。
8. 每个 Prompt、模型调用、archive commit、派生索引变化、睡眠与 impression revision 均可追溯。
9. transcript 与全部提炼索引可删除后，Incarnation、Task Archive、Impression 与 Task state 仍成立。

## 十一、演进

记忆子系统已评审出的演进方向（召回 / cue 生成、SQLite 三轨检索、评测体系）见
[`memory/05-演进方向.md`](memory/05-演进方向.md)，依据的领域调查见 [`research/`](research/)。
