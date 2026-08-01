# From Storage to Experience: A Survey on the Evolution of LLM Agent Memory Mechanisms

- **arXiv**: 2605.06716 (cs.CL) | 2026-05-07
- **作者**: Jinghao Luo, Yuchen Tian, Chuxue Cao, Ziyang Luo, Hongzhan Lin, Kaixin Li 等（GitHub: FeishuLuo/Evolving-LLM-Agent-Memory-Survey）
- **本地原始资料**: `sources/papers/storage-to-experience-survey-2605.06716.html`（arxiv HTML 全文）

## 核心思想
提出记忆机制演化的三段论框架：**Storage（轨迹保存）→ Reflection（轨迹精炼）→ Experience（轨迹抽象）**。主张记忆演化不是存储容量扩张，而是信息密度提升与认知抽象维度的跨越。调查目标是在"操作系统工程派"与"认知科学派"之间架桥。

## 记忆架构（演化框架）
- **Stage 1 Storage**：以忠实记录交互轨迹为目标——线性存储（原文）、结构化存储（表格/分层/知识图谱）、参数存储。
- **Stage 2 Reflection**：把记忆从被动记录器变为主动批判者，用反馈信号修正/去噪轨迹（quality 提升）。
- **Stage 3 Experience**：跨轨迹抽象，把离散轨迹压缩为可迁移的策略先验。两大机制：
  - **Active Exploration**（主动探索）：记忆驱动 agent 从被动记录者变为目标驱动的经验收集者，分广度/深度/策略三维。
  - **Cross-Trajectory Abstraction**（跨轨迹抽象）：对比归纳、行为 chunking 聚合、行为模式→可复用代码函数封装、轨迹→参数 fine-tuning。抽象粒度分浅（自然语言规则）、中（模块化骨架）、深（模型权重内化为直觉）。

## 创新点
1. 用演化/时间轴视角（Why-How-What）串联 2024→2026 的记忆研究，第一次把 "Experience 阶段" 作为独立研究方向系统化。
2. 明确 reflection 是轨迹内修正、experience 是跨轨迹归纳的区分。
3. 把 fine-tuning / RL / meta-learning 定位为 memory-centric agent 架构内的经验内化手段。

## 局限
- 纯定性分析，无统一基准的量化对比（作者自陈）。
- Experience 阶段 2025 下半年才成形，覆盖有 recency bias，部分论文未过审。
- 与既有 RL/continual learning 范式界限模糊，被作者承认非全新学习范式。

## 对 Memory 设计的意义
给"经验层/技能层"记忆以明确的工程抓手：rules（浅）→ code skeletons（中）→ weights（深）三级抽象粒度，可据此设计 agent 从交互轨迹蒸馏技能的管线。
