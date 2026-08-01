# 工业界官方 Agent Memory 设计调研笔记（2026 年 8 月）

> 本笔记基于各公司**官方第一手资料**（官方文档、官方 blog）撰写。原始资料见 `../sources/industry/`。所有引文均可回溯到对应官方页面。调研时间：2026-08-01。

---

## 一、各厂商核心方案一句话

| 厂商 | 一句话方案 |
| --- | --- |
| **OpenAI** | ChatGPT 记忆 = 显式 saved memories + 后台自动合成的 "Dreaming"（V3，2026-06 推出，可离线评估三项记忆目标）；开发者侧 = Agents SDK 的 Session（短期）与 Sandbox Agent Memory（长期，两阶段抽取→合并）。 |
| **Anthropic** | 记忆即文件：Memory tool（客户端 CRUD `/memories` 目录）+ 服务端 Context editing/Compaction + Managed Agents 的文件系统 memory store；配《Effective context engineering》整套方法论文档。 |
| **Google** | ADK 三层模型（Session / State / MemoryService）+ Vertex AI Memory Bank（LLM 抽取+合并+向量检索+TTL+revision），主张 "context is a compiled view"（存储与呈现分离）。 |
| **Microsoft** | Copilot 记忆存在 Exchange 邮箱隐藏文件夹（saved memories + chat history 推断 + custom instructions）；Agent Framework 用 Context/History Provider 抽象（向量语义记忆、Neo4j 图记忆、Mem0/Cognee）；Windows Recall 是本地快照+向量索引的"摄影式记忆"。 |
| **AWS** | AgentCore Memory 全托管服务：短期事件存储（不可变事件流）+ 长期记忆（异步抽取/合并，namespace + 内置 strategy：语义/摘要/偏好）+ 2025-12 新增 episodic 记忆。 |
| **Meta** | Meta AI 1:1 聊天记忆（显式/上下文捕获，可删除）；模型层靠 Muse Spark 1.1 的 1M 上下文窗口 + "compact" 能力，无公开的完整记忆架构文档。 |
| **xAI** | Grok memory（2025-04 beta）：根据对话记忆个性化，"Referenced Chats" 透明展示引用来源，可关闭/删除；无公开技术细节。 |
| **NVIDIA** | 以 1M 上下文窗口（Nemotron 3）+ RAG/向量检索（NeMo Retriever/AI-Q）作为记忆手段，主张长上下文替代分块；无独立记忆工具 API。 |

---

## 二、各厂商方案对比表

### 2.1 记忆类型分层

| 厂商 | 短期/会话内 | 长期/跨会话 | 用户显式指令层 |
| --- | --- | --- | --- |
| OpenAI (ChatGPT) | chat history 引用（2025-04 起） | saved memories + Dreaming 合成记忆（memory summary 呈现） | Custom Instructions |
| OpenAI (Agents SDK) | `Session`（SQLite/Redis/Mongo/Dapr/…） | Sandbox `Memory()`（`memories/MEMORY.md` + `memory_summary.md`） | Agent `instructions`（静态/动态函数） |
| Anthropic | 上下文窗口 + Compaction + Context editing | Memory tool（`/memories` 文件）+ Managed Agents memory store | System prompt / CLAUDE.md |
| Google ADK | `Session` + `State`（`user:`/`app:`/`temp:` 前缀） | `MemoryService`（Memory Bank / RAG / InMemory） | Instruction 模板 `{placeholder}` |
| Microsoft | Agent Framework `AgentSession` / History Provider | Copilot: saved memories + chat history 推断；AF: ChatHistoryMemoryProvider / Neo4j / Mem0 | Copilot Custom Instructions |
| AWS | AgentCore Memory 短期事件（actor/session 隔离） | 长期记忆记录（语义/摘要/偏好 strategy + episodic） | —（用 namespace 组织） |
| Google (consumer) | 会话内对话 | Gemini "Memory"（过去聊天）+ Saved Info（"ask Gemini to remember"）+ Personal Intelligence | Saved Info / 提示词 |

