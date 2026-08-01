# Letta（原 MemGPT）记忆架构（官方文档 docs.letta.com / blog，2026-08 抓取）

来源：
- https://docs.letta.com/ （首页）
- https://docs.letta.com/guides/core-concepts/memory/memory-blocks/ （memory blocks guide）
- https://www.letta.com/blog/memory-blocks/ （2025-05-14）
- https://www.letta.com/blog/sleep-time-compute/ （2025-04-21）
- https://docs.letta.com/guides/core-concepts/stateful-agents/
- https://github.com/letta-ai/letta-code README

## 定位
"The platform for building stateful agents"。Letta agents 从经验中学习、随使用而改进。开源 harness（letta-code，Apache 2.0）。源自 UC Berkeley Sky Computing Lab 的 MemGPT（arXiv 2310.08560）。
2026 转向：Letta Code（model-agnostic agent harness + 持久记忆），memory-first 编程 agent。

## 记忆模型：memory blocks（内存块）
- 记忆块 = agent 上下文窗口中被结构化划分、跨交互持久的区段，始终可见、无需检索。
- 一个 block 包含：label（唯一标识）、description（用途说明，agent 决定如何读写的主要依据）、value（内容字符串）、limit（字符/ token 大小上限）、read_only。
- 核心用例：`human` block（用户记忆）+ `persona` block（agent 自我认知），源自 MemGPT 论文的自编辑记忆演示。
- 多个 agent 可共享同一 block（"shared blocks"）：共享知识库、sleep-time agent 更新主 agent 记忆、协作记忆。
- 块独立持久化于 DB，有 block_id，开发者可直接改 value（整体替换语义，不是 append；并发写 last-write-wins——官方明确警告需要应用逻辑防护）。
- 记忆块可通过 attach/detach 动态授予/撤销访问权限（临时授予敏感信息、按任务切换上下文、RBAC）。

## 记忆层级（三层，均持久化）
- **Core memory（核心记忆）**：由 memory blocks 组成，注入 context window（system prompt），agent 通过 memory tools 自行读写。即"工作记忆/RAM"。
- **Recall memory（回忆记忆）**：对话历史 / 消息，全部存 DB，即使被压缩/驱逐出上下文仍可经 API/工具检索。
- **Archival memory（档案记忆）**：专门保存的长期记忆，agent 用检索工具按需查找（外部存储/磁盘类比）。
→ 心智模型就是 MemGPT 的 OS 虚拟内存分页：main memory（context）↔ external storage。

## 自编辑记忆（self-editing memory）
- agent 拥有编辑自己 memory blocks 的工具（core_memory_replace 等，2026 部分弃用转 filesystem 操作）。
- 状态 = system prompt + memory blocks + messages + tools，全量持久化；LLM 请求时从 DB state 编译 context window（Jinja 模板可定制）。

## Sleep-Time Compute（2025-04，Letta 0.7.0 起）
- 论文 arXiv 2504.13171。让 agent 在空闲期（idle）深度思考、重组织上下文——"agent dreaming / AI that dreams"。
- 实现：创建 agent 时生成两个 agent——primary（对话、工具、检索 recall/archival，但**不**给编辑 core memory 的工具）与 sleep-time agent（负责管理 primary 的 in-context 记忆 + 自己的记忆）。
- 解决原 MemGPT 单 agent 问题：记忆管理与会话解耦（异步、更快更可靠）；增量记忆变脏 → sleep-time 持续重整出干净、简洁、详细记忆。
- 两个 agent 可配不同模型（对话用快模型 gpt-4o-mini，sleep-time 用强模型 gpt-4.1/Sonnet 3.7）；频率可调（token 成本↔记忆质量）。
- 文档分析：后台解析文档并把重要发现写入 primary 记忆（"anytime" 方式，无需等 sleep-time 完成）。
- 2026 演进：睡眠/做梦工作流从 server-side 转向 client-side subagent 系统；research 方向为 memory models（memory-native RL 训练的 token-space 记忆生成/策展模型，2026-06 博客）。

## 2026 重大转向（Letta's Next Phase，2026-03-16 博客）
- 聚焦 Letta Code：open、model-agnostic agent harness，持久记忆内建。
- 记忆从"专用 memory tools 改 DB"→"generalized computer use 工具操作 git-backed 文件"（Context Repositories / MemFS）。
- Context Repositories（2026-02）：git 版记忆——memory blocks、skills、prompts 全部 git 追踪、可版本化、可同步自定义 GitHub 仓库（`.memory-repository set git@...`）。
- 弃用/迁移：server-side 记忆工具（core_memory_replace）、Templates、Identities、server-side MCP、server-side sleep-time agents、硬编码 multi-agent tools → 全部被 client-side subagent / skills / filesystem 取代。
- Research timeline：Sleep-time Compute (2025-04) → Continual Learning in Token Space (2025-12) → Context Repositories (2026-02) → Context Constitution (2026-04) → Memory Models (2026-06)。
- 记忆价值主张：agent 的记忆比底层模型更有价值、可跨模型世代迁移（token-space representations 是多模型系统的粘合剂）。

## 多 agent / 多用户
- shared memory blocks（多 agent 共享）；subagents（general-purpose / forked / recall / history-analyzer）；agent 可调用其他 agent（包括自己）作 subagent。
- 身份/多租户 2026 移向应用层（tags）。

## 托管 vs 自托管（2026-06 状态）
- 开源框架 Apache 2.0，可自托管（App Server / 本地）。
- Letta Cloud：Free（≤3 managed agents，BYOK）、Pro $20/月（≤20 stateful agents + Letta Auto 配额 + 按量超额）、Team/Enterprise 定制（SSO、SLA）。Credit 制（LLM 推理与 CPU 消耗 credit）。2026 重构后原 $200/月 Max 档取消。
- 曾传闻被 OpenAI 洽谈收购（TechCrunch 2025 报道"talks"），未证实/未落地；2026 明确走开放、model-agnostic 路线。

## 性能/评测
- MemGPT 团队创立 DMR（Deep Memory Retrieval）基准；Zep 论文中 DMR 94.8% vs MemGPT 93.4%。
- Letta Code 主打 coding 场景记忆；"doctor" 审计记忆质量、"/palace" 查看记忆、"/sleeptime" 配置周期做梦。
