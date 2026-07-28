# YUKI.N Memory 体系设计

> 状态：底层 memory / cache 机制与历史实现说明。
> 身份、作用域、自我管理与 Prompt 治理以 `docs/incarnation-design.md` 为权威；
> 清醒 / 睡眠 / 长期记忆 / 印象的实现以 `docs/cognition-design.md` 为权威。
> 冲突时以后者为准。

本文保留 artifact、cache、rollup 与 briefing 的机制设计。原文以 Thread 为长寿主体，
是分身模型建立前的过渡假设；其中 facts / scoped memory / rollup 均只算派生索引，
不再承担长期记忆本体。

## 背景与判据

传统 agent 以 session（多轮对话 transcript）为本体。本设计反转之：**transcript 是渲染，memory 是本体**。chat completions API（对话形状、无状态、逐字重放）只是被迫使用的基底层（L0），置于其上的回路层（L1，已有的 run/tools/journal/replay）与记忆层（L2，本设计）才是真架构。

四条不可违约束（历轮批判的沉淀）：

1. transcript 是渲染；同一分身全部 Task 的原始结构化 Archive 才是长期 memory 本体。
2. run 内 transcript 只增不改，天然全命中 provider prefix cache；任何中段拼接皆 cache bust，须按 epoch 摊销。
3. 内容按可寻址性分流：可再取的大宗（工具返回，先验 60–85%）外置；不可再取的实质（决定、对话）辊压；可弃的（reasoning 轨迹）政策丢弃。
4. 先测量，后预算。一切阈值待 token 解剖报告（步骤 0）。

## 模型：incarnation × intent × task(thread)? × run

「多轮 session」拆为三个不同寿命之物：

**Incarnation**（长寿，本体）：跨任务持续存在的 Yuki 分身。拥有规范自我、私有记忆、挂载记忆、能力、承诺与可追溯演化。

**Run**（短寿，已有）：一次执行。可直属分身处理即时 Intent，也可属于某个 Task。渲染即逐字 transcript，append-only，继承天然 cache 命中。memory 在此仅三事：工具返回落地即哈希（去重）、检索注入走固定槽位、逼近窗口时头部 epoch splice（辊压与外置共用一次 bust）。

**Thread / Task**（中寿、可选）：只有持久工作才创建，可跨多个 Run。只拥有任务局部连续性，不拥有分身的人格或全部长期记忆。

```
原件      = append-only Task Archive Entry
            （同一 incarnation 的全部 Task，含已归档 Task；task/run/entry identity、provenance）
审计      = append-only Experience Event
            （真时间、incarnation/thread/run/worker scope、operation 与 lifecycle）
派生态    = artifacts（原文 Blob，content-addressed）
          + rollups（轮→episode→日→项目，多粒度摘要树，带 provenance 与时段）
          + distilled index（身份、事实、方法、默契、承诺、经历；带 archive 来源与 revision）
```

「回到分身」无 session 可续，只有一次**上下文编译**：新 Run 启动时从 Root Kernel、分身、挂载包、可选任务与 Run scratch 渲染 Memory View。连续性来自分身记忆，不来自 replay 的惯性。

## 长期记忆原件与取回

Task Archive 的长期证据提交边界是：已接受的用户输入、已提交的 assistant 结果、已提交
的工具结果。instruction、tool call、reasoning 若随已闭合记录保存，只是因果审计辅项。
流式 delta、半截 reasoning、未完成工具输出只写 Run Journal；闭合前不得进入 Archive。

Archive 以 `incarnationId` 隔离；同一分身的检索默认覆盖全部 Task，Task 的归档状态不
改变可见性。原始 Archive 不 mount、不跨分身共享。

取回协议固定为：

```text
memory_grep(literal query, optional task/kind/case/limit)
→ bounded task/run/entry excerpts
→ memory_read(exact entryId, offset/chars/before/after)
→ bounded evidence window
```

`memory_grep` 不做 embedding 或语义扩写；`memory_read` 不提供无上限全文。未走这条链，
Archive 正文不得自动注入模型。rollup、facts、Memory Record 与 Living Model 都可从
Archive 重建；纠错写后续证据，派生索引可 revise / void，但不能改写原件。

## Tool result 与 cache（三层）

prefix cache 的律：入过 transcript 的内容自下一轮起为 prefix，全命中。故 tool result 落地轮付全价（模型必须读，不可免），此后命中价续命。真浪费仅二：重复、占窗。对策三层：

