# 记忆系统评测基准调研笔记（Benchmarks & Evaluation Methods）

> 调研日期：2026-08-01
> 任务范围：【基准与评测方法】。所有结论均基于第一手资料（论文原文 / 官方仓库 / 官方博客），原始 HTML 保存在 `sources/benchmarks/`。
> 重要声明：任务清单中给出的部分 arxiv 编号经逐一核验为**错误**（见 §2），本笔记以实抓内容为准，未编造任何编号与结论。

---

## 1. 调研对象一览（一句话总结 + 链接 + 本地文件）

| # | 基准/工作 | 一句话总结 | 官方链接 | 本地保存文件 |
|---|---|---|---|---|
| 1 | **LoCoMo** (2402.17753, ACL 2024) | 首个"超长期"多会话对话记忆基准：机器-人工管线生成 300~600 轮/10-35 会话的对话，用 QA（单跳/多跳/时间/开放域/对抗）+ 事件图摘要 + 多模态对话生成三项任务评测记忆，结论是长上下文 LLM 与 RAG 仍比人类落后 ~56%，时间推理与对抗题是最大短板。 | https://arxiv.org/abs/2402.17753 · https://github.com/snap-research/locomo | `locomo-2402.17753.md` `locomo-repo-readme.md` |
| 2 | **LongMemEval** (2410.10813, ICLR 2025) | 评测聊天助手长期记忆的"金标准"：500 道人工题，覆盖信息提取、多会话推理、时间推理、知识更新、弃答（abstention）五大能力；设计了 S(115k tokens)/M(500 sessions~1.5M tokens) 两档可扩展历史，并提出 indexing-retrieval-reading 三段式记忆设计空间。 | https://arxiv.org/abs/2410.10813 · https://github.com/xiaowu0162/LongMemEval | `longmemeval-2410.10813.md` `longmemeval-repo-readme.md` |
| 3 | **MemBench** (2506.21605, ACL Findings 2025) | 补足"反思型记忆 + 观察场景"两个维度：数据含事实记忆/反思记忆两层、参与/观察两种场景，指标除准确率外还引入 recall、capacity、temporal efficiency；基于 MemEngine 评测 7 种记忆机制。 | https://arxiv.org/abs/2506.21605 · https://github.com/import-myself/Membench | `membench-2506.21605.md` |
| 4 | **MemEval (ProsusAI harness)** | 一个"评测框架/脚手架"而非新数据集：统一 LLM、embedding、打分管线与 token 成本统计，内置 9 套记忆系统 × LoCoMo/LongMemEval 两个基准，做横向公平对比。**注意**：用户提供的 "MemEval 2406.08544" 实为 QKD 论文，arXiv 上不存在名为 "MemEval: A benchmark for LLM-based dialogue memory" 的独立论文。 | https://github.com/ProsusAI/MemEval | `memeval-harness-prosusai.md` |
| 5 | **Anthropic memory 评测** | Anthropic 未发布公开命名的 memory benchmark：Claude 记忆功能（2025-09）靠"extensive safety testing"内部评测；开发者平台 context management（2025-09-29）报告内部 agentic search 评测上 memory tool+context editing 提升 39%、单 context editing +29%、100 轮 web search 省 84% token。 | https://claude.com/blog/memory · https://www.anthropic.com/news/context-management | `anthropic-memory-blog.md` `anthropic-context-management.md` |
| 6 | **Mem0 (2504.19413, ECAI 2025) + OpenMemory** | Mem0 论文在 LoCoMo 上做 6 类基线（文献基线/RAG/全上下文/开源/闭源/Zep）大对比；"OpenMemory" 是其本地优先 MCP 记忆产品，**不是评测基准**——其评测基准是开源的 `memory-benchmarks`（跑 LoCoMo/LongMemEval/BEAM），2026-04 新算法在 LoCoMo 92.5、LongMemEval 94.4、BEAM(1M) 64.1、BEAM(10M) 48.6。 | https://arxiv.org/abs/2504.19413 · https://github.com/mem0ai/memory-benchmarks · https://github.com/mem0ai/mem0 | `mem0-2504.19413.md` `mem0-evaluation-readme.md` `mem0-memory-benchmarks-readme.md` `mem0-token-efficient-algorithm.md` |
| 7 | **RULER** (2404.06654, COLM 2024) | 长上下文"真实上下文长度"的合成基准：扩展 NIAH 到检索/多跳追踪/聚合/QA 四类任务，控制长度 4K-128K；结论：标称 32K+ 的模型中仅一半在 32K 达到 Llama-2-7B@4K 的基线，几乎所有模型在实际声明长度前就已掉线。 | https://arxiv.org/abs/2404.06654 · https://github.com/hsiehjackson/RULER | `ruler-2404.06654.md` `ruler-repo-readme.md` |
| 8 | **LongBench v1** (2308.14508, ACL 2024) | 首个广泛采用的长上下文真实任务基准：21 任务/中英双语/3-5k~30k+ tokens，指标为 F1/ROUGE 等，促成了 long-context 模型与 RAG 的范式对比（LongBench 论文被 LongBench v2 论文引用确认编号）。 | https://arxiv.org/abs/2308.14508 | （信息来自 LongBench v2 原文引用；未单独下载） |
| 9 | **LongBench v2** (2412.15204, ACL 2025) | 面向"深度理解与推理"的长上下文多任务基准：503 道专家标注选择题（8k-2M words），6 大类；人类限时 15 分钟仅 53.7%，最佳模型直答 50.1%、o1-preview 长推理 57.7%，强调推理与 inference-time compute 而非记忆。 | https://arxiv.org/abs/2412.15204 · https://longbench2.github.io | `longbench-v2-2412.15204.md` |
| 10 | **BEAM** (2510.27246, ICLR 2026) | 当前最能打"生产规模"的记忆基准：自动生成 100 段多域长对话 + 2000 道题，长度 128K/500K/1M/10M，覆盖 10 种记忆能力（含矛盾消解、事件排序、指令遵循、偏好遵循、总结等此前缺失维度）；1M 上下文模型+RAG 也随长度增长大幅衰减。 | https://arxiv.org/abs/2510.27246 · https://github.com/mohammadtavakoli78/BEAM | `beam-2510.27246.md` `beam-benchmark-readme.md` |
| 11 | **MemoryAgentBench** (2507.05257) | 按认知科学定义记忆 Agent 四大核心能力——准确检索、测试时学习、长程理解、选择性遗忘，并把长上下文数据集切块为增量多轮交互；新增 EventQA、FactConsolidation 两个数据集；结论：当前 RAG/商用记忆系统在冲突消解与遗忘上几乎失败。 | https://arxiv.org/abs/2507.05257 · https://huggingface.co/datasets/Robin076/MemoryAgentBench | `memoryagentbench-2507.05257.md` `memoryagentbench-repo.md` |
| 12 | **A-MEM** (2502.12110, NeurIPS 2025) | Zettelkasten 风格 agentic memory，自带 **PersonaMem** 评测数据集（人物记忆、偏好变化等），在 LoCoMo/PersonaMem 上评测；是"记忆系统自带配套评测"的典型。 | https://arxiv.org/abs/2502.12110 | `a-mem-2502.12110.md` `a-mem-2502.12110-body.html` |
| 13 | **MemVerse** (2512.03627) | 多模态记忆框架（核心/情景/语义知识图谱 + 参数化记忆），在 LoCoMo/LongMemEval 上评测，LoCoMo F1 60.0（GPT-3.5-16k）。**注意**：用户提供的 "MemoryVerse 2410.09677" 实为量子物理论文，arXiv 上不存在名为 "MemoryVerse" 的基准或论文；同名的 memoryverse.ai 是无关的 3D 记忆保存项目。 | https://arxiv.org/abs/2512.03627 · https://github.com/KnowledgeXLab/MemVerse | `memverse-2512.03627.md` |
| 14 | **MemORAI** (2605.01386, ACL Findings 2026) | 图记忆框架（选择性过滤+provenance 图+动态加权 PageRank），在 LoCoMo/LongMemEval 上做 turn/session 级 Recall@k 与 QA 评测；是"MemorAI"这一名称下唯一可核实的真实学术工作（其余名称未找到对应论文）。 | https://arxiv.org/abs/2605.01386 | `memorai-2605.01386.md` |
| 15 | **LongMemEval-V2 / LME-V2** (2605.12493, 2026) | 面向"经验丰富的 web 同事"：从 WebArena/WorkArena 的 agent 轨迹中人工整理 451 题，覆盖静态状态回忆/动态状态跟踪/工作流知识/环境陷阱/前提意识，历史 25M-115M tokens；记忆系统须把轨迹沉淀为可复用环境经验。 | https://arxiv.org/abs/2605.12493 | `longmemeval-v2-2605.12493.md` |
| 16 | **PERMA** (2603.23231, 2026) | 事件驱动的个性化记忆基准：偏好"涌现-补充"演化 + 跨域噪音，多选+交互两模式，三时间点探测（zero-memory/in-time/post-interference）以测遗忘与漂移；2166 条偏好细节、800+ 事件、1.8M tokens。 | https://arxiv.org/abs/2603.23231 · https://github.com/PolarisLiu1/PERMA | `perma-2603.23231.md` |
| 17 | **PerMem-Bench** (2605.25535, 2026) | 首个"个性化记忆策略"基准：多年多域交互历史 + 多样化人设，提出 session-level storage gating 探究"什么该存、什么该跳过"；结论：完美 gating 收益巨大但当前 gating 准确率不够。 | https://arxiv.org/abs/2605.25535 · https://github.com/yeonjun-in/PerMemBench | `permem-bench-2605.25535.md` |
| 18 | **EvolMem** (2601.03543, 2026) | 认知驱动的多会话记忆基准：声明性/非声明性记忆分层，topic-initiated + narrative-inspired 混合合成；结论：无模型在所有维度全胜，记忆机制未必增强 LLM 且有效率瓶颈。 | https://arxiv.org/abs/2601.03543 | `evolmem-2601.03543.md` |
| 19 | **ES-MemEval** (2602.01885, 2026) | 长期情感支持场景的对话记忆基准：信息提取/时间推理/冲突检测/弃答/用户建模五能力 × QA/摘要/对话生成三任务，配套 EvoEmo 多会话数据集。 | https://arxiv.org/abs/2602.01885 · https://github.com/slptongji/ES-MemEval | `es-memeval-2602.01885.md` |
| 20 | **StructMemEval** (2602.11243, 2026) | 反其道而行：指出"简单 RAG 就能过 LoCoMo/LongMemEval"，转而测记忆的**结构组织能力**（记账本、待办清单、树等人类靠结构解决的问题）。 | https://arxiv.org/abs/2602.11243 | `structmemeval-2602.11243.md` |
| 21 | **GAIA** (2311.12983, ICLR 2024) | 通用 AI 助手基准：466 道人类设计、概念上对人简单但对 AI 难的现实问题（推理/多模态/网页浏览/工具），人类 92% vs GPT-4+plugins 15%；不直接测记忆，但 agent 评测常以它为任务级指标。 | https://arxiv.org/abs/2311.12983 · https://huggingface.co/spaces/gaia-benchmark/leaderboard | `gaia-2311.12983.md` |
| 22 | **AgentBench** (2308.03688, ICLR 2024) | 首个系统化的 LLM-as-Agent 基准：8 个环境（OS/DB/KG/数字卡牌/横向思维/购物/网页浏览/游戏），27 个模型；结论是"长程推理/决策/指令遵循"是 agent 主要瓶颈——与记忆缺陷高度相关。 | https://github.com/THUDM/AgentBench | `agentbench-2308.03688.md` |
| 23 | **τ-bench** (2406.12045, ICLR 2025) | 工具-Agent-用户交互基准：LLM 模拟用户 + 领域 API + 策略文档，用"用户评分+任务成功率"评测，域内/域外两种策略设定；强调记忆相关的"从对话中记住用户偏好并持续遵循"。 | https://github.com/sierra-research/tau-bench | `tau-bench-2406.12045.md` |
| 24 | **Memory in the Age of AI Agents** (2512.13564) | 2025 年底权威综述（被 ProsusAI/MemEval、MemORAI 等引用），梳理 agent 记忆的存储/检索/更新/遗忘全生命周期与评测现状，是我们整体框架的参考地图。 | https://arxiv.org/abs/2512.13564 | `memory-in-age-of-ai-agents-2512.13564.md` |
| 25 | **AI Hippocampus / Human-like memory 视角** (2601.09113, 2026) | "AI 离人类记忆多远"综述：implicit/explicit/agentic 记忆三元分类，用神经科学（海马-新皮层互补学习系统）映射 agent 记忆架构与基准。 | https://arxiv.org/abs/2601.09113 | `ai-hippocampus-2601.09113.md` |

