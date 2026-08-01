# Agent Memory 体系设计：领域综述研究报告

> 调研日期：2026-08-01 · 项目：YUKI.N Memory 体系设计
> 方法：7 个并行调查组，全部基于**第一手原始资料**（arXiv 论文原文 / 官方文档 / 官方博客 / 规范原文 / 社区原文），逐条核实编号与链接；本报告为跨维度综合，原始资料见 `sources/`，各维度精读笔记见 `notes/`。
> 时效性声明：本领域 2025-2026 变化剧烈，报告中所有事实均以 2026-08 抓取的原文为准；多个任务清单中的 arxiv 编号经核实为错误（详见 §9.3 编号核验记录），已在正文使用核实后的正确编号。

---

## 0. 执行摘要（30 秒结论）

Agent 的 Memory 已经从"给 LLM 外挂一个向量检索"演进为**独立的一等系统组件**，2025 下半年到 2026 年发生范式级转向，四条主线同时展开：

1. **记忆分层是唯一共识**：几乎所有系统（学术/工业/框架/平台）都收敛到"工作记忆/短期上下文 + 跨会话长期记忆 + 可选的图/时态层"，CoALA 的 working/episodic/semantic/procedural 四分类成为标准术语。
2. **长期记忆的主流写法 = LLM 抽取 → 合并演化 → 语义/混合检索**（不再存原文）；写入从"系统启发式"走向"agent 自主决定 + 门控校验"双通道。
3. **遗忘与更新从被忽视变成一等公民**：知识更新（KU）、矛盾消解（CR）、选择性遗忘在 2025-2026 被评测体系正式收编，"该忘不忘"首次成为可量化指标（FAMA）。
4. **可信性与安全成为显式议程**：记忆投毒（OWASP ASI06）、检索准入门控、写路径校验、TEE、防洗白，2026 年已形成独立子领域。

**三个被反复证实的反面结论**（跨维度交叉验证，无需再论证）：
- **长上下文窗口 ≠ 记忆**：LongMemEval 上长上下文 LLM 比 oracle 检索降 30–60%；BEAM 上 1M 上下文模型 + RAG 仍失败；社区实测超过 ~100K token 后 agent 开始重复旧动作。
- **向量检索 ≠ 记忆**：纯 vector top-k 在 LongMemEval 上约 49%，混合/图/结构化方案 71–95%；"检索到"不等于"记住并会用"。
- **小基准可被暴力刷分**：简单 RAG 就能刷过 LoCoMo/LongMemEval 的大部分题；引用任何分数必须核对 token 预算、top-k、judge 与评测协议。

---

## 1. 研究方法与资料来源

| 维度 | 调查组 | 核心交付物 |
|---|---|---|
| 学术奠基（2023-2025） | A | `sources/papers/`（12 篇精读全文）+ `notes/academic-foundational/README.md` |
| 学术最新（2025-2026） | B | `sources/papers/`（30 篇）+ `notes/academic-recent/README.md` |
| 工业界官方 | C | `sources/industry/`（28 份官方原文）+ `notes/industry/README.md` |
| 开发框架 | D | `sources/frameworks/`（23 份）+ `notes/frameworks/README.md` |
| 记忆平台/MaaS | E | `sources/memory-platforms/`（6 组）+ `notes/memory-platforms/README.md` |
| 基准与评测 | F | `sources/benchmarks/`（39 份）+ `notes/benchmarks/README.md` |
| 社区生态与标准 | G | `sources/community/`（30 份）+ `notes/community/README.md` |

合计：**262 个原始资料文件 + 7 份精读分析笔记**。

---

## 2. 领域全景：七个维度的现状

### 2.1 学术奠基（2023–2025）——从"检索增强"到"记忆管理"

**思想脉络**：RAG（2020，arXiv 2005.11401）把外部知识抽象为"可替换的非参数化记忆"→ Generative Agents（2023，2304.03442）给出**记忆流 + 反思 + 规划**、检索评分三要素 `recency × importance × relevance` → MemGPT（2023，2310.08560）用**操作系统分层内存**（context=RAM、外部存储=磁盘）+ 函数调用自驱读写 → MemoryBank（2023，2305.10250）引入**艾宾浩斯遗忘曲线** `R=e^(−t/S)`（召回即强化）→ CoALA（2023，2309.02427）给出**记忆分类学**（working/episodic/semantic/procedural）→ HippoRAG（2024，2405.14831）用**知识图谱 + 个性化 PageRank**做一步多跳联想 → A-MEM（2025，2502.12110）用 **Zettelkasten 原子笔记 + 记忆演化** → Mem0（2025，2504.19413）把更新抽象为 **ADD/UPDATE/DELETE/NOOP 四类 LLM 裁决操作** → HippoRAG 2（2025，2502.14802）以"**概念×上下文双编码 + 识别记忆**"修正实体中心缺陷。

