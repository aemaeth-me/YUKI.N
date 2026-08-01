# MemoryArena: Benchmarking Agent Memory in Interdependent Multi-Session Agentic Tasks

- **arXiv**: 2602.16313 (cs.CL) | 2026-02-18 | ICML 2026 | GitHub/Website: memoryarena.github.io
- **作者**: Zexue He, Yu Wang, Churan Zhi, Yuanzhe Hu, Tzu-Ping Chen, Lang Yin, Ze Chen, Tong Arthur Wu, Siru Ouyang, ... Yejin Choi, Alex Pentland
- **本地原始资料**: `sources/papers/memoryarena-2602.16313.html`（arxiv HTML 全文）

## 核心思想
批评既有评测把"记忆"与"行动"割裂：一类只测 recall（LoCoMo/LongMemEval），一类只测单会话 agent 行动（WebArena/WebShop）。提出 **Memory-Agent-Environment 循环** 的统一评测场：多会话、子任务相互依赖，agent 必须在早期行动中把经验蒸馏进记忆，再用记忆引导后续行动。

## 评测架构
- **四个域**：bundled web shopping（捆绑购物，后项依赖前项型号）、preference-constrained group travel planning、progressive information searching、sequential formal reasoning（数学/物理归纳题）。
- **规模**：766 个任务，平均 6.9 会话、57 个动作步，>40k token 推理轨迹。
- **统一接口**：记忆系统实现 retrieve(q) 与 update(完成子任务后并入) 两个抽象函数；可挂长上下文缓冲/RAG/记忆 agent。
- **基线**：long-context agents、RAG、外部记忆系统在同一设置下评测。

## 关键发现（最震撼的结论）
- **LoCoMo 近饱和的模型，在 MemoryArena 只剩 40-60%**——被动 recall 的优等生是差劲的记忆 agent。
- "Long context ≠ memory" 的实证：长上下文模型在有选择性检索/主动管理需求的任务上系统性落后于专用记忆系统。
- 所有 SOTA 记忆方法完成率低，暴露跨会话维持与再利用潜在任务状态的持久困难。

## 创新点
1. 把记忆评测嵌入完整 agentic 任务，强制"记忆必须被用于决策"（decision-relevant memory use）。
2. 子任务因果依赖设计（后项未说明则无法完成），杜绝用上下文偷懒。
3. 首次系统量化 recall 基准与 agentic 记忆效用之间的鸿沟。

## 局限
- 任务规模（766）相对 LoCoMo（7512）小；人类工人标注成本高。
- 四个域以 Web/规划/推理为主，编码类 agent 未覆盖。

## 对 Memory 设计的意义
最重要的方法论提醒：**记忆系统的验收必须放回真实 agent 任务闭环中测**，recall 分数不能代表记忆效用。建议我们的评测矩阵同时包含 recall 类与 MemoryArena 类（决策耦合）测试。
