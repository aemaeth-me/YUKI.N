# LangGraph Stores — Long-term Memory 底座

> Source: https://docs.langchain.com/oss/python/langgraph/stores (fetched 2026-08-01)

## Store 与 Checkpointer 的分工

- **Checkpointer**：保存 graph state，scoped to one thread（会话内 short-term/durable execution）。
- **Store**：跨线程持久化任意 key-value 数据（用户偏好、累积知识、跨会话事实）——long-term memory 底座。

## Store API（BaseStore）

记忆按 `namespace`（tuple 字符串，类似文件夹，可含 `user_id`）与 `key`（唯一标识）组织。每条 Item 有：`value`（dict）、`key`、`namespace`、`created_at`、`updated_at`。

方法：
- `put(namespace, key, value)` / `get(namespace, key)` / `delete`
- `search(namespace_prefix, query=None, filter=None, limit=10, offset=0)` — 无 query 时按前缀枚举；有 query 时做**语义搜索**（需配置 embedding index）
- `list_namespaces` — 枚举存在的 namespace

自定义 store：subclass `BaseStore`，实现 5 个 async 方法（asearch/aget/aput/adelete/alist_namespaces）。语义搜索支持：`query` 参数嵌入后按 cosine 排序，返回 `score` 字段；不支持向量则 `NotImplementedError`。

内置实现：`InMemoryStore`（开发）、`PostgresStore`/`AsyncPostgresStore`（生产，DB-backed）、LangSmith/LangGraph Platform 默认提供 postgres-backed store。

## 语义搜索配置

配置 store 时指定 embedding（如 `{"dims": 1536, "embed": "openai:text-embedding-3-small"}`），可用 `fields`/`index` 参数控制哪些字段被嵌入。LangGraph Platform 需在 langgraph.json 配 indexing settings。

## 在 LangGraph 中使用

graph 同时 compile checkpointer + store；用 `thread_id`（会话）+ `user_id`（namespace）invoke。节点内通过 `Runtime` 对象（自动注入）访问 store，`store.search` 取记忆并在 model call 中作为上下文。同 user 的新 thread 仍可访问相同记忆。

## 与 LangMem 的关系

LangMem 的记忆工具（manage/search）就是封装 BaseStore：namespace 里用 `{langgraph_user_id}` 等运行时占位符；Store 决定记忆如何存取，LangMem 决定"何时/记住什么"（LLM 决策）。
