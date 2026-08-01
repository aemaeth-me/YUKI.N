# TrustMem: Learning Trustworthy Memory Consolidation for LLM Agents with Long-Term Memory

- **arXiv**: 2606.25161 (cs.CL) | 2026-06-23
- **作者**: Tianyu Yang, Sudipta Paul, Vijay Srinivasan, Vivek Kulkarni, Srinivas Chappidi（Amazon）
- **本地原始资料**: `sources/papers/trustmem-2606.25161.html`（arxiv HTML 全文）

## 核心思想
聚焦记忆写路径的可信度：记忆 agent 自动生成的 write/revise/delete 更新可能**遗漏重要信息、破坏既有记忆、注入幻觉**，且一旦存储就成为影响未来推理的持久系统态错误。TrustMem 用 **Memory Transition Verifier** 在**迁移级（transition-level）** 评估每次记忆更新，并用偏好排序做 RL，直接优化记忆更新行为。

## 记忆架构（可信巩固框架）
- **Memory Transition Verifier**：冻结 LLM 作为状态迁移评估器，对每个 transition z_t=(chunk c_t, 旧记忆 M_{t-1}, 动作 a_t, 新记忆 M_t) 沿三维打分：
  - coverage（当前 chunk 的重要信息是否被保留）；
  - preservation（旧有效记忆是否未遭无据删除/扭曲）；
  - faithfulness（新增/修改内容是否被 chunk 或旧记忆支撑）。
- **Transition-Ranked GRPO**：在同一记忆状态下对候选更新构造偏好对，替代纯终局奖励，提供细粒度监督。
- **动机**：终局标量奖励对长序列记忆更新无法做精确 credit assignment（错误可能来自早期遗漏、中途覆盖或最终推理瑕疵）。

## 实验结果（论文口径）
- MemoryAgentBench、HaluMem、Mem-α 验证集三处 SOTA；HaluMem 记忆提取 +12.14 F1。
- 迁移级错误：omission 减少 40.1%、corruption 减少 79.1%、hallucination 减少 50.0%。

## 创新点
1. 首次把记忆更新的"可信度"拆成 coverage/preservation/faithfulness 三维并做迁移级监督。
2. 用 verifier + RL 替代"先错误存储后补救"，在错误进入持久状态前拦截。
3. 直接回应记忆一致性（Memora 的 FAMA 暴露的问题）。

## 局限
- Verifier 依赖强 LLM，推理开销随记忆操作频次增加。
- 评估集中在 QA/记忆可靠性任务，agentic 长程执行待验证。

## 对 Memory 设计的意义
**写路径防护**是 2026 记忆研究的重心：任何记忆系统都应内置"写入前的覆盖/保真/忠实校验"（或在写入后审计），TrustMem 的三维 verifier 是一套现成标准。