### 2.2 写入机制

| 厂商 | 写入机制 |
| --- | --- |
| OpenAI ChatGPT | ①用户显式 "remember..."；②模型自动捕获（有明确意图才写）；③Dreaming 后台自动从历史合成（离线更新记忆状态，不依赖显式请求） |
| OpenAI SDK | 每 run 后自动持久化新 items；Sandbox Memory 在 sandbox session 关闭时两阶段生成（Phase1 对话抽取 → Phase2 布局合并） |
| Anthropic | 模型自主调用 memory tool 的 create/str_replace/insert/delete/rename（客户端执行）；Managed Agents 用文件工具写 `/mnt/memory/` |
| Google ADK | `add_session_to_memory` / `add_events_to_memory` / `add_memory`；Memory Bank `GenerateMemories`（异步、按批处理规则）+ `CreateMemory`（memory-as-a-tool） |
| Microsoft | Copilot 仅在"明确意图"时保存；AF 在每次 invocation 后存（embeddings 向量化）或 LLM 抽取实体入图 |
| AWS | `CreateEvent` 同步存短期（不可变）；长期为**异步后台**抽取+合并（有延迟，需缓存/hydration 策略配合） |
| Meta | 1:1 聊天显式 + 上下文捕获 |
| xAI | 对话中自动捕获偏好，无公开细节 |

### 2.3 检索机制

| 厂商 | 检索机制 |
| --- | --- |
| OpenAI ChatGPT | 每次对话注入 saved memories + 参考 chat history；memory sources 显示引用来源 |
| OpenAI SDK | Session 历史全量或 limit 截断注入；Sandbox memory 渐进披露（先注入 summary，再按需搜 MEMORY.md 关键词 → 打开 rollout_summaries） |
| Anthropic | 会话开始时模型自动 view `/memories`；just-in-time 按需读取（渐进披露） |
| Google ADK | 主动 recall（`preload_memory` 注入）+ 被动 recall（`load_memory` tool）；Memory Bank 用按 identity 隔离的向量相似度搜索 |
| Microsoft | AF 语义相似检索（默认取 top-3，注入 `## Memories` 提示块）；Neo4j 图查询；Copilot 用 chat history 推断 |
| AWS | `RetrieveMemoryRecords` 语义搜索；`ListEvents`/`GetEvent` 短期；metadata 过滤 + namespace 精确定位 |
| xAI | "Referenced Chats" 侧栏显示引用来源 |

### 2.4 更新与删除

| 厂商 | 更新/遗忘机制 |
| --- | --- |
| OpenAI ChatGPT | 模型自动合并/更新/删除记忆；Dreaming 按时间自动修正（"going to Singapore"→"went"）；用户可编辑/删除 memory summary、关闭记忆、临时聊天 |
| OpenAI SDK | `pop_item` 回滚最后一条；Sandbox memory 有 recency-based forgetting（超过 `max_raw_memories_for_consolidation` 丢弃旧记忆） |
| Anthropic | 模型自主编辑记忆文件；Managed Agents 有 audit log、版本回滚、redact；memory tool 路径越界防护 |
| Google ADK | Memory Bank consolidation 合并演化 + TTL 自动过期 + memory revisions（可审计记忆如何变换）+ IAM 条件控制读写 |
| Microsoft | Copilot：用户删除 saved memory；chat history 推断动态更新/丢弃（关掉后 30 天删除） |
| AWS | 事件不可变（编辑用 branching）；长期记录可刷新合并；namespace 控制访问；KMS 加密 |
| Meta | 用户随时删除记忆 |

### 2.5 长上下文策略

