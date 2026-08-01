# MemBench: Towards More Comprehensive Evaluation on the Memory of LLM-based Agents

- **arXiv**: 2506.21605 (cs.CL) | 2025-06-20 | ACL 2025 Findings | GitHub: import-myself/Membench
- **作者**: Haoran Tan, Zeyu Zhang, Chen Ma, Xu Chen, Quanyu Dai, Zhenhua Dong
- **本地原始资料**: `sources/papers/membench-2506.21605.html`（arxiv HTML 全文 / ar5iv）

## 核心思想
针对既有评测"记忆层次单一、交互场景单一、只测有效性"的缺陷，构建**多层次内容 × 多场景 × 多指标**的记忆评测：factual vs reflective 记忆两个层次，participation vs observation 两种交互场景。

## 评测架构
- **双层次内容**：factual memory（事实提取、跨会话推理、知识更新、时间推理）+ reflective memory（反思性摘要）。
- **双场景**：participation（agent 与用户交互）+ observation（agent 作为旁观者记录用户信息）。
- **多指标**：effectiveness（准确率）、recall（召回）、capacity（记忆增长下性能衰减）、temporal efficiency（时间效率）。
- **噪声控制**：用 News 数据注入无关会话制造 100k+ token 的干扰记忆。
- **基线与模型**：7 种记忆机制（FullMemory/RetrievalMemory/RecentMemory/GenerativeAgent/MemoryBank/MemGPT/SCMemory）× 4 模型（Qwen2.5-7B、gpt-4o-mini、Llama-3.1-8B、GLM-4）。

## 关键发现
- 检索型记忆机制在 long-horizon 下容量衰减明显（MemGPT、SCMemory 随 token 增长准确率锐降）。
- 反射性记忆捕获能力普遍弱于事实记忆，且随交互延长更难维持。
- 基底模型选择对记忆性能影响显著。

## 创新点
1. 引入"参与/观察"双视角，区分 agent 主动交互 vs 被动记录的记忆。
2. 把容量（capacity）与时间效率纳入指标——呼应 2026 年"评测须计入成本"的共识。
3. 100k token 规模的噪声记忆压力测试。

## 局限
- 会话数据合成属性强；未覆盖 agentic 工具执行场景。
- 反射性记忆的评测依赖 LLM judge。

## 对 Memory 设计的意义
Capacity 与 temporal efficiency 指标提示我们：记忆系统必须报告"随记忆增长的性能衰减曲线"与"维护成本"，而非只看单点 F1。
