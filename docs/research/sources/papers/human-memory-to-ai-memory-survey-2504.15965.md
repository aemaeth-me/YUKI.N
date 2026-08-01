# From Human Memory to AI Memory: A Survey on Memory Mechanisms in the Era of LLMs

- **arXiv**: 2504.15965 (cs.CL) | 2025-04-22
- **作者**: Yaxiong Wu, Sheng Liang, Chen Zhang, Yichao Wang, Yongyue Zhang, Huifeng Guo 等
- **本地原始资料**: `sources/papers/human-memory-to-ai-memory-survey-2504.15965.html`（arxiv HTML 全文）

## 核心思想
以人类记忆为锚点，系统梳理 LLM 驱动 AI 系统的记忆机制。首次建立"人类记忆类型 ↔ AI 记忆"的对应关系（sensory/working/short-term ↔ 个人/系统记忆；explicit/implicit ↔ parametric/non-parametric；short/long-term ↔ 时间维度），并提出 **3D-8Q（object–form–time 三维、八象限）** 记忆分类法。

## 记忆架构（taxonomy）
- **object 维度**：personal memory（个性化） vs system memory（复杂任务求解）。
- **form 维度**：parametric memory（权重内） vs non-parametric memory（外部存储）。
- **time 维度**：short-term vs long-term。
- 八个象限 = 3 个二值维度的笛卡尔组合，每个象限对应明确的功能角色（如 personal+non-parametric+long-term = 个性化长期外部记忆）。

## 创新点
1. 人类认知科学 ↔ LLM 记忆的严格映射（是 2024 年 agent-memory 综述未系统做的）。
2. 八象限框架给"个人记忆 vs 系统记忆"划分了清晰边界——对产品化 agent 的模块划分直接有用。
3. 分别从个性化能力与复杂任务能力两个角度综述 personal memory 与 system memory 的研究。

## 局限
- 发布于 2025 年 4 月，未覆盖 2025 下半年 RL memory agent 与 2026 基准。
- 偏分类学描述，缺乏机制层面的深入比较。

## 对 Memory 设计的意义
object 维度提示：memory 体系应按"个人/用户侧"与"任务/系统侧"物理或逻辑隔离；form 维度提示 parametric 与 non-parametric 是互补而非二选一。
