# Pydantic AI — Memory / Message History

> Source: https://pydantic.dev/docs/ai/core-concepts/message-history/ (fetched 2026-08-01)
> 另见：pydantic/pydantic-ai PR #4894（2026-03）引入 tiered AbstractMemoryStore；pydantic-ai-harness PR #361（durable Memory capability）。

## 核心定位：stateless，消息历史是"一等公民"但记忆靠应用

Pydantic AI **核心库本身没有内置持久化记忆**。agent 默认无状态；跨 run 上下文靠 `message_history` 参数传递。

### 消息历史 API
- `result.all_messages()` / `new_messages()`（及 JSON 变体）
- `Agent.run/run_sync/run_stream(..., message_history=...)`：把先前消息作为输入继续对话
- `ModelMessagesTypeAdapter`：官方 TypeAdapter，把 `ModelMessage` 序列化/反序列化到 JSON，用于存盘/DB/跨语言
- `sanitize_messages`：清理不可信客户端提交的历史
- `run_id`（每次 run 唯一）、`conversation_id`（沿 message_history 继承，用于追踪/分支 fork）
- `ProcessHistory` capability（或 `before_model_request` hook）：每次请求前拦截/修改消息历史（隐私过滤、token 裁剪、自定义压缩）
- 历史自动修复：broken tool-call/tool-result pairing 会被修复以让 provider 接受

### 压缩/长上下文（Capabilities）
- `Compaction`：LLM 总结旧消息以保持在 context window 内（含 provider-native compaction 与 Pydantic AI Harness 策略）

### 官方 memory 抽象（2026-03，PR #4894）
`pydantic_ai.memory` 新增 tiered 记忆存储协议 `AbstractMemoryStore`：
- `load_recent(session_id, limit)` — short-term：最近 N 条 verbatim 消息
- `load_summary(session_id)` — long-term：压缩文本摘要（注入为 synthetic system context block，避免烧 context window）
- `save(session_id, messages)` — 持久化完整更新历史
- `summarize(session_id)` — LLM 压缩 stub（默认 no-op，子类实现）
- `clear(session_id)`
- `MemoryScope` dataclass：两级 key 组成（user_id, agent_id, conversation_id）
- 内置 `InMemoryStore`、`SQLiteMemoryStore`；`memory=` 参数加到 `Agent.__init__`，`session_id=`/`memory_scope=` 加到 run/iter 变体。

### 生态
- `pya-memory`（第三方）：SQLite/Postgres/DynamoDB 持久化 `ModelMessage` 的 StoreCapability + ProcessHistory 裁剪。
- `pydantic-ai-harness`：官方 "batteries" 包，`memory` capability（top-level，bounded read/write/edit/delete/search tools、filesystem/SQLite/Postgres 存储、tenant scoping、prompt-safe injection）；另有 `SessionPersistence` capability（SQLite/Redis/Postgres）。
- Hindsight / Mem0 等第三方记忆引擎以 tools + instructions 形式接入。

## 结论
Pydantic AI 设计哲学：agent stateless，消息历史作为纯数据自由序列化；持久化/记忆协议（tiered store）逐步进入核心，但最底层的"记住什么、怎么检索"仍由开发者/第三方记忆引擎决定。
