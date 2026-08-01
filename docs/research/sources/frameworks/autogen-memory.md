# AutoGen (Microsoft) Memory

> Source: https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/memory.html (fetched 2026-08-01)
> 原文 HTML 已存 autogen-memory.html。

## Memory protocol (autogen_core.memory.Memory)

AgentChat provides a `Memory` protocol that can be extended. The key methods are `query`, `update_context`, `add`, `clear`, and `close`:

- `add`: add new entries to the memory store
- `query`: retrieve relevant information from the memory store
- `update_context`: mutate an agent's internal `model_context` by adding the retrieved information (used in the `AssistantAgent` class)
- `clear`: clear all entries from the memory store
- `close`: clean up any resources used by the memory store

> autogen_core.memory 参考：Memory 是"the storage for data that can be used to enrich or modify the model context"。实现可以使用任何存储机制（list、database、filesystem）与任何检索机制（vector search、text search）。"It is also a memory implementation's responsibility to update the model context with relevant memory content based on the current model context and querying the memory store."

签名：
- `async query(query: str | MemoryContent, cancellation_token) -> MemoryQueryResult`
- `async add(content: MemoryContent, cancellation_token) -> None`（MemoryContent 有 mime_type：TEXT/JSON/MARKDOWN/IMAGE/BINARY）
- `async update_context(model_context: ChatCompletionContext) -> UpdateContextResult`

## ListMemory

`ListMemory` 是官方提供的示例实现：按时间顺序维护记忆的简单 list，把最近记忆追加到模型上下文。直观、易调试。

## 自定义记忆存储（Vector DB 等）

可继承 `Memory` 协议重载 `add`、`query`、`update_context`。官方 `autogen_ext` 扩展提供：

- `autogen_ext.memory.chromadb.ChromaDBVectorMemory` — ChromaDB 向量记忆（可配置 embedding function：SentenceTransformer / OpenAI；可序列化 config）
- `autogen_ext.memory.redis.RedisMemory` — Redis 向量记忆
- `autogen_ext.memory.mem0.Mem0Memory` — Mem0.ai 记忆系统集成（cloud + local backend）

## RAG 模式

文档展示完整 RAG agent：indexing（抓取/分块/存入 ChromaDBVectorMemory）+ retrieval（运行时相似度检索，`k`、`score_threshold` 配置）。

## 设计要点

- Memory 是"just-in-time"的：Agent 在每次推理前 query memory 并把结果注入 model_context（AssistantAgent 生成 MemoryQueryEvent 以可观测）。
- 官方在设计讨论（PR #4438）中明确："The AgentChat framework will likely only have the Memory protocol, developers should overload it to implement whatever vector, graph or any other type of Just in time memory they need." 并提议参考 Semantic Kernel 的 vector memory abstraction。
- 官方注释："AssistantAgent ... focuses on memory.query and adds that JIT to the agent context. It does not concern itself much with how stuff is added to memory ... it is expected that the developer will run memory.add outside of agent logic."
- Memory 组件可序列化为 JSON config（AGS declarative spec 方向）。
- 社区 RFC（#7523 AMP / #7748 SharedMemoryStore）探索跨会话、跨 agent 的共享记忆（agent/group/global scope、capsule recall、importance-based decay、hybrid search）。
- 2025-01 PR #5227 "Task-Centric Memory" 引入 MemoryController/Teachability，让 agent 从试错中学习；与 AssistantAgent 通过 Memory interface 组合。
