# Zep / Graphiti — Temporal Knowledge Graph Memory

> Source: Zep 论文 "Zep: A Temporal Knowledge Graph Architecture for Agent Memory"（arXiv:2501.13956, 2025-01）+ 社区综述（Mem0 vs Zep vs Letta vs Cognee 2026 对比，非官方，仅作背景）

## 定位

Zep 是 **memory layer 服务**，核心组件 **Graphiti**——开源 temporal knowledge graph 引擎。理念：动态合成非结构化对话数据 + 结构化业务数据，保持历史关系，供 agent 记忆检索。Zep Cloud 为托管服务（Graphiti 开源可自托管）。

## 核心机制

- **Temporal / bi-temporal knowledge graph**：每条事实 = 带 `valid_at` / `invalid_at` 有效性窗口的边。事实被取代时不删除，只把旧边标记失效并创建新边。可回答"现在是什么 true"与"March 时是什么 true"。这是与其他 vector 记忆最大的技术分水岭。
- **Episodic + semantic memory 融合**：图谱同时存事件片段与实体/事实，附 entity/community summaries。
- **Retrieval = 融合检索**：embedding（cosine）+ 全文搜索（BM25）+ 图上 BFS（n-hop 扩展），再 RRF 融合；读路径无 LLM（快）。
- **写路径成本高**：实体 + 关系抽取 + bi-temporal 打标（LLM 密集）。

## 基准

- DMR（MemGPT 的 benchmark）：94.8% vs 93.4%（超 MemGPT）。
- LongMemEval：比 baseline 高至 18.5%，延迟降低 90%；2026 社区对比 Zep 63.8%（GPT-4o）vs Mem0 49.0%（temporal retrieval 15 分差距）。
- 适合：CRM、合规、医疗；关系 + 时间查询为主的场景。不适合：无关系结构的工作负载。

## 自托管现实

Graphiti 是 Apache-2.0 但需要自跑 Neo4j（或 FalkorDB）；Zep Community Edition 已废弃。图构建/查询/延迟有额外成本（GraphRAG tax）。
