# 社区生态、协议标准与趋势 —— 分析笔记

> 项目：YUKI.N（需要持久跨会话记忆的 Agent）
> 调研日期：2026-08-01
> 原始资料：`../../sources/community/`（一手来源，见文末清单）
> 方法：websearch 定位一手来源 → 抓取原文（blog/spec/GitHub/HN/Reddit）→ 提炼要点；全部引述均来自已保存原文，无编造链接与观点。

---

## 一、社区共识清单

基于 MCP 官方 blog/spec、A2A 官方 blog、Anthropic/OpenAI/Google 官方文档、LangChain/Mem0/Zep/Letta 厂商文档、HN/Reddit 讨论、Drew Breunig / Simon Willison / Chip Huyen / Latent Space 等博客的交叉印证，2026 年社区对 agent memory 的共识如下：

1. **Memory ≠ vector DB，vector RAG 不足以做 agent memory。** "The database finds things. The memory layer decides what is worth finding later."（dreaming.press 2026-07-16）vector DB 是"retrieval primitive"，memory 是在其上的一层"policy"：提取、去重、矛盾解决、时间衰减、per-user 隔离。纯 vector 检索在 LongMemEval 上低于混合/图/结构化方案两位数（jake-cuth：vector-primary 49.0% vs 混合 71-95%）。

2. **"长上下文窗口 ≠ memory"已是定论。** Drew Breunig 的 context rot 四模式（poisoning / distraction / confusion / clash）被广泛引用；Gemini 2.5 实测超过 100k token 后 agent 开始重复旧动作（dbreunig 2025-06-22）。"The long-context arms race ended without a winner"（Zencoder，转引自 rohitraj 2026-06-15）。context window 是 RAM，memory layer 才是持久存储。

3. **记忆是 context engineering 的一个原语，与 compaction、tool clearing 并列。** Anthropic 官方 cookbook 的映射：compaction 压缩整个窗口、clearing 丢弃窗口内 stale 可重取数据、memory 把信息移出窗口跨会话存活。Anthropic memory tool（`memory_20250818`）就是"模型自己驱动的文件目录"。**"The key insight across all the above tactics is that context is not free."**（Drew Breunig / Simon Willison 2025-06-29）

4. **主流框架收敛到同一套架构分层。** 2026 的四个代表：Letta(MemGPT) 层级记忆 + agent 自管理、mem0 distill-at-write 提取式、Zep/Graphiti 双时态知识图谱、LangMem 语义/情节/程序三型。所有框架都在做同一件事：把 write path（提取、门控、去重、矛盾处理）和 read path（混合检索）打包。**生产 memory 需要的不止 vector store：write gates、episode formats、retrieval policy、tenant isolation、maintenance jobs 都需要有 owner**（Jatin Bansal 2026-05-19）。

5. **记忆类型学（语义/情节/程序/工作记忆）成为 2026 标准语言。** 源于认知科学与 CoALA；LangChain 官方把它作为长时记忆 taxonomy；Latent Space/Memory as Adaptation 论证"每种类型需要不同的存储机制、写规则、检索规则与验证规则"。尤其：**procedural memory（技能/规则/工作流）往往带来最明显的 agent 行为改进**；episodic memory 处理"上次部署跳 migration 导致宕机"这类时间性事件。

6. **模型（agent）自我管理记忆是确定趋势，但需要门控。** MemGPT 的 "LLM as OS / 自编辑记忆" 框架成了 agent-memory 领域默认范式（arxiv 2310.08560）；Anthropic memory tool、ChatGPT memory、Letta、LangMem procedural memory 都让模型自己决定记什么。**但社区强烈共识：不能让模型无条件拥有"提交权"**——HN 讨论和 Claude Lab 的 seven pitfalls 都指出要两段式写入（agent 提议 → 轻量 validator 决定）。

7. **MCP 是 memory 的标准暴露接口（事实标准），但 MCP 规范本身不定义 memory。** 官方 reference memory server（knowledge graph 型）、Mem0 MCP、Basic Memory MCP、OpenMemory MCP 等把 memory 做成 MCP 工具集。记忆工具面正在统一为"add/search/get/update/delete"（Mem0 MCP 11 个工具是典型）。**2026 年 7 月尚无任何经批准的 agent memory 互操作协议标准**（Mnemoverse 2026-07-12，与 W3C/IETF/LF 现状交叉印证）。