| 厂商 | 长上下文/压缩策略 |
| --- | --- |
| OpenAI | `OpenAIResponsesCompactionSession`（`responses.compact` 自动/强制）；Cookbook 提供 Trimming + Summarization 模板；强调"会话即记忆对象" |
| Anthropic | ①Compaction（服务端 `compact_20260112`，默认 150K 触发）②Context editing/tool-result clearing（`clear_tool_uses_20250919`）③Structured note-taking（agentic memory）④Sub-agent 隔离 ⑤1M 上下文 |
| Google ADK | Session 层 Context Compaction（滑动窗口 LLM 摘要写回 Session 事件流）+ Filtering + Context caching（稳定前缀/静态 instruction）+ Artifacts handle 模式（大对象外置） |
| Microsoft | Token truncation provider；Agent Framework 消息过滤；无统一服务端压缩，靠 provider 组合 |
| AWS | 长期记忆摘要化替代全文；事件 expiry（最长 365 天） |
| NVIDIA/Meta | 直接用 1M token 上下文窗口减少分块（Meta Muse Spark / NVIDIA Nemotron 3） |

---

## 三、产业共识（可交叉验证的设计原则）

1. **记忆必须分层**：会话内短期（上下文/History）+ 跨会话长期（Memory）是不同的子系统。Google ADK 明确 Session/State/Memory/Artifacts 四层；AWS 分 short-term events / long-term records；Anthropic 区分 compaction（会话内）与 memory（跨会话）；OpenAI 区分 Session（短期）与 Memory（长期）。

2. **长期记忆的主流写法 = LLM 抽取 + 合并（consolidation）+ 语义检索**，而不是存原文：
   - Google Memory Bank：extraction + consolidation + similarity search（"memory must be searchable, not permanently pinned"）。
   - AWS AgentCore：异步 extraction + consolidation，3 个内置 strategy。
   - OpenAI Dreaming：后台合成记忆状态；sandbox memory 两阶段。
   - Microsoft/Mem0：extraction → update 两阶段。
   - 共识要点：**只保留"高价值"信息；新记忆要与旧记忆合并演化，避免冗余与矛盾**。

3. **记忆的写入/检索越来越"agent-directed"（由 agent 自主决定）**：
   - Anthropic memory tool、Google ADK `load_memory` tool（reactive recall）、Google `CreateMemory`（memory-as-a-tool）、OpenAI 的渐进披露 + live update，都是让模型自己在运行时决定何时读写。
   - 但同时保留 "preload / proactive" 通道（Google `preload_memory` 工具、OpenAI 注入 memory_summary）。

4. **渐进披露（progressive disclosure）是标准检索模式**：先注入小摘要，agent 判断是否相关，再按需深入（Anthropic、OpenAI sandbox memory、Google）。

5. **"context is a finite resource"（上下文轮），压缩是必备能力**：Anthropic 的 context rot / attention budget 论述是产业基准。压缩手段分层：compaction（整体摘要）、tool-result clearing（清理工具结果）、filtering/trimming（丢弃旧轮次）、sub-agent 隔离、memory offload（移出窗口）。

6. **用户可控性/可解释性是产品级硬要求**：OpenAI memory summary + sources、Anthropic memory summary + incognito、Microsoft memory settings + Purview 合规、xAI Referenced Chats、Gemini Saved Info 均提供"查看、编辑、删除、关闭、临时对话"五件套。

7. **安全是显式设计维度**：路径越界防护（Anthropic）、memory poisoning 风险（AWS、Google 显式警告）、PII 剥离（AWS 默认忽略 PII、Codex redact secrets）、DLP 集成（Windows Recall）、审计日志（Managed Agents、AgentCore）。

---

## 四、各家差异与争议点

1. **存储介质哲学分歧：文件 vs 数据库/向量/图**
   - Anthropic（及早期 OpenAI sandbox）坚持**记忆即文件**（`/memories`、`MEMORY.md`、`NOTES.md`）：可移植、可审计、模型用熟悉工具访问、与代码工作流天然契合。Anthropic 甚至把"filesystem-based memory 让模型保存更全面、更有组织"当作产品卖点（Opus 4.7 + Managed Agents）。
   - Google/AWS/Microsoft 提供**托管存储抽象**（Memory Bank、AgentCore、vector store/Neo4j/Mem0），强调托管、隔离、检索能力。
   - 争议：文件简单透明但检索弱；向量/图检索强但黑盒。产业尚未收敛，多家同时支持两种（OpenAI 既有 Session DB 又有 sandbox files；微软既有向量又有图）。

