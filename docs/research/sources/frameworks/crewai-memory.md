# CrewAI Memory (official docs)

> Source: https://docs.crewai.com/en/concepts/memory (fetched 2026-08-01)
> 注：docs.crewai.com 为 Next.js 站点，以下为渲染后文本；原始 HTML 保存在 crewai-memory.html。

## Overview

CrewAI provides a **unified memory system** — a single `Memory` class that replaces separate short-term, long-term, entity, and external memory types with one intelligent API. Memory uses an LLM to analyze content when saving (inferring scope, categories, and importance) and supports adaptive-depth recall with composite scoring that blends semantic similarity, recency, and importance. You can use memory four ways: **standalone** (scripts, notebooks), **with Crews**, **with Agents**, or **inside Flows**.

## Quick Start

## Four Ways to Use Memory

### Standalone
Use memory in scripts, notebooks, CLI tools, or as a standalone knowledge base — no agents or crews required.

### With Crews
Pass `memory=True` for default settings, or pass a configured `Memory` instance for custom behavior.

When `memory=True`, the crew creates a default `Memory()` and passes the crew's `embedder` configuration through automatically. All agents in the crew share the crew's memory unless an agent has its own. Without a custom `embedder`, memory uses OpenAI `text-embedding-3-large` embeddings. After each task, the crew automatically extracts discrete facts from the task output and stores them. Before each task, the agent recalls relevant context from memory and injects it into the task prompt.

### With Agents
Agents can use the crew's shared memory (default) or receive a scoped view for private context.

### With Flows
Every Flow has built-in memory. Use `self.remember()`, `self.recall()`, and `self.extract_memories()` inside any flow method.

## Hierarchical Scopes

### What Scopes Are
Memories are organized into a hierarchical tree of scopes, similar to a filesystem. Each scope is a path like `/`, `/project/alpha`, or `/agent/researcher/findings`.

Scopes provide **context-dependent memory** — when you recall within a scope, you only search that branch of the tree, which improves both precision and performance.

### How Scope Inference Works
When you call `remember()` without specifying a scope, the LLM analyzes the content and the existing scope tree, then suggests the best placement. If no existing scope fits, it creates a new one. Over time, the scope tree grows organically from the content itself — you don't need to design a schema upfront.

### MemoryScope: Subtree Views
A `MemoryScope` restricts all operations to a branch of the tree. The agent or code using it can only see and write within that subtree.

### Best Practices for Scope Design
- **Start flat, let the LLM organize.**
- **Use `/{entity_type}/{identifier}` patterns.** `/project/alpha`, `/agent/researcher`, `/company/engineering`, `/customer/acme-corp`.
- **Scope by concern, not by data type.** `/project/alpha/decisions` rather than `/decisions/project/alpha`.
- **Keep depth shallow (2-3 levels).**
- **Use explicit scopes when you know, let the LLM infer when you don't.**

## Memory Slices

### What Slices Are
A `MemorySlice` is a view across multiple, possibly disjoint scopes. Unlike a scope (which restricts to one subtree), a slice lets you recall from several branches simultaneously.

### When to Use Slices vs Scopes
- **Scope**: restrict to a single subtree.
- **Slice**: combine context from multiple branches.

### Read-Only Slices
Give an agent read access to multiple branches without letting it write to shared areas.

### Read-Write Slices
When read-only is disabled, you can write to any of the included scopes, but you must specify which scope explicitly.

## Composite Scoring

Recall results are ranked by a weighted combination of three signals:

- **similarity** = `1 / (1 + distance)` from the vector index (0 to 1)
- **decay** = `0.5^(age_days / half_life_days)` — exponential decay (1.0 for today, 0.5 at half-life)
- **importance** = the record's importance score (0 to 1), set at encoding time

Each `MemoryMatch` includes a `match_reasons` list so you can see why a result ranked where it did (e.g. `["semantic", "recency", "importance"]`).

## LLM Analysis Layer

Memory uses the LLM in three ways:

1. **On save** — When you omit scope, categories, or importance, the LLM analyzes the content and suggests scope, categories, importance, and metadata (entities, dates, topics).
2. **On recall** — For deep/auto recall, the LLM analyzes the query (keywords, time hints, suggested scopes, complexity) to guide retrieval.
3. **Extract memories** — `extract_memories(content)` breaks raw text (e.g. task output) into discrete memory statements.