8. **"记忆该存什么 / 谁决定遗忘"是工程核心难点。** HN 讨论（47328951）里实测的最佳实践：certainty/conflict 标注、last-touched + recall-frequency 软删除、低置信度自动压缩、高置信度默认不动、`source_turn_id` 溯源。LangChain 官方原则："Not everything should be a memory update"；"Make sure future runs actually read the update"。

9. **token 成本与 prompt caching 是 memory 设计的一等公民约束。** 内存放 system prompt 每轮刷新会破坏前缀缓存；放在 cache breakpoint 之后的 trailing message 可省至 2x（Zep 实验 2026-06-24）。"Don't Break the Cache"（arXiv 2601.06007）：策略性缓存使成本降 41-80%。模型侧（Anthropic memory tool）与厂商（Zep）都走向"memory 按需读取 / 不污染稳定前缀"。

10. **记忆即服务已是真实赛道。** Mem0 融资 $24M（2025-10，Basis Set/YC/GitHub Fund/Peak XV，AWS Agent SDK 独家 memory provider）；Letta $10M seed；Zep/Graphiti 20k+ stars；加上 2026 年本地优先新玩家（MemPalace、SuperMemory、OpenMemory）。Mem0 官方论点："Just like every application needs a database, every agentic application needs memory." + "memory 应中性、可移植"（反对厂商锁定）。

---

## 二、主要争议与两种观点

### 争议 1：embedding + RAG 是否足够？/ 记忆会不会成为"下一个 vector db"

- **观点 A（轻量派）**：对大多数单用户/编码 agent，`MEMORY.md` + 文件 + grep + prompt caching 就在 Pareto 前沿，专用 memory 框架是过度工程。"MEMORY.md is the right answer for ~80% of solo coding-agent workflows and ~0% of consumer chat products"（jake-cuth 2026-05-07）。HN（47897790）多处实测：Claude Code 的 LOG.md+MEMORY.md 两级方案、gnosis 的"少存"哲学；Anthropic 官方 memory tool 本身就是"一个文件目录"。Chip Huyen 视角：工具不是越多越好（tool loadout）。
- **观点 B（重型派）**：凡是"事实会演化、需要冲突解决、成百上千 session、多用户/时态查询"的场景，文件/纯 RAG 非线性退化，需要提取、图、时态、衰减。Mem0/Zep/Graphiti/Letta 的 benchmark（LongMemEval 71-95% vs vector-primary 49%）支持此论。
- **代表链接**：观点 A = jake-cuth、HN 47897790、n1n.ai "Why Vector Databases Might Be Overkill"；观点 B = dreaming.press、Mem0 文档、Zep。

### 争议 2：图记忆 vs 向量记忆（graph vs vector）

- **向量派**：distill-at-write 提取式事实 + 向量检索，低成本、快接入（mem0）。
- **图/时态派**：知识图谱（尤其 bi-temporal）保存事实演化与关系，能回答 "what was true on date X"（Zep/Graphiti，arXiv 2501.13956）；MCP 官方 memory server 也是 knowledge-graph 型；Basic Memory 用 Markdown+wiki link 建图。
- **折中（2026 主潮）**：混合检索（vector + BM25 + graph traversal + RRF），Mem0 也加了 Mem0g graph 扩展；社区结论"在生产里 vector、graph、KV 各司其职"（MemNexus、dakera、Hindsight）。

### 争议 3：agent 自我管理记忆 vs 外部系统（harness）管理

- **自治派**：MemGPT/Letta "LLM as OS"——模型用工具调用把自己当内存管理器（core/recall/archival 分页），能 self-improve；LangMem procedural memory 让 agent 改自己的 system prompt。
- **治理派**：让模型决定记什么是"最贵的错误"（Claude Lab seven pitfalls #1：hypothetical statements stored as fact）；两段式写入、validator 持提交位、PII 过滤、user_id 物理隔离、checksum+quarantine、4-phase migration。HN（47328951）的 certainty-scoring 层同理。Anthropic 官方 memory tool 把存储实现放在 client 侧，也是一种"框架控写"。

### 争议 4：该记住一切还是该遗忘？（accumulate vs forget）

- EvoMemBench（2026）发现长上下文模型在 <50 sessions 仍具竞争力，外部 memory 的优势只在 >30 天、高频变化事实时才显现 → "forgetting might be premature optimization"。
- FadeMem/记忆衰减派主张遗忘是功能（decay、软删除）；社区实践用 certainty 连续值（低置信度可自动压缩，高置信度禁动）。
- 尚无实验把 decay 与高质量检索叠加测过 → "The field is genuinely split"（The Last Programmers 2026-06-21）。

