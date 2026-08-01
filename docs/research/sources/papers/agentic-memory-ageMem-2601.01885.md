# Agentic Memory (AgeMem): Learning Unified Long-Term and Short-Term Memory Management

- **arXiv**: 2601.01885 (cs.CL) | 2026-01-05 | ACL 2026 Long
- **作者**: Yi Yu, Liuyi Yao, Yuexiang Xie, Qingquan Tan, Jiaqi Feng, Yaliang Li, Libing Wu
- **本地原始资料**: `sources/papers/agentic-memory-ageMem-2601.01885.html`（arxiv HTML 全文）

## 核心思想
把长期记忆（LTM）与短期记忆（STM）统一收编进 agent 策略：记忆操作以工具（tool）形式暴露给 LLM 自主决策，并用 **三阶段渐进 RL + step-wise GRPO** 端到端训练，替代此前分离的启发式/辅助控制器。

## 记忆架构（工具化 + RL）
- **工具接口**：LTM——ADD（增）、UPDATE（改）、DELETE（删）；STM——RETRIEVE（取）、SUMMARY（摘要压缩）、FILTER（过滤无关段）。
- **状态建模**：每步状态 s_t = (context C_t, LTM store M_t, task T)；记忆操作成为 action space 的一部分。
- **三阶段课程**：Stage1 建设 LTM（闲聊中学会存什么、何时更新/删）；Stage2 STM 干扰管理（注入 distractor，学会 FILTER/SUMMARY）；Stage3 联合任务（利用两阶段积累完成最终任务）。C_t 在阶段间 reset 防泄漏，M_t 全程保留。
- **step-wise GRPO**：把轨迹终局奖励广播回所有中间记忆决策步，做长程 credit assignment；奖励 = w_task·R_task + w_context·R_context + w_memory·R_memory。

## 创新点
1. 首个统一 LTM+STM 的端到端可学习记忆管理（此前 Memory-R1/Mem-α 等仅管 LTM 或简化结构）。
2. step-wise GRPO 处理"记忆操作导致稀疏/不连续奖励"这一 RL memory agent 的核心难题。
3. 无需外部 expert controller，推理成本可控。

## 实验结果（论文口径）
Qwen2.5-7B 平均 41.96%、Qwen3-4B 54.31%，相对 no-memory +49.59%/+23.52%；较最优基线 Mem0/A-Mem +4.82/+8.57pt；RL 贡献 8.5pt；LTM 质量（MQ）0.533/0.605 最优。

## 局限
- 训练依赖 GRPO 与三阶段轨迹构造，对数据工程要求高。
- 工具操作粒度粗（整条 entry 级），细粒度事实更新仍需研究。
- 评测基准偏 QA/长对话，agentic 环境未充分覆盖。

## 对 Memory 设计的意义
"记忆操作 = 工具 + RL 学习策略"是 2026 公认方向：即使不训练，其工具接口（ADD/UPDATE/DELETE + RETRIEVE/SUMMARY/FILTER）本身就是 memory API 的合理最小集，值得作为我们 memory 模块的默认接口。
