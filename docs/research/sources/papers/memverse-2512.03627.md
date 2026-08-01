# MemVerse: Multimodal Memory for Lifelong Learning Agents

- **arXiv**: 2512.03627 (cs.AI) | 2025-12-02 | GitHub: KnowledgeXLab/MemVerse
- **作者**: Junming Liu, Yifei Sun, Weihua Cheng, Haodong Lei, Yirong Chen, Licheng Wen 等（华为系）
- **本地原始资料**: `sources/papers/memverse-2512.03627.html`（arxiv HTML 全文）

## 核心思想
模型无关、即插即用的多模态记忆框架。以 **互补学习系统（Complementary Learning Systems, CLS）** 理论为纲：慢路径（hierarchical multimodal knowledge graph, MMKG）负责结构化的长时记忆；快路径（轻量参数记忆模型）提供低延迟、可微的回忆。用 memory orchestrator 做两条路径的置信度路由。

## 记忆架构
- **Short-term memory**：滑动窗口缓存近期交互状态，避免冗余检索。
- **Long-term memory（MMKG 分层图）**：raw 对话先由 LLM 压缩成 salient memory descriptions，再结构化为三类子图——
  - core memory（跨会话持久的用户事实）；
  - episodic memory（带时间戳、上下文依赖的交互）；
  - semantic memory（跨用户可泛化的抽象知识）。
  按"用户身份依赖性 / 时间范围 / 抽象度"路由到相应子图。
- **Parametric memory**：轻量 LM，周期性对 LTM 内容做 supervised fine-tuning（periodic distillation），模拟检索行为、缓解 RAG 推理开销，与显式图记忆协同演化。
- **Memory orchestrator**：管理 add/update/retrieve/consolidate/delete，依据置信度在快慢路径间路由，显式刻画 speed–accuracy 权衡，无需学习参数。

## 创新点
1. 第一次把 parametric distillation + graph retrieval 做成统一多模态记忆框架，且是 CLS 理论（海马体≈图检索、新皮层≈参数压缩）的直接实例化。
2. periodic distillation 让"快回忆"可微、可插拔、不侵入问答 LLM。
3. 无学习参数的路由器（confidence-based），透明可控。

## 实验结果（论文口径）
LoCoMo F1 43.44（GPT-4o-mini）、60.00（GPT-3.5-Turbo-16k）；ScienceQA 84.48%；MSR-VTT R@1 90.4%。

## 局限
- 依赖强 LLM（GPT-4o-mini）做图构建与检索，工程成本高。
- 蒸馏是定期全量式 SFT，未见对新增知识的增量/在线更新机制细节。
- 评估基准多偏 QA/检索，agentic 决策型记忆（MemoryArena 类）未测。

## 对 Memory 设计的意义
CLS 双路径 + orchestrator 路由是一个可直接借鉴的架构模板：图检索管"精确关联"，参数蒸馏管"快速直觉"，中间用可配置的置信度门控。
