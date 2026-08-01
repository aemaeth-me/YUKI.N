# MemGate: Beyond Similarity — Trustworthy Memory Search for Personal AI Agents

- **arXiv**: 2606.06054 (cs.CL) | 2026-06-04 | GitHub: Kevin-Zh-CS/MemGate
- **作者**: Jiawen Zhang, Kejia Chen, Jiachen Ma, Yangfan Hu, Lipeng He, Yechao Zhang 等
- **本地原始资料**: `sources/papers/memgate-2606.06054.html`（arxiv HTML 全文）

## 核心思想
指出当前记忆管线几乎全由语义相似度驱动，存在**信任边界缺陷**：语义相关但上下文不合适的记忆被注入后，会引发跨域泄漏、谄媚（sycophancy）、工具调用漂移、记忆诱导越狱等威胁。主张从"无条件相似度检索"转向"**任务条件化记忆准入（task-conditioned memory admission）**"。

## 记忆架构（轻量防御插件）
- **MemGate**：9M 参数、35.1MB 的检索时准入层，插在向量记忆库与 backbone LLM 之间，不修改 LLM、不重写记忆库、不调用推理期 LLM judge。
- **机制**：普通语义搜索得到候选集 → MemGate 对每个 query–memory 对预测动态掩码（mask）覆盖记忆表示，衰减与"域错配/过时约束/不安全关联"对应的维度，query 保持为任务锚点。
- **评估对象**：A-Mem、Mem0、MemOS + 真实个人 agent 环境 OpenClaw；跨 GPT-4o-mini、Gemini-3-Pro、Claude-Sonnet-4.6。

## 关键结果（论文口径）
- OpenClaw + GPT-4o-mini：跨域泄漏 27.0%→3.5%，越狱 ASR 16.8%→4.4%；LoCoMo 效用 F1 38.9→40.8（不牺牲记忆效用反而提升）。
- Claude-Sonnet-4.6 上工具漂移从 77.1-91.4% 降至 25.7-28.6%。

## 创新点
1. 首次把"记忆检索=信任边界"形式化，并系统实证记忆诱导的四大威胁类别。
2. 轻量（9M）且非侵入——现成记忆系统可直接挂载。
3. 提供威胁评测范式（PS-Bench 风格 + 记忆诱导越狱模板）。

## 局限
- 门控作用于表示空间，无法完全消除谄媚（基底模型自身 bias 残留）。
- 防恶意写入（memory poisoning）仍需写路径防御（与 TMA-NM/MemTrust 互补）。

## 对 Memory 设计的意义
检索侧必须加"上下文适配性过滤"，不能只做相似度 top-k；MemGate 证明可以极低开销在向量检索与 prompt 组装之间插入安全层。
