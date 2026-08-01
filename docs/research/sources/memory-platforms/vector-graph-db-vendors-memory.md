# 向量/图数据库厂商的记忆方案（官方源，2026-08 抓取）

## Pinecone：Assistant（RAG 助手）→ Nexus（知识引擎，agent 时代主打）
来源：pinecone.io/blog/pinecone-nexus-public-preview、blog/knowledge-infrastructure-for-agents、product/nexus、docs.pinecone.io/guides/assistant
- **Pinecone Assistant**（2024 产品）：托管 RAG——传文件、自动 chunk/embed/存储，问答带 grounding。测比 OpenAI Assistants 准 12%。局限：静态文档 RAG，无 agent 记忆/更新。
- **Pinecone Nexus**（2025-11 早期访问 → 2026 public preview）：知识引擎（knowledge engine），主张"从 retrieval 到 knowledge compilation"。
  - 概念层级：Knowledge Engine → Context（按团队/角色/工作流策展的 artifact 集合）→ Artifact（typed、governed 的信息对象，为具体任务构造）。Manifest（SME 定义的领域蓝图）指导策展；Tasks（import/curate/search）在隔离 Sandbox 跑；Connectors 摄入 Box/OneLake/Drive/Slack/GitHub 等。
  - **KnowQL**：面向 agent 的声明式查询语言，六个原语：ask / where / shape / ground / confidence / budget。返回 typed + field-level citation 的结构化答案，单次调用。
  - 卖点：30× 更快的任务完成、90%+ 完成率、token 消耗降 90%、编译一次多次查询、SME 掌控知识层抗"knowledge drift"（重新策展即更新）。
  - 部署：BYOC（你的 VPC，数据不出域）。
- 定价动态：新增 Builder tier $20/月、Dedicated Read Nodes（77-97% 规模降本）、数据库原生 full-text。
- 意义：向量库厂商向上走"知识编译"层，与记忆平台的"预提取结构化记忆"是同一思路的不同切法。

## Weaviate：Engram（2025-2026，managed memory service）
来源：weaviate.io/product/engram、Turing Post 2026-05-06 综述
- Engram = 基于 Weaviate 向量库的**托管 agent 记忆服务**：发用户交互/上下文 → 后台自动抽取与管理记忆 → 实时检索。
- 结构化记忆、scopes 做数据隔离（隐私）与上下文共享（编排）、可扩展 properties + composable pipelines（按领域塑形记忆）。
- 典型 pattern：multi-agent systems 的 shared/persistent/scoped memories。
- 意义：向量库厂商在 vector 之上包"自动抽取 + 记忆生命周期管理"层，直接对标 Mem0 类平台。

## Chroma：Context-1（2026-03，agentic search subagent）
来源：trychroma.com/research/context-1、HuggingFace chromadb/context-1、MarkTechPost
- 20B 参数（源自 gpt-oss-20B，MoE）agentic search 模型，SFT+RL（CISPO staged curriculum）训练，Apache 2.0 open weights + 全套合成数据生成管线（context-1-data-gen）。
- 定位：检索 subagent（search subagent），不直接作答，返回排序后的支持文档给下游 frontier reasoning model（decouple search from generation）。
- 关键机制：
  - Query decomposition：把复杂 query 拆子查询，迭代多轮搜索（平均 2.56 tool calls/turn，4x 并行 + RRF 融合）。
  - **Self-editing context**：上下文填满时选择性丢弃无关 passage（prune_chunks，精度 0.94），对抗 context rot；硬 token 预算 + 软阈值注入 + 硬截止。
  - 工具：search_corpus（hybrid sparse+dense）、grep_corpus（regex）、read_document、prune_chunks。
- 性能：接近 frontier LLM 的检索质量，快 10×、便宜 25×。
- 意义：把"检索 = agent 行为"模型化，是 agentic RAG/记忆检索的学术前沿；对记忆体系启示——检索不只是一次 top-k，而是受训的自我编辑上下文循环。

## Neo4j：agent-memory / LLM Knowledge Graph Builder / GraphRAG
来源：github.com/neo4j-labs/agent-memory、neo4j.com/labs/genai-ecosystem/llm-graph-builder、neo4j-graphrag-python docs
- **agent-memory（neo4j-labs）**：graph-native agent 记忆系统，三层记忆：
  - Short-term：会话与消息（per-session，vector + text search）
  - Long-term：实体、偏好、事实 → 知识图谱（POLE+O 模型），entity resolution & dedup
  - Reasoning：推理轨迹与工具使用，:TOUCHED 审计边从推理步骤连到实体
  - 多阶段实体抽取（spaCy/GLiNER/LLM）、关系抽取（GLiREL）、背景富化（Wikipedia/Diffbot）、geospatial、MCP server（16 tools）、多租户（user_identifier）、buffered writes、consolidation.dedupe_entities、eval harness。NAMS 托管服务或自托管 bolt。
- **LLM Knowledge Graph Builder**：把非结构化文档→知识图谱的应用（Document/Chunk 节点 + 嵌入 + SIMILAR kNN 边 + LLM 抽取实体关系；Vector + Text2Cypher + GraphRAG 检索）。由 Neo4j 贡献给 LangChain 的 llm-graph-transformer。
- **GraphRAG（neo4j-graphrag-python）**：SimpleKGPipeline（load→split→embed→LLM extract entities→write）+ retrievers（Vector / VectorCypher / graph 遍历 1-2 hops）。官方声称 GraphRAG 使 agent 更真实（80% 博客标题）。
- 意义：图数据库厂商的记忆方案 = 把 KG 构建管线 + hybrid retrieval（vector+text+Cypher/graph）+ 审计性做成库/托管服务；无时态失效机制（对比 Zep Graphiti），无内置矛盾处理。

## Qdrant：Skills + qcloud-cli（2026-03）
来源：qdrant.tech/blog/qdrant-skills-release/
- 不是记忆平台，而是把 Qdrant 运维/调优知识编码为 agent skills（诊断决策树：何时量化、HNSW/segment/tenant 多租户调优），配 qcloud-cli 让 agent 直接管理集群。
- 意义：DB 厂商把"文档"→"agent 可导航的操作知识"（skills 格式，Claude Code/Cursor/OpenCode 通用），是 2026 DB 生态接入 agent 的典型姿势；多租户实践（tenant_id + is_tenant 索引 + 分片）对记忆体系的多用户隔离有工程参考价值。
