# Memory for Autonomous LLM Agents: Mechanisms, Evaluation, and Emerging Frontiers

- **arXiv**: 2603.07670 (cs.CL) | 2026-03
- **作者**: 未署名作者组
- **本地原始资料**: `sources/papers/memory-autonomous-agents-survey-2603.07670.html`（arxiv HTML 全文）

## 核心思想
覆盖 2022–2026 初的 agent memory 综述。将 agent memory 形式化为 **write–manage–read 循环**（与 perception/action 紧耦合，POMDP 风格 agent 周期），提出三维 taxonomy，并给出五个机制族系与新一代评估基准的比较。

## 记忆架构（taxonomy 与机制族系）
- **三维 taxonomy**：时间范围（temporal scope）、表示基板（representational substrate）、控制策略（control policy）。
- **五个机制族系**：
  1. context-resident compression（上下文内压缩，如摘要）；
  2. retrieval-augmented stores（检索增强外部存储，RAG）；
  3. reflective self-improvement（反思式自改进，如 Reflexion/Generative Agents）；
  4. hierarchical virtual context（分层虚拟上下文，MemGPT/Letta 系）；
  5. policy-learned management（策略学习式管理，2025-2026 的 RL memory agent）。

## 评测立场（与本综述配套的要点）
- 世代变迁：prompt 级压缩 → 检索增强外部存储 → 端到端学习式记忆策略。
- 评测从静态 recall 走向多会话 agentic 基准（MemoryArena 显示 LoCoMo 近饱和模型在此只剩 40–60%）。
- "Long context ≠ memory"；RAG 与人类差距仍大，瓶颈从存储转向检索质量；"没人好好测遗忘"（仅 MemoryAgentBench 显式测 selective forgetting）；parametric/non-parametric 失败模式不同；评测必须计入成本（token/延迟）。

## 开放挑战
continual consolidation、causally-grounded retrieval（因果而非相似度检索）、trustworthy reflection、learned forgetting、multimodal embodied memory。

## 局限
- 综述 snapshot，部分最新工作（Memora、LME-V2）可能未纳入。
- POMDP 形式化是描述性的，未提供可操作实现。

## 对 Memory 设计的意义
提出"记忆值得与模型本身同等量级的工程投入"的主张；write–manage–read 循环可作为 memory 子系统生命周期接口的组织骨架。
