# Rethinking Memory in AI: Taxonomy, Operations, Topics, and Future Directions

- **arXiv**: 2505.00675 (cs.CL) | 2025-05
- **作者**: Yiming Du 等（GitHub: Elvin-Yiming-Du/Survey_Memory_in_AI）
- **本地原始资料**: `sources/papers/rethinking-memory-ai-taxonomy-2505.00675.html`（arxiv HTML 全文）

## 核心思想
不沿用功能/时间分类，而是从 **原子操作（atomic operations）** 与 **表示类型（representation types）** 两个维度重述 AI 记忆系统。强调此前综述忽略的"记忆底层动力学"——记忆不是静态数据，而是一组可组合的原子操作。

## 记忆架构
- **表示类型**：parametric、contextual-structured（图/表/结构化）、contextual-unstructured（向量库/原文）。
- **六大原子操作**：Consolidation、Updating、Indexing、Forgetting、Retrieval、Compression。
- 用 RCI（相对引用指数）扫描 2022–2025 的 30K+ 顶会论文（NeurIPS/ICLR/ICML/ACL/EMNLP/NAACL），把操作映射到四个研究主题：long-term memory、long-context、parametric modification、multi-source memory。

## 创新点
1. 把"遗忘（Forgetting）"与"压缩（Compression）"提升为与 retrieval 并列的一等操作——这与 2025-2026 基准（MemoryAgentBench 的 selective forgetting、Memora 的 FAMA）形成呼应。
2. 数据驱动（RCI）而非直觉驱动地选取重要文献。
3. 从数据管理视角总结框架层（Letta、Mem0、Zep、Graphiti 等）与 memory layer 系统。

## 局限
- 操作分类偏系统视角，对"何时/为何做某个操作"（策略学习）着墨较少——而这正是 2025 下半年 RL memory agent 的主攻方向。

## 对 Memory 设计的意义
直接给出实现 agent memory 的最小操作集合（CRUD + consolidation + indexing + compression + forgetting），可作为 memory 模块 API 设计的 checklist。
