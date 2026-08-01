# MemoryBench: A Benchmark for Memory and Continual Learning in LLM Systems

- **arXiv**: 2510.17281 (cs.CL) | 2025-10-20 | ICML 2026 | GitHub: THUIR/MemoryBench
- **作者**: Qingyao Ai, Yichen Tang, Changyue Wang, Jianming Long, Weihang Su, Yiqun Liu（清华 THUIR）
- **本地原始资料**: `sources/papers/memorybench-2510.17281.html`（arxiv HTML 全文）

## 核心思想
从"数据/参数/测试时计算扩展触顶"的现实出发，主张评测 LLM 系统的**服务期持续学习（continual learning from user feedback）**能力。与把记忆简化为长文阅读理解（LoCoMo 类）的基准不同，MemoryBench 用 LLM-as-user 模拟用户反馈，检验系统能否在服务时间从反馈日志中学习程序性记忆。

## 评测架构
- **规模**：28 个数据集、3 域（Academic & Knowledge / Legal / Open-Domain）、4 种任务形态（Long-Long/Long-Short/Short-Long/Short-Short），覆盖多语言。
- **反馈模拟**：Mistral-Small-3.2-24B 驱动的 user-feedback simulator，生成行为日志（like/copy 等）与反馈。
- **四种实验体制**：off-policy（批量重放）、stepwise off-policy（分批重放，读间隔离）、on-policy（在线生成，真实持续学习环）、training performance（过拟合/灾难遗忘检测）。
- **基线与指标**：8 个 memory 系统（vanilla、BM25-M/S、Emb-M/S、A-Mem、Mem0、MemoryOS），LLM-as-judge 归一化指标。

## 关键发现
- **现有记忆系统的有效性/效率都远不达标**，不少场景被 naive RAG（BM25/Embedding 直接把语料当检索库）反超。
- 记忆构造时间差异巨大（MemoryOS >17s/例），Mem0 推理速度异常。
- 垂直域（法律/学术）反馈利用困难，性能波动大。
- "现有方法无法同时处理声明性与程序性记忆"。

## 创新点
1. 第一次把"用户反馈驱动的服务期持续学习"作为记忆评测核心，脱离静态 recall 框架。
2. 提供 on-policy/off-policy 两套可扩展评测协议与统一注册接口，便于横向扩展系统。
3. 明确报告记忆时间（memory time）与推理时间（predict time）的成本维度。

## 局限
- 反馈是模拟的（LLM-as-user），与真实用户行为有差距。
- 任务以知识型为主，agentic 环境（工具、执行）覆盖不足。

## 对 Memory 设计的意义
最贴近"产品化 agent 在服务期持续学习"的评测：提醒我们 memory 系统必须证明"能比 naive RAG 更好地利用反馈"，并报告构建/查询成本；on-policy 协议可作为我们持续学习能力的验收标准。
