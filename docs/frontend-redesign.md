# YUKI.N 前端重设计：分身本位

> 记忆交互以 `docs/cognition-design.md` 为准：记忆页严格拆成「印象 / 长期 / 睡眠」；
> 长期记忆默认不展示正文，须显式 grep；thread 只属于「工作」，不得重回页头主语。

> 状态：产品与 UI/UX 权威基线
> 上游模型：`docs/incarnation-design.md`
> 范围：本地单用户工具。本文不讨论鉴权、多用户、协作、商业化或对外扩展。
>
> 2026-07-28 的实现闭环：分身 rail；此刻 / 记忆 / 工作 / 能力 / 自我；记忆内严格拆分
> 印象 / 长期 / 睡眠；Root 与 Composite Charter 的 draft / activation / lineage 审计；
> 旧 Run / Journal 退入 Root 审计。实现细节以 `docs/cognition-design.md` 为准。

## 一、修正

上一版虽将 Transcript 降为过程视图，仍以 Thread 为最高产品对象。它只是把「聊天」改名为「任务」，没有改变本体。

新的产品定义是：

> **YUKI.N 管理的是几个持续存在、各自记得、各自成形、能工作也能反省的 Yuki。**

因此：

```text
Yuki 分身                最高持久主体
├── Self                 它是谁
├── Memory               它因何成为现在的自己
├── Capabilities         它此刻能做什么
├── Commitments          它尚欠什么
└── Intents              它此刻被交付什么
    ├── Direct            即时询问或处理
    ├── Memory / Self     纠正记忆或修改自己
    └── Work              只有持久工作进入此支
        └── Thread / Task 一次任务
            └── Run       一次执行
                └── Worker 临时分工
```

Thread 不再拥有长期人格、通用记忆或 system prompt。它只保有任务契约、局部上下文与执行记录。

前端不可先于这一模型独立重做。若底层仍只有 `threadId`、一段可覆盖的 system prompt 与全局 `facts.jsonl`，任何「分身界面」都只是视觉别名。

---

## 二、现状再审

### 2.1 可见界面的错位

当前界面将三个 runtime 子系统直接做成产品导航：

- 工作：Transcript 主画布；
- 配置：ThreadConfig 表单；
- 审计：Journal、Run、Memory、Artifact；
- 会话：挤在右侧窄栏。

这使日常使用始终围绕「某次对话发生了什么」，而非：

- 我现在要找哪个 Yuki；
- 它记得什么；
- 它如何理解自己；
- 它有哪些未完承诺；
- 它为何这样工作；
- 这次经历令它发生了什么变化。

### 2.2 真实运行的错位

在 agentic runtime 中，主要 Transcript 可能只有一条用户输入，实质工作却包含数十次模型请求、工具调用与子代理执行。聊天形状不能代表真实工作。

旧重设计进一步把 Plan、Run、Child Run、Result 抬高，这是必要但不充分的。它仍把一次任务的执行结构当成产品首页；任务结束后，产品主体也随之失焦。

### 2.3 底层模型的错位

当前实现尚无持久分身：

- 无 `incarnationId`；
- Thread 同时承担配置、cwd、memory 与执行边界；
- Thread system prompt 可整段覆盖 Root prompt；
- `ThreadBrief` 无法形成跨任务自我；
- `FactStore` 又被所有 Thread 无条件共享；
- child 沿用父 threadId 与 memory hooks；
- `sub_agent` 只有一段自由文本，尚非可治理的委派。

所以本次不是单纯 UI 工程，而是领域模型、运行时与前端共同迁移。

---

## 三、产品原则

### 3.1 打开的永远是一个 Yuki

启动后恢复上次使用的分身。切换器首先列分身，而非任务。

一个分身页面始终回答四件事：

```text
我是谁        Charter + Self Model
我记得什么    Memory + 来源 + 当前 Context
我能做什么    Capability Snapshot
我在做什么    Commitments + Tasks + Workers
```

### 3.2 Memory 是连续性的可见载体

时间线只证明发生过什么；Memory 说明这段经历留下了什么。

每次 Intent 收束，默认首先展示：

- 本次实际唤起了哪些记忆；
- 得到了什么 Outcome；
- 得到的新认识；
- 被修正的旧认识；
- 新形成或失效的工作方法；
- 尚未兑现的承诺；
- 未被接纳的记忆候选。

Transcript 只在需要核查证据时展开。

### 3.3 Prompt 是编译结果，不是人格文本框

用户不应为每个层级手写完整 prompt。界面管理的是有语义的源对象：

- Root Constitution；
- Incarnation Charter；
- Self Model；
- Memory Policy；
- Capability / Tool Policy；
- Orchestration Policy；
- Playbooks；
- Task Contract。

系统从这些对象生成 Prompt Build。用户可查看、比较、修改来源；历史生效文本不可变。

### 3.4 自治必须可见、可解释、可撤回

分身可以：

- 归纳经验；
- 提议修正自己；
- 自动决定是否使用工具；
- 自动拆分与委派工作；
- 维护开放问题与承诺。

但任何行为都应留下：

- 决定；
- 理由；
- 使用的上下文；
- 造成的变化；
- 可撤销的版本。

### 3.5 复杂度按需显露

