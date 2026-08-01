# AWS Bedrock AgentCore Memory

> Source: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/memory.html + memory-types.html + release-notes (fetched 2026-08-01)
> AgentCore 于 2025-07 preview 发布，Memory 为其中托管服务。

## 概述

AgentCore Memory 是**全托管**记忆服务，解决 agent 无状态问题：short-term（会话内原始事件）+ long-term（跨会话抽取的知识）。支持多种 SDK 与 agent 框架（Strands、LangChain、AutoGen、Google ADK、OpenAI Agents、CrewAI、LlamaIndex、LangGraph——Runtime 均可跑，Memory 为资源层）。

## 两种记忆类型

### Short-term memory
按 session 存储原始 events（对话消息、工具调用等），经 `CreateEvent` 写入，`sessionId` 关联。可用 `ListSessions`/`ListEvents`/`GetEvent` 恢复会话上下文（服务重启后仍可恢复）。Event metadata 支持键值过滤。Event 保留期可配（`eventExpiryDuration`，7-365 天，默认 30 天）。

### Long-term memory
后台异步把 raw events 抽取出关键洞察（summary、facts、user preferences），存为 memory records，可跨 session 通过 `RetrieveMemoryRecords` 语义检索（topK + relevanceScore）。流程：**Extraction**（抽取）+ **Consolidation**（与已有记忆合并去重）。

## Memory strategies（long-term 抽取策略）

- `SEMANTIC` — 向量相似度检索事实
- `SUMMARIZATION` — 对话压缩摘要（`/summaries/{actorId}/{sessionId}`）
- `USER_PREFERENCE` — 用户偏好（`/users/{actorId}/preferences`）
- `EPISODIC` — 有意义的交互片段（`/episodes/{actorId}/{sessionId}` + reflection）
- `CUSTOM` / built-in with overrides / self-managed strategy

namespace 模板做作用域（actorId + sessionId + app_name）。可配 indexed metadata keys（≤10）做结构化过滤，KMS 加密，Resource-Based Policies，record streaming（Kinesis 推送 CRUD 事件）。

## 使用方式

- CLI `agentcore add memory --strategies SEMANTIC,USER_PREFERENCE ...`；`agentcore deploy`
- Boto3 SDK：`bedrock-agentcore` / `bedrock-agentcore-control`
- Harness（托管 agent loop）：默认内置 memory（semantic+summarization，30 天 event expiry），每轮自动保存会话并按 session/actor 隔离；retrieval 默认 topK=10、relevanceScore=0.2，自动注入上下文。Context truncation：`sliding_window`（默认）/ `summarization` / `none`。

## 与 RAG 对比（官方文档专节）
Long-term memory（记忆）vs RAG（检索外部文档库）是不同的关注点：记忆从对话中自动抽取，RAG 索引外部语料。

## 备注
AgentCore Memory 从对话中自动抽取长期记忆（LLM 驱动 extraction/consolidation），理念接近 LangMem 的 background memory manager 与 Zep/Graphiti，但作为 AWS 托管服务（事件保留、加密、RBAC、流式、跨账号等治理完备）。best practices 中专门讨论 memory poisoning / prompt injection 防御。