2. **模型窗口 vs 外部记忆之争**：OpenAI/Anthropic/Google 的工程文档一致认为"**等更大上下文窗口不够**"（context rot 与成本），主张外部记忆 + 压缩；而 Meta（Muse Spark 1M）与 NVIDIA（Nemotron 3 1M）把"大窗口原生 + 模型自管理压缩"作为路线，认为可以减少分块启发式。这是 2026 年最尖锐的路线分歧。

3. **记忆是否"学习/演化"**：OpenAI Dreaming 明确把"随时间保持新鲜"（时间流逝感知）作为第三目标，自动把"将要"改为"已经"；Google Memory Bank 有 consolidation + revisions + TTL；AWS 有 consolidation。而简单的 saved-memory 方案（早期 ChatGPT、Meta、xAI）容易陈旧。2026 年的趋势是"记忆状态"而非"记忆条目"。

4. **multi-agent 记忆共享 vs 隔离**：Anthropic Managed Agents 支持跨 agent 共享 store + 不同 scope 权限（org 只读 / user 可写）；OpenAI sandbox memory 用 layout 隔离（GTM 与 engineering 分开）；AWS 用 namespace 隔离；Google 用 identity scope 隔离。**"隔离优先、按需共享"是主流**，但 Anthropic 明确提供并发写同一 store 的能力。

5. **协议层是否管记忆**：A2A 协议明确**不暴露内部状态/记忆**（记忆是 agent 内部责任，仅通过 context_id 映射）；MCP 提供 memory server 参考实现但属生态层。**记忆标准化仍停留在厂商各自产品层**。

6. **隐私/合规立场差异**：Microsoft 把 Copilot 记忆放进 Exchange 邮箱（复用既有合规/发现基础设施），Windows Recall 走完全本地加密（VBS Enclave + Windows Hello）；Google 把 Personal Intelligence 设计成"数据已在 Google，无需外传"；xAI 因 EU/UK 法规暂缓记忆。**记忆的存储位置（云端 vs 本地）与合规框架深度绑定**。

7. **评测数据稀缺且口径不一**：公开量化数据仅少数：Anthropic（context management +39% 性能、-84% token；Managed Agents 记忆 -97% 首过错误、-27% 成本、-34% 延迟；Wisedocs +30% 验证速度）、Rakuten -97%。OpenAI Dreaming 只给了相对提升方向性结论。缺乏统一公开 benchmark（学术圈有 LoCoMo、MemBench、LongMemEval 但未被工业界采纳为官方评测）。

---

## 五、对我们 Memory 设计的启示

1. **分层架构是地基**：采用 Session（会话）+ State（会话内结构化状态）+ Long-term Memory（跨会话）+ Artifacts（大对象外置）四层模型（对齐 Google ADK 与 OpenAI SDK 的划分）。会话内压缩（compaction/trimming）与跨会话记忆必须是两个独立子系统。

2. **长期记忆管线照抄"抽取→合并→检索"三步**：记忆不是原文备份，而是 LLM 抽取出的高信号事实/偏好/摘要，新记忆与旧记忆 consolidation（防冗余与矛盾），检索用语义相似度 + 渐进披露（先摘要后细节）。可参考 OpenAI Dreaming 的时间感知更新（"计划"→"已完成"）作为高级目标。

3. **读写交给 agent，但留 preload 通道**：设计成 tool（`remember`/`recall`/`forget`），同时支持每轮开始自动注入摘要；让模型决定是否深入。渐进披露（summary → index → detail）能显著省 token。