日常界面只呈现状态、意图、结果与变化。Prompt 片段、工具参数、事件、API、Journal、原始 Transcript 均进入检查层。

「可以 audit」不等于「永远占据主界面」。

---

## 四、信息架构

### 4.1 路由

```text
/yukis

/i/:incarnationId
/i/:incarnationId/memory
/i/:incarnationId/work
/i/:incarnationId/runs/:runId
/i/:incarnationId/work/:threadId
/i/:incarnationId/work/:threadId/runs/:runId
/i/:incarnationId/capabilities
/i/:incarnationId/self
/i/:incarnationId/evolution

/system/root
/system/shared-memory
/system/capabilities
/system/audit
```

`/system/*` 是低频控制面，不与分身并列成日常工作对象。

### 4.2 一级导航

```text
分身切换器
└── 当前 Yuki
    ├── 此刻
    ├── 记忆
    ├── 工作
    ├── 能力
    └── 自我
```

「演化」不必常驻一级导航。存在待审提案时，它以明确收件箱出现；无待办时归于「自我」。

### 4.3 桌面骨架

```text
┌──────────┬────────────────────────────────────────────────────┐
│ Yuki Rail│  研究者 Yuki · 正在形成判断                     ⚙ │
│          │  此刻   记忆   工作   能力   自我                  │
│  研      ├────────────────────────────────────────────────────┤
│  写      │                                                    │
│  工      │                  当前页面                          │
│          │                                                    │
│  +       │                                                    │
│          ├────────────────────────────────────────────────────┤
│  Root    │  交给这个 Yuki…                            ⌘↵      │
└──────────┴────────────────────────────────────────────────────┘
```

左轨只用于身份切换：

- 分身标记；
- 名称；
- 当前状态；
- 需要注意的提案或阻塞；
- 创建分身；
- Root 控制面入口。

任务列表不得重新侵入左轨。

### 4.4 分身页头

页头不是装饰性 profile，而是压缩后的 Self Manifest：

- 名称与一句使命；
- 当前状态：空闲 / 工作中 / 等待你 / 自我整理；
- 当前 capability revision；
- memory revision 与最近更新时间；
- 当前承诺数；
- 正在执行的任务及 Worker 数。

点击任一项进入其来源，不展示不可验证的拟人状态。

---

## 五、「此刻」：默认首页

「此刻」不是活动流，也不是通用 dashboard。它呈现这个分身当前自我的最小完整截面。

向「此刻」输入不必进入 Work。一次询问可在当前页形成即时 Outcome；记忆纠正进入 Memory Mutation；自我修改进入 Evolution Proposal。只有 work route 才创建任务。

### 5.1 页面结构

```text
┌──────────────────────────────┬───────────────────────────────┐
│ 当前理解                     │ 正在承担                      │
│ 最近形成的判断               │ 活跃任务 / 等待确认 / 承诺    │
├──────────────────────────────┼───────────────────────────────┤
│ 最近变化                     │ 自我观察                      │
│ 新增/修正/争议记忆           │ 工具失效、方法候选、边界变化  │
├──────────────────────────────┴───────────────────────────────┤
│ 本次：唤起的记忆 → Outcome → Memory / Commitment 变化        │
├──────────────────────────────────────────────────────────────┤
│ 与它继续：交付意图、提问或纠正                              │
└──────────────────────────────────────────────────────────────┘
```

### 5.2 当前理解

展示少量高显著记忆，而非最近事件：

- 当前方向的核心判断；
- 与用户已形成的稳定约定；
- 最近被修正的认识；
- 正在影响工作的程序性记忆。

每项标明来源与作用域。点击进入 Memory Record。

### 5.3 正在承担

按承诺而非时间排列：

- 正在执行；
- 等待用户；
- 已排队；
- 长期开放问题；
- 已逾期或失去上下文。

任务只是承诺的一个实现容器。一次承诺可以跨多个 Thread，Thread 结束也不自动消灭承诺。

### 5.4 最近变化

只显示对分身产生影响的变化：

- Memory Mutation；
- Charter / Policy revision；
- Capability 变化；
- 新 Playbook；
- 自我提案的通过、拒绝与回滚。

普通工具调用与消息不进入此处。

### 5.5 当前 Intent

提交后不自动跳往 Thread。当前页原位展开一条完整事务：

```text
本次唤起
  3 条私有记忆 · 1 个项目挂载 · 1 条争议未采用
        ↓
Outcome
  当前答案、成果、等待项；长任务只显示阶段结论
        ↓
留下什么
  Memory Mutation · Commitment 变化 · Self proposal
```

长任务提供「查看 Work Graph」，但完成提问、查看结果、纠正记忆与确认变化均无需进入 Work。

该区域由持久 `IntentTransaction` 投影，不由组件本地状态拼装。断流、刷新或重启后，仍能恢复 `routing / executing / awaiting review / committed / failed / cancelled` 与对应 receipts。

---

## 六、Memory Workspace

Memory 是产品核心工作区，不是审计页的一张卡。

### 6.1 默认视图：Incarnation Living Model

Memory 首页首先呈现「这个分身当前如何理解世界」，不是记录列表：