**三条主线**：
1. 检索→管理：静态索引 → 模型自决读写/逐出 → 记忆组织与更新也交给模型。
2. 文本→结构化：自然语言 → KG+PPR → 有向图 → 概念/段落双编码；反复出现的张力是"实体中心损失上下文"。
3. 遗忘从被忽略到一等公民：无删除 → 遗忘曲线 → 理论遗忘界（MemoryLLM 的 1/e）→ 冲突消解 DELETE/标记 invalid。

**关键教训**：写入决定读取；评估从 F1 走向 LLM-as-Judge + 能力五维 + 延迟/token 部署指标；图必须与向量互补而非替代（Mem0^g 在多跳上反而不如 dense）。

### 2.2 学术最新（2025–2026）——范式级转向

四条主线（详见 `notes/academic-recent/README.md`）：

1. **记忆策略学习化（RL 接管记忆）**：AgeMem（2601.01885）、Mem-T（2601.23014）、Mem-α（2509.25911）、Memory-R1（2508.19828）、MEM1（2506.15841）、MemAgent（2507.02259）把"何时写/读/改/删/压缩"从手工规则变成端到端 RL 策略，GRPO 族成为标配。核心难题收敛到"**长链稀疏奖励与 credit assignment**"，三个独立框架（AgeMem 的 step-wise GRPO、Mem-T 的 MoT-GRPO 树回溯、TrustMem 的 Transition-Ranked GRPO）收敛到同一解法族。Mem-α 证明弱模型（4B）+ RL 可超越强模型（gpt-4.1-mini）的记忆管理能力。
2. **分层 + 图 + 显式巩固成为工程事实标准**：MemoryOS（2506.06326）、MemVerse（2512.03627）、G-Memory（2506.07398）、GAM（2604.12285）、HippoRAG2 结构高度收敛。**关键共识：巩固（consolidation）必须显式、被触发、原子化**；GAM 的"写入隔离缓冲 + 语义事件触发升迁"成为一致性最佳实践。
3. **评测从 recall 走向决策耦合与遗忘**：MemoryArena（2602.16313）证明"被动 recall 高分 ≠ 好用记忆"（LoCoMo 近饱和模型在决策耦合任务只剩 40–60%）；Memora（2604.20006）的 FAMA 指标把"该忘不忘"变成可量化惩罚；MemoryAgentBench（2507.05257）把**选择性遗忘**列为一等能力（多跳冲突消解当前仅 ≤7% 准确率）。
4. **可信性与安全成为显式议程**：MemGate（2606.06054，任务条件化检索准入，跨域泄漏 27%→3.5%）、TrustMem（2606.25161，迁移级写路径校验）、MemTrust（2601.07004，TEE 零信任）、TMA-NM（2606.24322，防投毒：内容/谱系防御可被洗白，需源绑定）。

**2023-2024 vs 2025-2026 的本质差异**：前者解决"**能不能记住**"（context 不够 → 外部存储）；后者解决"**该记什么、何时忘、怎么用得对、是否可信**"。

### 2.3 工业界官方方案

