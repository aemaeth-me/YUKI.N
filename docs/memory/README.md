# YUKI.N 记忆子系统设计

> 本目录是对 YUKI.N 中「印象」（Impression）与「记忆」（Memory）子系统的完整设计文档，
> 位于项目 `docs/memory/`，是认知体系（`../cognition-design.md`）中的记忆部分；
> 概念级架构见 `../incarnation-design.md`。
> 全部内容基于 `../../src/Yuki/N/` 下的实现源码提炼，附模块路径、类型名、常量与机制说明。

## 文档索引

| 文档 | 内容 |
|------|------|
| [01-印象.md](01-印象.md) | 印象层：子意识线索（激活）与印象固化（巩固）的完整设计 |
| [02-工作记忆.md](02-工作记忆.md) | 工作记忆：Focus Frame、睡眠-清醒状态机、Wake Packet、检查点 |
| [03-长期记忆.md](03-长期记忆.md) | 长期记忆：不可变任务档案、可修订记忆库、经验流、线程简报 |
| [04-生命周期.md](04-生命周期.md) | 跨层数据流、Agent 钩子集成、并发控制、恢复与迁移 |
| [05-演进方向.md](05-演进方向.md) | 2026-08 讨论纪要：召回/cue 生成、SQLite 三轨检索、评测体系、演进路线图 |

> 领域调查与演进依据见 `../research/`（Agent Memory 现状综述）。

## 设计总览

YUKI.N 的记忆系统不是单一数据库，而是一组**分工明确、单向依赖的存储层**。其核心立场写在
Root Constitution（`../../src/Yuki/N/Cognition.hs`）中：

> - 当前上下文是工作短期记忆。拥挤、混乱或需要干净续接时调用 `sleep`。
> - 本化身不可变的 Task Archive 是它的长期记忆。派生摘要永远不能取代原始证据。
> - 长期记忆是一种能力，绝不是环境注入（prompt injection）。
> - 印象线索是潜意识、非事实的提示，未经 `memory_grep`/`memory_read` 验证不得当作回忆的事实。
> - 不存在「手动把一句话变成记忆」的动作：完成工作就自动写入原始 Task 记录。

### 五层结构

```
┌─────────────────────────────────────────────────────────────┐
│ 1. 经验流 Experience（append-only 事件日志，唯一事实源）       │
│    experience/… 每化身一条流，顺序号连续，负载存 Blob          │
└─────────────────────────────────────────────────────────────┘
        │ 写入                        │ 读取（光标）
        ▼                             ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. 任务档案 Task Archive（不可变原始记录，长期记忆本体）        │
│    task-archive/index.json + Blob 内容；按化身×任务分域，      │
│    memory_grep / memory_read 直接扫描它                       │
└─────────────────────────────────────────────────────────────┘
        │ 追加（run 结束）            ▲ 检索（工具）
        ▼                             │
┌─────────────────────────────────────────────────────────────┐
│ 3. 工作记忆 Working Memory（短期，睡眠-清醒循环）              │
│    working/working.json；Focus Frame 每任务一个；             │
│    睡眠产出 Wake Packet（派生短期检查点）                      │
└─────────────────────────────────────────────────────────────┘
        │ 固化请求（经验事件驱动）      │ 注入（上下文）
        ▼                             ▲
┌─────────────────────────────────────────────────────────────┐
│ 4. 印象 Impression（潜意识倾向，非事实）                       │
│    impressions.json；激活产出 cues 注入上下文；                │
│    固化更新 ≤24 条印象，版本化 CAS 提交                        │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. 记忆库 LongTerm（可修订索引，仅 HTTP API 使用）              │
│    long-term.json；private/shared 可见性；版本历史；           │
│    代理不直接使用——它不是证据，是人工可维护的索引               │
└─────────────────────────────────────────────────────────────┘
```

另有旧版轻量机制 `ThreadBrief`（`../../src/Yuki/N/Memory.hs`）——每线程滚动摘要 + 事实缓存，
被重设计后的认知层所取代，但回放（Replay）仍依赖它做确定性还原。

### 核心原则

1. **证据不可变，摘要可修订。** 原始对话、工具结果按 run 追加进 Task Archive，只增不改；
   任何派生物（印象、Wake Packet、摘要、记忆库条目）都带版本号，可被新版本覆盖。
2. **记忆是能力，不是注入。** 模型必须主动调用 `memory_grep`（确定性固定串扫描）找到
   证据条目，再 `memory_read`（有界窗口）验证后才可依赖。没有任何机制把长期记忆自动塞进上下文。
3. **印象非事实。** 印象由独立模型在低预算、受控 prompt 下生成，只表达「倾向、显著性、
   解读习惯」，禁止存储关于工具/系统行为的事实性诊断（代码里有一份中文+英文禁用词表）。
4. **子意识与意识分离。** 激活模型（产生线索）与固化模型（更新印象集）是两次独立调用、
   独立 prompt revision（`impression-activation/v2`、`impression-consolidation/v3`），
   都通过 `Invocation` 框架记录 journal、限时、限输出。
5. **一切状态机化。** 工作记忆的睡眠-清醒是一个显式状态机（awake→quiescing→asleep→waking→awake，
   外加 degraded），每个迁移都做 revision 乐观锁校验；中断后由 `cognitionRecover` 按状态机恢复。
6. **预算与绝缘。** 记忆钩子全部包在 `insulate`/`shield` 里——记忆失败绝不破坏主对话；
   每个量都有硬上限（印象 ≤24、cues ≤5、候选 ≤1200 字符、检索预算每 run 3 次、冷却 5 轮……）。

### 关键文件

| 模块 | 职责 |
|------|------|
| `../../src/Yuki/N/Memory/Impression.hs` | 印象状态、激活、固化、校验、存储 |
| `../../src/Yuki/N/Memory/Working.hs` | 工作记忆头、Focus Frame、睡眠循环状态机 |
| `../../src/Yuki/N/Memory/Archive.hs` | 任务档案：追加、grep、read、目录 |
| `../../src/Yuki/N/Memory/LongTerm.hs` | 记忆库：remember/grep/read/void/space/receipt |
| `../../src/Yuki/N/Memory.hs` | 旧版线程简报 + 事实 watcher（memoryHooks） |
| `../../src/Yuki/N/Experience.hs` | 经验流（append-only 事件日志） |
| `../../src/Yuki/N/Cognition.hs` | 认知层：钩子编排、睡眠、固化队列、工具、恢复 |
| `../../src/Yuki/N/Incarnation.hs` | 化身与提示词谱系（印象模型可配置） |
| `../../src/Yuki/N/ContextEpoch.hs` | 上下文纪元（睡眠保留段的投影依据） |
| `../../src/Yuki/N/Invocation.hs` | 模型调用框架（限时、限输出、journal 记录） |

### 存储文件一览

| 路径（相对数据目录） | 内容 |
|------|------|
| `events/events.jsonl` | 经验事件流（追加写） |
| `task-archive/index.json` | 任务档案索引（条目元数据） |
| `task-archive/*.blob` | 条目内容（Blob 存储） |
| `working/working.json` | 工作记忆头、检查点、Wake Packet、睡眠循环 |
| `impressions.json` | 印象状态、激活记录、修订记录 |
| `long-term.json` | 记忆库空间、记忆版本历史、读取回执 |
| `threads/*.json` | 旧版线程简报 |
| `facts.jsonl` | 旧版事实缓存 |
| `journal.jsonl` | run 审计日志（所有模型调用与事件） |
