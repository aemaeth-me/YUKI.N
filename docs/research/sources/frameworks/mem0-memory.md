# Mem0 — Universal Memory Layer

> Source: https://docs.mem0.ai/open-source/python-quickstart, /platform/quickstart, /core-concepts/memory-operations/search, /platform/features/entity-scoped-memory, github.com/mem0ai/mem0 (fetched 2026-08-01)

## 定位

Mem0 是 **drop-in memory API / memory layer**（不是 agent 框架），可为任意 agent 框架（LangChain、CrewAI、LangGraph、OpenAI Agents SDK 等）加记忆。开源（Apache-2.0，~47K-61K stars）+ 托管平台（Mem0 Platform）。2025-10 获 $24M Series A。

## API 面（两个函数起步）

```python
m = Memory()  # or MemoryClient(api_key=...) for Platform
m.add(messages, user_id="alex")              # 传入对话轮次，自动抽取事实
results = m.search("What do you know about me?", filters={"user_id": "alex"})
```

**写入时蒸馏（distill-at-write）**：`add()` 用 LLM（默认 gpt-5-mini）把对话抽出离散事实（"Is a vegetarian"、"Allergic to nuts"），去重/冲突解决（self-editing pipeline）。`infer=False` 可跳过 LLM 存原文。**记忆单位是蒸馏后的事实，而非原始轮次。**

## 实体作用域（entity-scoped memory）

`user_id` / `agent_id` / `app_id` / `run_id` 四个标识符做记忆隔离（隐私边界）。写可带任意组合；读在 filters 中按单一实体空间解析（AND user+agent 返回空，用 OR）。`*` 通配匹配非 null。隐含 null scoping。

## 检索

`search()`：向量语义检索为主，可选 keyword/entity 信号融合、reranker（Platform 有托管的 reranker catalog）、`threshold`/`top_k`、AND/OR 比较运算符过滤、categories 分类、时间戳。Platform v3 支持 Temporal Reasoning（时间感知查询）。OSS 可 `explain=True` 调试排序。

## 默认技术栈（OSS）

OpenAI `gpt-5-mini`（抽取/更新）+ `text-embedding-3-small`（1536 维）+ Qdrant 向量库（/tmp/qdrant）+ SQLite history（~/.mem0/history.db）。可换任意 LLM/embedder/vector store。可选 Graph Memory（Neo4j/Memgraph，付费 tier）做实体关系。

## 记忆管理

CRUD（add/search/get/get_all/update/delete）、categories、metadata、expiration_date、异步处理（add 后等 2-3s 再搜）。

## 评价

- 优点：接入最快、生态最大、自动抽取/去重/更新、托管 + 自托管。
- 缺点：事实型记忆（不保留原始轮次 verbatim）、时间正确性弱（存时间戳但无原生 as-of 查询）、graph 特性在付费 tier。
- 基准（自报）：LongMemEval 94.4%（token-efficient algorithm, mem0.ai/research, 2026）；LoCoMo 从 2025 66.9% → 2026 92.5%。
- 适合：个人化（稳定用户偏好）；不适合：需要原始 episode、点查询历史正确性、关系推理为主的工作负载。