| 厂商 | 一句话方案 | 关键动态（2025–2026） |
|---|---|---|
| **OpenAI** | ChatGPT = 显式 saved memories + 后台自动合成记忆 **Dreaming**（V3，2026-06，时间感知更新"将要→已经"）；开发者侧 = Agents SDK Session（短期）+ Sandbox Agent `Memory()`（长期，两阶段抽取→合并） | 2026-05 memory sources 透明化；无官方《Effective context engineering》文章（那是 Anthropic 的） |
| **Anthropic** | **记忆即文件**：memory tool（模型 CRUD `/memories`）+ 服务端 Context editing/Compaction + Managed Agents 文件系统 memory store；《Effective context engineering》方法论 | memory tool GA 2025-09；compaction `compact_20260112`；Managed Agents memory beta 2026-04（audit log/回滚/多 agent 并发）；公开评测 +39% 性能 / −84% token |
| **Google** | ADK 三层（Session/State/MemoryService），"**context is a compiled view**"；Vertex AI **Memory Bank**（LLM 抽取+合并+向量检索+TTL+revision） | 2025-12 ADK context 编译模型；2026 改名 Gemini Enterprise Agent Platform；Gemini app 上线 Personal Intelligence |
| **Microsoft** | Copilot 记忆存 Exchange 邮箱隐藏文件夹；Agent Framework 用 Context/History Provider（向量/Neo4j 图/Mem0/Cognee）；Windows Recall = 本地加密快照+语义索引 | Copilot memory 2025-07 GA，2026-01 起 chat history 个性化；Recall 本地 VBS Enclave |
| **AWS** | **AgentCore Memory** 全托管：短期不可变事件流 + 长期记忆（异步抽取+合并，3 内置 strategy：语义/摘要/偏好，namespace 隔离） | 2025-08 GA；2025-12 加 **episodic 记忆** + Policy（自然语言→Cedar）+ Evaluations；2M+ 下载 |
| **Meta / xAI / NVIDIA** | Meta 1:1 聊天记忆 + Muse Spark 1.1 1M 上下文；xAI Grok memory + "Referenced Chats"；NVIDIA 以 1M 窗口（Nemotron 3）+ RAG 替代分块 | 均无公开完整记忆架构 |

**产业七共识**：①记忆必须分层（会话内 vs 跨会话是不同子系统）；②长期记忆 = 抽取→合并→语义检索，不存原文；③写读越来越 agent-directed，但保留 preload/proactive 通道；④渐进披露（summary → 按需深入）是标准检索模式；⑤压缩五件套（compaction / tool-result clearing / trimming / sub-agent 隔离 / memory offload）；⑥用户可解释可删除是产品级底线；⑦memory poisoning 是显式安全威胁。

**最大路线分歧**：OpenAI/Anthropic/Google 一致认为"等更大上下文窗口不够"（context rot + 成本），主张外部记忆 + 压缩；Meta/NVIDIA 押注"1M 原生窗口 + 模型自管理压缩"。存储介质也分裂为"文件（Anthropic）" vs "托管向量/图（Google/AWS/微软）"两派。

### 2.4 开发框架层

13 个框架可分三类哲学（对比矩阵见 `notes/frameworks/README.md`）：

- **隐式 context 派**（记忆=对话历史）：OpenAI Agents SDK（Session 仅历史）、pydantic-ai（消息序列化 + 2026 tiered store）、Semantic Kernel（只管向量底座）、Claude Agent SDK（文件即记忆，渐进加载 200 行/25KB）。
- **显式记忆抽象派**（记忆=一等公民，LLM 管写读更新）：LangGraph+LangMem（agentic memory，BaseStore namespace+KV+向量底座，语义/情景/程序三类，hot path 工具 + 后台 memory manager 双通道）、LlamaIndex（Memory 类 + MemoryBlocks，token_limit+priority 截断）、CrewAI（统一 Memory + LLM 推断 scope/重要性，LanceDB）、AutoGen（最小 Memory 协议）、Google ADK（MemoryService）、AWS AgentCore。
- **图谱记忆派**（记忆=结构化知识）：Zep/Graphiti（bi-temporal，可答"何时为真"）、Cognee（ECL 管线 → typed 图谱 + 14 检索模式）。

**关键洞见**：
- 所有框架都区分**会话历史**（追加日志）与**长期记忆**（可更新文档/记录）——我们的设计必须照此分开。
- 显式派里存在"**谁决策**"差异：LangMem/Letta 让 **agent 自己**用工具决定（hot path）；CrewAI/ADK/AWS/Mem0 由**框架管线**决定（后台抽取）。最佳实践是双通道：hot path（agent 工具，低延迟）+ background（事后提炼）。
- **无人原生实现基于 importance 衰减的自动遗忘**——这是框架共同空白，是我们可切入的点。

### 2.5 记忆平台 / 记忆即服务

三种记忆形态（详见 `notes/memory-platforms/README.md`）：