```text
当前理解｜YUKI.N 产品
├── 当前主张      产品主体应是分身，而非 Thread        [3 来源]
├── 关系          Memory 塑造 Self，Prompt 投影 Self    [5 来源]
├── 已知争议      Shared Memory 是否普遍挂载            [2 冲突]
├── 未知          首批分身方向尚未确定                  [开放]
├── 稳定方法      先审计真实运行，再做产品抽象           [4 证据]
└── 承诺          完成分身化迁移 M0                     [进行中]
```

Incarnation Living Model 是带 revision 的 durable 派生投影：

- 每条主张均内联来源；
- 不得产生无 Memory Record 支持的新事实；
- 明确区分主张、推断、争议与未知；
- 点击进入底层记录、谱系或纠错；
- 可切换主题与时间；
- 显示 `fresh / stale / rebuilding / failed` 与输入 topology revision。

它不含 Task Local、Run Scratch 或临时 Mount。Context Preview 另生成 `ContextSynthesis`，展示某个 Intent 实际使用的临时 record set；两者不可混称。

### 6.2 Record Explorer

```text
┌─────────────────┬────────────────────────────────────────────┐
│ Scope / Type     │  记忆详情                                  │
│ 私有 / 共享挂载 │  内容 / 状态 / 置信度 / revision            │
│ 身份 / 事实     │  来源证据 / 历次修正 / 使用记录             │
│ 方法 / 默契     │  正在影响哪些 Synthesis、Context 与任务     │
│ 承诺证据 / 经历 │  [纠正] [归档] [锁定] [移动作用域]          │
└─────────────────┴────────────────────────────────────────────┘
```

搜索结果按语义相关性、作用域、时效与状态排序；不以 Transcript 命中数替代 Memory 检索。

### 6.3 必备视图

- **当前理解**：Incarnation Living Model，按主题呈现主张、关系、争议、未知、方法与承诺；
- **记录**：底层 Memory Record Explorer；
- **已采用**：当前可被检索的正式记忆；
- **候选**：分身从经历中提出、尚未确认的变化；
- **争议**：证据冲突或被用户纠正的记录；
- **承诺**：仍有未来约束力的事项；
- **衰退**：长期未用、低置信或可能过时的内容；
- **谱系**：某条记忆由哪些事件、任务与 prompt revision 派生。

Shared Memory 是可挂载的库，不是默认广播层。界面必须区分：

- 已挂载给当前分身；
- 未挂载；
- 用户明确标为 universal pinned；
- 来自 legacy import、尚待分类。

Commitment 与 Playbook 不以普通 Memory Record 充当权威：

- Memory 只保存承诺与方法的证据；
- Commitment 页面修改其状态机；
- 只有 active PlaybookRevision 进入 Prompt；
- Living Model 引用二者的 exact revision。

### 6.4 修改语义

编辑不是覆盖文本，而是创建 `MemoryMutation`：

- 纠正：新记录 supersede 旧记录；
- 删除：默认归档或作废，保留证据；
- 移动：迁往另一个可写 Memory Space；
- 挂载：另行创建或修改 Memory Mount，不改变原 Record 的 space；
- Pack 写回：默认进入当前分身的 private overlay，不改 Pack 原文；
- 锁定：禁止自动改写；
- 晋升：Observation → Semantic / Procedural / Charter proposal。

界面默认呈现变化的语义，不要求用户理解事件存储。

### 6.5 Context Preview

提供一个关键诊断工具：

> 「如果现在把这件事交给它，它实际会看到什么？」

输入一个意图后，预览：

- 命中的记忆；
- 被排除的记忆及原因；
- exact Mount / Space / Record revisions；
- 作用域与 token 占用；
- 冲突与过时项；
- 最终 `Memory View`；
- 针对此 Intent 的 `ContextSynthesis`；
- 该视图将进入哪个 Prompt Build。

它只预览，不启动 Run。

### 6.6 Memory Read / Change Receipts

每次 Intent 产生两份不同回执：

- **Memory Read Receipt**：本次读取、排除、冲突与 mount snapshot；
- **Memory Change Receipt**：本次提出、自动提交、待审、拒绝或 supersede 了什么。

```text
本次经历留下：
  + 2 条新认识
  ~ 1 条修正
  ↑ 1 个方法候选
  ! 1 个未决冲突
  ○ 4 个观察未采用
```

它们在「此刻」围绕 Outcome 展示：Read 在前，Change 在后；Task 页面只是同一事务的钻取。

Change Receipt 明确分组：

- `autoCommitted`：已经生效，不再等待「整批接受」；
- `pendingReview`：用户可逐项或整批接受；
- `proposed`：尚未完成验证；
- `rejected`：附拒绝理由；
- `superseded`：显示被替代记录。

只要仍有 `pendingReview`，Intent Transaction 保持 `awaiting_review`；执行结束不冒充事务已提交。

---

## 七、Work：任务退居其位

### 7.1 任务列表

任务只属于当前分身，也只接收被判定为 work 的意图。列表按「需关注 / 正在进行 / 开放 / 已收束」组织，而非纯时间排序。

一项任务显示：

- 任务契约；
- 当前结果或阻塞；
- 最近 Run；
- 未决承诺；
- 本任务对记忆造成的变化；
- 是否存在活跃 Worker。

不显示长消息预览。

### 7.2 任务首页