### 争议 5：记忆该不该"厂商中立、可移植"

- Mem0 主张 memory 应中性（不被单一大模型厂商锁定）且可移植（memory passport）。用户侧（Simon Willison 反复关注 memory 透明性、可导出、project 级隔离）支持开放可移植。
- 反方：Anthropic/OpenAI 消费者产品用 memory 做锁定与留存；W3C/LF 尚无标准可谈，各家 memory 格式事实上不互通（Mnemoverse 五 faces 分析）。

---

## 三、协议标准现状（MCP / A2A 记忆相关）与对我们的约束

### MCP（Model Context Protocol）

**规范演进（2025-2026，一手来源已存）**：
- `2025-06-18`：elicitation（server 向用户请求缺失输入）、OAuth/Resource Server、structured tool output；移除 JSON-RPC batching。
- `2025-11-25`：async/Tasks 准备（SEP-1391）、GET stream 轮询澄清。
- `2026-07-28`（**2026-07-28 刚发布，最大一次修订，破坏性**）：
  - **stateless core**：移除 `initialize`/`initialized` 握手与 `Mcp-Session-Id`（SEP-2575/2567）；每请求自描述（协议版本、client info、capabilities 在 `_meta`）；新增可选 `server/discover` RPC。
  - Streamable HTTP 现要求 `Mcp-Method`/`Mcp-Name` 头（网关可直接路由/计量）。
  - 服务端→客户端请求（sampling/elicitation/roots）改为 **MRTR**（multi round-trip requests，`input_required` + `inputResponses`）。
  - list 结果带 `ttlMs`/`cacheScope` 缓存提示（`tools/list` 可缓存——与 prompt caching 直接相关）。
  - 正式 extensions 框架：Tasks 进 `io.modelcontextprotocol/tasks`；MCP Apps、EMA。
  - Roots/Sampling/Logging 与 HTTP+SSE 正式废弃（12 个月过渡期）。

**MCP 中的 memory**：
- 官方 reference：`@modelcontextprotocol/server-memory`（Knowledge Graph Memory Server）——entities/relations/observations，`MEMORY_FILE_PATH` JSONL，`memory://knowledge-graph` Resource，变更通知 `notifications/resources/updated`。**它是"用 MCP 把 memory 暴露为工具+资源"的范式模板**，但仅是最小实现（无提取、无衰减、无冲突解决）。
- 生态 memory servers：**Mem0 MCP**（官方 repo 已归档→云托管 `https://mcp.mem0.ai/mcp`，11 个工具：add/search/get/update/delete/list/…）；**Basic Memory**（本地 Markdown 知识图谱，local-first，MCP + Obsidian）；**OpenMemory**（本地优先 MCP memory server）；另有大量社区 server（engram-mcp、agents-remember 等）。
- **MCP 官方 SDK 的 memory**：Python/TS SDK 不内置"memory 抽象"，但 Anthropic SDK 有 `BetaLocalFilesystemMemoryTool`/`BetaAbstractMemoryTool`（那是 Claude memory tool 的 client 侧 helper，不是 MCP 层面的）。

### A2A（Agent2Agent）

- Google 2025-04-09 发布（50+ 伙伴），2025-06-23 捐给 Linux Foundation（100+ 公司）；2025-07 v0.3（gRPC、签名 AgentCard）；2026-06 一周年：Python/Go SDK 1.0 GA，Java/.NET 跟进。
- **A2A 与 MCP 是互补而非竞争**：MCP = agent↔工具/上下文；A2A = agent↔agent。Google 官方明确 "MCP is for agent-to-tool communication… A2A is for agent-to-agent communication"。
- **A2A 刻意不碰 memory**：规范明确 agent 协作 "without needing access to each other's internal state, memory, or tools"（opaque execution）；只提供 `contextId` 做会话内任务分组。官方一周年文章把 "Zero Context Pollution"（主 agent 的 memory 不被子任务污染）作为卖点。
- **对 multi-agent 记忆的影响**：A2A 明确把持久共享 memory 留给互补层解决。多 agent memory consistency 被论文（arXiv 2603.10062）称为 "the most pressing open challenge"。SAMEP（arXiv 2507.10562）等提案想补这一层，但均非标准。