1. **提取式**（Mem0、Supermemory、Weaviate Engram）：`add()` 内 LLM 把对话蒸馏为结构化事实，多信号检索（semantic+BM25+entity+temporal）；Mem0 明确 ADD-only（矛盾交给显式 update/delete），有损 + 矛盾堆积是风险。
2. **图式**（Zep/Graphiti、Cognee、Neo4j agent-memory）：实体抽取→resolution→事实边；**Zep 独有双时态 + 自动边失效**（不删除、可回溯，"当时 vs 现在"）；冷启动成本高。
3. **文档式**（Letta memory blocks、Basic Memory、MemFS）：agent 自编辑文档块，透明、可 git 版本化、可迁移；依赖 agent 自觉 + 并发丢写风险。

**写入时机两流派**：同步（Mem0 每交互 `add()`）vs **异步/sleep-time**（Letta dreaming、Supermemory Dynamic Dreaming、Zep ingestion）——2026 明显趋势是**记忆维护从"推理时"转向"空闲时"**。

**商业化**：2025-10 是融资分水岭（Mem0 $24M、Supermemory $2.6M；Letta $10M、Zep $500K）。最大生存威胁 = 模型厂商原生记忆 API 商品化（"when, not if"），防御叙事 = 中立/可迁移/可自托管。MCP 成为记忆分发通道；DB 厂商向上封装（Pinecone Nexus、Chroma Context-1、Neo4j）正面竞争。

### 2.6 评测基准

**能力覆盖演进**：LoCoMo（2402.17753）→ LongMemEval（2410.10813，+知识更新/弃答/偏好）→ MemBench（2506.21605，+反思记忆/观察场景）→ **BEAM**（2510.27246，10 维含矛盾消解/事件排序/指令/偏好，128K–10M tokens）→ **LME-V2**（2605.12493，115M tokens，agent 环境经验）。

**长度标尺**：10K（LoCoMo）→ 115K/1.5M（LongMemEval）→ 1M+（MemoryAgentBench）→ 10M（BEAM）→ 115M（LME-V2）。**评测不标 token 级长度则不可比**。

**方法学共识**（详见 `notes/benchmarks/README.md` §4）：
- **写读分离 + oracle 对照**：先测"给定 oracle 证据能否答对"（读），再测"检索到证据"（检索），差异即记忆系统瓶颈——LongMemEval 范式。
- **时间/遗忘曲线**：多点探测（PERMA 三时间点、MemBench capacity 曲线、Memora 周/月/季）。
- **成本必报**：tokens/query + p50/p95。
- **分层评测建议（L0-L8）**：写入提取→检索→事实回忆→时间线→偏好→更新/冲突→遗忘→技能迁移→端到端，可作为我们 CI 评测管线蓝图。

**一致结论**：人类远胜机器（30-50+ 分差距）；时间推理与知识更新是所有系统共同短板；简单 RAG 检索强但长程理解/冲突消解失败；2026 供应商自报分数普遍未第三方复现。

### 2.7 社区生态与协议标准

**共识**：①vector DB ≠ memory（memory 是"policy"：提取/去重/矛盾/衰减/隔离）；②长上下文 ≠ memory（context rot 四模式：poisoning/distraction/confusion/clash）；③记忆是 context engineering 原语，与 compaction、tool clearing 并列；④主流框架收敛到同一分层架构；⑤agent 自我管理记忆是主流但**必须有写门控**（两段式写入：agent 提议 → validator 裁定）；⑥MCP 是记忆暴露的事实标准接口，但**规范本身不定义 memory**。

**协议现状**：
- **MCP 2026-07-28 大版本（破坏性）**：stateless core（移除 initialize/session 握手）、MRTR、list 缓存提示（`ttlMs`/`cacheScope`，与 prompt caching 直接协同）、Roots/Sampling 废弃。官方 memory server 是 knowledge-graph 型（entities/relations/observations，最小实现）。
- **A2A 刻意不碰 memory**（opaque execution、"Zero Context Pollution"），把持久共享记忆留给互补层；多 agent memory consistency 被称为"最紧迫的开放挑战"。
- **2026-07 仍无任何 ratified 的 agent memory 互操作标准**——不要等标准，自建领域模型。

**两派之争**（社区实测）：
- 轻量派：`MEMORY.md` + 文件 + grep + prompt caching 在 Pareto 前沿，对 ~80% 单用户 coding agent 足够（"MEMORY.md is the right answer for ~80% of solo coding-agent workflows and ~0% of consumer chat products"）。
- 重型派：事实演化、冲突解决、多 session、多用户/时态场景下文件/纯 RAG 非线性退化，需要提取/图/时态/衰减。

---

## 3. 收敛共识（跨维度交叉验证）

