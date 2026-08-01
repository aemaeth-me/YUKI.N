# Zep / Graphiti 时态知识图谱（官方文档与论文，2026-08 抓取）

来源：
- https://www.getzep.com/ （官网）
- https://docs.getzep.com/ （文档）
- https://github.com/getzep/graphiti README
- https://arxiv.org/abs/2501.13956 （Zep 论文，2025-01-20）
- https://www.getzep.com/ai-agents/temporal-knowledge-graph/ （2026-05-31）

## 定位
"Agent memory at enterprise scale"。记忆 = temporal knowledge graph（时态知识图谱，TKG），Zep 称 Context Graph；托管在 governed Context Lake 上，sub-200ms p95 检索。核心开源引擎 Graphiti（Apache 2.0，~20-27K GitHub stars）。

## 记忆模型：Context Graph（时态知识图谱）
- 图 G=(N,E,φ) 三层子图：
  1. **Episode subgraph（情节子图）**：原始输入数据（聊天消息、JSON、文档）作为 ground-truth 流；每个派生事实都有 provenance 追溯到源 episode。
  2. **Semantic entity subgraph（语义实体子图）**：实体节点（从 episode 抽取、与既有实体做 entity resolution）+ 语义边（fact = (实体-谓词-实体) 三元组，超边实现多实体 fact）。
  3. **Community subgraph（社区子图）**：强连通实体簇的聚类 + 高层摘要。
- 关键特征：**bi-temporal（双时态）**。每个 fact 带四个时间戳：
  | 时间戳 | 含义 |
  |---|---|
  | valid from | 现实中何时为真 |
  | valid to | 何时不再为真（若仍为真则为 open）|
  | observed | 源数据何时陈述 |
  | recorded | 系统何时摄取（provenance）|
- 可回答："现在什么是真"、"某历史日期什么是真"、"来自哪里"。
- 本体：prescribed（Pydantic 模型预定义 entity/edge 类型）+ learned（从数据涌现）。自定义实体与边类型。

## 写路径（ingestion / graph construction）
1. 实体抽取：处理当前消息 + 最近 n 条（默认 n=4）作为 NER 上下文；speaker 自动成实体；reflexion 反思技术降低幻觉、提升覆盖率。
2. 实体 embedding（1024 维）+ 全文本搜索找候选节点 → LLM entity resolution（重名合并，更新 name/summary）。
3. fact 抽取 + fact embedding；edge 去重（限定同实体对的边做混合搜索，控制复杂度）。
4. **时态抽取与边失效（edge invalidation）**：用 t_ref 抽绝对/相对时间戳；新边与语义相近既有边用 LLM 比较矛盾，若时间重叠冲突则将旧边 t_invalid = 新边 t_valid（标记失效而非删除）；事务时间线上新信息优先。
5. Cypher 查询写入图（不用 LLM 生成 DB 查询，保证 schema 一致、降低幻觉）。
- 增量式（incremental）：新数据立即整合，无需批量重算。非破坏性（non-lossy），完整保留历史。

## 读路径（retrieval）
混合检索，非 LLM 摘要：
- cosine 语义相似（fact 字段 / entity name / community name）
- BM25 full-text
- BFS 图遍历（breadth-first search）
→ 候选集后重排。定位：token-efficient、prompt-ready 的 context 组装（Context Lake 服务）。
- 更新处理：矛盾信息使旧 fact 失效（validity window 关闭），agent 基于最新状态推理，历史仍可查（Observations：图结构模式/重复/共现分析）。

## 记忆抽象（面向开发者）
- **Episodes**：摄入的原始数据单元（聊天消息/JSON/文本块），按大小消耗 credit。
- **Entities / Facts / Communities**：图中的节点、边、簇摘要。
- **Observations**（Flex Plus+）：跨 fact/summary 之上，从图结构派生的模式/规律（如"Jane 在近三次产品发布两周内都升级"）。
- 治理（Governance at the substrate）：授权、保留、审计在底层实施，贯穿所有图/查询/层；Principal-Resource-Action-Policy。

## 性能/评测
- 官网（2026）：检索 p95 10K图 148ms / 100K 152ms / 1M 156ms / 10M 161ms / 100M 168ms，sub-200ms。
- LoCoMo 94.7% accuracy / 155ms / 5,760 tokens context；LongMemEval 90.2% / 162ms / 4,408 tokens（官网 2026 数字）。
- 论文（2025-01）：DMR 94.8% vs MemGPT 93.4%；LongMemEval 比基线高至多 18.5%，延迟降 90%。
- 对比 GraphRAG（静态文档摘要）与 Graphiti（动态增量时态图谱）：sub-second vs 数秒到数十秒延迟。

## 托管 vs 自托管（2026 状态）
- Graphiti 开源（Apache 2.0）：自托管跑在 Neo4j / FalkorDB 等图库上；无商业编排层。
- Zep Cloud：完全托管，专有 Context Graph Engine（针对"海量小图、多冷图"优化的图运行时，无需第三方图库）。社区版（Community Edition）已弃用。
- 部署模式：Cloud / Cloud+BYOK / BYOC（你的 VPC）。
- 定价（2026，大幅上移）：credit 制（1 credit / 350 bytes 摄入；检索、存储、用户免费）。Free 1000 credits/月；Flex $1,250/年（50,000 credits/月）；Flex Plus $3,750/年（200,000 credits/月）；Enterprise 定制（SLA、SOC 2 Type II、HIPAA BAA、审计日志）。旧的 $25/月档已取消。
- 融资：仅 $500K pre-seed（YC W24，2024-03）——远少于 Mem0/Letta。

## 2025-2026 动态
- 定位从"chat memory"转向"agent memory at enterprise scale / Context Lake"。
- Graphiti 成行业参考实现（20K+ stars，Neo4j/FalkorDB 后端）。
- Zep 提供 Claude Code / Codex 插件（skill + Zep docs MCP server）。
- 官网强调 governance（S&P Global 引用："Zep 正在成为企业 agent 栈这一层的 de facto 伙伴"）。
