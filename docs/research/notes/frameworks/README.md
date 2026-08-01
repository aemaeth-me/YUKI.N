# 开发框架层记忆抽象调研笔记（2026-08）

> 调研对象：LangGraph+LangMem、LlamaIndex、CrewAI、AutoGen/Semantic Kernel、OpenAI Agents SDK / Claude Agent SDK / pydantic-ai、Google ADK、AWS Bedrock AgentCore，以及新兴记忆层（Mem0、Zep/Graphiti、Letta、Cognee）。
> 全部基于官方文档/官方 blog 第一手资料，原始抓取存于 `sources/frameworks/`。
> 结论日期：2026-08-01。

---

## 一、一句话总结（每个框架的记忆方案）

| 框架 | 记忆方案一句话 | 官方链接 |
| --- | --- | --- |
| **LangGraph + LangMem** | 用 LLM 做记忆的读写（agentic memory）：BaseStore（namespace+key 的 KV/向量存储）为底座，LangMem 提供 manage/search 记忆工具与后台 memory manager 做抽取/合并/淘汰，分语义/情景/程序三类记忆。 | https://langchain-ai.github.io/langmem/ |
| **LlamaIndex** | `Memory` 类 = 短程 FIFO 消息队列（SQLite）+ 长程 MemoryBlocks（静态/LLM 事实抽取/向量检索），按 token_limit 与 priority 合并截断，`put/get` 接口。 | https://developers.llamaindex.ai/python/framework/module_guides/deploying/agents/memory/ |
| **CrewAI** | 2025 后统一为单个 `Memory` 类：LLM 在保存时推断 scope/分类/重要性，层级 scope 树 + 语义/时效/重要性复合评分召回，LanceDB 存储，带 consolidation 去重。 | https://docs.crewai.com/en/concepts/memory |
| **AutoGen** | 只定义 `Memory` 协议（query/add/update_context/clear/close），agent 推理前 JIT 检索并注入 model_context，具体存储（List/ChromaDB/Redis/Mem0）由实现决定，官方不做高层抽象。 | https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/memory.html |
| **Semantic Kernel** | 不做对话记忆抽象，只给向量存储统一抽象（VectorStore/Collection/IVectorSearchable，model-first），通过 plugin/search function 暴露做 RAG。 | https://learn.microsoft.com/en-us/semantic-kernel/concepts/vector-store-connectors/ |
| **OpenAI Agents SDK** | 框架只管 Session（对话历史，SQLite/Redis/MongoDB 等多后端）+ context 注入；长期记忆完全交给开发者（"memory-as-a-tool"+ hooks + RunContextWrapper state）。 | https://openai.github.io/openai-agents-python/sessions/ |
| **Claude Agent SDK / Claude Code** | 记忆 = agent 自己维护的 markdown 文件（CLAUDE.md / MEMORY.md / subagent memory 目录），随会话渐进式加载；平台另有 memory tool 与 Managed Agents memory store，配 server-side compaction。 | https://code.claude.com/docs/en/memory |
| **pydantic-ai** | 核心 stateless，消息历史可序列化（ModelMessagesTypeAdapter）自由持久化；2026 新 tiered `AbstractMemoryStore`（load_recent + load_summary + save/summarize/clear）；压缩靠 Compaction capability。 | https://pydantic.dev/docs/ai/core-concepts/message-history/ |
| **Google ADK** | Session（短期）+ State（会话内 KV，`user:`/`app:` 前缀跨会话）+ `MemoryService`（长期）：InMemory 关键词 / Vertex AI Memory Bank（LLM 抽取合并）/ Vertex AI RAG（向量），preload/load 记忆工具。 | https://github.com/google/adk-docs/blob/main/docs/sessions/memory.md |
| **AWS Bedrock AgentCore** | 全托管记忆：short-term = 原始 events（按 session + actor 隔离，可配保留期），long-term = 后台 LLM 策略抽取（semantic/summarization/user_preference/episodic）存 records，语义检索（topK+relevance），含加密/审计/流式。 | https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/memory.html |
| **Mem0（新兴记忆层）** | drop-in 记忆 API：`add(对话)` 时 LLM 蒸馏事实、`search(query)` 向量检索，user/agent/app/run 实体作用域隔离，可自托管（Qdrant+SQLite）或托管。 | https://docs.mem0.ai/ |
| **Zep / Graphiti（新兴）** | bi-temporal 知识图谱记忆：每条事实带有效性窗口（valid_at/invalid_at），检索融合 embedding+BM25+图 BFS，可回答"何时为真"的时间正确性查询。 | https://arxiv.org/html/2501.13956 |
| **Letta（新兴，MemGPT 系）** | 记忆 = 操作系统分页：Core memory blocks（常驻 context，agent 用工具自管）+ Recall（可搜索历史）+ Archival（冷存储向量），sleep-time dreaming 后台整理。 | https://docs.letta.com/guides/core-concepts/memory/memory-blocks/ |
| **Cognee（新兴）** | ECL 管线（Extract-Cognify-Load）把文档构造成 typed 知识图谱，统一关系+向量+图存储，暴露 MCP server，14 种检索模式。 | https://github.com/topoteretes/cognee |