4. **压缩策略做成可组合的原语**：compaction（LLM 整体摘要）、tool-result clearing（清理旧工具结果）、trimming（最近 N 轮）、sub-agent 隔离、memory offload 五件套，按瓶颈选择（参考 Anthropic context engineering cookbook 的决策框架：整窗过大→compaction；可重取工具结果→clearing；需跨会话→memory）。

5. **遗忘与更新是一等公民**：需要 TTL/recency-based forgetting（OpenAI、Google）、合并演化（consolidation）、显式删除/关闭/临时会话、版本/审计（Managed Agents、Memory Bank revisions）。记忆会 stale 和 poisoning，需要检测与回滚手段。

6. **隔离优先、按需共享**：默认按 user/session/agent/namespace 隔离（AWS namespace、Google scope、OpenAI layout），需要时再显式共享（Anthropic store 共享 + 权限）。

7. **可解释性与用户控制不可省**：任何产品级记忆都要有"记忆摘要/面板、引用来源、单条删除、全局关闭、incognito/临时会话"。这是 OpenAI、Anthropic、Microsoft、Google、xAI 五家的共同最低要求。

8. **存储介质按需混用**：结构化事实用关系/文档/图存储，语义检索用向量，过程状态用文件/JSON（Anthropic 的文件方案在 agentic coding 场景被证明高效）。不必二选一；文件适合"记忆即工作产物"场景，向量+图适合"大范围语义召回"场景。

9. **安全设计前置**：路径越界、prompt injection / memory poisoning（AgentCore 与 Memory Bank 都列为显式威胁）、PII 过滤、密钥加密、审计日志，都应作为记忆子系统的内建能力而非事后补丁。

10. **留意路线分歧，不孤注一掷**：1M 窗口模型（Meta/NVIDIA）可能在部分场景减少对外部记忆的依赖，但 OpenAI/Anthropic/Google 一致认为长窗口不能替代记忆管理（成本 + context rot）。我们的设计应让"大窗口可用"与"外部记忆"兼容：即使窗口够大，也保持抽取-合并-检索的管线。

---

## 六、关键官方链接与最新动态（2025–2026）

### OpenAI
- ChatGPT Dreaming (2026-06-04)：https://openai.com/index/chatgpt-memory-dreaming/
- Memory 与 controls (2024-02，含 2025-04/2025-06 更新)：https://openai.com/index/memory-and-new-controls-for-chatgpt/
- Memory FAQ：https://help.openai.com/en/articles/8590148
- Agents SDK Sessions：https://openai.github.io/openai-agents-python/sessions/
- Agents SDK Context：https://openai.github.io/openai-agents-python/context/
- Agents SDK Sandbox Memory：https://openai.github.io/openai-agents-python/sandbox/memory/
- Session memory cookbook：https://developers.openai.com/cookbook/examples/agents_sdk/session_memory
- Long-term memory cookbook (2026-01)：https://developers.openai.com/cookbook/examples/agents_sdk/context_personalization
- Codex memories：https://learn.chatgpt.com/docs/customization/memories
- **最新动态**：2026-06 Dreaming V3 上线（Plus/Pro 美国，5x 算力优化，向 Free 扩展）；2026-05 memory sources 与参考 chat history 检索增强；Plus/Pro 记忆容量翻倍。注：未发现 OpenAI 官方发表标题为 "Effective context engineering for AI agents" 的独立文章（该文是 Anthropic 的）；OpenAI 的 context engineering 实践落在 Agents SDK 文档与 cookbook 中。

### Anthropic
- Memory 进 Claude app (2025-09-11；10-23 扩至 Pro/Max)：https://claude.com/blog/memory
- Context management（memory tool + context editing，2025-09-29）：https://www.anthropic.com/news/context-management
- Memory tool 文档：https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool
- Context editing 文档：https://platform.claude.com/docs/en/build-with-claude/context-editing
- Effective context engineering (2025-09-29)：https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- Building effective agents：https://www.anthropic.com/engineering/building-effective-agents
- Managed Agents Memory (2026-04-23)：https://claude.com/blog/claude-managed-agents-memory
- **最新动态**：2025-09 memory tool GA（`memory_20250818`，Claude 4+）；2026-01 compaction `compact_20260112`；2026-04 Managed Agents memory public beta（文件系统 store、audit log、多 agent 并发）；2026-04 Opus 4.7 强化文件系统记忆。公开评测：context management +39% 性能、-84% token；Managed Agents 记忆 -97% 首过错误。