### 对我们的约束（YUKI.N）

1. **协议层面没有现成标准可依赖**：2026-07 无任何 ratified 的 agent memory 互操作标准（Mnemoverse 调查 + W3C CG 现状）。不要等标准；把 memory 作为自己的领域模型设计。
2. **接口层面用 MCP 暴露是事实标准**：若 YUKI.N 需要跨客户端/跨工具记忆，做成 MCP server（工具 = add/search/update/delete + Resource = 完整记忆视图）是低成本、即插即用的选择；2026-07-28 spec 的 stateless core 让 MCP server 部署更简单（无 session 状态），memory 状态我们自己持有即可（官方建议：跨调用状态用显式 handle，而非 transport session）。
3. **memory 的"地址/身份"要自定**：MCP 的 Resource 只能按 server 寻址，不命名 memory 空间。需自行设计命名空间（user/project/agent scope）——可参照 Anthropic memory tool 的 `/memories` 前缀 + per-user/per-project 目录隔离，或 LangGraph store 的 namespace/key。
4. **与 prompt caching 的约束**：若要每轮注入 memory，必须放在缓存断点之后（trailing message / mid-conversation system message），保持 system prompt 为稳定前缀；或采用按需读取（模型主动 read），天然不破坏缓存。
5. **安全基线**：OWASP Agentic 2026 把 "Memory & Context Poisoning"（ASI06）列为风险；memory 是 attacker-controllable 输入 → 写路径门控、路径校验（防 traversal）、把存储 memory 当不可信输入处理。
6. **厂商实践可借鉴为基线**：Anthropic memory tool 的"模型驱动文件目录 + client 侧存储"、MemGPT 的层级记忆、Mem0 的 extract-at-write、Zep 的 bi-temporal——都不是标准，但都是被验证的 pattern 库。

---

## 四、2026 趋势研判

1. **从 RAG 到 state management**：memory 从"检索增强"演进为"agent 的状态管理层"（Latent Space/Memory as Adaptation 2026-05-22）。self-improvement 离不开记忆。
2. **记忆即服务商业化深化**：Mem0（$24M，AWS 独家）、Letta（$10M）、Zep/Graphiti 成三巨头；本地优先/隐私优先新玩家（OpenMemory、MemPalace、SuperMemory、Basic Memory）分化市场。厂商 benchmark 混战（LoCoMo 各家互相矛盾）→ 社区共识"自报 benchmark 只作上界，不可用于选型"。
3. **memory × prompt caching 融合**：缓存经济决定 memory 放哪。Claude 模型已自动 prompt caching，OpenAI GPT-5.6 2026-07 转向显式断点 + 1.25x 写费 + 30min TTL（对齐 Anthropic 模型）。memory 位置、稳定前缀、model-homogeneous staging 成为成本工程的一部分。
4. **memory × reasoning 边界**：记忆让 agent 的推理基于"持久 belief state"而非每轮从零重建；procedural memory（技能）与 working memory（当前轨迹）被当作推理能力的一部分。自改进/自我修正依赖记忆闭环（LangSmith Engine 把 trace→memory 做成产品）。
5. **"让模型自我管理记忆"主流化，但治理层随之而来**：MemGPT 范式普及的同时，"写门控/validator/审计"成为生产必选项。方向是"模型提议 + 系统裁定"。
6. **标准化的前夜**：MCP 已把 memory 作为工具面统一（工具名都趋向 add/search/get/update/delete）；A2A 明确让出 memory 层；尚无 memory 协议标准，但 W3C/IETF/LF 已有动静（W3C CG 2026-05，单一厂商发起、状态微弱）。未来 12-18 个月可能出现"记忆层协议"或"记忆通用格式"的收敛尝试。
7. **本地优先回潮**：文件/Markdown + 本地 SQLite + 可选向量/图（Basic Memory、OpenMemory、Graphiti self-host、MemPalace zero-API）在 2026 成为一类明确流派——与"数据主权 + 避免锁定"诉求绑定。

---

## 五、对 YUKI.N Memory 设计的启示

（结合项目背景：需要持久跨会话记忆的 agent；Haskell 纯函数偏好——先给结论，取舍留待设计阶段）