---

## 2. 编号核验记录（重要，防误用）

以下用户任务清单中给出的 arxiv 编号经逐一实测，**均为错误编号**，请勿沿用：

- LoCoMo 的真实编号是 **2402.17753**（用户写 2401.09453 → 该号不存在于记忆领域）。
- "MemEval 2406.08544" → 实为《A practical framework for analyzing high-dimensional QKD setups》（量子密钥分发，cs 无关）。
- "MemoryVerse 2410.09677" → 实为《Optical Manifestations of Quantum Geometry in Electron-Phonon Coupling》（物理论文）。
- "MemorAI" → arXiv 上无此名称的基准论文；可核实的是 **MemORAI (2605.01386)** 与 A-MEM 的 PersonaMem。
- "MemoryAgent" → 无此名称独立论文；对应实体是 **MemoryAgentBench (2507.05257)** 与 LongMemEval 中 agentic 设定。
- "Mem0 OpenMemory 评测基准" → OpenMemory 是产品名；Mem0 的评测基准 = `mem0ai/memory-benchmarks` 框架 + LoCoMo/LongMemEval/BEAM。

教训：**引用记忆评测编号前必须逐个 curl arXiv abs 页核验 title**，本笔记所有编号均通过此流程确认。

---

## 3. 各基准覆盖的记忆维度对比