1. **落地即入 prefix**：返回照常内联全文（尾部 append），此后继承命中。
2. **落地即哈希，重复即引用**：content hash 入 artifact store；与既有 artifact 相同则不内联第二份——原文在逐字区指「同上 #id」，已出逐字区指存根。重复内容零重付、零占窗。
3. **衰老即外置，需要即回取**：逐字区只保最近 K 轮全文；更老的在 epoch 头部 splice 时整批换存根+头部摘录（约 50 token），原文已在 store。回取 `artifact.read(id)` 作为新工具返回追加于尾——全价一次，复归命中。摘录常已够用，回取多不发生。

外置与辊压共用同一次头部 splice：一次 bust 摊两笔账。

跨 run：provider cache 有 TTL 不可恃；**artifact store 即 tool output 的应用层缓存**——content-addressed、跨 incarnation/run/thread 持久。新 run 简报只带授权作用域内的 artifact 索引（id+类别+摘录+时间）。

## Derivation（纯机 + 驱动，全部 journaled）

| 派生器 | 产出 | 驱动 | 触发 |
| --- | --- | --- | --- |
| archive committer | immutable Task Archive closure | 纯代码 | accepted user / committed assistant / committed tool result |
| externalizer | artifacts + 存根/引用 | 纯代码 | 工具返回落地（去重）；epoch splice（外置） |
| rolling watcher | episode 摘要、rollup 升级 | 廉价模型（flash 级，第二 provider 配置） | 轮边界 / episode 关闭 |
| derived curator（legacy / optional） | 可重建提炼候选（带 archive refs） | 同上 | 闭合后，宁缺 |
| impression activation | literal grep 线索（非事实） | 专门模型 | Intent 首次调用前 |

watcher 非「第二 session」，是廉价模型驱动的归约器：小状态进、结构化 JSON 决策出。
它的历史 `memorize?` 输出只算 derived candidate；不得写 Task Archive，也不得由
Impression consolidation 代为生成。理由必填，全部入 journal 子 scope，可回放可 A/B。

## Briefing（投影，两处两形）

> 以下是旧 watcher 时代的历史投影。`cognition-v2` 不再自动注入 Memory View 或
> thread brief；当前规则是 Impression 只给 cue，Task Archive 正文须先经固定字符串
> `memory_grep` 定位，再经有界 `memory_read` 主动取得。

- **run 内**：退化为 append；唯存根化与槽位注入。
- **run 开场**：真投影，按挥发性分层（比例诚实，大宗已外置）：

```
[ Root Constitution      ] 稳定 prefix
[ Incarnation Charter    ] 分身规范自我
[ Self/Capability Snapshot ] 当前现实自我
[ Memory View            ] 带 scope 与 provenance 的检索投影
[ Task Contract + Brief  ] 仅 work route；本任务目标、决定与开放问题
[ 近尾证据               ] 必要的存根化逐字尾
[ 本轮输入               ] 当前事件
```

每块带标记，无一处伪装现场发言；简报时效以一行 `as of`（最新 episode 时间）注入。

## 不变式

1. Append-only：Task Archive 不突变；纠错写后续记录（bitemporal 留地平线）。
2. run 内渲染 append-only；除头部 epoch splice 无中段扰动。
3. 存根必达：可解回 immutable artifact。
4. 无为为省：watcher 跳过无需理由，取与写须附理由，理由入 journal。
5. 自盲：watcher 观察投影滤掉自己的注入。
6. 预算封顶：每 run 检索次数、每轮注入 token、同 query hash 冷却。
7. Task 归档不删除其 Archive；跨分身 grep 不命中。
8. 所有提炼记录均可删除后由 Archive 重建。

## 阶段

| 步 | 内容 | 依赖/验收 |
| --- | --- | --- |
| 0 | token 解剖器：扫 journal 按类别出占比（system/工具定义/用户/正文/推理/工具返回） | 已有 journal；报告驱动全部阈值 |
| 1 | artifact store + 存根化：content-hash store、落地去重、epoch 外置、`artifact.read` 工具 | 0 定阈值；测试覆盖去重/回取 |
| 2 | episode rollup watcher + 开场简报：廉价模型派生、thread 首续 | 1；假模型驱动测试 + 回放对账 |
| 3 | facts + read 裁决 + 检索槽位（legacy，待迁至 scoped Memory Space） | 2 |
| 4 | 遗忘/逐出、bitemporal 修正、workbench 可视化 | 3 |

## 已定与待定

已定（本轮拍板，可复议）：timeline 与 journal 分流（journal 守审计、timeline 守记忆，共享底材）；存根带固定预算的头部摘录；episode 以 run 边界为单位起步。

待定（解剖报告后定）：外置大小线、K（逐字区轮数）、摘录行数、注入 token 上限、检索冷却。
