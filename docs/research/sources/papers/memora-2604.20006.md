# Memora: From Recall to Forgetting — Benchmarking Long-Term Memory for Personalized Agents

- **arXiv**: 2604.20006 (cs.CL) | 2026-04-21 | ACL 2026 | GitHub: geniesinc/Memora
- **作者**: Md Nayem Uddin, Kumar Shubham, Eduardo Blanco, Chitta Baral, Gengyu Wang
- **本地原始资料**: `sources/papers/memora-2604.20006.html`（arxiv HTML 全文）

## 核心思想
把长期记忆评测从"静态事实检索"升级为"持续演化过程"：要求 agent 在**数周至数月**的用户会话中做记忆巩固（consolidation）与记忆变异（mutation，更新/删除），并提出 **FAMA（Forgetting-Aware Memory Accuracy）** 指标，明确惩罚"依赖已失效记忆"。

## 评测架构
- **构造管线（模拟驱动）**：10 个专业 persona 种子记忆（偏好/活动/目标）→ 逐会话模拟交互并注入偏好漂移、重复活动、长期目标推进 → 转录为高质量多轮对话 → 由记忆轨迹派生出三个任务。
- **三任务**：Remembering、Reasoning、Recommending。
- **压力规模**：Quarterly 设置下每人平均 1991 会话、1171.4 次记忆操作；平均跨会话引用 28.4、变异 14.8（对比 LoCoMo ~1、LongMemEval 0-2）。
- **FAMA**：FAMA = max(0, MPA − λ(1−FAA))，MPA=有效记忆被正确使用的比例，FAA=失效/删除记忆被正确排除的比例，λ 按遗忘项占比动态加权；3 个 LLM judge（GPT-4.1/Claude Haiku 4.5/Gemini 2.5 Flash）多数表决，与人工标注一致率 88.3%。
- **被测**：4 LLM（GPT-5.2、Claude Sonnet 4.5、Gemini 3 Pro、Qwen3-32B，含 reasoning 模式）× 6 记忆 agent（A-Mem、LangMem、Mem-0、MemoBase、MemoryOS、Nemori，统一 GPT-4o-mini 后端）。

## 关键发现
- **推理类任务是普遍最大短板**（记忆 agent 最好仅 27.55，LLM 通常 <14，GPT-5.2 Monthly 甚至 0）。
- 所有系统都频繁复用已失效记忆——FAMA 相比普通 accuracy 大量扣分。
- 记忆 agent 只在 Remembering 占优（119.45 vs LLM 65.6）；Recommending 中 LLM 反超；时间跨度越长性能越差。
- 常规 accuracy 显著高估长期记忆性能。

## 创新点
1. 评测范式从"Do you remember?"转向"Do you know what to forget?"。
2. FAMA 是可复用的"惩罚失效记忆"指标，把 forgetting 提升为评测一等维度。
3. 史无前例的记忆变异压力（14.8 次 mutation vs 既有 0-2）。

## 局限
- 会话由模拟器生成，persona 有限（10 个）。
- LLM-as-judge 依赖三模型投票，成本较高。

## 对 Memory 设计的意义
Memora + FAMA 是 2026 年"遗忘/记忆一致性"评测的最强信号：我们的记忆系统必须能处理频繁更新与删除（版本化 + 失效标记 + 一致性校验），并用 FAMA 类指标自测。