记忆能力维度归纳为 10 类（合并自 BEAM 的 10 维划分与 LongMemEval/MemBench 的能力集）：

- IE 信息提取 / 事实回忆
- MR 多会话推理 / 多跳
- KU 知识更新 / 冲突消解
- TR 时间推理 / 时效性
- ABS 弃答 / 反幻觉
- CR 矛盾消解（contradiction resolution）
- EO 事件排序
- IF 指令遵循
- PF 偏好遵循（个性化）
- SUM 总结 / 提炼

| 基准 | 规模/长度 | IE | MR | KU | TR | ABS | CR | EO | IF | PF | SUM | 记忆层次 | 场景 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| LoCoMo | 10 会话 / 9K-16K tokens | ✔ | ✔ | ✘ | ✔ | ✔ | ✘ | ✘ | ✘ | ✘ | ✔ | 事实型 | 参与（user-user 对话）|
| LongMemEval | 500 题 / 115K-1.5M tokens | ✔ | ✔ | ✔ | ✔ | ✔ | ✘ | ✘ | ✘ | ✔(preference) | ✘ | 事实型 | 参与（user-assistant）|
| MemBench | ~1000 题 / ~100K tokens | ✔ | ✔ | ✔ | ✔ | ✘ | ✘ | ✘ | ✘ | ✔ | ✔(反思) | 事实型+反思型 | 参与+观察 |
| BEAM | 2000 题 / 128K-10M tokens | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | 事实型为主 | 参与（多域）|
| MemoryAgentBench | 2071 题 / 103K-1.44M | ✔(准确检索) | ✔(长程理解) | ✔(冲突消解) | ✔ | ✘ | ✔ | ✘ | ✔(测试时学习) | ✘ | ✘ | 事实+技能 | 参与（增量多轮）|
| LME-V2 | 451 题 / 25M-115M tokens | ✔(静态状态) | ✔(工作流) | ✔(动态跟踪) | ✔ | ✔(前提意识) | ✘ | ✘ | ✘ | ✘ | ✘ | 环境经验 | agent 轨迹 |
| PERMA | 2166 偏好 / 1.8M tokens | ✔ | ✔ | ✔(偏好更新) | ✔ | ✘ | ✘ | ✘ | ✘ | ✔(核心) | ✘ | 事实+偏好演化 | 参与 |
| PerMem-Bench | 多年多域交互 | ✔ | ✔ | ✔ | ✔ | ✘ | ✘ | ✘ | ✘ | ✔(核心) | ✘ | 个性化存储策略 | 参与 |
| ES-MemEval | 1209 题 / 27.2 会话 | ✔ | ✘ | ✔(冲突检测) | ✔ | ✔ | ✔ | ✘ | ✘ | ✔(用户建模) | ✔ | 事实+情感状态 | 参与 |
| RULER | 13 任务 × 500 例 / 4K-128K | ✔(NIAH) | ✔(多跳追踪) | ✘ | ✘ | ✘ | ✘ | ✘ | ✘ | ✘ | ✔(聚合) | —（长上下文，非记忆系统）| 文档 |
| LongBench v2 | 503 题 / 8K-2M words | ✔ | ✔ | ✘ | ✘ | ✘ | ✘ | ✘ | ✘ | ✘ | ✔(长对话历史) | —（长上下文）| 文档/对话 |