```text
任务：重新定义前端
目标：形成可实施的分身本位产品蓝图
状态：正在执行 · 3 Workers · 需要 1 项确认

[本次] [执行] [检查]
```

默认打开「本次」，按同一事务顺序呈现：

- 本次使用的 Memory Read Receipt；
- 当前可交付结果；
- 已完成与未完成；
- 关键决定；
- 文件或工件；
- Memory Mutation 与 Commitment 变化；
- 下一步。

### 7.3 执行

执行页呈现 Work Graph，而非聊天气泡流：

```text
目标
├── 主路径：综合产品模型                    进行中
├── 委派：审计 Memory 实现                  完成
├── 委派：审计 Prompt 与工具调用            完成
└── 委派：生成替代信息架构                  完成
```

每个节点显示：

- owner；
- 输入契约；
- 允许能力与可执行的 Memory Lease / Tool Grant；
- 状态与耗时；
- 产出；
- 验收；
- 写回边界。

节点状态明确区分 `running / submitted / revision requested / accepted / merged / completed`。Worker 结束不显示为任务已完成；只有验收通过并合并后才闭合节点。

修改 objective、lease、tool grant 或验收条件时显示 Delegation Amendment diff；普通 steering note 不得静默改变契约。

模型主动委派时，页面用一句话解释：

> 将三个相互独立的审计并行委派，以减少遗漏；Worker 仅获得任务局部上下文，无长期记忆写权限。

### 7.4 运行中输入

输入不伪装为普通聊天。系统先给出路由判断：

- **纠偏当前 Run**：立即影响正在执行的路径；
- **追加任务约束**：更新 Task Contract；
- **随后处理**：进入当前任务队列；
- **新任务**：从当前分身开启另一 Thread；
- **即时回答**：形成无 Thread 的 Direct Run；
- **修正分身**：形成 Memory / Charter proposal。

默认自动判断，发送前以轻量标签显示；用户可一键改路由。

### 7.5 检查

检查层才包含：

- Transcript；
- Tool calls；
- Worker prompts；
- Prompt Build；
- 完整 Context Build 与 Model Invocation Snapshot；
- Events；
- API；
- Journal；
- Replay；
- Artifact 原文。

任何一条最终结论均可反查到这些证据；这些证据不再主导日常工作。

---

## 八、Self：可认识、可修改的自我

### 8.1 Self 页面

```text
规范自我     Charter
经验自我     Self Model
现实自我     Capability Snapshot
行为方法     Playbooks / Policies
生成方式     Prompt Program
演化记录     Proposals / Revisions / Evaluations
```

三个「自我」必须分开：

- Charter 是用户与分身共同确认的规范；
- Self Model 是由经历归纳的描述；
- Capability Snapshot 是运行时事实。

分身不能用自我描述冒充实际能力，也不能用一次经历静默改写 Charter。

### 8.2 Charter 编辑

Charter 以结构化块呈现：

- 使命；
- 原则；
- 方法倾向；
- 表达风格；
- 质量标准；
- 边界；
- 正例与反例。

支持两种修改：

1. 直接编辑某一块；
2. 用自然语言告诉它「希望你以后怎样」，由系统生成 diff。

提交前显示：

- 具体改动；
- 影响的 Prompt 层；
- 可能改变的既有 Playbook；
- Evaluation Suite 结果；
- revision 与回滚点。

### 8.3 Self Model

Self Model 使用明确语气区分确定性：

- 我已经稳定采用……
- 我倾向于……
- 我最近观察到……
- 我尚不能确定……
- 我曾在……失败，因此……

每句可追溯至 Memory Record。无法追溯的自我认识不得进入稳定 Self Model。

---

## 九、Prompt Studio

Prompt Studio 不提供一个巨型可变 textarea。

### 9.1 Prompt Graph

```text
Root Constitution                    用户可审计 / 版本化
    ↓
Incarnation Charter                  用户可改 / 可锁
    ↓
Policy Bundle + Playbooks             生成后可改 / 可锁
    ↓
Workspace Instruction Contract        来自项目规范
    ↓
Task / Run / Delegation Spec          按 route 生成
    ↓
Effective Prompt Build                不可变

Prompt Build
    + Self Snapshot
    + Capability / Tool Manifest
    + Workspace observations / client context
    + Memory View
    + Task state / compacted evidence
    + Current Input
    ↓
Context Build                         每次模型调用不可变
    ↓
Model Invocation Snapshot             provider 请求可追溯
```

每一节点显示：

- 来源；
- 生成器；
- revision；
- 最后修改者；
- 是否锁定；
- 输入与输出；
- 覆盖关系；
- 被哪些 Operation / Run 使用。

### 9.2 七个视图

- **来源**：真正可维护的结构化对象；
- **生效文本**：某次 Build 的完整 prompt；
- **上下文**：一次调用的全部有序 segment、tool manifest、compaction 与 provider rendering；每项同时显示来源与 immutable payload snapshot；
- **差异**：两版 Build 或来源 revision 的变化；
- **历史**：何时、为何、由谁生效；
- **测试**：固定场景下的行为与回归。
- **生成器**：该层由哪个 generator、template revision、输入 schema 与验证过程生成；同时显示无环依赖图。

生成块允许：

