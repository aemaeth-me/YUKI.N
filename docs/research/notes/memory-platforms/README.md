# 记忆平台调研：Memory-as-a-Service 与记忆基础设施（2026-08）

> 调研背景：为我们的 Agent 项目设计 Memory 体系。本笔记覆盖【记忆平台/创业公司】部分。
> 全部基于官方第一手资料（官网/官方文档/官方博客/论文 arXiv/官方 GitHub），并已 websearch 交叉确认 2025-2026 最新状态。
> 原始资料见 `../sources/memory-platforms/`。

---

## 0. 一句话速览（每平台方案）

| 平台 | 一句话 | 官方入口 |
|---|---|---|
| **Mem0** | 通用记忆层中间件：ADD-only LLM 抽取结构化事实 + 多信号检索（semantic/BM25/entity/temporal），托管或自托管，AWS Agent SDK 独家记忆伙伴，$24M | [mem0.ai](https://mem0.ai) · [docs](https://docs.mem0.ai/core-concepts/how-it-works) · [arXiv 2504.19413](https://arxiv.org/abs/2504.19413) |
| **Letta（原 MemGPT）** | Stateful agent 运行时：memory blocks（context 内可编辑记忆）+ recall/archival 分层 + Sleep-Time Compute（离线"做梦"重整记忆），2026 转向 git 版记忆的 Letta Code | [letta.com](https://www.letta.com) · [docs](https://docs.letta.com) · [sleep-time](https://www.letta.com/blog/sleep-time-compute/) |
| **Zep（Graphiti）** | 企业级时态知识图谱记忆：双时态 fact（valid/observed 窗口）+ episode 溯源 + 自动事实失效，sub-200ms p95，托管 Context Lake，$500K | [getzep.com](https://www.getzep.com) · [arXiv 2501.13956](https://arxiv.org/abs/2501.13956) |
| **Cognee** | 开源记忆引擎：cognify 六段管线把文档→知识图谱（三 store：relational+vector+graph），14 种检索模式，v1 收敛为 remember/recall | [cognee.ai](https://cognee.ai) · [docs](https://docs.cognee.ai) |
| **Basic Memory** | 本地优先 Markdown 记忆：human+AI 双写同一批文件 + wikilink 知识图 + MCP，无抽取管线、完全透明 | [github.com/basicmachines-co/basic-memory](https://github.com/basicmachines-co/basic-memory) |
| **Supermemory** | 记忆/上下文引擎：自研 vector-graph + 自动 User Profiles + 混合检索，自称三基准 #1，$2.6M，主打低延迟与 consumer 转 infra | [supermemory.ai](https://supermemory.ai) · [github](https://github.com/supermemoryai/supermemory) |
| **Onyx（开源企业搜索）** | 附带 agent 自主记忆工具（LLM 决定 add/update，per-user cap 10 条，注入/写入开关解耦），$10M | [onyx.app](https://onyx.app) · [PR #8331](https://github.com/onyx-dot-app/onyx/pull/8331) |
| **MemoryLane** | 命名空间散乱的小项目：Claude JSONL 会话归档（jMyles）、通用记忆层营销站（memorylanehq.com）——边缘信号，非主流平台 | [memorylanehq.com](https://memorylanehq.com) |
| **Hyperbrowser** | 浏览器基础设施，非记忆平台；示例"BrowserBrain"（截图→视觉记忆→二次 recall）代表 recall-or-learn 缓存模式 | [github.com/hyperbrowserai](https://github.com/hyperbrowserai) |
| **Pinecone Nexus** | 知识引擎（不是检索器）：Manifest 策展 + 预编译 Artifact + KnowQL 声明式查询，把检索前移到"编译一次、多次查询"，BYOC | [pinecone.io/product/nexus](https://www.pinecone.io/product/nexus/) |
| **Weaviate Engram** | 向量库之上的托管 agent 记忆服务：自动抽取 + scopes 隔离/共享 + 可组合 pipeline | [weaviate.io/product/engram](https://weaviate.io/product/engram) |
| **Chroma Context-1** | 20B open-weights agentic search subagent：自我编辑上下文 + 多轮检索，比 frontier 快 10× 便宜 25× | [trychroma.com/research/context-1](https://www.trychroma.com/research/context-1) |
| **Neo4j agent-memory / KG Builder** | 图库厂商记忆方案：三层记忆（short/long/reasoning）+ POLE+O 图谱 + 审计边，GraphRAG 检索 | [github.com/neo4j-labs/agent-memory](https://github.com/neo4j-labs/agent-memory) |

---

## 1. 平台横向对比矩阵

| 维度 | Mem0 | Letta | Zep | Cognee | Basic Memory | Supermemory |
|---|---|---|---|---|---|---|
| **核心抽象** | 结构化记忆记录（fact 条目） | memory blocks + 消息/档案分层 | 时态知识图谱（entity/fact/episode/community） | 知识图谱 + chunk/DataPoint | Markdown 文件 + wikilink 图 | 记忆图 + User Profiles |
| **记忆模型类型** | 提取式（fact 抽取） | 文档/块式（agent 自编辑） | 图式（双时态） | 图式 + 向量混合 | 文档式（文件系统） | 向量图混合 + 自动画像 |
| **谁决定写什么** | 系统：`add()` 内 LLM 抽取 | Agent 自主（memory tools / filesystem）；sleep-time agent 后台重整 | 系统：ingestion 管线自动抽实体/fact | 系统：cognify 管线 LLM 抽实体关系 | Agent/人类显式写文件 | 系统：自动抽取记忆/画像 |
| **写路径** | Single-pass ADD-only，一次 LLM 调用，不覆盖 | agent 工具改 context 内 block（整体替换语义） | 实体抽取→resolution→fact→边失效（incremental） | classify→chunk→extract→summarize→embed→commit | 文件读写（无自动抽取） | 自动抽取 + connectors + 多模态抽取器 |
| **读路径** | 多信号融合检索（semantic+BM25+entity+temporal） | 全量注入 context（blocks）+ 工具检索 recall/archival | 混合检索（cosine+BM25+BFS）+ context 组装 | 14 检索模式（graph completion / CoT / NL2Cypher…） | 全文+向量混合 + 图遍历 build_context | 混合检索（RAG+memory）+ ~50ms user profile |
| **更新/遗忘** | 显式 update/delete + expiration + feedback；矛盾不自动处理 | agent 覆写块；sleep-time 重整 | **自动事实失效**（validity window，非删除，可回溯） | 增量重跑 + memify 演化 + 可选 contradicts 边 | 编辑即覆盖，无矛盾处理 | 自动遗忘/矛盾处理（官方宣称） |
| **多用户/多 agent** | user/agent/app/run_id 隔离（AND 交叉是坑） | shared blocks 跨 agent + subagents + tags 身份 | per-user/entity 海量小图 + 治理策略 | 每 user/group/共享图 + dataset 权限 | 项目/workspace 隔离 | 用户画像隔离 |
| **托管 vs 自托管** | 三档：Library / Self-hosted server / Cloud | 开源框架 + Letta Cloud（Free/Pro/Enterprise） | Graphiti OSS（仅引擎）+ **Zep Cloud 独家完整功能** | OSS + Cognee Cloud | 本地 + 可选 Cloud | 本地可离线下 + 托管平台 |
| **定价** | 托管按量；OSS 免费（Apache 2.0） | Pro $20/月 + 按量；credit 制 | Cloud credit 制 $1,250/年起（2026 涨价，无 $25 档） | 本地免费，云按规模 | Cloud 订阅 + OSS（AGPL） | 免费 app + API 按量 |
| **融资** | $24M（Seed+Series A，2025-10） | $10M seed（2024-09）+ 传闻 OpenAI 洽谈 | $500K pre-seed（YC W24） | 未披露主流融资 | 未披露 | $2.6-3M（2025-10） |
| **评测主张** | LoCoMo 92.5 / LongMemEval 94.4 / BEAM 1M 64.1、10M 48.6，<7K tokens/query | 首创 DMR 基准；sleep-time 论文 | DMR 94.8%、LongMemEval 高 18.5%、p95 sub-200ms | 自有 memory evals 框架 | 无基准（文件系统） | LongMemEval 95% R@15、三基准 #1 |
| **2025-2026 演进** | 新算法（ADD-only+entity linking+temporal）、OpenMemory MCP、AWS 独家 | Letta Code、Context Repositories（git 记忆）、Memory Models 研究、server 功能弃用 | 定位 Context Lake/企业治理、涨价、Graphiti 20K+ stars | v1.0 remember/recall、contradiction detection | v0.19 语义搜索/schema、Cloud 上线 | SMFS、Dynamic Dreaming、插件生态 |

### 向量/图库厂商（补充行）
| 厂商 | 方案 | 类型 | 记忆 vs 检索 |
|---|---|---|---|
| Pinecone | Assistant→**Nexus**（知识编译 + KnowQL） | 知识引擎 | 预编译 artifact 替代 per-query 检索循环 |
| Weaviate | **Engram**（托管记忆服务） | 记忆层 | 自动抽取 + scopes + 可组合 pipeline |
| Chroma | **Context-1**（agentic search subagent） | 检索 subagent | 自我编辑上下文的受训多轮检索 |
| Neo4j | **agent-memory** + LLM KG Builder | 图原生记忆 | 三层记忆 + POLE+O 图谱 + GraphRAG + 审计边 |
| Qdrant | Skills + qcloud-cli | DB 接入 agent | 运维知识编码为 skills，非记忆 |

---

## 2. 架构模式归纳

### 2.1 三种主流记忆形态
1. **Extraction-based（提取式）**——Mem0、Supermemory、Engram、Neo4j、Cognee（部分）
   - 写入：系统在 `add()`/ingestion 时用 LLM 把对话/文档抽取为"结构化事实/记忆条目"（有时带 metadata、categories、expiration）。
   - 读取：把抽取结果当作检索单元（向量 + 关键词 + 实体/时间多信号），本质上仍是"更干净的 RAG"。
   - 关键区别：**抽取的单元是否独立可寻址（memory_id）、可 update/delete、带生命周期**。Mem0 把这一点做成产品（CRUD API、expiration、feedback）。
   - 风险：抽取是有损的（信息在抽取时就可能被丢/错）；矛盾不自动处理（Mem0 明确 ADD-only，纠正靠显式 update/delete）；抽取成本（每消息 1 次 LLM 调用）。
2. **Graph-based（图式）**——Zep/Graphiti、Cognee、Neo4j、Supermemory（memory graph）
   - 写入：实体抽取 → entity resolution（去重/合并）→ fact/关系三元组 → 图存储；Zep 独有**双时态**（valid/observed/recorded 四时间戳）与**自动边失效**（矛盾→关 validity window，不删除）。
   - 读取：混合检索（向量 + 全文 + BFS/图遍历）+ context 组装；Cognee 提供 NL2Cypher / CoT 多跳。
   - 价值：关系/多跳/时间推理强（"现在 vs 某历史时刻"）、provenance/审计完整。
   - 成本：冷启动高（先建图）、抽取管线复杂、图查询延迟与扩展性挑战（Zep 为此自研专有图引擎）。
3. **Document-based（文档式）**——Letta memory blocks、Basic Memory、MemFS/Context Repositories
   - 写入：agent 用工具直接读写"文档块"（Markdown 文件 / context 内 block / git 仓库），无独立抽取管线。谁写=agent 自己决定（self-editing）。
   - 读取：blocks 常驻 context（零检索延迟）+ 文件/图遍历按需取。
   - 价值：透明、可版本化（git）、可审计、跨模型迁移（token-space）；零/低基础设施。
   - 风险：记忆质量依赖 agent 自觉；整体替换语义的并发丢写（Letta 官方警告 last-write-wins）；规模上限（context 内 block 有字符上限）；"memory rot"（脏记忆累积）——Letta 用 sleep-time 解决。

### 2.2 横向维度上的关键设计抉择
- **写入时机的两个流派**：同步（Mem0 每次交互 `add()`）vs 异步/后台（Letta sleep-time compute、Supermemory Dynamic Dreaming、Zep/Neo4j/Cognee ingestion 管线、Chroma 离线合成训练）。2026 明显趋势：**记忆维护从"推理时"转向"空闲时"**（sleep-time compute 成为范式）。
- **矛盾/遗忘的处理谱系**：不处理（Basic Memory）→ 显式 API 纠正（Mem0）→ 自动失效保留历史（Zep，最强）→ 仅标记 contradicts 边（Cognee，非破坏性审计式）→ 自动遗忘（Supermemory 宣称）。
- **检索的三个层次**：单次 top-k（Pinecone Assistant 时代）→ 多信号/混合融合（Mem0）→ **agentic 自我编辑检索**（Chroma Context-1：受训的检索 subagent 自己拆 query、多轮、剪上下文）。
- **多租户**：Mem0 用作用域标识符过滤；Qdrant 给出工程解法（tenant_id + is_tenant 索引 + tiered 分片）；Zep 用"海量小图"；Cognee 用数据集权限。**图/向量天然要处理租户隔离，这是自建记忆体系最容易踩的坑。**

---

## 3. 商业化与生态动态（2026）

### 3.1 融资图谱（记忆基础设施赛道，2024-2026）
| 公司 | 金额 | 时间 | 领投 | 备注 |
|---|---|---|---|---|
| Mem0 | $24M（Seed+Series A）| 2025-10 | Kindred→Basis Set | GitHub Fund、Peak XV、YC 参与；AWS Agent SDK 独家记忆伙伴 |
| Letta | $10M seed | 2024-09 | Felicis | 2025 年有 OpenAI 收购洽谈报道（未落地）；2026 转向 Letta Code |
| Zep | $500K pre-seed | 2024-03 | YC W24 | 资金最少却技术独树一帜（TKG）|
| Supermemory | $2.6-3M | 2025-10 | Susa/Browder/SF1 | Jeff Dean、Cloudflare CTO 等天使 |
| Onyx（企业搜索，附记忆工具）| $10M seed | 2025-03 | Khosla + First Round | 非纯记忆玩家 |
| LangMem | — | 2025-02 发布 | LangChain 生态 | 框架内置记忆 SDK（LangGraph BaseStore）|
| Chroma Context-1 | — | 2026-03 | 开源模型 | 无融资焦点，产品化研究 |

要点：
- **资本正涌入"记忆中间件"**，2025-10 是分水岭（Mem0、Supermemory 同期融资）。
- 玩家分两派：**纯记忆层**（Mem0、Supermemory、Zep）vs **stateful agent 运行时**（Letta——记忆只是其 agent 平台的一部分）。
- **最大的生存威胁被反复点名**：OpenAI/Anthropic 若在平台层推出原生持久记忆 API，会商品化掉中间件（多家第三方评测一致判断"when, not if"）。Mem0/Letta 的防御叙事：中立（model-agnostic）、可迁移（memory passport / token-space 记忆跨模型迁移）、可自托管。

### 3.2 生态与平台动作
- **AWS 背书**：Mem0 成为 AWS Agent SDK 独家记忆提供方（重大渠道信号）。
- **MCP 成为记忆的分发通道**：Mem0 OpenMemory MCP、Basic Memory MCP、Zep 的 Claude Code/Codex 插件、Cognee MCP server、Neo4j agent-memory MCP（16 tools）。"记忆即 MCP 工具"正在标准化。
- **DB 厂商向上封装**：Pinecone（Nexus 知识编译）、Weaviate（Engram）、Chroma（Context-1）、Neo4j（agent-memory）都在向量/图之上叠加"抽取+记忆生命周期"或"agentic 检索"，与记忆创业公司正面竞争。
- **Coding agent 成为记忆的样板场景**：Letta Code、Mem0 的 Claude Code/Cursor skills、Supermemory/Basic Memory 的 Claude 插件——记忆厂商用编程 agent 验证并分发自己的记忆体系。
- **定价上移与企化**：Zep 2026 取消 $25/月档、改年付 $1,250 起；Mem0/Letta/Zep 均推 SOC 2/HIPAA/BYOK/BYOC 企业叙事。记忆从"开发者玩具"变成"合规基础设施"。
- **评测话语权竞争**：Mem0 自建 BEAM（1M/10M token 大基准，讽刺小基准可被暴力刷分）；Zep 引用 DMR/LongMemEval；Supermemory 自称三基准 #1。**评测标准不统一、各说各话**是当前常态，对比时须核对 token 预算与检索深度。

---

## 4. 对我们 Memory 体系设计的启示

### 4.1 值得借鉴的模式
1. **分层记忆 + 明确生命周期**：采纳 Letta 的三层心智模型——working（context 内、常驻、agent 可编辑）→ recall（对话/事件流，按需检索）→ archival（长期事实/文档，检索型）。三层的持久化/检索路径不同，别揉成一团。
2. **写读分离的清晰接口**：Mem0 的 `add()`（谁写、写什么由系统抽取）与 `search()`（多信号融合）是对外部 agent 最友好的 API 形状；面向多 agent 时**作用域过滤（user/agent/run）必须是一等公民**。
3. **时态处理是真正的差异化**：Zep 的双时态 + 自动失效（不删除、可回溯）解决了"矛盾信息""现在 vs 当时"这类记忆核心难题，且天然满足审计。即便不自建完整 TKG，也应为每条记忆至少记录 `valid_from/valid_to` + provenance 链接。
4. **异步记忆维护（sleep-time compute）**：把记忆整理/压缩/矛盾消解放到空闲后台（Letta sleep-time、Supermemory dreaming），不占在线路径延迟——这是 2026 被验证的方向，成本可控（频率可调）。
5. **文档/文件作为记忆底座**：Basic Memory 的"人类与 AI 双写同一批 Markdown"与 Letta 的 git 版记忆（MemFS）极适合我们：透明、可版本化、可 diff、可人工修正、可跨模型/跨 agent 迁移。对重视可审计性的项目，这是**零锁定**的底座。
6. **检索 subagent 化（前沿）**：Chroma Context-1 证明"检索本身可以是受训的多轮自我编辑 agent"。现阶段可用轻量版：查询分解 + 迭代检索 + 上下文裁剪，而非一次性 top-k。
7. **预编译/策展（Pinecone Nexus 思路）**：对高频、结构化的领域知识，"编译一次、多次查询"比每次 RAG 更省 token、更准（Manifest/SME 在环）。适合我们的项目知识层。

### 4.2 要避开的坑
1. **提取式记忆的有损性与矛盾堆积**：Mem0 的 ADD-only 把矛盾处理丢给应用层；若我们也"只加不改"，时间长了会记忆自相矛盾。必须配套：显式 update/delete API + 反馈信号 + 可选矛盾检测（参考 Cognee 的 `contradicts` 边：非破坏性、可审计）。
2. **并发覆盖丢写**：Letta 明示 block 是整体替换、last-write-wins。多 agent/多进程共写同一记忆单元时要有版本/锁/追加语义防护。
3. **"上下文里全塞进去"不扩展**：Letta 的 blocks 全量注入只在记忆量小时成立；规模上来必须分层（注入核心 + 检索长尾）。
4. **多租户隔离**：Mem0 文档里的坑（user_id+agent_id 用 AND 返回空）和 Qdrant 的 HNSW 全局图教训都说明：**租户隔离必须在存储/索引层设计，不是查询时过滤**。
5. **冷启动与"记忆冷启动贵"**：图式记忆（Zep/Cognee）建图成本高；若项目数据量小/关系简单，先用提取式或文档式，别过早引入图谱。
6. **把平台当存储用会锁死**：托管平台（Zep Cloud、Mem0 Platform）各有专属优化且价格上移；若对数据主权敏感，选 OSS 内核 + 可插拔存储（Mem0 20+ 向量库、Cognee 三 store 可换、Neo4j bolt/NAMS 双后端），避免把核心记忆锁死在某个托管商。
7. **评测数字别盲信**：各厂基准口径不一（token 预算、top-k、是否 agentic loop、judge 模型）。自建评测时对齐 Mem0 的"报告 token/query + 约束一致"做法。

### 4.3 一个可落地的参考组合（供后续设计讨论）
- 底座：文件/文档（git 版，Basic Memory / MemFS 风格）保证透明与可迁移 + SQLite/Postgres 做索引与元数据真源。
- 抽取：可选"Mem0 式"轻量 fact 抽取（每交互一次 LLM、additive），但**每条记忆带 provenance + valid 窗口**，矛盾走"新事实+失效旧事实"（Zep 式），不做静默覆盖。
- 检索：多信号（语义 + BM25 + 实体/时间）融合；高频领域知识走"预编译策展"（Nexus 思路）；复杂查询用可选的 agentic 检索。
- 维护：后台 sleep-time 作业做压缩/去重/矛盾消解/画像更新，不占在线路径。
- 隔离：租户/项目在存储层隔离（参考 Qdrant tenant 索引与 Zep 每用户小图）。

---

## 5. 原始资料索引（sources/memory-platforms/）
- `mem0-core-concepts.md` / `mem0-2025-2026-updates.md`
- `letta-memory-architecture.md`
- `zep-graphiti-architecture.md`
- `cognee-architecture.md`
- `other-startups-basicmemory-supermemory-memorylane-onyx-hyperbrowser.md`
- `vector-graph-db-vendors-memory.md`