以下共识在**至少三个独立维度**中被独立验证，可信度最高：

| # | 共识 | 验证维度 |
|---|---|---|
| 1 | **长上下文窗口 ≠ 记忆**，扩窗口不能替代记忆管理 | 学术（LongMemEval/BEAM/RULER/MemoryArena）+ 工业（Anthropic/OpenAI/Google 立场）+ 社区（Drew Breunig/Zep/实测）|
| 2 | **记忆必须分层**（工作/会话内 vs 跨会话长期，可选图/时态层）| 学术（CoALA/MemGPT/MemoryOS）+ 工业（四层模型共识）+ 框架（13 家全部区分 short/long）+ 平台（Letta 三层）|
| 3 | **长期记忆 = LLM 抽取 → 合并演化 → 语义/混合检索**，不存原文 | 学术（Mem0/A-MEM）+ 工业（Memory Bank/AgentCore/Dreaming 的 extraction+consolidation）+ 平台（Mem0/Zep/Cognee）|
| 4 | **agent 自决读写是趋势，但必须门控**（两段式写入）| 学术（MemGPT/AgeMem）+ 工业（memory tool/agent-directed）+ 社区（写门控/validator 强烈共识）|
| 5 | **知识更新、矛盾消解、遗忘是一等能力** | 学术（KU/CR 成评测标准、FAMA）+ 工业（consolidation/失效/TTL）+ 评测（2025-2026 新基准的核心增量）|
| 6 | **检索必须混合**（语义 + 关键词 + 元数据 + 可选图遍历），纯向量不够 | 学术（HippoRAG2/Mem0 多信号）+ 框架（CrewAI 复合评分/Zep 融合）+ 平台（Mem0/Zep/Supermemory）|
| 7 | **time 是一等公民**（时间戳/valid 窗口/时序推理）| 学术（LongMemEval TR/HippoRAG）+ 平台（Zep bi-temporal）+ 评测（TR/EO/KU 维度）|
| 8 | **渐进披露是标准检索模式**（先摘要后细节）| 工业（Anthropic/OpenAI/Google 全部采用）+ 框架（progressive disclosure）+ 社区（token 成本约束）|
| 9 | **记忆是注入向量，安全必须内建**（投毒/越界/校验）| 学术（MemGate/TrustMem/TMA-NM）+ 工业（AgentCore/Memory Bank 显式警告）+ 社区（OWASP ASI06）|
| 10 | **评测必须写读分离、报成本、标长度** | 学术（LongMemEval 范式）+ 评测（BEAM/MemBench/ProsusAI）+ 平台（Mem0 token 报告）|

---

## 4. 关键争议与未决问题

1. **大窗口 vs 外部记忆**：Meta/NVIDIA（1M 原生窗口）vs OpenAI/Anthropic/Google（长窗口不够）。设计启示：两者兼容——即使窗口够大也保留抽取-合并-检索管线。
2. **文件 vs 托管向量/图存储**：Anthropic 的"记忆即文件"（可移植/可审计）vs AWS/Google 的托管抽象（检索强/黑盒）。产业尚未收敛，多家同时支持。
3. **向量 vs 图记忆**：提取式事实+向量（Mem0）vs 双时态图谱（Zep）；2026 主潮是混合（vector+BM25+graph+RRF），"各司其职"。
4. **谁拥有遗忘**：显式 DELETE（RL 派）、时间衰减（MemoryBank/MemoryOS）、版本化失效（Zep/Memora）无共识；"安全遗忘"与"审计可追溯"张力未解。
5. **参数化 vs 非参数化记忆配比**：MemVerse/MemOS 主张"都要"，但合并收益缺系统验证。
6. **RL 记忆是否值得**：GRPO 训练长轨迹开销大；152 QA 低数据论点（Memory-R1）vs 复杂结构论点（Mem-α）无定论。
7. **记忆的自我进化边界**：Reflexion 式反思可能固化错误（confirmation bias），"可进化"与"可信"如何平衡是开放问题。
8. **该记住一切还是该遗忘**：EvoMem 发现外部记忆优势只在 >30 天、高频变化事实时才显现——"forgetting might be premature optimization"，而 FAMA 却惩罚"该忘不忘"。两派都缺与高质量检索叠加的对照实验。

---

## 5. 技术演进时间线（2020 → 2026）