### Google
- ADK Memory：https://adk.dev/sessions/memory/
- ADK 状态：https://github.com/google/adk-docs/blob/main/docs/sessions/state.md
- ADK context engineering blog (2025-12-04)：https://developers.googleblog.com/architecting-efficient-context-aware-multi-agent-framework-for-production/
- Memory Bank：https://cloud.google.com/gemini-enterprise-agent-platform/scale/memory-bank
- A2A 协议 (Linux Foundation, v1.0)：https://a2a-protocol.org/v1.0.0/specification/
- Gemini consumer memory：https://blog.google/innovation-and-ai/products/gemini-app/switch-to-gemini-app/
- Personal Intelligence (2026-01-14)：https://blog.google/innovation-and-ai/products/gemini-app/personal-intelligence/
- **最新动态**：2025-08 Memory Bank 作为 Vertex AI Agent Engine 组件；2025-12 ADK context 编译模型（Sessions/Memory/Artifacts + flows/processors）；2026 年改名 Gemini Enterprise Agent Platform；2026-01/03 Gemini app 上线 Personal Intelligence 与记忆导入/聊天历史导入（"past chats"更名"memory"）。A2A v1.0 不含记忆抽象。

### Microsoft
- Copilot personalization & memory：https://learn.microsoft.com/en-us/microsoft-365/copilot/copilot-personalization-memory
- Agent Framework memory：https://learn.microsoft.com/en-us/agent-framework/get-started/memory
- Chat History Memory Provider：https://learn.microsoft.com/en-us/agent-framework/integrations/chat-history-memory-provider
- Windows Recall：https://learn.microsoft.com/en-us/windows/apps/develop/windows-integration/recall/
- **最新动态**：Copilot memory（saved memories + custom instructions）2025-07 GA；2026-01 起用 chat history 个性化（GA 完成预计 2026-07）；记忆存 Exchange 邮箱隐藏文件夹（复用合规）。Agent Framework（AutoGen/Semantic Kernel 合并）以 Context/History Provider 提供记忆抽象。Recall 2025-04 GA（本地加密快照 + 语义索引 + VBS Enclave）。

### AWS
- AgentCore Memory 文档：https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/memory.html
- Memory types：https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/memory-types.html
- Memory blog (2025-08-13)：https://aws.amazon.com/blogs/machine-learning/amazon-bedrock-agentcore-memory-building-context-aware-agents/
- re:Invent 2025 公告：https://aws.amazon.com/about-aws/whats-new/2025/12/amazon-bedrock-agentcore-policy-evaluations-preview/
- **最新动态**：2025-08 AgentCore Memory GA（AWS Summit NYC）；2025-12 episodic 记忆 GA + Policy（自然语言→Cedar，2026-03 GA）+ Evaluations（13 内置评估器，2026-03 GA）；metadata 过滤、RBP、record streaming；Harness GA 内建 memory。2M+ 下载。

### 其他
- Meta：https://about.fb.com/news/2025/01/building-toward-a-smarter-more-personalized-assistant/ （1:1 记忆）；Muse Spark 1.1 (2026) 1M 上下文。
- xAI：https://x.ai/legal/faq ；Grok memory 2025-04 beta，"Referenced Chats"。
- NVIDIA：Nemotron 3 (2025-12) 原生 1M 上下文；AI-Q/NeMo Retriever RAG 蓝图；Vera CPU 图遍历 prefetcher（"agent memory traversal"）。
- Anthropic MCP memory server 为生态参考实现（记忆标准化未达协议层）。
