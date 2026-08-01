# G-Memory: Tracing Hierarchical Memory for Multi-Agent Systems

- **arXiv**: 2506.07398 (cs.MA) | 2025-06-09 (v2) | NeurIPS 2025 | GitHub: bingreeky/GMemory
- **作者**: Guibin Zhang, Muxin Fu, Guancheng Wan, Miao Yu, Kun Wang, Shuicheng Yan
- **本地原始资料**: `sources/papers/g-memory-2506.07398.html`（arxiv abs 页）

## 核心思想
面向 LLM 多智能体系统（MAS）的层级 agentic 记忆。受组织记忆理论启发，指出现有多智能体记忆 (1) 忽略智能体间细粒度协作轨迹、(2) 缺乏跨 trial 与智能体定制化，遂用三层图结构管理长交互历史。

## 记忆架构（三层图 + 双向遍历）
- **Insight Graph**：从历史经验抽象出的可泛化洞察（高层）。
- **Query Graph**：任务查询的元信息及连接拓扑。
- **Interaction Graph**：智能体间的细粒度文本通信日志（低层）。
- **检索**：双向遍历——由 query graph 向上（query→insight）取高层可迁移知识，向下（query→interaction）取相关的核心协作子图，缓解信息过载。
- **更新/演化**：每次任务执行后，将新协作轨迹吸收进三层图，渐进演化 agent 团队。

## 创新点
1. 首次针对 MAS 提出"洞察/查询/交互"三层图记忆，兼顾跨 trial 泛化与单 trial 细节。
2. 即插即用：不改底层 MAS 框架（AutoGen、AgentVerse 等），注入记忆 cue 即可。
3. 效果显著：embodied action 成功率最高 +20.89%，知识 QA 准确率 +10.12%，跨 5 基准、3 骨干、3 框架。

## 局限
- 面向任务求解型 MAS；协作轨迹捕获依赖多智能体框架的对话记录，格式耦合强。
- 图更新是事后（post-hoc）摘要式，非流式实时。

## 对 Memory 设计的意义
对多智能体/多角色场景给出"分层抽象记忆"范式：洞察层（跨会话可复用策略）+ 查询层（任务关联索引）+ 交互层（原始证据），三层之间有明确的上下行检索路径。