```
2020  RAG ──── 外部知识=非参数化记忆（检索增强，静态索引）
2023  Generative Agents ── 记忆流+反思+规划；检索三要素评分
      MemGPT ──────────── OS 分层内存、函数自驱读写（"LLM as OS"）
      MemoryBank ──────── 艾宾浩斯遗忘曲线
      CoALA ───────────── 记忆分类学（working/episodic/semantic/procedural）
2024  HippoRAG ────────── KG+PPR 一步多跳（海马索引理论）
      LongMemEval ─────── 评测五能力 + value/key/query/reading 四控制点
2025  A-MEM ───────────── Zettelkasten 连接与演化
      Mem0 ────────────── ADD/UPDATE/DELETE/NOOP 四类更新 + 图记忆（生产化）
      HippoRAG 2 ──────── 概念×上下文双编码 + 识别记忆
      [工业] Anthropic memory tool / ChatGPT memory / AWS AgentCore / Google Memory Bank
      [框架] LangMem agentic memory / CrewAI 统一 Memory
      [RL]   Memory-R1 → Mem-α → AgeMem → Mem-T（GRPO 接管记忆策略）
      [评测] MemoryAgentBench 四能力 / Memora-FAMA 遗忘感知 / BEAM 10M tokens
2026  [工业] OpenAI Dreaming V3 / Anthropic Managed Agents / AWS episodic + Policy
      [协议] MCP 2026-07-28 stateless / A2A 明确让出 memory 层
      [可信] MemGate 检索门控 / TrustMem 写校验 / TEE / 防投毒
      [存储] sleep-time compute（记忆维护移到空闲后台）
```

**一句话演进**：RAG 把记忆当作"查"→ MemGPT 让 agent"管"记忆 → RL 让 agent"学"记忆 → 2026 把记忆当作"可信的一等系统资源"。

---

## 6. 对我们 YUKI.N Memory 体系设计的综合启示

（综合七维度，直接可落地的行动项）

### 6.1 架构分层（地基）
- **四层模型**：Session/会话历史（追加日志）· Working memory（context 内状态，agent 可编辑）· Long-term memory（跨会话，可更新）· Artifacts（大对象外置）——对齐 Google ADK / OpenAI SDK 划分。
- **长期记忆内部再分**：语义（facts/profile）+ 情景（事件/经验）+ 程序（技能/规则/工作流）+ 可选图/时态层。Profile（常变状态单文档覆盖）vs Collection（知识积累逐条检索）之分值得直接采用（LangMem）。
- **物理分层参考 MemGPT**：context=热内存（两级水位 warning/flush + 递归摘要兜底）、向量/图=冷存储、摘要=压缩层。

### 6.2 写入路径
- **抽取式而非全量**：LLM 从对话抽取高信号事实/偏好/摘要，**每条记忆带元数据**：`source_turn_id`（溯源地基）、createdAt/observedAt/validUntil、置信度（continuous）、状态（open/resolved/contradicted）、来源/证据引用、热度、ACL。
- **两段式写入**：agent 提议候选记忆 → 独立 validator 裁定（避免"同一事实三十种措辞"、假想陈述当真话）；hot path（agent 工具，低延迟）+ background（事后提炼/巩固，sleep-time）双通道。
- **更新显式化**：原子操作集 ADD / UPDATE / DELETE / RETRIEVE / SUMMARY / FILTER / CONSOLIDATE——既是工程接口也是未来 RL 训练的 action space；被推翻事实**标记 invalid/失效而非物理删除**（保时序可回溯）。

### 6.3 检索路径
- **混合检索**：语义（embedding top-k）+ 关键词（BM25）+ 元数据过滤 + 可选图遍历（PPR）；多信号融合可加 time 衰减 + importance（Generative Agents 三要素）。
- **渐进披露**：常驻小摘要（预算内，如 25KB，放 prompt caching 断点之后）→ 按需工具拉取细节 → 后台提炼；绝不每轮全量注入。
- **任务条件化准入**（可选前沿）：MemGate 式低开销门控防御跨域泄漏。

### 6.4 遗忘与生命周期
- **遗忘显式设计**：recency 衰减 + 定时合并 + 冲突删除 + 容量策略（token_limit + priority）+ 低置信度自动压缩（高置信度禁动）+ last-touched/recall-frequency 软删除。
- **时态处理**：至少 `valid_from/valid_to` + provenance 链接（Zep 双时态的轻量化），支撑"当时 vs 现在"与审计。
- **记忆维护异步化**：压缩/去重/矛盾消解/画像更新放后台作业，不占在线路径。