---

## 二、横向对比矩阵

### 2.1 记忆抽象层级与 API

| 框架 | 抽象层级 | 核心存取接口 | 记忆类型/单元 |
| --- | --- | --- | --- |
| LangGraph+LangMem | 存储层（BaseStore）+ 语义层（LangMem 工具/manager） | `store.put/get/search`（namespace,key）；`manage_memory`/`search_memory` 工具 | Semantic（Profile/Collection）、Episodic、Procedural |
| LlamaIndex | 单一 `Memory` 对象 | `memory.put()/get()`，blocks `aput/aget` | 短程消息 FIFO + 长程块（Static/FactExtraction/Vector） |
| CrewAI | 统一 `Memory` 类 + scope 树 | `remember()/recall()/extract_memories()` | 原子事实语句（LLM 抽取），scope/categories 组织 |
| AutoGen | `Memory` 协议（最小契约） | `add()/query()/update_context()/clear()` | `MemoryContent`（mime-typed），实现自由 |
| Semantic Kernel | 存储抽象（无记忆层） | `collection.upsert/get/search` + `create_search_function` | 通用记录（model-first schema） |
| OpenAI Agents SDK | Session 协议（仅对话历史） | `session.get_items/add_items/pop_item/clear_session` | 对话 item 流 |
| Claude Agent SDK | 文件系统记忆 | Read/Write/Edit 工具操作 `/memories`、CLAUDE.md、MEMORY.md | 自由格式 markdown 文档 |
| pydantic-ai | 消息历史 + tiered store | `message_history` 参数；`load_recent/load_summary/save/summarize/clear` | `ModelMessage` / 摘要文本 |
| Google ADK | SessionService + MemoryService | `session.state`；`memory_service.add_session_to_memory/search_memory`；`load_memory`/`preload_memory` 工具 | 事件流 → MemoryEntry |
| AWS AgentCore | 托管资源（Memory） | `CreateEvent`/`ListEvents`；`CreateMemoryRecord`/`RetrieveMemoryRecords` | Event（原始）/ MemoryRecord（抽取） |
| Mem0 | 托管/开源 API | `add(messages, user_id)/search(query, filters)` | 蒸馏事实 + categories + metadata |
| Zep/Graphiti | 图谱引擎/服务 | `add_episode` / `search`（融合检索） | 带时间窗的事实边（entity-relation） |
| Letta | 运行时三层 | 工具编辑 memory blocks；`archival_memory_search` | Block（label/description/value/limit）|
| Cognee | 数据→图谱管线 | `add`/`search`/`graph_query`（14 模式） | typed nodes/edges + provenance |

### 2.2 存储、检索、遗忘、多 agent 共享