1. **分层而非单一存储**。参考 2026 收敛架构：working/short-term（对话历史+checkpoint）→ 持久记忆（结构化）→ 可选图/时态层。YUKI.N 至少要区分：会话态 vs 跨会话持久态；事实/偏好（semantic）vs 事件/经验（episodic）vs 流程/规则（procedural）。四种类型需要不同的写规则、检索规则、验证规则。

2. **"提取 + 门控"写路径，而非无脑存日志**。采纳社区验证的模式：
   - 两段式写入（agent 提议候选记忆 → 独立 validator 决定是否落库），避免"同样的事实被写成三十种措辞"；
   - 每条记忆带元数据：`source_turn_id`（溯源，一切审计/迁移/冲突排查的地基）、createdAt/observedAt/validUntil、置信度（continuous）、状态（open/resolved/contradicted）；
   - 矛盾检测：写入时对既有记忆做相似性检查，冲突不静默覆盖而标记并链接（让 agent 在上下文中看到双方自己裁决）；
   - 遗忘即功能：last-touched + recall-frequency，低置信度可自动衰减/压缩，高置信度默认不动。

3. **记忆条目是可读、可审计、可导出的文本**。倾向"结构化 Markdown/JSON 文件 + 本地索引（SQLite）+ 可选向量/图"，而非把记忆锁在专有 vector DB。理由：可检查性（"vector index 无法 inspect agent 到底知道什么"）、可移植性（防锁定）、与 Anthropic memory tool / Basic Memory / AGENTS.md 生态兼容、利于 Haskell 侧以纯函数处理文件与索引。

4. **暴露为 MCP server（工具 + Resource），并实现"按需读取"**。工具面最小集：`add/search/get/update/delete` + 完整的 memory 视图作为 Resource；可加 `stats`/`diff` 类诊断工具。读取设计成"模型主动、just-in-time"，避免每轮全量注入破坏 prompt cache；若必须注入，放缓存断点之后。

5. **显式命名空间与隔离**。自定 memory 地址（如 `user/<id>/project/<id>/...`），物理隔离（per-user 目录/前缀），跨 session 用同一 namespace 续接——不依赖任何 transport session（MCP 2026-07-28 stateless 后更应如此）。参照 Anthropic per-project memory、Claude Code 的 CLAUDE.md/MEMORY.md 两级。

6. **把 token 成本当作一等约束**。记忆注入位置、条目标注（重要性/衰减）、检索 top-k 预算、压缩阈值都影响成本；设计时用 prompt caching 视角审视"哪些是稳定前缀、哪些是每轮动态内容"。可借鉴 Zep 实验与 Anthropic compaction（软阈值 ~70%）经验。

7. **安全默认值**。记忆是注入向量：路径校验、写门控、PII 过滤、把存储内容当不可信输入；支持 read_only 共享参考库（Anthropic memory store 建议）。多 agent 场景按 A2A 哲学保持 opacity——YUKI.N 的主 agent 不需要暴露内部状态给其他 agent，持久记忆层作为互补的显式层存在。

8. **不绑定单一厂商/框架，但借鉴其 pattern**。Mem0 的中立/可移植主张、Letta 的自管理、Zep 的时态、LangMem 的 procedural——作为模式库而非依赖。接口抽象薄一点（`remember`/`recall`），后端可换（本地文件/SQLite → pgvector → 图）。

---

## 附：原始资料清单（sources/community/）

**协议 / 官方规范**
- `mcp-official-memory-server-2026.md` — MCP 官方 Knowledge Graph Memory Server（@modelcontextprotocol/server-memory）
- `mcp-blog-2026-07-28-release-2026-07-28.md` — MCP 2026-07-28 发布 blog（stateless core、MRTR、tasks、废弃项）
- `a2a-specification-2026.md` — A2A 规范原文（opaque execution、contextId）
- `a2a-google-announcement-2025-04-09.md` — Google 发布 A2A（2025-04）
- `a2a-google-1st-birthday-2026-06-18.md` — A2A 一周年（SDK 状态、zero context pollution）

**厂商 memory 产品 / 文档**
- `mem0-github-2026.md`、`mem0-mcp-github-2026.md`、`mem0-mcp-docs-2026.md`、`mem0-series-a-2025-10-28.md` — Mem0 全套（核心库、MCP、融资）
- `letta-github-2026.md`、`memgpt-paper-abstract-2023.xml` — Letta/MemGPT
- `basic-memory-github-2026.md` — Basic Memory（本地 Markdown 知识图谱）
- `anthropic-memory-tool-docs-2026.md` — Anthropic memory tool 文档 + compaction/context editing
- `langchain-how-to-give-agent-memory-2026-06-24.md` — LangChain 官方 memory 方法论（semantic/episodic/procedural + trace loop）
- `jatin-bansal-production-memory-frameworks-2026-05-19.md` — Letta/mem0/Zep/Graphiti 生产对比