### 6.5 存储介质
- **文件/文档（git 版）作为记忆底座**（Basic Memory / MemFS 风格）：透明、可版本化、可 diff、可人工修正、可跨模型迁移、利于审计——与 Anthropic memory tool、AGENTS.md 生态兼容。
- **SQLite/Postgres 做索引与元数据真源**；可选向量/图做语义召回。把核心记忆锁在专有托管平台是坑。
- **租户/命名空间隔离必须在存储层设计**，不是查询时过滤（Mem0 AND 过滤器是坑、Qdrant HNSW 全局图是教训）。

### 6.6 接口与标准
- **暴露为 MCP server**（工具面：add/search/get/update/delete + Resource 记忆视图），即插即用；注意 MCP 2026-07-28 stateless core（跨调用状态自持，用显式 handle）。
- **自定命名空间**：`user/<id>/project/<id>/...` 物理隔离，跨 session 同 namespace 续接。
- 无现成记忆协议标准可等，但可对齐生态事实标准（工具名趋向 add/search/get/update/delete）。

### 6.7 安全与治理
- **写门控 + 路径校验**（防 traversal）+ PII 过滤 + 把存储记忆当不可信输入处理（OWASP ASI06 记忆投毒）。
- **版本/审计**：记忆变更日志（Managed Agents / Memory Bank revisions 模式）、支持回滚。
- 多 agent 场景按 A2A 哲学保持 opacity：主 agent 不暴露内部状态，持久记忆层作为显式互补层。

### 6.8 评测体系
- **建分层评测管线（L0-L8）**：写入提取 → 检索 → 事实回忆 → 时间线 → 偏好 → 更新/冲突 → 遗忘 → 技能迁移 → 端到端（见 `notes/benchmarks/README.md` §7）。
- **写读分离 + oracle 对照**（LongMemEval 范式）；**报 token/延迟成本**；**标 token 级长度**；**报告 judge/answerer 模型**。
- 选型任何外部记忆方案时，**不盲信自报分数**（LoCoMo 各家互相矛盾），核对评测协议。

### 6.9 预留升级路径（防过时设计）
- 记忆操作工具化，接口稳定，未来可换装 **RL 策略**（AgeMem/Mem-T 式）而不改接口——现在用启发式（heat/recency/语义三因子），预留 RL 位。
- 大窗口模型若到来，保持抽取-合并-检索管线与"大窗口可用"兼容，不孤注一掷。
- 保持模型/厂商中立（Mem0 主张），避免把记忆锁死在单一模型或托管商。

---

## 7. 风险与待验证假设

1. **记忆有损性**：抽取式记忆在写入时就可能丢/错上下文（HippoRAG→2 的修正对象、Generative Agents 的幻觉润色）；需 provenance 保底 + 一致性校验。
2. **成本**：每交互一次 LLM 抽取有成本；写门控、top-k 预算、压缩阈值都要以 token 成本为约束设计。
3. **评测噪声**：当前基准可刷分、自报分数不可比——我们的分数需要统一 harness + 第三方可复现。
4. **RL 记忆的可行性**：启发式 → RL 的迁移收益尚未在我们场景验证，先做接口预留而非立即投入。
5. **记忆中毒与误记**：长期积累的错误记忆会自我强化（confirmation bias）；需要检测、回滚与用户纠错通路。

---

## 8. 结论

Agent Memory 在 2026 年 8 月已是一门**有清晰工程共识、有成熟评测方法学、有活跃商业化、但尚无统一标准**的领域。对本项目最有价值的三个结论：

1. **架构可照抄已收敛的范式**：分层 + 抽取式写入 + 混合检索 + 显式巩固/遗忘 + 渐进披露——这是 2025-2026 学术界、工业界、框架、平台四方收敛出的共同答案。
2. **差异化空间仍在**：基于 importance 的自动遗忘、时态推理、记忆治理/审计、检索门控安全——多数框架与平台仍未做好，是我们可以做出价值的地方。
3. **设计要为两年后的变化留口**：RL 化记忆策略、sleep-time compute、大窗口模型、记忆协议标准化——接口抽象薄一点（remember/recall），后端可换，评测管线随时可跑。

---

## 9. 附录

### 9.1 目录结构与导航

