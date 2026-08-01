# AI Agent Memory in 2026 · Vector DBs vs MEMORY.md vs Graphs (Agent Memory Lab)

URL: https://www.jakecuth.com/work/agent-memory-lab/
Author: Jake Cuth
Published: 2026-05-07

---

Anthropic's CLAUDE.md is one extreme. A managed temporal knowledge graph is the other. Between them sit vector DBs, framework memory layers, long context windows, and the hybrids that ship in production.

> The honest synthesis: MEMORY.md is the right answer for ~80% of solo coding-agent workflows and ~0% of consumer chat products, with a large messy middle where hybrids dominate.

## 关键数据点

- 2025-09 Anthropic 推出 memory tool：它就是一个目录，五个操作（view, create, str_replace, insert, delete），没有 vector store，没有 graph backend。
- 到 2026-04，基于该原语的"标准文件系统 agent"在 LoCoMo 拿到 74.0%，超过 Mem0 专门的 graph variant 的 68.5%——"对专用记忆类别来说是个尴尬的结果"。
- 但不通用：LongMemEval 上，full-context GPT-4o 60.2-64%，Mem0 v1 独立复测 49.0%，Zep/Graphiti 71.2%，2026 前沿 (Mastra Observational, Mem0 v2, EverMemOS, TiMem) 83-95%。凡是事实演化、需要冲突解决、或数百个 session 叠加在同一用户时，文件式记忆非线性退化。

## 2026 现状

> The field is consolidating around a hybrid. Claude Code, Cursor, and Windsurf all combine a static instruction file (CLAUDE.md, .cursor/rules, global_rules.md) with just-in-time retrieval and, for some, a learned memory store. Vector DBs are roughly 78% enterprise-adopted but losing pricing power at the bottom; long context windows reach 1M to 10M tokens but suffer measurable context rot; dedicated frameworks (Mem0, Zep, Letta) are converging on roughly the same architecture. Below the threshold, plain files. Above it, hybrid.

时间线（2023-2026）：
- 2023 Liu et al. "Lost in the Middle"：middle-of-context 检索 15-30% 下降
- 2025-01 Zep/Graphiti paper: 94.8% DMR, 71.2% LongMemEval, 90% latency cut
- 2025-07 Chroma "Context Rot" 报告（18 个 LLM，非均匀退化确认）
- 2025-09 Anthropic 发布 memory tool（文件目录而非数据库）
- 2025-10 Mem0 融 $24M；成为 AWS Strands SDK 独家 memory provider
- 2026 前沿 benchmarks: TiMem 76.88%, EverMemOS 83.0%, Mastra Observational 94.87% LongMemEval

## 结论

> Below the threshold (one user, one project, deterministic preferences, fewer than 30 facts, queries that fit in context after caching), MEMORY.md is not just adequate. It is on the Pareto frontier.
> Above the threshold (multi-user, evolving facts, temporal reasoning, hundreds of sessions per user, conflicting updates that need to replace not append), file-based memory degrades non-linearly.

> Not a recommendation against vector DBs. Vector RAG remains the default for >10M-document corpora. The argument is narrower: for cross-session agent memory, vector RAG alone underperforms hybrid memory layers by double-digit points on published benchmarks.

另注（Stack Overflow 2025 调查）：Redis 以 43% 居"top AI-agent data store"，领先所有专用 vector DB。
