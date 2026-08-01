# MemoryAgentBench: Evaluating Memory in LLM Agents via Incremental Multi-Turn Interactions

- **arXiv**: 2507.05257 (cs.CL) | 2025-07-07 (v3) | ICLR 2026 | GitHub: HUST-AI-HYZ/MemoryAgentBench
- **作者**: Yuanzhe Hu (Yannan Hu), Yu Wang, Julian McAuley
- **本地原始资料**: `sources/papers/memoryagentbench-2507.05257.html`（arxiv HTML 全文）

## 核心思想
基于记忆科学/认知科学识别记忆 agent 的 **四项核心能力**，构建增量式多轮交互评测，覆盖此前基准（LoCoMo、LongMemEval 等）的空白：把长上下文数据集重构为多轮交互流，模拟真实记忆累积过程。

## 评测架构（四项核心能力）
- **Accurate Retrieval (AR)**：从长历史中精确召回（含 NIAH 式单/多文档 QA、EventQA 时间序列推理）。
- **Test-Time Learning (TTL)**：对话中即时学习（ICL 系列：banking/clinic/nlu/trec）。
- **Long-Range Understanding (LRU)**：长程理解（detectiveQA）。
- **Selective Forgetting / Conflict Resolution (SF/CR)**：选择性遗忘与冲突消解（FactConsolidation，用 MQUAKE 反事实编辑对构造，长度 6K-262K）。
- 新增数据集：**EventQA**（时间序列 NIAH，全自动管线）、**FactConsolidation**（真/反事实成对）。
- 规模：2071 题，上下文深度 103k-1.44M token。

## 关键发现
- **没有任何系统四项全优**，绝大多数在 selective forgetting 上明显失败。
- 评测三类 agent：长上下文（LCA）、RAG、agentic memory（AM）。

## 创新点
1. 首次把"选择性遗忘"列为记忆 agent 一等评测维度。
2. "注入一次、多次查询"（inject once, query multiple）的高效评测设计。
3. 统一协议下横向比较商业记忆 agent（MIRIX、MemGPT）、RAG 与长上下文模型。

## 局限
- 基于合成/重构数据，真实世界交互覆盖有限。
- 预算限制导致 agent 样本较少（作者自陈）。

## 对 Memory 设计的意义
四项能力（AR/TTL/LRU/Forgetting）是我们 memory 体系的自测清单；尤其"选择性遗忘"应纳入我们系统的显式设计目标，而非事后修补。