```
docs/research/                      # 本目录（原 MemDesign/）
├── README.md                       # 本索引（总入口）
├── 00-综述报告-Agent-Memory-现状.md # 本报告（综合七维度）
├── notes/                          # 各维度精读分析笔记
│   ├── academic-foundational/README.md   # 学术奠基论文（2023-2025，12 篇精读）
│   ├── academic-recent/README.md         # 学术最新（2025-2026，30 篇）
│   ├── industry/README.md                # 工业界官方（8 厂商对比 + 共识 + 链接）
│   ├── frameworks/README.md              # 开发框架（13 框架对比矩阵）
│   ├── memory-platforms/README.md        # 记忆平台/MaaS（对比矩阵 + 商业模式）
│   ├── benchmarks/README.md              # 评测基准（25 基准 + 分层评测建议）
│   └── community/README.md               # 社区生态 + 协议标准（MCP/A2A）
└── sources/                         # 第一手原始资料（262 份）
    ├── papers/                      # 学术论文原文（HTML 全文 + txt 纯文本 + 方法摘要 md）
    ├── industry/                    # 厂商官方文档/blog 原文
    ├── frameworks/                  # 框架官方文档原文
    ├── memory-platforms/            # 平台官方文档/架构原文
    ├── benchmarks/                  # 基准论文/官方仓库/官方 blog
    └── community/                   # 协议规范/官方 blog/社区讨论原文
```

### 9.2 关键原始链接（全部已存档）

- 奠基论文：MemGPT `arxiv.org/abs/2310.08560` · Generative Agents `2304.03442` · MemoryBank `2305.10250` · A-MEM `2502.12110` · HippoRAG `2405.14831` · HippoRAG 2 `2502.14802` · Mem0 `2504.19413` · CoALA `2309.02427` · 记忆综述 `2404.13501` · MemoryLLM `2402.04624` · LongMemEval `2410.10813` · RAG `2005.11401`
- 最新论文（节选）：MemoryOS `2506.06326` · MemVerse `2512.03627` · AgeMem `2601.01885` · MemoryAgentBench `2507.05257` · Memora `2604.20006` · BEAM `2510.27246` · LME-V2 `2605.12493` · MemGate `2606.06054` · Graphiti/Zep `2501.13956`
- 工业官方：Anthropic `claude.com/blog/memory` + `anthropic.com/news/context-management` · OpenAI `openai.com/index/chatgpt-memory-dreaming` + `openai.github.io/openai-agents-python/sessions` · Google `developers.googleblog.com/architecting-efficient-context-aware-multi-agent-framework-for-production/` · AWS `docs.aws.amazon.com/bedrock-agentcore/.../memory.html`
- 框架：LangMem `langchain-ai.github.io/langmem` · LlamaIndex `developers.llamaindex.ai/.../agents/memory` · CrewAI `docs.crewai.com/en/concepts/memory` · ADK `adk.dev/sessions/memory`
- 协议：MCP `modelcontextprotocol.io`（2026-07-28 spec）· A2A `a2a-protocol.org`
- 社区：`simonwillison.net`（context/memory）· `dbreunig.com/2025/06/22/how-contexts-fail...` · `langchain.com/blog/how-to-give-your-agent-memory`

### 9.3 编号核验记录（重要防误用）

调研中核实并修正了若干错误编号（均已在正文使用正确编号）：
- LoCoMo = **2402.17753**（非 2401.09453）
- HippoRAG 2（From RAG to Memory）= **2502.14802**（非 2505.12931，后者是数学论文）
- Mem0 = **2504.19413**（非 2505.08811，后者是水下三维重建论文）
- "MemEval 2406.08544" = QKD 论文，无同名记忆基准；真实的是 ProsusAI MemEval **harness**
- "MemoryVerse 2410.09677" = 量子物理论文；真实的是 MemVerse **2512.03627**
- "MemorAI" 无同名基准；可核实的是 MemORAI **2605.01386**
- "Mem0 OpenMemory 基准" = 产品名；评测框架是 `mem0ai/memory-benchmarks`
- "Effective context engineering" 官方文章是 **Anthropic** 的（非 OpenAI）

**教训**：引用记忆领域编号前必须逐个 curl arXiv abs 页核验 title。

---

*本报告由 opencode 基于 7 组并行调查的第一手原始资料综合而成。各维度细节、对比矩阵与逐条引文见 `notes/` 对应目录；所有原始资料见 `sources/`。*
