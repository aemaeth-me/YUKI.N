# Cognee 记忆引擎架构（官方文档 docs.cognee.ai / cognee.ai，2026-08 抓取）

来源：
- https://cognee.ai/ （官网）
- https://docs.cognee.ai/ 
- https://docs.cognee.ai/core-concepts/main-operations/legacy-operations/cognify （cognify 文档）
- https://docs.cognee.ai/api-reference/cognify/cognify
- https://cognee.ai/blog/fundamentals/how-cognee-builds-ai-memory （2026-02-24）
- DeepWiki：cognee 系统架构总览

## 定位
"Open Source Memory Platform for Agents"（v1.0，2026 上线）。把上下文捕获 → graph memory，让 agent 跨 session 召回。本地开源起步，可扩展到 Cognee Cloud。Bayer 等 70+ 公司生产使用，Python SDK 每月运行百万级 pipeline。

## 记忆模型：三 store 混合（Relational + Vector + Graph）
| Store | 存什么 | 作用 |
|---|---|---|
| Relational（默认 SQLite，可 Postgres）| 文档、chunk、provenance（来源与链接）| 永久记忆摄入期的元数据 |
| Vector（默认 LanceDB，可 Qdrant/pgvector/Redis/DuckDB/Pinecone/ChromaDB）| chunk 与 DataPoint 的嵌入 | 语义相似检索 |
| Graph（默认 Kuzu，可 Neo4j/FalkorDB/Neptune/Memgraph）| 实体与关系 | 结构遍历（Cypher）|

- 基本单元 **DataPoint**（Pydantic）：内容 + metadata，决定哪些字段被嵌入。实体、chunk、摘要、关系都是 DataPoint。图上每个 node 都有对应 embedding（语义↔结构可互跳）。
- 会话记忆（session memory）= 短期工作记忆，把相关嵌入与图片段载入运行时上下文；永久记忆（permanent memory）= 长期知识工件（用户数据、交互痕迹、外部文档、派生关系），在图中交叉连接。

## 写路径：cognify()（核心，v1 中被 remember() 取代）
六段 pipeline：
1. classify documents（+权限校验）
2. text chunking / semantic segmentation
3. LLM entity extraction
4. relationship detection → graph construction
5. embedding（node + summary）写向量库
6. summarization + indexing
- 增量：只处理新增/变更文件。可后台运行（run_in_background）。
- 成本：默认每 chunk 2 次 LLM 调用（graph extraction + summarization）；chunk_size 由模型上限自动算（~1024-8192 token）。
- 自定义：graph_model（JSON schema 自定义实体抽取）、custom_prompt、ontology_key（预上传本体文件约束抽取）、chunkers、chunks_per_batch/data_per_batch。
- **Contradiction detection（可选，默认关）**：CONTRADICTION_DETECTION=true 时，把本轮触及的 fact 与既有邻居 fact 比较，LLM 判定冲突则写 `contradicts` 边（只加边，不删不改，非破坏性）。fact cap 限制比较规模。
- **memify()**：摄入后精化——修剪陈旧节点、强化频繁连接、基于使用信号重加权边、添加派生事实（self-improvement）。
- 后续演进（作者博客）：memory graph 可每 user/group/共享图实例化；dataset 级权限（read/write/delete/share）；多租户支持 pgvector/Neo4j/Kuzu/LanceDB。

## 读路径：search()
14 种检索模式（v1 前）：
- GRAPH_COMPLETION（默认）：vector 提示找相关三元组 → 图遍历构造结构化上下文 → LLM 生成。不同于 vanilla RAG（非 top-k chunk 直出）。
- RAG_COMPLETION、GRAPH_COMPLETION_COT（多跳图遍历链式推理）、GRAPH_COMPLETION_CONTEXT_EXTENSION（迭代扩上下文）、GRAPH_SUMMARY_COMPLETION、TRIPLET_COMPLETION、NATURAL_LANGUAGE（NL→Cypher）、CYPHER、CHUNKS、CHUNKS_LEXICAL（Jaccard）、SUMMARIES、TEMPORAL（时态图搜索）、CODING_RULES、FEELING_LUCKY（LLM 自动选模式）。
- 2026-02 博客提及：向量搜索作为"hint"找相关三元组，再图遍历补全——graph-vector hybrid。

## 更新与遗忘
- add()/update()/delete()/forget()；cognify 幂等（跳过已处理）。schema 变更需删数据集重建或 memify 增量富化。
- 更新语义：默认不破坏性；memify 做结构演化（修剪/重加权/派生事实）。

## 托管 vs 自托管
- 开源（AGPL/Apache 讨论中，README 为社区版）：pip install cognee，本地默认三 store 全内置。
- Cognee Cloud：托管。MCP server 让 Claude Code、Cursor、LangGraph、OpenClaw 等读写 cognee 记忆。
- 定价：本地免费，云按规模付费（官网未给具体价目）。

## 2025-2026 动态
- v1.0（2026）：API 收敛为 remember()/recall()（合并 add+cognify+memify）。cognify/search 标记 legacy。
- 定位从"better RAG / 向量库抽象层"→"structured, persistent, adaptive memory / 知识引擎"。
- 论文/评测：官方侧重 AI memory evals（自有评测说明）与 MCP 集成。ENIAC 架构未在 2026 官方文档中作为主线出现（2024 的早期代号），当前架构文档是"三 store + pipeline"。
