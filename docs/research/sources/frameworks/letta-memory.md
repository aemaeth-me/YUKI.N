# Letta (formerly MemGPT) — Memory

> Source: https://docs.letta.com/guides/core-concepts/memory/memory-blocks/ + /guides/core-concepts/stateful-agents/ + /configuration/memory (fetched 2026-08-01)
> 另见：MemGPT 论文 "MemGPT: Towards LLMs as Operating Systems"（Packer et al. 2023）。

## 哲学：记忆 = 操作系统（RAM/磁盘分页）

MemGPT 把 LLM 类比 OS：有界 context window = RAM，外部存储 = 磁盘，agent 用工具在两者间"分页"信息。Letta 是其生产化实现，是**完整的 agent runtime**（REST API + 自己的开发环境），而非 bolt-on memory API。

## 三层记忆（tiered memory）

1. **Core memory（memory blocks）**：context window 内结构化区块，所有交互中始终可见，无需检索。Block = `label` + `description` + `value` + `limit`（字符数）。agent 用内置 memory tools 自主读写。常用 `persona`（agent 人设）与 `human`（用户记忆）两个 block。
2. **Recall memory**：可搜索的完整对话历史（context 之外，类似磁盘缓存）。所有消息持久化在 DB，即使被压缩/逐出仍可检索。
3. **Archival memory**：冷存储，agent 通过工具查询（向量支撑）。

## 关键机制

- **Agent-managed**：agent 自己决定把什么提升进 context、逐出什么（调用 memory-edit 工具），而不是框架决定。
- **Shared memory blocks**：同一 block 可 attach 到多个 agent，一处更新处处可见（多 agent 共享记忆）。
- **Read-only blocks**：`read_only: true` 禁止 agent 修改。
- **Attach/detach**：动态控制 agent 可访问信息，临时授予/撤销敏感信息访问。
- **Sleep-time compute（dreaming）**：后台 subagents 审查近期对话，整合经验写回记忆（不阻塞实时响应）。CLI `/sleeptime` 配置，可运行于 N 条用户消息后或 context 压缩时。
- **MemFS（2026 新版）**：git-backed 记忆文件系统，agent 可查看/编辑，`/init`、`/doctor`、`/remember` 管理。记忆跨会话共享并随学习提升。
- **Stateful agents**：所有状态（记忆、用户消息、推理、工具调用）持久化在 DB，永不丢失（即使被逐出 context window）。

## 评价维度

- 写路径成本：低（DB write + tool call）；读路径：低（工具调用，无 LLM in core path）。
- 无原生 bi-temporal（与 Zep 对比）。
- 多租户：per-agent state（built-in）。
- 采用成本高：要求采用 Letta 的 agent 模型；LangGraph/Claude Agent SDK 用户迁移成本高。
- 基准：LongMemEval ~83%（社区报告）。
- 适合：长运行、自学习、自管理记忆的状态型 agent；不适合无状态/短命 agent。