| 框架 | 持久化 | 检索策略 | 记忆管理 / 遗忘 | 多 agent 共享 |
| --- | --- | --- | --- | --- |
| LangGraph+LangMem | InMemory / Postgres（BaseStore）；Platform 默认托管 | 语义搜索（embedding index）+ metadata 过滤 + 直接 get | 主动（agent 工具：create/update/delete）+ 被动（后台 memory manager 合并/consolidate）| namespace 分层（user/org/team），读共享写隔离 |
| LlamaIndex | SQLite（默认，可换远端 DB）| token_limit FIFO + 可选向量 top-k + fact 抽取 | 超限 flush 到长程块，priority 决定截断顺序 | 无内建共享原语（多 agent 各持 Memory 实例） |
| CrewAI | LanceDB（本地目录，可换 backend）| 语义×时效×重要性复合评分；shallow/deep RecallFlow（LLM 引导多路检索）| LLM consolidation（keep/update/delete/insert）、batch 去重、recency 半衰 | Crew 内所有 agent 共享一个 Memory；scope/slice 控制可见性；private + source 隔离 |
| AutoGen | 存储由实现决定（List/ChromaDB/Redis/Mem0）| 由实现决定（vector / 全文）；`update_context` 注入 model_context | 无框架级遗忘；`clear()`；社区 RFC 提 importance-based decay | 每个 agent 挂 `memory=[...]`；社区提案 SharedMemoryStore（agent/group/global scope） |
| Semantic Kernel | 25+ 向量库连接器 | vector / vectorizable-text / hybrid keyword search | 无遗忘机制（纯存储层）| 共享 collection 即共享 |
| OpenAI Agents SDK | Session 多后端（SQLite/Redis/SQLAlchemy/MongoDB/Dapr/服务端）| 全量/limit N 取历史；自定义 session_input_callback 裁剪 | compaction（responses.compact）；pop_item 修正；无长期遗忘 | 多个 agent 可共享同一 Session |
| Claude Agent SDK | 文件（本地）+ SessionStore 镜像（S3/Redis/PG）| agent 自主读文件 + 每会话加载前 200 行/25KB | MEMORY.md 由 agent 自行 curation；store 2000 条上限 + 版本化审计 | 共享 memory store（read_only/read_write）多会话挂载 |
| pydantic-ai | InMemory / SQLite（store）或自建 | load_recent(verbatim) + load_summary(摘要注入 system 块) | summarize() 需自己实现（stub）；ProcessHistory 裁剪 | MemoryScope(user_id, agent_id, conversation_id) 隔离 |
| Google ADK | InMemory / Database(SQL) / Vertex AI（Memory Bank / RAG）| keyword（InMemory）/ LLM 抽取语义（Memory Bank）/ 向量（RAG）| Memory Bank LLM 合并去重；事件保留策略 | `user:`/`app:` state 前缀；MemoryService 按 app+user 作用域 |
| AWS AgentCore | 全托管（KMS 加密）| `RetrieveMemoryRecords` 语义检索 topK+relevance；metadata 过滤 | event 保留期（7-365 天）；long-term 抽取+consolidation | actorId+sessionId+namespace 模板隔离；可跨 harness 共享（BYO）|
| Mem0 | Qdrant + SQLite（OSS）；托管平台 | 向量 + 可选 keyword/entity + rerank；categories/entity filters | 写时去重/冲突解决；expiration_date；async 处理 | user/agent/app/run 四维实体隔离；同一 agent 跨用户共享 |
| Zep/Graphiti | Neo4j/FalkorDB 图谱 + 向量 + BM25 | 融合检索（cosine+BM25+图 BFS+RRF）| 边失效打标（bi-temporal），保留审计轨迹 | user_id/session_id/group_id 内建 |
| Letta | Postgres DB（全状态持久化）| 常驻 blocks（无需检索）+ recall/archival 工具检索 | agent 自主编辑；dreaming 后台合并 | 同一 block attach 多 agent = 共享记忆 |
| Cognee | 单 Postgres（关系+pgvector+graph）或嵌入式；生产图后端 | 14 种检索模式；图遍历 | memify 边权重学习；provenance 追踪 | tenant/user 隔离；跨 agent 知识共享 + MCP |

### 2.3 与 context window 的关系

- **显式分层预算**：LlamaIndex 最典型——短程+长程合并后强制 ≤ token_limit，priority=0 常驻。pydantic-ai 的 load_summary 摘要注入也是此思路。Claude 的 MEMORY.md 前 200 行/25KB 同理。
- **工具按需拉取**（progressive disclosure）：LangMem search_memory 工具、CrewAI RecallFlow、ADK load_memory、OpenAI cookbook memory-as-a-tool、Claude memory tool、Letta archival——记忆不常驻，模型需要时再检索。
- **后台提炼**：LangMem background manager、CrewAI 后台保存、ADK 会话结束 callback、AgentCore 异步抽取、Letta dreaming、OpenAI sandbox Phase1/2——把"从 context 提炼记忆"移出主链路。
- **Context 压缩作为独立机制**：Claude（compact_20260112 / clear_tool_uses_20250919）、OpenAI（responses.compact + compaction session）、AutoGen BufferedChatCompletionContext、AWS sliding_window/summarization、pydantic-ai Compaction capability——压缩与记忆正交，很多框架同时提供。

---

## 三、设计哲学差异：显式记忆类 vs 隐式 context

可把 13 个框架归为三类哲学：

### A. 隐式 context 派（记忆 = 对话历史 / 上下文窗口）
OpenAI Agents SDK（Session 只是历史，记忆靠开发者）、pydantic-ai（message_history 自由序列化）、Semantic Kernel（只管向量底座）、Claude Agent SDK（文件即记忆）。
- 核心主张：agent 本身 stateless，框架不替你判断"什么值得记"；记忆是应用层的事。
- 优点：极简、可组合、无隐藏魔法；缺点：开发者要自己造轮子（RAG、抽取、遗忘）。

### B. 显式记忆抽象派（记忆 = 一等公民，框架/工具管写读更新）
LangMem（agentic memory：LLM 决定何时写/改/删）、LlamaIndex（Memory 类 + Blocks）、CrewAI（统一 Memory + LLM 分析层）、AutoGen（Memory 协议）、Google ADK（MemoryService）、AWS AgentCore（托管 Memory）、Letta（agent 自管 blocks）。
- 核心主张：记忆是有生命的系统，需要存取策略、合并、遗忘；LLM 是最佳"记忆管理者"（agentic memory）。
- 差异在**谁决策**：
  - LangMem/Letta：**agent 自己**用工具决定写/读/更新（hot path），可配后台管理器。
  - CrewAI/ADK/AWS/Mem0：**框架管线**决定（保存时 LLM 分析、后台抽取、consolidation），agent 只调用检索。
