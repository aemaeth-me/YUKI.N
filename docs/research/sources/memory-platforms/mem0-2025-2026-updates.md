# Mem0 2025-2026 动态（融资、OpenMemory、算法演进、生态）

来源：
- TechCrunch 2025-10-28：https://techcrunch.com/2025/10/28/mem0-raises-24m-from-yc-peak-xv-and-basis-set-to-build-the-memory-layer-for-ai-apps/
- PRNewswire 2025-10-28：https://www.prnewswire.com/news-releases/mem0-raises-24m-series-a-to-build-memory-layer-for-ai-agents-302597157.html
- mem0.ai/series-a
- mem0.ai/blog/introducing-openmemory-mcp
- arXiv 2504.19413（2025-04）Mem0 论文
- GitHub mem0ai/mem0 README（2026 状态）

## 融资
- 2025-10-28 公布 $24M（此前未公开的 $3.9M seed + $20M Series A）。
- Seed 由 Kindred Ventures 领投；Series A 由 Basis Set Ventures 领投，Peak XV Partners、GitHub Fund、Y Combinator 参与。
- 天使：Scott Belsky、Dharmesh Shah、Datadog CEO Olivier Pomel、Supabase CEO Paul Copplestone、PostHog CEO James Hawkins、ex-GitHub CEO Thomas Dohmke、Weights & Biases CEO Lukas Biewald。
- 愿景："Every agentic application needs memory, just as every application needs a database"；"Plaid for memory / memory passport"（记忆跨应用随用户流动）。
- 数据点（2025-10）：41,000+ GitHub stars、14M+ Python 下载、80,000+ 云端开发者、API 调用 Q1 35M → Q3 186M（~30%/月增长）。

## 生态位置
- AWS Agent SDK 的独家 memory provider（官方背书）。
- CrewAI、Flowise、Langflow 原生集成；22 个框架集成（LangChain、LlamaIndex、Vercel AI SDK 等）。
- 编程 agent 插件：Claude Code、Cursor、Codex、Windsurf、OpenCode、OpenClaw 的 skills/MCP 插件。
- 与 OpenAI Memory、LangMem、MemGPT 的官方对比博客（2026-07-29）："OpenAI Memory vs LangMem vs MemGPT vs Mem0"。Mem0 主张最佳 accuracy-vs-speed-vs-cost 平衡。

## OpenMemory（2025-2026 战略动作）
- "OpenMemory MCP" 博客：本地优先（local-first）记忆基础设施，跨任何 AI 应用携带记忆。
- OpenMemory MCP Server：私有本地记忆层 + 内置 UI，兼容所有 MCP 客户端（Cursor↔Claude↔Windsurf 上下文互通），数据全在本地、完全自控。这是 Mem0 的消费者/开发者侧打法（对标 ChatGPT Memory 的开放替代）。

## 算法/架构演进（2026-04 "New Memory Algorithm"）
- 旧：UPDATE/DELETE 类、增量记忆更新、易碎片化。
- 新：Single-pass ADD-only extraction（一次 LLM 调用，无 UPDATE/DELETE，记忆累加不覆盖）；agent-generated facts first-class；entity linking（实体跨记忆链接、检索加分）；multi-signal retrieval（semantic + BM25 + entity 并行融合）；temporal reasoning（时间感知排序）。
- 论文（arXiv 2504.19413）：Mem0 与 Mem0^g（graph memory 变体，实体为节点、关系为有向标签边）在 LoCoMo 上对比 6 类基线；Mem0^g 在 temporal/open-domain 更强；对比 full-context 减 91% p95 延迟、省 90%+ token。
- 2026-07 工程博客：Reasoning Tokens and Memory: 8x Cost Reduction Test；How We Cut Vector Search Latency by 70x。

## 商业化
- 托管平台（app.mem0.ai）用量计费；自托管免费（Apache 2.0）。
- SOC 2 Type 1、HIPAA、BYOK、zero-trust；Kubernetes/私有云/air-gapped 同 API。企业版卖"governance/portability/auditability"。