**观测**：
1. **能力覆盖的演进**：LoCoMo(2024) → LongMemEval(2024/ICLR25) 增加 KU/ABS/偏好 → MemBench 增加反思型记忆与观察场景 → BEAM(2026) 补齐 CR/EO/IF/PF/SUM 到 10 维。**知识更新、矛盾消解、选择性遗忘是 2025-2026 才真正被重视的维度**。
2. **长度标尺**：LoCoMo ~10K → LongMemEval 115K/1.5M → MemoryAgentBench ~1M+ → BEAM 10M → LME-V2 115M。**记忆评测必须标注 token 级长度，否则不可比**。
3. **场景**：绝大多数是"参与场景"（agent 在对话中记住用户信息）；MemBench 独有"观察场景"（agent 旁观记录）；LME-V2 独有"agent 在环境中的经验沉淀"（workflow/环境知识，对应程序性记忆）。

---

## 4. 评测方法学：如何评估记忆的读写准确率 / 时效性 / 遗忘

### 4.1 评测范式（memory types 怎么被"注入"）

- **NIAH 式长历史**（LongMemEval、MemoryAgentBench、BEAM）：证据句藏在大量 distractor sessions 里，系统须在线消费历史后回答问题；难度由历史长度/证据分散度/噪音比例控制。
- **增量多轮注入**（MemoryAgentBench、MemBench）：把长文档切成块按时间顺序一轮轮喂给 agent，"之前的信息只能通过记忆回忆"——比一次性灌入更接近真实。
- **人格/时间线/事件图锚定**（LoCoMo）：对话由 persona + 因果事件时间线生成，保证"该记住什么"有 ground truth。
- **事件驱动偏好演化**（PERMA）：偏好不是静态陈述，而是通过用户在交互中的要求/反馈/约束一步步涌现并演化。

