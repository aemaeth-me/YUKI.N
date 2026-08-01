# LongMemEval-V2: Evaluating Long-Term Agent Memory Toward Experienced Colleagues

- **arXiv**: 2605.12493 (cs.CL) | 2026-05
- **作者**: 未署名作者组
- **本地原始资料**: 搜索结果摘要（无本地 HTML；arxiv.org/html/2605.12493）

## 核心思想
面向**专业 Web 环境**的长期记忆评测：记忆系统应让 agent 成为"经验丰富的同事"——记住界面 affordance、状态动态、工作流与反复出现的失败模式。提出 context-gathering 评测范式（Insert 轨迹 + Query 返回证据），用 451 道人工问题、最多 500 条轨迹 / 1.15 亿 token 的压力环境。

## 评测架构
- **五项记忆能力**：static state recall、dynamic state tracking、workflow knowledge、environment gotchas、premise awareness。
- **两档规模**：Small（100 轨迹 / 25M token，所有问题共享 haystack）、Medium（500 轨迹 / 115M token，按问题定制）。
- **AgentRunbook 基线**：AgentRunbook-R（RAG，三知识池：raw observations/state transition events/strategy notes）；AgentRunbook-C（把轨迹存文件，用 coding agent 在沙箱中收集证据）。
- **接口**：内存系统实现 Insert(trajectory) 与 Query(question)→context 两 API，固定 token 预算下喂给固定 reader LLM。

## 关键结果（论文口径）
AgentRunbook-C 平均准确率 72.5%，超最强 RAG 基线（48.5%）与现成 coding agent（Codex 69.3%）；但 coding-agent 方案延迟高（Codex ~182s/query，为 RAG 6.9x）。

## 创新点
1. 把评测推向"环境经验内化"（workflow/gotchas/状态追踪），远超 recall 类基准。
2. coding agent 作为记忆控制器（文件系统 = 记忆）的新范式。

## 局限
- 面向 Web agent 领域，泛化性待验证。
- coding-agent 基线延迟高，不实用。

## 对 Memory 设计的意义
专业环境 agent 需要"程序性/环境经验"记忆（非仅事实）；文件/代码化记忆（AgentRunbook-C）提示记忆可以用 agent 的既有能力（文件操作、搜索）作为检索引擎，值得借鉴。
