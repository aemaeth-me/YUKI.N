# Claude Agent SDK / Claude Code — Memory

> Source: https://code.claude.com/docs/en/memory, /agent-sdk/subagents, /agent-sdk/session-storage, /agent-sdk/hosting + https://platform.claude.com/docs/en/managed-agents/memory (fetched 2026-08-01)
> 另见平台 cookbook：memory tool (`memory_20250818`)、context editing（compaction `compact_20260112`、tool clearing `clear_tool_uses_20250919`）。

## 哲学：记忆 = 文件系统 + 上下文注入（CLAUDE.md / MEMORY.md）

Claude Code 的跨会话记忆两大机制（每个会话从空 context 开始）：
1. **CLAUDE.md files**：人类写的持久指令（user/project/org 层级，随目录树逐级加载）。加载进 context，被视为 context 而非强制配置。
2. **Auto memory**：Claude 自己在工作中写笔记（build commands、调试洞察、架构决策、风格偏好），存于 `~/.claude/projects/<hash>/memory/`，`MEMORY.md` 作为索引入口，每会话载入前 200 行 / 25KB，超出的移到 topic 文件。

关键点：记忆是 markdown 文件，agent 用 Read/Write/Edit 工具管理自己的记忆目录；加载到 context window 有 token 配额（200 行/25KB）。

## Agent SDK 中的记忆

- **Subagents**：`memory: 'user' | 'project' | 'local'` 参数给 subagent 持久记忆目录（`~/.claude/agent-memory/<agent>/`、`.claude/agent-memory/<agent>/`、`.claude/agent-memory-local/<agent>/`）。启用后 system prompt 包含读写指令 + 载入 MEMORY.md 前 200 行/25KB。属于 auto memory 体系（`CLAUDE_CODE_DISABLE_AUTO_MEMORY` 可关）。
- **Sessions**：会话 transcript 存 JSONL（`~/.claude/projects/<hash>/*.jsonl`），continue/resume/fork；`SessionStore` adapter 镜像到 S3/Redis/Postgres 以跨主机恢复。Session 是对话历史（short-term），不是知识记忆。
- **托管（Managed Agents）memory store**（2026-07 beta `agent-memory-2026-07-22`）：workspace 级文本文档集合，挂载到 session sandbox 的 `/mnt/memory/<slug>/`，agent 用文件工具读写，每会话最多 8 个 store，access read_write/read_only，每条 memory 有不可变版本（`memver_`）用于审计/回滚/redact，store 上限 2000 条。官方明确提示 memory poisoning 风险：对不可信输入用 read_only。

## 平台级 context engineering 三件套（官方 cookbook，2026-03）

| 机制 | 标识符 | 触发 | 做什么 |
| --- | --- | --- | --- |
| Compaction | `compact_20260112` | token 阈值（服务端，min 50K，默认 150K） | 整段 transcript 压缩成摘要（lossy，保留架构决策/未决问题/关键事实） |
| Tool result clearing | `clear_tool_uses_20250919` | token 阈值（默认 100K） | 子转录操作：只替换旧 tool_result 为占位符，可重新获取 |
| Memory tool | `memory_20250818` | 模型主动调用 | client 端实现（view/create/str_replace/insert/delete/rename），把信息移出 context window，跨会话存活 |

官方总结："compaction compresses the whole window when it grows too large, clearing drops stale re-fetchable data inside the window, and memory moves information out of the window so it survives across sessions."

## 结论
Claude 生态把"记忆"当作**agent 自己维护的 markdown 文件 + 上下文注入**（渐进式加载），框架负责会话历史与 context 压缩；无向量/图数据库抽象，检索靠 agent 主动读写文件（关键词）。平台 memory tool 与 Managed Agents memory store 是 2025-2026 新增的一等支持。
