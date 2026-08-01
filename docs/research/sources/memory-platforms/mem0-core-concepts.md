# Mem0 核心概念（来自官方文档 mem0.ai / docs.mem0.ai，2026-08 抓取）

来源：
- https://mem0.ai/ （官网首页）
- https://docs.mem0.ai/ （文档首页）
- https://docs.mem0.ai/core-concepts/how-it-works
- https://docs.mem0.ai/platform/advanced-memory-operations
- GitHub mem0ai/mem0（docs/core-concepts/memory-operations/add.mdx、memory-evaluation.mdx、api-reference）

## 定位
"AI Memory Layer for your Agents & Apps | Persistent Context"。Drop-in memory infrastructure，三行代码接入。
与 2024 年早期（"smart memory for LLM"）相比，2026 年主页强调：Memory Compression Engine（自动把聊天历史压缩成紧凑记忆）、减少冗余上下文、降低 token 成本。

## 记忆模型
- 结构化记录（memory = 一条条事实/偏好/决策文本 + metadata + categories），不是原样对话转写。
- 存储是混合的多 store 架构：
  | Store | 用途 |
  |---|---|
  | SQL 数据库 | Facts 与 metadata，真源 |
  | Vector 数据库 | 嵌入，语义检索 |
  | Entity/graph store | 实体与关系（启用 graph memory 时）|
- 默认 `infer=True`：add 时 LLM 抽取结构化记忆；`infer=False` 存储原始内容（会引入重复）。
- 记忆可带 categories、metadata（任意 key-value）、expiration_date、时间戳。
- 作用域标识符：user_id / agent_id / app_id / run_id / session，用于隔离多用户多 agent。

## 写路径（Extraction，两阶段之一）
`add(messages, user_id=..., ...)` 触发：
1. Context lookup：先查相关既有记忆，避免重复存储
2. Fact extraction：LLM 抽取偏好、决策、计划等可复用事实
3. Deduplication + embedding：去重后逐条嵌入
4. Entity linking（可配置）：跨记忆链接人/地/组织/概念

关键点（2026-04 新算法）："Single-pass ADD-only extraction"，一次 LLM 调用、不覆盖旧记忆（additive）。新事实与旧事实冲突时保留两者，靠显式 update/delete 纠正。agent 生成的事实（agent 确认的动作）与用户事实同权存储。

Platform 上 add 自动拉取同 user_id/run_id 的历史消息作为抽取上下文（无需重发对话历史）。v3 API 异步处理（先返回 queued ADD 事件，轮询 status）。

## 读/检索路径（Retrieval）
`search(query, filters, top_k, rerank, threshold)` 多信号融合排序：
| 信号 | 机制 | 适用 |
|---|---|---|
| Semantic | 向量相似度 | 概念类问题 |
| Keyword | BM25 词项匹配 | 名字/ID/事实查找 |
| Entity | 提升与 query 中实体相连的记忆 | 关于人/项目/账号的问题 |
| Temporal | 写入时提取的时间元数据 vs query 时间意图 | "何时/当前状态/新旧" |

Platform 为多信号融合；OSS 依赖所配向量库 + 可选 reranker + 图库。
score 为 v3 的合并多信号相关度（0-1 区间）。

## 更新与遗忘
- update(memory_id, text, metadata, timestamp, expiration_date)：覆盖内容/元数据/到期时间；batch_update 一次最多 1000 条（Platform）。
- delete / delete_all(user_id, app_id)。
- expiration_date：到期记忆默认从 search/get_all 隐藏（fetch by id 仍可见），可用 show_expired 取回。
- immutable 记忆只能删了重建。
- Feedback 机制：up/down 反馈可自动化纠正（self-heal）。
- 自动提取路径是纯累加，"I moved from Austin to Seattle" 不会静默改写旧记忆——需要显式 update/delete。这意味着**矛盾处理由应用层负责**。

## 多用户/多 agent
- user_id/agent_id/app_id/run_id 隔离；AND 同用 user_id+agent_id 会空结果（已知坑，需 OR）。

## 托管 vs 自托管
三档：Library（pip install mem0ai）→ Self-Hosted Server（docker compose，dashboard、per-user API keys、审计日志）→ Cloud Platform（app.mem0.ai，托管 stores）。
OSS 可替换 SQL/vector/graph store（支持 20+ 向量库）。Platform 含私有优化（benchmark 分数高于 OSS）。

## 评测（官方 memory-evaluation.mdx）
新的 token-efficient 算法（2026-04）：
| Benchmark | 旧 | 新 | tokens/query |
|---|---|---|---|
| LoCoMo | 71.4 | 91.6→92.5 | ~6,956 |
| LongMemEval | 67.8 | 93.4→94.4 | ~6,787 |
| BEAM (1M) | — | 64.1 | ~6,719 |
| BEAM (10M) | — | 48.6 | ~6,914 |

- BEAM（github mem0ai/memory-benchmarks）是 Mem0 自建基准，1M/10M token 规模，10 类任务；强调"小基准可被暴力检索刷分"，10M 才是真实考验。10M 下 temporal_reasoning(16.3)/event_ordering(20.2)/multi_session(26.1) 弱——官方承认是开放问题。
- 基准强调同时报告 token 预算（cost）与准确率，反对只报分数。

## 官方 API 参考（mem0-plugin skills 文件）
- POST /v3/memories/add/ （异步、ADD-only）
- POST /v3/memories/search/
- POST /v3/memories/ （get all）
- GET /v1/memories/{id}/
- PUT /v1/memories/{id}/ （update）
- DELETE /v1/memories/{id}/
- DELETE /v1/memories/?user_id=&app_id= （delete all）
- GET /v1/event/{id}/ （异步状态）
- metadata 过滤仅支持 top-level key，操作符 eq/contains/ne。
