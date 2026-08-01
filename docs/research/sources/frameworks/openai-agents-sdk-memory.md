# OpenAI Agents SDK — Session Memory / Context

> Source: https://openai.github.io/openai-agents-python/sessions/ + cookbook (fetched 2026-08-01)

## 定位：SDK 不做长期记忆抽象，记忆=Session（对话历史）+ context 注入

OpenAI Agents SDK **没有内置的长期记忆/知识记忆抽象**。官方 docs/context.md 明言 LLM 只能看到 conversation history，要提供数据给 LLM 只有 4 种方式：
1. Agent `instructions`（system prompt，可静态或动态函数）
2. `input` 参数（消息）
3. **Function tools**（on-demand context，LLM 需要时调用）
4. Retrieval / web search 工具（grounding）

### Session（会话记忆 / short-term）
`Session` 协议管理单个会话的对话历史，跨多次 run 持久化：
- run 前自动 `get_items` 取出历史并 prepend 到输入；
- run 后自动 `add_items` 保存新 item；
- `SessionSettings(limit=N)` 限制取回历史数量；
- `session_input_callback` 自定义"历史 + 新输入"的合并/裁剪；
- 内置实现：`SQLiteSession`、`AsyncSQLiteSession`、`RedisSession`、`SQLAlchemySession`、`MongoDBSession`、`DaprSession`、`OpenAIConversationsSession`（OpenAI 服务端托管）、`OpenAIResponsesCompactionSession`（用 responses.compact 自动压缩历史）、`EncryptedSession`（加密 + TTL）、`AdvancedSQLiteSession`（分支/用量分析）。
- 协议仅 4-5 个 async 方法：`get_items`、`add_items`、`pop_item`、`clear_session`。

### 记忆不是 SDK 的一等公民：靠开发者
官方 cookbook（Context Engineering for Personalization / Memory & Compaction）展示的长期记忆模式完全由应用层实现：
- `RunContextWrapper` 携带结构化 state（local-first memory store）；
- "memory-as-a-tool"模式：模型通过工具调用在会话中实时蒸馏候选记忆（live memory distillation）；
- 会话结束用 LLM consolidation 把 session notes 合并去重进 global memory；
- 每轮开始用 hooks 把 profile/memory 渲染成 markdown 注入 system prompt（带优先级规则）；
- 保留最近 N 轮原文，更早的压缩为摘要（TrimmingSession / SummarizingSession）。

### Sandbox Agent 的 Memory 能力（2026 新）
Sandbox agent 支持 `Memory()` capability：把一次 run 的"工作流经验"蒸馏为 `memories/MEMORY.md` + `memory_summary.md` 文件，供未来 run 使用（progressive disclosure：先注入小摘要，需要时再按关键词搜索 rollout_summaries）。记忆隔离按 `MemoryLayoutConfig`。还有 `Compaction()` capability（server-side compaction）用于长上下文。

## 结论
OpenAI Agents SDK：上下文窗口内的 Session 历史由框架管，长期记忆完全交给开发者（工具/context/hooks 组合），官方 cookbook 称之为 "memory-as-a-tool" 与 "context injection" 模式。