### 4.2 记忆写读分离（推荐做法）

- **检索级指标**：Recall@k、NDCG@k、turn/session 级命中（MemORAI、LongMemEval 的 evidence-grounded retrieval；ProsusAI MemEval 也报告 Recall@k 到 top-k）。
- **问答级指标**：F1、BLEU、ROUGE、LLM-as-judge（binary 正确性）、FactScore（LoCoMo 的事件摘要）。
- **关键分离**：LongMemEval 的 oracle retrieval 设定区分"检索到位了吗" vs "读懂了会推理吗"；其发现 LLM 全量读 115K 比 oracle 检索掉 30-60%，证明**先测检索再测阅读**能定位瓶颈在记忆系统还是模型推理。

### 4.3 时效性（temporal）评测的三种实现

1. **时间戳 + 时间推理题**（LongMemEval TR、BEAM TR/EO）：问"什么时候发生/先后顺序"，需要利用 metadata 中的日期。
2. **知识更新题**（LongMemEval KU、BEAM KU、ES-MemEval 冲突检测）：后说的事实覆盖前说的事实，测 agent 是否用新值而非旧值。
3. **时间探测点**（PERMA 的 zero-memory/in-time/post-interference、MemBench 的 capacity 曲线、Memora 的 FAMA）：在交互的不同时点重新提问，画准确率-时间曲线，暴露 recency bias 与灾难性遗忘。

### 4.4 遗忘（forgetting）评测——2025-2026 的新焦点

- MemoryAgentBench 把 **选择性遗忘（selective forgetting）** 列为四大能力之一，新增 FactConsolidation 数据集（判断该保留/该丢弃），并揭示多跳冲突消解全部个位数准确率。
- Memora (2026) 提出 **FAMA（Forgetting-Aware Memory Accuracy）** 指标：`max(0, Memory Presence Accuracy − forgetting_penalty × forgetting_requirement_ratio)`，每周/月/季交互，发现 64% 推荐错误来自"该丢没丢的过时记忆"。
- 启示：**"能忘"与"记得住"同样重要**，评测应同时给"精确率"（存的都对）与"该忘率"（该清的清掉了）双指标。

### 4.5 成本与效率维度