- 重新生成；
- 固定当前版本；
- 添加受控 override；
- 修改生成规则；
- 回滚。

不可直接修改历史 Effective Build；否则审计失真。

一个 Change Set 若修改 generator，不得同时修改用于批准它的 validator、judge、evaluation suite 或 activation policy。界面应锁定本次验收依赖，并明确显示「由变更前的哪些 revision 验收」。

激活前显示 frozen dependency closure 与 `expectedActiveRevisionSet`；若后台已有新 revision 生效，本次提案退回重测，不覆盖。Evaluation 标明 frozen fixture、sandbox 与空副作用 receipt。

### 9.3 默认编辑层级

用户表达的是意图，系统负责选择最低充分层：

| 用户意图 | 默认落点 |
| --- | --- |
| 所有 Yuki 都必须遵守 | Root Constitution proposal |
| 这个方向长期这样做 | Charter / Playbook proposal |
| 记住一个事实或偏好 | Memory Mutation |
| 这次任务这样做 | Task Contract |
| 当前步骤临时这样做 | Run guidance |
| 临时 Worker 这样做 | Delegation Spec |

提交时明确告诉用户「这次修改会影响哪里」，避免无意间把局部纠偏写成人格。

---

## 十、Capabilities 与 Orchestration

### 10.1 能力不是工具开关表

Capability 页面描述真实能力：

```text
能力
├── 工具：是否可用、作用域、健康、权限边界
├── 模型：适用任务、限制、当前预算
├── Workspace：可读写范围与环境
├── Playbook：已验证的方法
└── Tool Heuristics：成功条件与失败记忆
```

单个工具显示：

- 当前状态；
- 输入与副作用；
- 适用 / 不适用场景；
- 最近成功与失败；
- 使用它的任务；
- 来源于 Root Kernel 还是分身配置；
- 当前分身的偏好与禁用规则。

### 10.2 编排策略

分身有可审计的 Orchestration Policy：

- 何时先独立调查；
- 何时并行拆分；
- 何时需要不同视角；
- 何时由 Coordinator 自行完成；
- 最大深度、并发与预算；
- 哪些 memory scope 可租给 Worker；
- Worker 可否调用哪些工具；
- 如何验收与合并；
- 何时停止。

它由 Root Kernel 的默认策略生成，分身可通过提案形成局部偏好。

### 10.3 委派不是新分身

Worker 默认是临时执行者：

- 无独立长期身份；
- 无分身私有记忆写权限；
- 获得明确的 `Delegation Spec`；
- 只回交结果、证据与 memory candidates；
- 生命周期随任务结束。

若某类 Worker 反复出现并积累稳定使命、方法与私有记忆需求，系统可以提议：

> 将「文献审校」晋升为新的 Yuki 分身？

这必须经用户确认，不能由一次委派静默生成。

---

## 十一、自我管理与演化收件箱

### 11.1 分身可自行维护

分身可自动完成低风险、可逆的整理：

- 提取 observation；
- 合并重复 episode；
- 更新使用次数与显著性；
- 标记可能过时；
- 形成 procedural candidate；
- 维护开放承诺；
- 记录工具失败模式。

### 11.2 必须审阅的变化

以下进入 Evolution Inbox：

- Charter 修改；
- Root Shared Memory 修改；
- 新的稳定方法或工具禁令；
- 分身间迁移 Memory；
- Capability / Orchestration Policy 改变；
- 自动创建、合并或删除分身；
- 大量归档或重写稳定记忆。

### 11.3 提案卡

```text
示例提议：在产品分析前先核对运行证据

原因
  仅观察 UI 容易误判真实执行结构。

拟修改
  Playbook / 产品分析 / 第一步

证据
  待附 Task 与审计记录

影响
  今后相关任务会先运行 usage audit；预计增加一次只读检查。

[接受] [修改后接受] [暂不] [拒绝并记住原因]
```

「拒绝并记住原因」本身可形成一条关系或程序性记忆，防止同一提案反复出现。

---

## 十二、关键流程

### 12.1 创建一个 Yuki

不是从空白 system prompt 开始。

1. 用户描述方向、期望与不喜欢的做法；
2. 选择可挂载的共享或项目 Memory Pack；
3. Root Kernel 的已登记 Bootstrap Generator 生成初稿：
   - 名称与使命；
   - Charter；
   - 初始 Memory Policy；
   - Capability Profile；
   - Orchestration Policy；
   - Playbook 候选；
   - 正例与反例；
4. 用户审阅摘要与关键 diff；
5. 系统使用预先 active 的 onboarding suite 与用户原始正反例运行 Evaluation；
6. 激活首个 revision。

用户可以展开全部生成 prompt，但不需逐层手写。

Bootstrap 生成的 Evaluation case 只是 staged proposal，不得反过来验收同一次 Bootstrap；最早从下一 Change Set 生效。

### 12.2 交付一个意图

1. 当前分身接收输入，写入 `IntentEnvelope` 并打开 `IntentTransaction`；
2. 已登记的 route Operation 在 `direct / memory / self / work / system` 中选择路径；
3. 页面显示路由、理由与目标，用户可在执行前纠正；
4. Prompt Compiler 固定 incarnation、memory、capability 与 policy revision；
5. 按路径执行：
   - `direct`：生成无 Task 的 Direct Run，在「此刻」返回 Outcome；
   - `memory`：打开 Memory Mutation diff；
   - `self`：打开 Evolution Proposal；
   - `work`：继续旧 Task 或创建新 Task，再编译 Task Contract 与 Work Graph；
   - `system`：进入明确的 Root Kernel 控制操作；