- 优点：开箱即用、语义质量高；缺点：引入 LLM 延迟、魔法多、难调试。

### C. 图谱记忆派（记忆 = 结构化知识，非消息非事实列表）
Zep/Graphiti、Cognee（以及 Mem0 的可选图、LangMem 的 semantic collections）。
- 核心主张：agent 长期记忆本质是"实体-关系-时间"的世界模型；向量检索是浅层，图谱才能做多跳推理与时间正确性。
- 这是 2026 年最活跃的分化方向（bi-temporal 是 Zep 独有优势）。

### 关键张力：谁拥有"遗忘"？
- 显式派提供系统化遗忘：LangMem 后台 consolidation、CrewAI consolidation_threshold、AgentCore 策略合并、Mem0 写时冲突解决、Letta dreaming。
- 隐式派把遗忘留给开发者（裁剪/摘要/清理 hook）。
- 无框架真正原生支持基于 importance 衰减的自动遗忘（仅 CrewAI recency 半衰 + 社区 RFC 提及），这是我们的可切入空白点。

---

## 四、对我们的启示（构建自有 Memory 体系）

1. **记忆 ≠ 对话历史**。所有 2025-2026 框架都区分"会话历史（short-term/checkpointer/session）"与"长期记忆（store/memory service）"。我们应把两者分开设计，历史用追加日志，记忆用可更新文档/记录。

2. **采用 agentic memory（LLM 写读）是大势**。LangMem 明确"LLM 决定何时写、改、删"；CrewAI/ADK/AWS 也在保存时用 LLM 分析。但要注意：把 LLM 放进写路径（hot path）会引入延迟与不可控性——可复制"hot path（agent 工具，低延迟）+ background（事后提炼，深度合并）"双通道（LangMem 的两种 formation 方式）。

3. **四类记忆模型值得直接采用**：语义（facts/profile）、情景（episodic）、程序（procedural/rules）、工作上下文（working memory/scratchpad）。LangMem 的 Profile vs Collection 之分尤其有用：常变状态用 profile（单文档覆盖更新），知识积累用 collection（逐条检索）。

4. **存储层可借鉴 namespace 分层**（LangGraph BaseStore / CrewAI scope / Mem0 entity scope / AgentCore namespace 模板）：
   - 作用域维度：user_id、agent_id、org/team、session。
   - 读写分离：共享读 + 私有写，是天然的多 agent 共享模式（LangMem shared namespace 读写分离）。

5. **检索必须是混合的**：纯向量会漏掉精确标识符。可组合：语义（embedding top-k）+ 关键词（BM25/全文）+ 元数据过滤 + 可选图遍历。CrewAI 的复合评分（语义×时效×重要性）是简单可落地的折中；Zep 的时间窗与 Mem0 的 rerank 是进阶。

6. **遗忘/合并要显式设计**：至少具备
   - 保存时去重/合并（CrewAI consolidation、Mem0 冲突解决）；
   - recency 衰减（CrewAI half-life 30 天）；
   - 容量策略（token_limit + priority 截断，LlamaIndex 方案最清晰）；
   - 人工可编辑/审计（Claude memory 版本化、AgentCore 审计是先进参考）。

7. **与 context window 的关系 = 分层 + 渐进披露**：常驻小摘要/Profile（预算内，如 25KB），按需工具检索详情，后台提炼长程知识。避免把记忆整体塞进 context。

8. **多 agent 共享是架构问题不是功能问题**：LangMem（namespace 读写分离）、ADK（`user:`/`app:` state 前缀）、Letta（共享 block）、AgentCore（actor/session 隔离）各给出一种答案。建议：作用域树 + 读写 ACL + 来源（provenance）标签，并保留 private 记录（CrewAI private+source）。

9. **可选前瞻**：如果业务需要"事实何时为真"（订阅、状态、合规），bi-temporal 图谱（Graphiti）是 2026 年独一份的能力；否则 Mem0 式的向量+实体记忆足够。

---

## 五、原始资料索引

`sources/frameworks/` 下按框架保存（`*-memory.md`，部分为官方 HTML 渲染文本 + 原始 HTML）：
langmem-index/conceptual/hotpath/tools/background/extract-semantic/user-profile/summarization + langmem-readme、langgraph-stores、langchain-memory-concept、llamaindex-memory、crewai-memory、autogen-memory、semantic-kernel-memory、openai-agents-sdk-memory、claude-agent-sdk-memory、pydantic-ai-memory、adk-memory/adk-sessions/adk-state、aws-agentcore-memory、mem0-memory、zep-graphiti-memory、letta-memory、cognee-memory。