- ProsusAI MemEval：统一 LLM/embedding/打分 + **端到端 token 成本跟踪**（ingestion+retrieval+answer）。
- Mem0：报告 tokens/query（~6,900）与 latency p50，LoCoMo 上 ~7K tokens vs 全上下文 25K+。
- MemBench：accuracy/recall/capacity/temporal efficiency 四指标。
- 观点：**评测结果必须与成本挂钩**，否则"用 10x 上下文暴力过基准"会污染榜单（见 §6 饱和问题）。

---

## 5. 各基准模型表现结论（来自原文/官方，2024-2026）

| 基准 | 人类基线 | 最佳模型表现（原文当时） | 关键结论 |
|---|---|---|---|
| LoCoMo | F1 87.9 | gpt-4-turbo 32.4（v1 版）~51.6（ACL 版），gpt-3.5-16k 37.8 | 长上下文+22-66% 提升但仍落后人类 ~56%；时间推理落后 ~73%；对抗题（陷阱题）长上下文反而崩（gpt-4-turbo 对抗仅 15.7%）|
| LongMemEval | — | 商用系统 30-70%（简化版设定）；长上下文 LLM 全量读比 oracle 检索掉 30-60% | 2026 年排行榜：Mastra OM 94.87%、Hindsight 91.4%、Supermemory 84.6%、Zep 71.2%、full-context 60.2%、Mem0 49%——**Mem0(49%) < full-context(60.2%)，说明设计差的记忆不如无记忆** |
| BEAM | — | 10M tokens：LIGHT(Hindsight) 64.1%、Honcho 40.6%、Llama-4 RAG 24.9% | 1M 上下文模型+RAG 也无法靠扩窗口解决；BEAM 是唯一"不可能靠塞上下文到 100%"的基准 |
| Mem0 论文(LoCoMo) | — | Mem0 J=67.13（vs OpenAI 63.79、Zep 61.70）；Mem0g 时间题 51.55 | 图记忆提升时间/开放域；降 91% p95 延迟、省 90%+ token |
| RULER | — | Gemini-1.5-Pro > GPT-4 > 其余 | 标称 32K 的模型仅一半在 32K 有效；大多在声明长度前掉线 |
| LongBench v2 | 53.7% (15min) | 直答 50.1%；o1-preview 57.7% | 强调推理与 test-time compute；非记忆问题 |
| GAIA | 92% | GPT-4+plugins 15% | agent 任务级难题，人类-机器差距极大 |
| AgentBench | — | gpt-4 最佳，OSS 平均 0.51 vs 商用 2.15 | 长程推理/指令遵循为 agent 主要瓶颈 |
| MemoryAgentBench | — | RAG(BM25) 在 NIAH 检索 100% vs GPT-4o-mini 22.8% | RAG 检索强但长程理解弱；Mem0 构建耗时是 BM25 的 20000x；多跳冲突消解 ≤7% |
| LME-V2 | — | AgentRunbook-C 72.5%（编码 agent 管记忆）vs RAG 48.5% | 轨迹→环境经验的记忆系统才开始被系统评测 |

**跨基准的一致结论**：
1. 人类远胜机器（LoCoMo/GAIA/LongBench v2 均有 30-50+ 分差距）。
2. 时间推理与知识更新是所有记忆系统的共同短板（BEAM/Mem0/PERMA/LME-V2 反复确认）。
3. 简单 RAG 在"检索"上很强，但在"长程理解/跨会话推理/冲突消解"上失败——**检索≠记忆**。
4. 长上下文≠记忆：扩窗口不能替代记忆系统（LongMemEval 30-60% 掉线、BEAM 1M 模型仍失败、RULER 有效长度远小于标称）。
5. 2026 年供应商自报分数普遍偏高且未第三方复现（Medium 对比文与 SuperLocalMemory 均提醒"self-reported numbers are tier-3 until replicated"），引用时需谨慎。

---

## 6. 现有基准的局限与批评