6. 所有路径写入 Experience Event；只有 work route 写入 Thread。

页面留在「此刻」，以「唤起的记忆 → Outcome → 留下的变化」完成事务；只有用户主动钻取时进入 Work。

自动路由必须显示：

> 已创建新任务，因为该意图目标独立、不会共享当前任务的未决状态。
> 使用的是「研究者 Yuki」；私有记忆与「项目 YUKI.N」挂载包已载入。

用户可纠正路由，纠正可成为该分身的关系记忆候选。

Direct Outcome 不形成聊天列表。用户可以：

- 继续追问：发送新的 Intent，并引用当前 Outcome；
- 固化：保存为 Memory；
- 扩展：转成 Task；
- 离开：仅保留事件与必要派生物。

### 12.3 任务收束

1. 生成结果；
2. 对照 Task Contract 验收；
3. 收拢 Worker 结果；
4. 关闭或保留 Commitments；
5. 生成 Memory Read / Change Receipts；
6. 提交低风险派生物；
7. 将高风险自我变化送入 Evolution Inbox；
8. Thread 进入已收束，但分身继续存在。

### 12.4 回来继续

恢复的不是 Transcript，而是当前分身：

- Self Manifest；
- 相关 Memory View；
- 活跃 Commitments；
- 目标任务的 Task Brief；
- 最近结果；
- 必要的近尾证据。

原 Transcript 可查，但不作为恢复连续性的唯一来源。

---

## 十三、Root Kernel 控制面

Root Kernel 是系统平面，不是另一个聊天人格。界面可简称「Root」，领域对象不得省略 Kernel。

### 13.1 页面

- **Constitution**：所有分身共同遵循的根律；
- **Incarnations**：注册、派生关系、状态与 revision；
- **Shared Memory**：跨分身显式共享的稳定内容；
- **Capabilities**：工具、模型、workspace 与健康；
- **Prompt Compiler**：模板、生成器、优先级与测试；
- **Orchestration**：全局预算、并发、深度与委派约束；
- **Audit**：跨分身事件与不可变 Build；
- **Migration**：旧 Thread、Fact 与 Prompt 的归属处理；显示 ledger、provenance quality、失败恢复与待分类项。

### 13.2 Root Kernel 的可见性

Root Kernel 提供全量审计，但日常不抢占导航：

- 左轨底部固定入口；
- 有全局错误或高风险提案时显示状态；
- 分身页可深链至 Root Kernel 来源；
- Root Constitution 或 Kernel Policy 修改总以影响范围与受影响分身呈现。

---

## 十四、视觉与交互语言

### 14.1 视觉主语

保留现有深色、青绿、琥珀、红的克制语义，但改变权重：

- 分身名称、使命与当前状态最大；
- Memory 与自我变化高于消息；
- Result 高于执行细节；
- Worker 图高于工具日志；
- Transcript 与 raw event 最低。

每个分身可有一个克制的识别色或字形，只用于切换与定位，不把产品做成角色收藏界面。

### 14.2 状态颜色

- 青绿：已确认、可用、完成；
- 琥珀：候选、等待、可能过时；
- 红：失败、冲突、越界；
- 蓝灰：运行时事实；
- 紫灰：由系统生成、尚未由用户确认。

颜色不单独承载语义，均配文字或图形。

### 14.3 密度

- 正文不低于 14px；
- 元数据不低于 12px；
- 高信息密度使用分组、缩进与留白，不靠 8px 小字；
- 避免所有对象都成为等权边框卡片；
- Diff、谱系与 Work Graph 使用专门视图，不塞进窄侧栏。

### 14.4 窄屏

产品仍以桌面为主，但不允许功能消失：

- 分身左轨收为顶部切换器；
- 一级导航横向滚动或进入抽屉；
- 双栏工作区切成 list → detail；
- Work Graph 变为缩进时间线；
- Prompt Graph 变为可展开层级；
- Composer 与当前路由标签始终可见；
- Root 与高级检查进入菜单，而非隐藏。

### 14.5 键盘

- `⌘K`：跨分身、Memory、任务与命令搜索；
- `⌘J`：切换分身；
- `⌘N`：向当前分身交付新意图；
- `⌘⇧N`：创建分身；
- `⌘↵`：提交；
- `⌘.`：中止当前 Run；
- `⌘⇧P`：打开当前 Prompt Build；
- `⌘⇧M`：打开本次 Memory View / Receipt。

---

## 十五、前端所需投影

前端不得从 Transcript 猜出领域状态。

### 15.1 Incarnation Summary

```text
IncarnationSummary
├── id / name / mark / mission
├── state
├── charterRevision / selfRevision / memoryRevision
├── capabilityRevision
├── activeCommitments / activeTasks / activeWorkers
├── latestEvolution
└── attention
```

### 15.2 Self Manifests

