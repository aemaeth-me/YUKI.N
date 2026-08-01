# Production Memory Frameworks: MemGPT/Letta, mem0, Zep, Graphiti

URL: https://jatinbansal.com/ai-engineering/production-memory-frameworks/
Author: Jatin Bansal
Published: 2026-05-19

---

Production memory requires more than a vector store: write gates, episode formats, retrieval policy, tenant isolation, and maintenance jobs all need an owner. Letta, mem0, Zep, and Graphiti package different subsets of that work and impose different storage and retrieval contracts.

A production memory framework is a runtime that bundles the write pipeline, storage substrate(s), read pipeline, multi-tenancy primitives, and maintenance passes into a single SDK. A substrate (pgvector, Qdrant) is unopinionated; a framework picks an episode shape, a write gate, a retrieval blend, a tier policy, and a tenant model, then exposes them as a coherent add/search/update/delete API. Adopting a framework is buying its opinions.

Four define the field in 2026:
- **MemGPT/Letta**: productized version of the original MemGPT paper; three-tier hierarchical memory (core/recall/archival) with the agent self-managing tier promotion via tool calls. 核心意见："agent-driven memory management"——没有显式 memory.add()，agent 决定记什么。
- **mem0**: the distill-at-write vector layer with optional graph extension (Mem0g); the LLM-gated fact-extraction pipeline runs on every add. 核心意见："long-term memory 的单位是蒸馏后的事实，而非原始轮次"。
- **Zep**: graph-first hybrid; a bi-temporal knowledge graph wraps vector and BM25 indexes, all retrieval fused, no LLM in the read path.
- **Graphiti**: Zep's open-source temporal-graph engine, usable standalone.

## 对比表

| Dimension | Letta | mem0 | Zep | Graphiti |
| --- | --- | --- | --- | --- |
| Primary substrate | Hierarchical (core/recall/archival) | Vector + optional graph | Graph + vector + BM25 | Bi-temporal graph |
| Write path cost | Low (DB write + tool call) | High (LLM fact extraction per turn) | Very high (entity+relation extraction + bi-temporal stamping) | Very high |
| Read path cost | Low | Low (vector + optional graph traversal) | Low (pure traversal + RRF, no LLM) | Low |
| Bi-temporal | No | No | Yes (valid + transaction time) | Yes |
| Self-managed by agent | Yes | No (harness-driven) | No | No |
| Multi-tenancy | Per-agent state | user_id required param | user_id/session_id | group_id namespace |
| 2026 benchmark anchor | ~83% LongMemEval | 94.4% LongMemEval | 71.2% LongMemEval | — |

> The benchmark numbers in that row are the most volatile entry in the table. Mem0's LoCoMo score went from 66.9% in 2025 to 92.5% in 2026; partly genuine algorithm improvement, partly protocol stabilization, partly hill-climbing. Read protocols (judge model, ingest pipeline, top-K) before comparing across rows.

## 决策框架

> Reach for a framework when (a) your team has fewer than two engineers who can own a memory subsystem long-term, (b) your workload fits within ±20% of one of the four frameworks' opinions, and (c) you don't have an existing storage layer the framework would fight. Hand-roll when (a) you have those engineers, (b) your defining write or read pattern isn't covered, or (c) you already operate a vector store and a graph store.

> The most common mistake: adopting a framework, then writing so much code around it to make it fit that you would have been better off rolling your own. ... If you find yourself overriding more than two defaults, the framework is wrong for your workload.

> The escape from the binary: roll your own on a store primitive and adopt a framework only for the layer where its opinions are critical. LangGraph stores give you a tuple-namespaced KV/vector store; ... Most teams converge on this after a year.

## Bi-temporal 的价值 (Graphiti/Zep)

> The bi-temporal property is critical: the "as of March 20" query returns Priya (the manager as-of that date), not Devansh (the current one). Vector-only stores cannot answer that question correctly regardless of how their retrieval is scored. If your workload doesn't include point-in-time queries, this property is wasted complexity; if it does, no other framework ships it as a first-class concept.

## 相关论文

- MemGPT (Packer et al., 2023) arXiv:2310.08560 — 层级记忆与 OS paging 类比
- Mem0 (Chhikara et al., 2025) arXiv:2504.19413 — distill-at-write + Mem0g
- Zep (Rasmussen et al., 2025) arXiv:2501.13956 — bi-temporal knowledge graph
- mem0 "State of AI Agent Memory 2026" (mem0.ai/blog/state-of-ai-agent-memory-2026)