1. **基准饱和/可被暴力刷分**：StructMemEval 指出"简单 RAG 就能过 LoCoMo/LongMemEval 的大部分题"；MemoryAgentBench 也观察到 RAG 在检索类任务近满分；Mem0 博客承认"小基准（LoCoMo/LongMemEval）可被激进检索、更大上下文或前沿模型显著刷高"。→ 分数通胀、区分度下降。
2. **检索与记忆混为一谈**：大多数基准把"检索到相关片段"等同于"记住"；PERMA、StructMemEval、MemoryAgentBench 都批评这一点——真正的记忆应包含抽象、整合、更新、遗忘，而非 top-k 召回。
3. **合成/窄域数据**：LongMemEval 对话主题单一且合成（MemoryAgentBench 批评）；LoCoMo 仅 10 段对话、规模过小；MemBench 用 twitter-news 当噪音。
4. **动态演化缺失**：多数基准的偏好/事实是静态的；PERMA 批评"静态用户建模忽略跨会话依赖"，引入偏好涌现-更新-漂移；PerMem-Bench 引入"该存什么"的个性化决策。
5. **遗忘与时效评测缺失**：直到 MemoryAgentBench(2025)/Memora(2026) 才把 forgetting 作为一等公民；BEAM 之前几乎无 CR(矛盾)/EO(排序) 维度。
6. **一致性/可比性问题**：同一 LoCoMo 各家得分差异巨大（Mem0 92.5 vs ProsusAI 复现 Mem0 0.344 F1）——因评测协议（LLM、top-k、judge、token 预算）不统一；Zep 的 LoCoMo 结果还被第三方质疑需修正（getzep/zep-papers#5）。→ 需要统一 harness（如 ProsusAI MemEval）与第三方复现。
7. **成本缺失**：多数基准只看准确率，不看 token/延迟；而生产决策恰恰取决于 cost-accuracy 权衡（Mem0/ProsusAI 是少数报成本的）。
8. **"过基准"≠"实用"**：BEAM/Mem0 直言小基准被刷、生产规模（1M-10M tokens）才是真考验；LME-V2 将评测推进到 115M tokens 的 agent 轨迹。
9. **Agent 任务级 vs 记忆模块级**：GAIA/AgentBench/τ-bench 测的是"端到端任务成功率"，记忆只是隐含变量，无法归因；需要"任务级"与"模块级（检索/读取/更新/遗忘分测）"结合。

---

## 7. 设计我们自己的评测方案的建议（分层评测体系）

借鉴上述基准的方法学，建议按"记忆生命周期 × 能力层次"分层，**写读分离、逐层可归因**：

### 7.1 层级结构（从易到难）

| 层 | 评测内容 | 借鉴基准 | 关键指标 |
|---|---|---|---|
| L0 写入/提取 | 给定对话能否提取正确、无幻觉的事实/偏好/事件 | MemBench(事实记忆)、Mem0(事实抽取) | 提取 precision/recall、抽取-真值 F1 |
| L1 检索 | 给定问题能否检索到正确证据（不分对话/分 turn）| LongMemEval(evidence-grounded)、MemORAI(Recall@k) | Recall@k、NDCG@k、turn/session 命中 |
| L2 事实回忆 | 单跳/多跳事实问答（阅读正确性）| LoCoMo、LongMemEval | F1、LLM-judge、准确率 |
| L3 时间线 | 时间推理/事件排序/时效性（最新状态）| LongMemEval TR、BEAM TR/EO、PERMA 时间探测 | 时间题准确率、Kendall-τ、recency 误差 |
| L4 偏好 | 隐式偏好推断 + 个性化响应 | LongMemEval SSP、PERMA、ES-MemEval 用户建模 | 偏好命中、个性化一致性评分 |
| L5 更新/冲突 | 知识覆盖、矛盾消解、错误信息纠正 | LongMemEval KU、BEAM CR、ES-MemEval 冲突检测 | 更新正确率、冲突消解率 |
| L6 遗忘 | 该忘则忘（去噪/去过期），该记则记 | MemoryAgentBench(选择性遗忘)、Memora FAMA | FAMA、保留 precision、过时-残留率 |
| L7 技能迁移 | 从经验中沉淀可复用技能/工作流并迁移 | LME-V2(workflow/gotchas)、MemoryAgentBench(测试时学习) | 新环境任务成功率提升 |
| L8 端到端 | 长程任务成功率 + 成本 | GAIA/AgentBench/τ-bench(任务)、BEAM(规模) | 任务成功率、tokens/query、p95 延迟 |

### 7.2 评测协议要点（从各基准吸取的工程教训）