```text
IncarnationManifest
├── normativeSelf
├── experientialSelf
├── capabilitySnapshot
├── commitments
├── activePolicies
├── promptProgramRevision
└── generatedAt

ActorManifest
├── actorId / incarnationId / actorKind / lineage
├── intentId / taskId? / runId
├── operationId / promptBuildId
├── memoryScopes / capabilitySnapshot
└── executionPolicy

KernelActorManifest
Commitment / CommitmentChangeSet
PlaybookRevision
```

### 15.3 Memory Projections

```text
MemorySearchResult
MemorySpace
MemoryMount
MemoryRecordDetail
MemoryLineage
MemoryMutation
MemoryView
MemoryReadReceipt
MemoryChangeReceipt
IncarnationLivingModel
ContextSynthesis
```

所有对象必须携带 `incarnationId`、scope、revision 与 provenance。

### 15.4 Prompt Projections

```text
PromptTemplate
PromptRevision
GeneratorRevision
GeneratorInvocation
ValidatorRevision
ValidationRun
EvaluationSuiteRevision
EvaluationRun
ActivationPolicyRevision
ChangeSet
PromptBuild
PromptSegment
ContextBuild
ContextSegment
ModelInvocationSnapshot
PromptDiff
PromptEvaluation
```

`PromptBuild` 绑定指令 source revisions；`ContextBuild` 再绑定：

- incarnation revision；
- memory view；
- capability snapshot；
- task / run / delegation spec；
- tool manifest、experience cursor 与 compaction；
- context compiler revision。

`ModelInvocationSnapshot` 再绑定 model、参数、provider adapter 与最终 request hash。

### 15.5 Intent / Operation Projections

```text
IntentEnvelope
IntentTransaction
RouteDecision
DirectRun
DirectOutcome
IntentChangeSet
Operation
KernelOperation
```

`taskId` 对 Direct Run 为空。前端不得为适配旧 Session API 伪造 Thread。

### 15.6 Work Projections

```text
Commitment
TaskSummary
TaskContract
RunProjection
WorkGraph
DelegationSpec
DelegationAmendment
DelegationInvocation
MemoryLease
ToolGrant
WorkerSubmission
WorkerExecutionReceipt
AcceptanceAttempt
AcceptanceDecision
MergeDecision
WritebackReceipt
Result
ArtifactRef
MemoryReadReceipt
MemoryChangeReceipt
```

活跃状态来自 runtime；历史状态来自持久事件投影。SSE 断开后通过 revision cursor 恢复，不以当前页面内存作为事实来源。

---

## 十六、保留、重构、移除

### 16.1 保留

- Markdown 与代码渲染；
- diff；
- 工具确认；
- Artifact 外置与回取；
- Journal / Replay；
- AG-UI 事件流；
- 当前配色基因；
- cwd 沙盒；
- Run 与 child Run 的基础事件。

### 16.2 重构

- Session → Task，并归属 Incarnation；
- ThreadBrief → Task Brief / Episode；
- global Facts → scoped Memory Spaces；
- system prompt 字符串 → Prompt Program / Build；
- `sub_agent(prompt)` → Delegation Spec / Invocation + Work Graph；
- 工具开关 → Capability Registry 与 Policy；
- watcher → Experience Event 驱动的 consolidation；
- 审计三栏 → 对象内检查 + Root Kernel Audit。

### 16.3 移除

- Transcript 作为首页；
- 工作 / 配置 / 审计三顶级后端映射；
- 右栏承担全部任务管理；
- giant system prompt textarea；
- 无来源的「AI 记忆」；
- child 直接污染父任务或分身 Memory；
- 将最终回答埋在数万像素过程末尾；
- 窄屏直接隐藏核心能力。

---

## 十七、首版默认决策

- **分身按方向建立，不按项目建立。** 项目是 workspace 与 Memory Pack；只有方向形成稳定的判断、风格与方法时才值得成为分身。
- **Shared 默认不共享。** 共享库须显式 mount；只有用户标记为 universal pinned 的少量内容进入全部分身。
- **Intent 默认从轻。** 简单询问、纠正与解释走 direct / memory / self；只有持久目标、承诺、后台执行、Work Graph 或多轮验收才进入 Task。
- **Charter 与稳定行为变化默认审阅。** 可重建索引、摘要、低风险标签与显著性可自动提交。
- **Worker 默认无长期记忆。** 它只能提交证据、结果与 Memory Candidate；反复出现的持久角色由用户决定是否晋升为分身。
- **空闲维护只做内部、可逆工作。** 不在没有当前明确 Intent 时触发外部副作用。
- **用户编辑 source，不编辑历史 Build。** 所有有效文本、Context 与 generator 均可查看；直接修改产生新 revision。
- **当前事务不跳页。** 「此刻」完成记忆唤起、Outcome、变化确认；Work、Prompt 与原始事件只供钻取。

这些是本地单用户工具的行为默认值，不是权限或多用户设计。

---

## 十八、实施顺序

### M0：Kernel bootstrap 与审计底座

- Operation / actor；
- Experience Event envelope；
- immutable payload snapshot；
- 最小 Prompt Template / Revision registry；
- Prompt Build / Context Build / Model Invocation 管线；
- 冻结的 Router、Bootstrap、Curator 与 Judge 模板。

验收：包括内部 generator 在内，任一模型请求均有 operation、template revision 与完整可解引用 request snapshot。

