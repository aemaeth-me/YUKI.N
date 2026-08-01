# Cognee — Graph-native AI Memory Platform

> Source: github.com/topoteretes/cognee README（fetched 2026-08-01）+ 2026 社区综述（背景）

## 定位

Cognee 是**开源 AI memory platform**：摄入任意格式数据，持续构建自托管知识图谱，给 agent 跨会话持久长期记忆。暴露为 MCP server，可被 Claude Code、Cursor、Windsurf 等读写。

## ECL 管线（Extract-Cognify-Load）

1. **Extract**：从异构源（38+ sources：文档、PDF、wiki、研究笔记）抽取实体与关系。
2. **Cognify**：用认知科学启发的本体生成，把内容结构化进 typed graph（节点 + 边 + embeddings 叠加）。
3. **Load**：载入可查询存储（关系 + 向量 + 图统一引擎）。

## 关键特性

- **统一存储**：cognee 1.0 可在单个 Postgres 实例上跑完整记忆层（关系元数据 + pgvector + graph backend + SQL session cache）；本地开发全嵌入式（SQLite、LanceDB、Kuzu）。图层生产环境推荐图原生后端（Kuzu/Neo4j）。
- **14 种检索模式**（plain RAG → chain-of-thought graph traversal）。
- **memify 层**：随时间调图，把带评分的响应喂回边权重，检索随使用变锐利。
- **provenance**：页级来源（University of Wyoming 用其构建政策证据图）。
- Claude Code plugin：钩住生命周期（SessionStart/UserPromptSubmit/PostToolUse/Stop/PreCompact/SessionEnd），注入 dataset-scoped context、会话结束同步进永久图谱。
- 多租户/租户隔离、OTEL collector、审计属性。

## 评价

- 优点：typed KG 严格结构化、跨文档关系推理、MCP-exposed、provenance。
- 缺点：无 SOC 2 / HIPAA 认证（截至 2026-06）；无 LongMemEval/LoCoMo 公开分数；无 BM25 / 专门 temporal 检索策略；托管云较新。
- 定位：面向"记忆 = 文档语料"（研究笔记、政策、文献），而非简单聊天用户偏好。对个人化场景是 overkill。
- 2026-02 获 €7.5M seed。
