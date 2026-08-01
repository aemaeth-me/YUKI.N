# MemAgent: Reshaping Long-Context LLM with Multi-Conv RL-based Memory Agent

- **arXiv**: 2507.02259 (cs.CL) | 2025-07-02 | GitHub: BytedTsinghua-SIA/RL-MemoryAgent-14B
- **作者**: Hongli Yu, Tinghong Chen, Jiangtao Feng, Jiangjie Chen, Weinan Dai, Qiying Yu, ... Jingjing Liu, Mingxuan Wang 等（字节 + 清华）
- **本地原始资料**: `sources/papers/memagent-2507.02259.html`（arxiv HTML 全文）

## 核心思想
把长文本处理建模为"读段 + 覆盖式更新记忆"的 agent workflow，用 RL（扩展 DAPO 的 Multi-Conv DAPO）端到端训练模型决定保留什么、丢弃什么。记忆是上下文窗口内固定长度的 token 序列，**覆盖式（overwrite）更新**使其保持恒定大小，端到端复杂度线性 O(N)。

## 记忆架构
- **潜变量记忆 m ∈ V^M**：固定长度 token 序列，位于 context window 内，普通 token，不改架构。
- **读取/写入分解**：每读一个 chunk，模型覆盖旧记忆为总结全部已知证据的新记忆；最终生成阶段只依赖问题 + 记忆。
- **RL 训练**：因记忆是离散潜变量且覆盖式更新，反向传播无法教"该留什么"，Multi-Conv DAPO 把每次 read-write-read 循环当作 RL transition，直接奖励能导致正确最终答案的记忆。

## 实验结果（论文口径）
8K context 训练（32K 文本），外推到 3.5M token QA 任务性能损失 <5%；512K RULER 达 95%+。

## 创新点
1. "恒定内存覆盖式更新" + 线性复杂度，无需架构修改即解锁长度外推。
2. RL 直接塑造"选择性压缩"行为（留 answer-critical 事实，丢 distractor）。

## 局限
- 覆盖式更新必然丢失细节，不适合需要高保真逐字回忆的任务。
- 面向 QA/文档任务；对话个性化与 agentic 工具环境未覆盖。

## 对 Memory 设计的意义
当上下文预算紧张时，"固定长度滚动记忆 + RL 学习压缩策略"是与外部保真存储互补的工作记忆方案；也印证 2026 综述"policy-learned management"家族的实证价值。