### M1：领域主体、Intent 与 Memory

- Incarnation / actor ownership；
- IntentTransaction 与可空 `taskId`；
- Memory Space / Mount / View / Record / Mutation / Receipts；
- default-yuki 与 versioned MigrationLedger；
- legacy facts 进入默认分身隔离区，briefs 只作低置信 candidate；
- global Artifact blob 保持去重，以 ArtifactRef 重新建立 provenance。

验收：关闭全部 Thread 后，分身仍完整呈现自我、记忆、能力与承诺；Intent 可从事件恢复。新 model-assisted Direct 尚不启用。

### M2：完整 Prompt compiler 与新执行

- Root Constitution、Charter、Policy Bundle 与 Playbooks；
- Incarnation / Actor / Capability / Memory snapshots；
- 完整 generator DAG、GeneratorInvocation、ValidationRun、EvaluationRun 与 CAS activation；
- source graph、diff、history、sandbox evaluation 与 replay；
- 禁止 Thread 整段覆盖 Root Constitution；
- 验收后启用 model-assisted Router、Bootstrap 与 Direct Run。

验收：任一模型请求均可解释每段 instruction、context 与 tool schema 的来源；修改来源后可预览差异并回滚。

### M3：Self-management

- Incarnation Manifest / Actor Manifest；
- consolidation loop；
- Evolution Proposal；
- 自动与待审策略；
- Playbook 晋升；
- evaluation 与 rollback。

验收：分身可认识自己的来源、能力、承诺与限制；稳定行为变化均有提案或明确自动策略。

### M4：Capabilities 与 Orchestration

- Capability Registry；
- Delegation Spec / Invocation；
- spawn / list / wait / cancel / merge；
- Work Graph；
- versioned amendment、Memory Lease、Tool Grant、验收、合并与写回回执；
- 编排决策与理由事件。

验收：分身能自主并行委派，Worker 不污染长期 Memory，结果可按契约验收。

### M5：前端壳层

1. 分身切换器与「此刻」；
2. Memory Workspace；
3. Work / Result / Work Graph；
4. Self 与 Prompt Studio；
5. Capability 与 Evolution Inbox；
6. Root Kernel 控制面；
7. 旧三视图仅保留迁移期深链，随后删除。

UI 原型可以先用假数据验证，但不得反过来固化缺失的领域模型。

---

## 十九、验收场景

### 场景 A：跨任务仍是同一个它

用户关闭旧任务，一周后向同一分身提出新问题。它通过自己的私有记忆、共享挂载与承诺恢复方向；无需继续旧聊天。

### 场景 B：两个分身真正不同

「研究者」与「写作者」面对同一素材，因 Charter、私有经验与 Playbook 不同而采取不同路径；共享事实保持一致，私有判断不会互相污染。

### 场景 C：用户不手写层层 Prompt

用户说「以后先给结论，除非我要求，不要铺陈过程」。系统将其定位为该分身的表达倾向，生成 Charter diff、运行回归并提交 revision；完整 Effective Prompt 仍可审计。

### 场景 D：分身自动委派

任务包含三个相互独立的审计面。分身自动创建带角色、预算、memory lease、工具与验收条件的 Worker，前端显示 Work Graph 与委派理由；用户无需手动创建三个聊天。

### 场景 E：工具使用来自自知

分身知道当前是否具备浏览器、shell 与文件写入能力，并依据 Tool Heuristics 决定使用顺序。工具不可用时，它更新现实自我，不假装仍有能力。

### 场景 F：一次经历改变了它

任务暴露了稳定方法缺陷。分身形成 Playbook proposal，列出证据、影响与测试；用户接受后，未来 Prompt Build 自动包含新方法，旧 Build 仍可复现。

### 场景 G：Transcript 只是证据

用户从一条记忆、结论或自我变化追溯到任务、Run、Worker、工具结果与原始消息；返回后仍停留在分身的 Memory 或 Self，而非被迫继续对话时间线。

### 场景 H：一次询问不是一个任务

用户问「你目前如何理解这个项目」。分身直接依据 Self 与 Memory 回答，不创建 Thread；用户若要求据此展开完整重构，才将新意图路由为 Task。

### 场景 I：Direct 也可恢复

Direct Outcome 生成后仍有两条 Memory Mutation 待审。用户刷新页面，Intent Transaction 仍恢复 Read Receipt、Outcome、pending changes 与 `awaiting_review`，不依赖隐藏 Session。

### 场景 J：生成器不能自证

分身提议修改 Reflection Generator 与一组新回归题。系统只用变更前冻结的 validator、suite 与 judge 验收 generator；新回归题进入下一 Change Set。

### 场景 K：Worker 返回不等于完成

Worker 已提交结果，但一项 acceptance check 失败。Work Graph 显示 `revision requested`，而非完成；新 Spec attempt 通过、合并并写回后节点才闭合。

---

## 二十、最终判据

若移除全部 Transcript，产品仍应能够回答：

- 这个 Yuki 是谁；
- 它记得什么，证据何在；
- 它能做什么，限制何在；
- 它正在承担什么；
- 它为何这样行动；
- 最近什么经历改变了它；
- 下一次任务会如何继承这些变化。

若不能，Memory 仍未成为产品形态。
