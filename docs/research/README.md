# Research — Agent Memory 体系设计：领域调查资料库

> 目的：为 YUKI.N 的 Memory 体系设计提供坚实的调研基础，现位于项目 `docs/research/`，
> 与记忆子系统设计（`../memory/`）、认知体系（`../cognition-design.md`）配套。
> 调研日期：2026-08-01。方法：7 组并行调查，全部基于第一手原始资料（arXiv 原文 / 官方文档 / 官方博客 / 规范 / 社区原文）。

## 快速导航

| 入口 | 内容 |
|---|---|
| **[00-综述报告-Agent-Memory-现状.md](00-综述报告-Agent-Memory-现状.md)** | **主报告**：七维度现状 + 收敛共识 + 争议 + 时间线 + 综合设计启示（先读这个） |
| `notes/academic-foundational/` | 学术奠基论文（2023-2025）：MemGPT / Generative Agents / MemoryBank / A-MEM / HippoRAG / Mem0 / CoALA / 综述，12 篇精读 |
| `notes/academic-recent/` | 学术最新（2025-2026）：RL 记忆 / 分层图巩固 / 评测转向 / 可信安全，30 篇 |
| `notes/industry/` | 工业界官方：OpenAI / Anthropic / Google / Microsoft / AWS / Meta / xAI / NVIDIA 对比 + 共识 |
| `notes/frameworks/` | 开发框架：LangMem / LlamaIndex / CrewAI / AutoGen / ADK / AgentCore 等 13 家对比矩阵 |
| `notes/memory-platforms/` | 记忆平台/MaaS：Mem0 / Letta / Zep / Cognee / Basic Memory / Supermemory + 商业化 |
| `notes/benchmarks/` | 评测基准：LoCoMo / LongMemEval / BEAM / MemoryAgentBench / FAMA 等 25 个 + 分层评测建议 |
| `notes/community/` | 社区生态 + 协议标准：MCP（2026-07-28 stateless）/ A2A / 共识与争议 / 趋势研判 |

## 核心结论（30 秒）

1. **分层是唯一共识**：working / 会话内短期 / 跨会话长期 /（可选）图时态层；CoALA 四分类为标准术语。
2. **长期记忆 = LLM 抽取 → 合并演化 → 语义/混合检索**，不存原文；agent 自决读写但必须门控。
3. **长上下文 ≠ 记忆、向量检索 ≠ 记忆、小基准可刷分**——三个已证实的反面结论。
4. **遗忘与更新是一等公民**：知识更新（KU）/矛盾消解（CR）/选择性遗忘（FAMA）是 2025-2026 评测的新焦点。
5. **安全内建**：记忆投毒（OWASP ASI06）、检索门控、写路径校验、审计回滚。

## 目录结构

```
docs/research/                      # 本目录（原 MemDesign/）
├── README.md                        # 本索引
├── 00-综述报告-Agent-Memory-现状.md # 综述主报告
├── notes/                           # 7 份精读分析笔记（各维度 README.md）
│   ├── academic-foundational/  academic-recent/  industry/
│   ├── frameworks/  memory-platforms/  benchmarks/  community/
└── sources/                         # 262 份第一手原始资料
    ├── papers/            # 论文原文（HTML 全文 + txt + 方法摘要 md）
    ├── industry/          # 厂商官方文档/blog
    ├── frameworks/        # 框架官方文档
    ├── memory-platforms/  # 平台官方文档
    ├── benchmarks/        # 基准论文/官方仓库/blog
    └── community/         # 协议规范/官方 blog/社区讨论
```

## 编号核验警示

调研中核实并修正了多个任务清单中的错误 arxiv 编号（详见主报告 §9.3）：
LoCoMo=`2402.17753`、HippoRAG 2=`2502.14802`、Mem0=`2504.19413`、MemVerse=`2512.03627`、MemORAI=`2605.01386`。
引用记忆领域编号前请逐个核验。

## 后续建议

- 阅读顺序：主报告 → 相关维度笔记 → 查原始资料。
- 如需深入某系统（如 Mem0 写路径 / Graphiti 双时态 / Anthropic context engineering），在 `sources/` 对应目录有完整原文。
- 设计决策文档建议落在 YUKI.N 主项目，本资料库作为事实依据持续维护。