## Memory Consolidation

When saving new content, the encoding pipeline automatically checks for similar existing records in storage. If the similarity is above `consolidation_threshold` (default 0.85), the LLM decides what to do:

- **keep** — The existing record is still accurate and not redundant.
- **update** — The existing record should be updated with new information (LLM provides the merged content).
- **delete** — The existing record is outdated, superseded, or contradicted.
- **insert_new** — Whether the new content should also be inserted as a separate record.

### Intra-batch Dedup
When using `remember_many()`, items within the same batch are compared against each other before hitting storage. If two items have cosine similarity >= `batch_dedup_threshold` (default 0.98), the later one is silently dropped. Pure vector math, no LLM calls.

## Non-blocking Saves

`remember_many()` is **non-blocking** — it submits the encoding pipeline to a background thread and returns immediately.

### Read Barrier
Every `recall()` call automatically calls `drain_writes()` before searching, ensuring the query always sees the latest persisted records.

### Crew Shutdown
When a crew finishes, `kickoff()` drains all pending memory saves in its `finally` block.

## Source and Privacy

Every memory record can carry a `source` tag for provenance tracking and a `private` flag for access control.

### Private Memories
Private memories are only visible to recall when the `source` matches.

## RecallFlow (Deep Recall)

`recall()` supports two depths:

- **`depth="shallow"`** — Direct vector search with composite scoring. Fast (~200ms), no LLM calls.
- **`depth="deep"` (default)** — Runs a multi-step RecallFlow: query analysis, scope selection, parallel vector search, confidence-based routing, and optional recursive exploration when confidence is low.

**Smart LLM skip**: Queries shorter than `query_analysis_threshold` (default 200 characters) skip the LLM query analysis entirely, even in deep mode.

## Embedder Configuration

Default: OpenAI `text-embedding-3-large` embeddings, 3072-dimensional vectors.

## LLM Configuration

Memory uses an LLM for save analysis, consolidation decisions, and deep recall query analysis. Default `gpt-4o-mini`. LLM is initialized **lazily**.

## Storage Backend

- **Default**: LanceDB, stored under `./.crewai/memory` (or `$CREWAI_STORAGE_DIR/memory`).
- **Custom backend**: Implement the `StorageBackend` protocol (`crewai.memory.storage.backend`) and pass an instance to `Memory(storage=your_backend)`.

## Failure Behavior

If the LLM fails during analysis, memory degrades gracefully (default scope `/`, importance 0.5, falls back to vector search).

## Memory Events

All memory operations emit events with `source_type="unified_memory"`.

## Configuration Reference

| Parameter | Default | Description |
| --- | --- | --- |
| `llm` | `"gpt-4o-mini"` | LLM for analysis |
| `storage` | `"lancedb"` | Storage backend |
| `embedder` | OpenAI text-embedding-3-large | Embedder |
| `recency_weight` | `0.3` | Weight for recency in composite score |
| `semantic_weight` | `0.5` | Weight for semantic similarity |
| `importance_weight` | `0.2` | Weight for importance |
| `recency_half_life_days` | `30` | Days for recency score to halve |
| `consolidation_threshold` | `0.85` | Similarity above which consolidation is triggered |
| `consolidation_limit` | `5` | Max existing records to compare during consolidation |
| `default_importance` | `0.5` | Importance when not provided |
| `batch_dedup_threshold` | `0.98` | Cosine similarity for dropping near-duplicates |
| `confidence_threshold_high` | `0.8` | Recall confidence above which results are returned directly |
| `confidence_threshold_low` | `0.5` | Recall confidence below which deeper exploration is triggered |
| `complex_query_threshold` | `0.7` | For complex queries, explore deeper below this confidence |
| `exploration_budget` | `1` | Number of LLM-driven exploration rounds during deep recall |
| `query_analysis_threshold` | `200` | Queries shorter than this skip LLM analysis during deep recall |

注：CrewAI 旧文档（v1.14.7 及更早）中的四类记忆（short-term、long-term、entity、contextual）在 2025 年中后被新统一的 `Memory` 类取代。旧 FAQ 仍列出："Short-term memory: Temporary storage for immediate context; Long-term memory: Persistent storage for learned patterns and information; Entity memory: Focused storage for specific entities and their attributes; Contextual memory: Memory that maintains context across interactions."
