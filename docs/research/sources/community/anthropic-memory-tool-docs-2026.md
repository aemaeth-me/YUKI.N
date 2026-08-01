# Memory tool — Claude Platform Docs

URL: https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool
Author: Anthropic
Status: 2026（memory_20250818，GA）

---

The memory tool lets Claude store and retrieve information across conversations in a directory of memory files. Claude can create, read, update, and delete files that persist between sessions, building up knowledge over time without keeping everything in the context window.

> Memory supports just-in-time context retrieval. Rather than loading all relevant information up front, an agent records what it learns in memory files and reads them back on demand. This keeps the active context focused on the current task.

The memory tool operates client-side: Claude requests file operations, and your application executes them. You control where and how the data is stored through your own infrastructure.

## 用法

- 在 requests 的 tools 中加入 `{"type": "memory_20250818", "name": "memory"}`，不定义 input schema。
- 实现 client-side handler 处理 commands：`view`, `create`, `str_replace`, `insert`, `delete`, `rename`。
- `/memories` 是路径前缀，handler 映射到你的真实存储（per-user 目录或数据库 key）。Memory 完全存在你的应用中。
- 安全：必须做 path traversal 防护（校验所有路径以 `/memories` 开头、canonicalize、拒绝 `../` 等）。

## 关键设计

- Claude 在开始任务前会自动检查 memory 目录；工作中把学到的写入 `/memories` 下文件，后续会话读回继续工作。
- 模型自己驱动记忆写入（tool call），实现 "just-in-time" 检索。
- 官方建议的长期 agent 模式：initializer session 建文件（progress log / feature checklist）→ 后续 session 打开先读 → session 结束更新 progress log。
- 与 context editing（tool-result clearing）和 server-side compaction 配合：compaction 让活动上下文保持小，memory 保存必须活过摘要的信息。

## 关于 Compaction（同来源 cookbook: platform.claude.com/cookbook/tool-use-context-engineering-context-engineering-tools）

- Compaction：接近 context window 上限时服务端摘要，全转录操作，lossy by design。
- Tool-result clearing：子转录操作，把可重取的 `tool_result` 替换为占位符（`clear_tool_uses_20250919`）。
- Memory：把信息移出窗口以跨会话存活（结构化笔记）。
- 三者映射：compaction 压缩整体窗口、clearing 丢弃窗口内 stale 可重取数据、memory 把信息移出窗口跨会话存活。
