# Mem-α: Learning Memory Construction via Reinforcement Learning

- **arXiv**: 2509.25911 (cs.CL) | 2025-09-30 | ICLR 2026 | GitHub: wangyu-ustc/Mem-alpha
- **作者**: Yu Wang, Ryuichi Takanobu, Zhiqi Liang, Yuzhen Mao, Yuanzhe Hu, Julian McAuley, Xiaojian Wu（Amazon + UCSD）
- **本地原始资料**: `sources/papers/mem-alpha-2509.25911.html`（arxiv HTML 全文）

## 核心思想
用 RL 训练 agent 驾驭**复杂多组件记忆系统**（core/episodic/semantic），解决"工具复杂但模型不会用"与"简化操作但结构不足"的两难。以端任务（QA 准确率 + 记忆质量）为奖励，让 agent 在试错中发现记忆构造策略。

## 记忆架构
- **三组件记忆**：core（用户核心事实）、episodic（时间性事件）、semantic（抽象知识），各配专用工具。
- **记忆构造 = 顺序决策**：agent 分块处理信息，每块决定调用哪些记忆操作。
- **奖励设计（4 类）**：Correctness（下游 QA 正确性）、Memory Content（记忆内容语义正确性）、Tool Call Format（工具调用格式）、Compression（压缩效率/内存紧凑性）。
- **训练**：GRPO 式 RL；专门构造多轮交互训练集（对话/文档共享/模式识别/讲故事），最大 30k token。

## 创新点
1. 首个在"复杂分层记忆架构"上做端到端 RL 记忆构造的工作（此前 Memory-R1/MEM1 都是简单列表/改写记忆）。
2. **长度泛化**：仅训练 ≤30k token，推广到 >400k token（13x 训练长度）——证明 RL 学到的是记忆管理原则而非过拟合。
3. Qwen3-4B + Mem-α 达 0.642，超过 gpt-4.1-mini 基线，证明 RL 收益主要来自优化而非架构。

## 局限
- 训练成本高（GRPO rollout 长轨迹）。
- 奖励工程复杂（4 类奖励权重需调）。
- 评测偏 QA/长文档，agentic/工具执行场景未充分覆盖。

## 对 Memory 设计的意义
证明"复杂记忆结构 + RL 训练"可让弱模型（4B）超越强模型（gpt-4.1-mini）的记忆管理能力；对需要大规模记忆系统的团队，Mem-α 是"结构表达力"与"可学习性"平衡的参考。
