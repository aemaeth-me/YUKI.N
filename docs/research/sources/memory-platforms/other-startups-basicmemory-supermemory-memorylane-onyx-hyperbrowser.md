# 其它记忆创业公司：Basic Memory、Supermemory、MemoryLane、Onyx、Hyperbrowser（官方源，2026-08 抓取）

## Basic Memory（basicmemory.com / github.com/basicmachines-co/basic-memory）
来源：GitHub README、docs.basicmemory.com、MCP 目录
- 定位：local-first、MCP-native 的记忆/知识管理。知识以 Markdown 文件存在本地磁盘，人类与 AI 双向读写同一批文件（two-way）。
- 记忆模型：**document-based（markdown + wikilinks + frontmatter + observations）**。结构化 Markdown 文件 + 本地 SQLite 索引；wikilink/relation 形成可遍历知识图；FastEmbed 语义向量 + 全文混合检索（可选 cross-encoder 重排）。
- MCP 工具：write_note/read_note/edit_note/move_note/delete_note、search_notes/recent_activity、build_context（memory:// 图遍历）、schema_infer/validate/diff。工具带行为提示（read-only/destructive/idempotent）。
- 写路径：agent 决定写什么（无自动抽取管线），人类/agent 共写同一文件系统；编辑 = 文件操作。简单、透明、可 git 版本化。
- 更新：覆盖/追加式文件编辑，无矛盾处理（文档制，自然如此）。
- 托管：本地运行（uvx basic-memory mcp）；可选 Basic Memory Cloud（Tigris S3 托管 + 同步 + 手机端），无锁定（随时导出 Markdown）。
- 许可证：AGPL-3.0（注意 copyleft）。与 Obsidian 互通。
- 风险/坑：AGPL；工具可删除/覆盖笔记（需限定专用目录）；无自动抽取，记忆质量依赖 agent 自觉。

## Supermemory（supermemory.ai / github.com/supermemoryai/supermemory）
来源：官网、GitHub README、TechCrunch 2025-10-06、Susa Ventures 投资博客、官方 blog
- 定位："The memory layer for AI agents / context engineering platform"。从"第二大脑"消费应用（50K+ 用户、10K GitHub stars）转为记忆引擎公司。
- 融资：$2.6-3M pre-seed（2025-10），Susa Ventures、Browder Capital、SF1.vc 领投；天使含 Cloudflare CTO Dane Knecht、Google AI 主管 Jeff Dean、DeepMind 产品经理 Logan Kilpatrick、Sentry 创始人 David Cramer 等。
- 记忆模型：Memory Graph（自研 vector graph engine + ontology-aware edges）、User Profiles（自动维护的用户上下文，一次调用 ~50ms）、Hybrid Search（RAG + memory 单查询）、多模态抽取器（PDF/图片 OCR/视频转写/代码 AST-aware chunking）、连接器（Drive/Gmail/Notion/OneDrive/GitHub 实时 webhook）。
- 评测主张：LongMemEval 95% Recall@15，加 ~720 token 上下文（比基线 -99.4% token）；自称 #1 on LongMemEval / LoCoMo / ConvoMem。
- 2026 动态：SMFS（Supermemory Filesystem，面向 agent 的文件系统，让 agentic retrieval 更便宜/准）；Dynamic Dreaming（类似 Letta sleep-time，自动后台压缩/反思）。插件：Claude Code、OpenCode、OpenClaw、Hermes。可完全本地（Ollama + 本地 embedding，离线下）。创始人 19 岁、曾在 Cloudflare/Mem0。

## MemoryLane（多个同名项目）
- memorylanehq.com：称 "The universal memory layer for AI"（2026 网站，产品信息少）。
- jMyles/memory-lane（HN 46100402）：Claude Code JSONL 会话归档系统——watcher 监视 Claude 日志、存 PostgreSQL（eras / context heaps / messages / compacting actions），Django 前端 + MCP server（bootstrap_memory/get_recent_work/search_messages/random_messages）。本质是"会话档案"而非语义记忆。为 magent 项目开发。
- 结论：MemoryLane 是一个分散的命名空间（多个小项目、早期、无统一品牌），不是主流的记忆平台——列为边缘信号。

## Onyx（onyx.app，原 Danswer）——企业搜索 + agent，附带 memory 工具
来源：TechCrunch 2025-03-12、onyx.app/blog/seed-round、GitHub PR #7547/#8331
- 定位：开源企业搜索/知识 agent（40+ 数据源连接器），非记忆平台，但 2025-2026 加入了 memory 工具层。
- 融资：$10M seed（2025-03），Khosla Ventures + First Round Capital 领投。客户：Netflix、Ramp、Thales；UCSD 3.7 万用户。
- Memory 机制（2025-2026 开发中）：MemoryTool（add_memory，LLM 决定何时写/改记忆）→ process_memory_update（secondary LLM 流决定 add vs update）→ DB add_memory/update_memory_at_index（per-user cap 10 条、最旧淘汰）。use_memories（注入 system prompt 的开关）与 enable_memory_tool（是否允许 agent 写）解耦。
- 注意："GitHub 内部 Onyx"与这家 onyx.app 不是一回事；用户提到的 Onyx 可能是混淆，此处记录开源 Onyx 的真实 memory 实现细节（agent 自主写、小容量 cap、注入/写入解耦）作为参考模式。

## Hyperbrowser（hyperbrowser.ai / github.com/hyperbrowserai）——浏览器基础设施，非记忆平台
来源：GitHub org、HyperAgent README、browserbrain 示例
- 定位：AI 浏览/抓取/headless browser 基础设施（scraping infra + sandboxes + persistent volumes + agents layer）。对记忆体系的意义：提供"浏览器记忆"（persistent volume）与 BrowserBrain 示例（截图 + gpt-5.5 视觉理解 → 每域名一份结构化记忆 → 二次访问直接 recall，无需 vision call）。
- 不构成独立记忆平台，但代表"记忆 = 结构化持久卷 + recall-or-learn 缓存"的工程模式。
