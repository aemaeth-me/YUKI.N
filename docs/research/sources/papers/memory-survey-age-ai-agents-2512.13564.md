# Memory in the Age of AI Agents

- **arXiv**: 2512.13564 (cs.CL) | v1 2025-12-15, v2 2026-01-13
- **作者**: Yuyang Hu, Shichun Liu, Yanwei Yue, Guibin Zhang, ... Shuicheng Yan (47 人，含多位 agent/记忆方向核心学者)
- **本地原始资料**: `sources/papers/memory-survey-age-ai-agents-2512.13564.html`（arxiv abs 页）

## 核心思想
2025 年底最新的一线 agent memory 综述。核心论点是：传统 long/short-term 二分 taxonomy 已不足以刻画当代 agent 记忆的多样性，需要以 **forms（形式）– functions（功能）– dynamics（动态）** 三重视角统一审视 agent 记忆，并把 agent memory 与 LLM memory、RAG、context engineering 明确区隔开来。

## 记忆架构（taxonomy）
- **Forms（三种主流实现）**：token-level（提示词/外部文本，如 RAG、MemGPT）、parametric（权重内知识）、latent memory（隐藏状态/向量层，如 MemoryLLM、M+）。
- **Functions（细粒度功能三分）**：factual memory（记录用户与环境的交互知识）、experiential memory（通过任务执行增量增强问题求解能力）、working memory（单个任务实例内的工作区信息管理）。
- **Dynamics（生命周期）**：记忆的形成（formulation）、检索（retrieval）、演化（evolution）——按时间线剖析记忆如何生成、如何随 agent 与环境互动被更新/强化/遗忘。

## 创新点
1. 对 "agent memory" 作出正式界定，并系统区分其与 LLM memory / RAG / context engineering 的边界（这是此前综述未明确处理的）。
2. 用 forms–functions–dynamics 三维框架替代单纯的时间二分，能容纳 2025 年出现的经验记忆蒸馏工具（Qiu et al.）、memory-augmented test-time scaling（Suzgun et al.）等新趋势。
3. 汇总了 benchmarks 与开源 memory frameworks，并给出前瞻方向：memory 自动化设计、记忆与 RL 深度融合、多模态记忆、多智能体共享记忆、可信性问题。

## 局限
- 综述性质，不做实验对比。
- 属于 snapshot 式梳理，2025 下半年至 2026 的 RL 化 memory agent（AgeMem、Mem-T 等）出现后其 forms/functions 分类仍需再版更新。

## 对 Memory 设计的意义
"memory 是一等公民原语（first-class primitive）" 的论断被明确推到前台；三层 forms 提示我们 agent 记忆体系应同时考虑显式外部存储与参数化/潜在表示层，而非单一路径。
