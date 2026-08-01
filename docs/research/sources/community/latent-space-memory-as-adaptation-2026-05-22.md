# Memory as Adaptation

URL: https://jaesolshin.com/posts/memory-as-adaptation/
Author: Jaesol Shin (Latent Space 频道文章)
Published: 2026-05-22

---

The surge of interest in memory this year traces to a single shift: agents moved from single-turn question-answering systems to long-running closed-loop systems. In single-turn interactions, model weights and a context window seemed sufficient. But working across sessions, iteratively reducing failures, and maintaining state for a user or project runs into the limits of the context window quickly.

> 近期 agent memory 综述指出：单个 context window 已经放不下 "what has happened, what was learned, and what should not be repeated"；并定义 memory 为"把无状态文本生成器变成自适应 agent"的核心能力。
> 因为这一转变，memory 不再是简单的 RAG 存储——它已成为一个状态管理层，agent 通过它在部分可观测环境中维持其 belief state 与 action history。

## 记忆类型为何再度重要

> Initially, semantic memory seemed like the natural solution. Putting facts, documents, user preferences, and code snippets into a vector database and retrieving them appeared to address the long-term memory problem adequately. But in long-running agents, "what has happened," "where did we fail," and "what procedure should we follow next" matter as much as "what does the agent know." Semantic memory alone proved insufficient.

- **Working memory**：维护当前任务的活跃状态。不是简单缓冲最近几轮对话，而是把"正在做什么、看过哪些文件、哪些测试失败、哪些假设仍有效"压缩进有限 context。编码 agent 中它被当作"维持当前修复轨迹、运行时状态、工具输出、失败测试记录"的机制。Code as Agent Harness 把 memory 视为决定"哪些留在活跃上下文、哪些压成摘要、哪些下放到持久存储"的状态管理层。
- **Episodic memory**：agent 的成败以事件形式积累。"用户偏好 PostgreSQL"是语义事实；"上次部署跳过了 migration 导致宕机，用 Redis cache 修复"是 episode。长周期工作中后者往往价值更大。Episodes 把时间、上下文、行动、结果、失败原因保存在一起。
- **Procedural memory**：经验开始以技能而非知识形式积累。反复解决同一类问题，更高效的方式是把成功的流程存为可调用 skill（Voyager 为代表——把经验积累为可复用的行为单元）。Procedural memory 存的是 "how the agent acts"。

## 为什么 memory 层会增殖：自改进离不开记忆

> Self-improvement is not simply correcting the next output after observing a current failure — it is changing prompts, code, procedures, verification loops, and skills so that the failure does not recur. To do that, the agent must remember which failures have repeated, which modifications had effect, which procedures reduced cost, and which validators were weak.

（Anthropic Managed Agents 中的 "dreaming"：周期性回顾 past sessions 与 memory stores 以保留重要模式——记忆在会话之间组织、并纳入未来工作的信号。）

## 控制论视角

> Working memory maps to the fast control loop; episodic memory to the event-driven diagnostic loop; semantic memory to the knowledge retrieval loop; procedural memory to the reusable action loop.

## 结论

> Ultimately, the surge of interest in memory this year is not only because agents have more to remember. More precisely, it is because agents have more to adapt to... Memory is no longer a subsystem of RAG — it is the core state layer that allows the policy space of weights, prompts, and code to move stably through time.
