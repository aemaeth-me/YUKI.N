# Where to place agent memory in the prompt to cut token costs up to 2x

URL: https://blog.getzep.com/where-you-put-memory-in-the-prompt-can-cut-your-token-bill-up-to-2x/
Author: Zep blog
Published: 2026-06-24
注：厂商博客，但实验数据可复现，代表了 2026 年 "memory 与 prompt caching 交互" 的核心工程发现。

---

* **Placement is a cost decision.** Agent memory is most useful when it is refreshed every turn, and where you place that fresh context in the prompt strongly affects your token cost.
* **The system prompt is the expensive default.** Because that block changes every turn, it breaks prompt caching: the entire conversation history below it is re-processed at full price on every turn.
* **A trailing message keeps the cache.** After the cache breakpoint, the system prompt and history stay unchanged and read from cache. Only the new messages and one fresh memory block are paid for in full each turn.
* **Up to 2x cheaper.** In an experiment, this one placement change cut total token cost by up to 2x, and the savings grow the longer the conversation runs.

## 原理

- 模型在回复前要 prefill 整个 prompt（system + tools + 全部对话历史）并为每个 token 存 KV cache。对长对话，prefill 是花费的大头，且随历史增长。
- Prompt caching 复用已处理的前缀。一旦模型处理过某前缀，其 KV cache 可保留复用；后续以完全相同 token 开头的请求跳过重复处理。
- Claude Opus 4.8：fresh input $5/M，cache read $0.50/M（-90%），cache write $6.25/M（1.25x，一次性，之后每次便宜读）。
- 关键规则：cache 匹配的是请求前缀，且只到"与上一请求的第一个不同 token"为止。

## 为什么放 system prompt 会打破缓存

System prompt 在请求最前，而 memory Context Block 每轮都要刷新 → 前缀从很靠前的位置就分歧 → 其后全部内容（包括整个对话历史）不再匹配上一次请求，全部按全价重新 prefill。

## 修复：把 Context Block 移到最后一个 message（cache breakpoint 之后）

- 把 memory 附在请求最后的 trailing message（通常是 fake tool-role message 携带 memory）。
- 这样 system prompt、tools、整个对话历史（直到最新 user message）都与上一轮相同 → 整个前缀走 cache；只有上一轮 reply + 新 user message + 一个 fresh Context Block 按全价。
- 实验（Claude Opus 4.8，18/36/54 轮）：总成本分别降 1.3x / 1.6x / 1.9x——up to 2x，且会话越长收益越大。
- Claude Opus 4.8 原生支持 mid-conversation system messages，可在 cache breakpoint 后追加 per-turn 权威上下文而不扰动缓存前缀。

## 对我们的启示

- 若 memory 每轮都要注入 context，"memory 放在哪"是一个 token 经济学决策，而非纯产品决策。
- 稳定性设计：system prompt 保持为不可变前缀；动态 memory 内容放缓存边界之后。
- 这也解释了 Anthropic memory tool（模型主动按需读取文件）的动机：它天然不破坏前缀缓存。
