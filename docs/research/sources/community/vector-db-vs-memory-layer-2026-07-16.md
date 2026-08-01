# Vector Database or Memory Layer: Which One Does Your Agent Actually Need?

URL: https://dreaming.press/posts/vector-database-vs-agent-memory-layer-which-do-you-need.html
Author: dreaming.press
Published: 2026-07-16

---

LanceDB and Chroma give you retrieval. mem0 and Zep give you memory. Teams reach for a memory layer when a vector database would have done — and reach for a raw vector database when they're about to rebuild mem0 by hand. Here's the line between them.

Two teams describe the same symptom — "our agent forgets" — and reach for opposite tools. One adds a vector database and starts dumping conversation turns into it. The other adds mem0 and lets it decide what to keep. Six weeks later the first team has quietly hand-built a fact-extraction pipeline around their vector DB, and the second is fighting an LLM write policy they can't fully see.

## 分层

> LanceDB, Chroma, and Qdrant do one job with precision: store embeddings and metadata, return nearest neighbors, filter by fields... What they store is exactly what you hand them. They will index a contradicting fact right next to the fact it contradicts and rank both, because resolving that isn't their job.

> mem0 and Zep don't replace the vector database — they sit above one and add the intelligence the database deliberately lacks. Hand mem0 a raw conversation and it uses an LLM at write time to pull out atomic facts, then decides whether each one is new, an update to something it already knows, or a contradiction that should overwrite the old value.

**关键论断**：

> The database finds things. The memory layer decides what is worth finding later. That decision is the entire product — and the entire cost.

代价：memory layer 在 write path 跑模型 → 延迟、token 成本、以及"你不完全控制的写策略"。当输入是开放式对话需要变成持久、自纠正、per-user 状态时，这是值得的；当输入是可直接索引的文档时，这是多余的开销。

## 决策

- 我已知要存什么？（文档、chunk、有 schema 的事件）→ vector DB 就是全部答案。
- 输入是开放式对话、必须演化、解决矛盾、按用户隔离？→ memory layer 在做真工作。
- 我是否正围绕裸 vector DB 手写 extraction/dedup/forgetting？→ 你正在重写 mem0。

> Retrieval is a solved primitive with several good implementations. Memory is a policy about that primitive — what to keep, what to merge, what to let go, and whose it is.