**博客 / 文章**
- `drew-breunig-how-long-contexts-fail-2025-06-22.md`、`simon-willison-context-2025-06-29.md` — context rot / context engineering
- `simon-willison-claude-memory-2025-09-12.md` — Claude vs ChatGPT memory 实现对比
- `chip-huyen-agents-2025-01-07.md` — Chip Huyen agents（tool inventory、planning、memory 定位）
- `latent-space-memory-as-adaptation-2026-05-22.md` — Memory as Adaptation（memory 四型、self-improvement）
- `zep-memory-placement-prompt-caching-2026-06-24.md` — memory 位置 × prompt caching（token 成本）
- `vector-db-vs-memory-layer-2026-07-16.md`、`jake-cuth-agent-memory-lab-2026-05-07.md` — vector DB vs memory layer / MEMORY.md vs graph 之争
- `mnemoverse-agent-memory-interop-gap-2026-07-12.md` — 无标准现状调查（五 faces、OWASP ASI06、W3C CG 状态）

**社区讨论（HN/Reddit，含 top comments）**
- `hn-ask-sota-agent-memory-2026.md` — Ask HN: What's SoTA in Agent Memory?
- `hn-memory-quality-thread-2025.md` — 记忆质量：certainty scoring / 矛盾检测 / 软删除实测
- `hn-open-source-memory-layer-2025.md` — 开源 memory layer（"store/remember vs 后台摘要"之争、MEMORY.md 实测）
- `hn-universal-memory-protocol-2026.md` — Universal Memory Protocol（LLM slop 批评、标准无采纳）
- `hn-memory-synced-over-ssh-2026.md` — 开源记忆 SSH 同步
- `hn-multi-agent-memory-consistency-2025.md` — multi-agent memory consistency（Claude Code leak 后）

（附：Reddit r/LLMDevs "How are you handling persistent memory in LLM apps?"（1r35hlc）与 "Ai Agent Amnesia"（1royccx）讨论了会话/项目/跨项目三层记忆结构；Eugene Yan 观点——RAG 的 tail queries 是时间黑洞、纯 embedding 检索是死路——作为反方引证未单独存文件，见下链接。）

---

## 附：核心链接汇总

- MCP spec 2026-07-28: https://blog.modelcontextprotocol.io/posts/2026-07-28/ ；spec: https://modelcontextprotocol.io/specification/2026-07-28
- MCP memory server: https://github.com/modelcontextprotocol/servers/tree/main/src/memory
- A2A: https://developers.googleblog.com/en/a2a-a-new-era-of-agent-interoperability/ ；https://a2a-protocol.org/
- Anthropic memory tool: https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool ；https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- Mem0 MCP: https://docs.mem0.ai/platform/mem0-mcp ；https://mem0.ai/series-a
- Basic Memory: https://github.com/basicmachines-co/basic-memory
- Letta: https://github.com/letta-ai/letta ；MemGPT paper: https://arxiv.org/abs/2310.08560
- Drew Breunig: https://www.dbreunig.com/2025/06/22/how-contexts-fail-and-how-to-fix-them.html
- Simon Willison: https://simonwillison.net/2025/Sep/12/claude-memory/ ；https://simonwillison.net/2025/Jun/29/how-to-fix-your-context/
- Chip Huyen: https://huyenchip.com/2025/01/07/agents.html
- LangChain memory: https://www.langchain.com/blog/how-to-give-your-agent-memory
- Jatin Bansal: https://jatinbansal.com/ai-engineering/production-memory-frameworks/
- Zep prompt caching: https://blog.getzep.com/where-you-put-memory-in-the-prompt-can-cut-your-token-bill-up-to-2x/
- Don't Break the Cache: https://arxiv.org/abs/2601.06007
- Mnemoverse interop gap: https://mnemoverse.com/docs/library/agent-memory-interop-gap
- Eugene Yan (RAG 反方): https://eugeneyan.com/writing/llm-patterns/ ；https://www.linkedin.com/posts/eugeneyan_my-mental-model-of-retrieval-in-rag-is-that-activity-7332097744079069187-FqiG