1. **统一 harness**：固定 LLM、embedding、judge、top-k、token 预算（借鉴 ProsusAI MemEval），否则跨系统分数不可比；鼓励第三方复现。
2. **写读分离 + oracle 对照**：先测"给定 oracle 证据能否答对"（读），再测"从记忆系统检索到证据"（检索），差异即记忆系统瓶颈（LongMemEval 范式）。
3. **长度标尺必注**：每个样本标注 token 级长度，分级（<10K / 100K / 1M / 10M+）报告，避免"小基准被刷分"。
4. **时间/遗忘曲线**：在交互时间线上多点提问（PERMA 三时间点、MemBench capacity 曲线、Memora 周/月/季），报告准确率-时间衰减。
5. **成本必报**：tokens/query + latency p50/p95（Mem0、ProsusAI），给出 cost-accuracy 帕累托曲线。
6. **噪音与干扰控制**：加入比例可调的 distractor/noise sessions（MemBench），报告噪音鲁棒性。
7. **对抗与弃答**：包含假前提题与"证据不存在"题，测反幻觉/弃答能力（LoCoMo adversarial、LongMemEval ABS、BEAM ABS）。
8. **数据来源**：优先事件驱动/时间线锚定的合成生成（LoCoMo/BEAM 管线）+ 人工校验，避免污染；需要真实多域数据时用脱敏的真实交互。

### 7.3 与我们 Memory 系统设计直接相关的启示

1. **评测驱动设计**：把 L0-L8 做成 CI 流水线（如 `memory-eval/`），每次改动跑分并报告 10 维雷达图，避免"只堆准确率"。
2. **记忆必须支持"更新"**：知识更新/冲突消解是 2025-2026 最受检验的能力（KU/CR），我们的记忆数据结构需支持 supersede/版本化与冲突检测（可参考 Zep 的 bitemporal、KNDL 的 immutable fact + supersedes 模式）。
3. **遗忘是一等公民**：设计明确的 retention 策略（recency/importance/干扰），用 FAMA 式指标防止"记了不该记的"。
4. **写读分离架构便于评测**：把提取、索引、检索、阅读、更新、遗忘做成可独立插桩的阶段（LongMemEval 的 indexing-retrieval-reading 三段式），评测即插桩。
5. **区分"记忆能力"与"模型推理能力"**：报告时注明使用的 answerer LLM 与 judge LLM，便于横向归因。
6. **警惕自报分数**：引用任何 memory 产品/论文分数时标注来源可信度（peer-reviewed / 自报 / 第三方复现）。

---

## 8. 参考资料索引（sources 目录）

```
sources/benchmarks/
├── locomo-2402.17753.md, locomo-repo-readme.md          # LoCoMo
├── longmemeval-2410.10813.md, longmemeval-repo-readme.md# LongMemEval
├── longmemeval-v2-2605.12493.md                          # LME-V2
├── membench-2506.21605.md                                # MemBench
├── memeval-harness-prosusai.md                           # MemEval harness
├── mem0-2504.19413.md, mem0-evaluation-readme.md, mem0-memory-benchmarks-readme.md, mem0-token-efficient-algorithm.md, mem0-state-of-ai-memory-2026.md  # Mem0/OpenMemory
├── ruler-2404.06654.md, ruler-repo-readme.md             # RULER
├── longbench-v2-2412.15204.md                            # LongBench v2
├── beam-2510.27246.md, beam-benchmark-readme.md          # BEAM
├── memoryagentbench-2507.05257.md, memoryagentbench-repo.md  # MemoryAgentBench
├── a-mem-2502.12110.md, a-mem-2502.12110-body.html        # A-MEM
├── memverse-2512.03627.md                                # MemVerse
├── memorai-2605.01386.md                                 # MemORAI
├── perma-2603.23231.md                                   # PERMA
├── permem-bench-2605.25535.md                            # PerMem-Bench
├── evolmem-2601.03543.md                                 # EvolMem
├── es-memeval-2602.01885.md                              # ES-MemEval
├── structmemeval-2602.11243.md                           # StructMemEval
├── gaia-2311.12983.md                                    # GAIA
├── agentbench-2308.03688.md                              # AgentBench
├── tau-bench-2406.12045.md                               # τ-bench
├── memory-in-age-of-ai-agents-2512.13564.md              # 综述
├── ai-hippocampus-2601.09113.md                          # 综述（人脑视角）
├── anthropic-memory-blog.md, anthropic-context-management.md  # Anthropic
```

未单独下载但已在笔记中引用（编号由 LongBench v2 等原文交叉确认）：LongBench v1 = 2308.14508；LongMemEval-V2 = 2605.12493；HippoRAG2 = 2502.14802；Memory-R1 = 2508.19828；τ²-bench = 2506.07982；SimpleMem = 2601.02553；Zep = 2501.13956。
