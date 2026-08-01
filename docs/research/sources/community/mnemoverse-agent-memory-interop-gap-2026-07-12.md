# The Missing Layer: No Protocol Says What Agents Know

URL: https://mnemoverse.com/docs/library/agent-memory-interop-gap
Author: Edward Izgorodin (Mnemoverse)
Published: 2026-07-12

> 注意：来源为记忆即服务厂商 Mnemoverse 的文档，立场偏向"需要专门的 memory 协议/API"这一论点；但其对 MCP/A2A 不定义 memory 语义的事实性陈述与对标准现状的调查与多方交叉印证。引用时注意立场。

---

**TL;DR**

*   A2A (Agent2Agent) standardizes agent-to-agent work. MCP (Model Context Protocol) standardizes access to tools and external context. Neither defines persistent shared-memory semantics.
*   我们的分解提出 agent memory 互操作性的五项要求：identity and addressing, schema, trust and provenance, consistency, permissions。
*   团队往往通过"把所有 agent 连到同一个共享存储"来绕开协议级交换——存储的记录格式、访问控制和事务模型就成了隐式协议。
*   早期提案只解决部分问题。截至 2026 年 7 月，尚无经批准的 agent memory 互操作标准。

## 核心论点

> 该遗漏源于 A2A 的既定设计：agent 之间协作"无需访问彼此的内部状态、memory 或工具"（A2A 规范）。这对任务交接没问题，但当 agent 需要在任务完成后分享所学时，它就成为一堵墙。

## 五项互操作要求 (作者自己的分解)

| 面 | 需要的协议语义 | 今日规范提供什么 | 实践者临时拼凑什么 |
| --- | --- | --- | --- |
| Identity & addressing | memory 的命名空间/地址/发现 | A2A 命名 agent 与端点，不命名其 memory；MCP 命名 server 与暴露的功能，不命名可移植 memory 空间 | 共享 vector store/数据库/知识图谱的连接串 |
| Schema on the wire | 条目字段、类型、作者、时间、置信度、溯源 | A2A Parts/Artifacts 承载任务输出；MCP Resources 承载上下文。两者都不对持久 "memory" 做类型化 | 框架特定的记录与定制的导入导出格式 |
| Trust & provenance | 来源、完整性、防篡改、是否消费条目的规则 | A2A 传输认证可识别 agent，MCP 授权验证 client↔server。两者都不确立存储知识的可信度 | 几乎没有标准；条目级验证由应用自定义 |
| Consistency | 排序、冲突解决、stale-read 行为、并发写保证 | A2A 与 MCP 都不定义持久共享 memory 的一致性模型 | 单一中心存储，其事务模型成为事实一致性模型 |
| Permissions | memory 空间的读写范围、隔离边界、授权与撤销 | A2A/MCP 授权交互或 API 调用，不授权 memory 空间 | 存储级 ACL、应用检查、或全员共享 |

## 关键引述与调查结论

- OWASP Top 10 for Agentic Applications (2026) 将 **ASI06 "Memory & Context Poisoning"** 列为一类；缓解措施包括 gated writes、provenance tracking、memory segmentation、以及"把存储的 memory 当作不可信输入"。→ 当 agent B 摄入 agent A 的受污染条目时，memory 交换成为跨 agent 攻击路径。
- 论文 "Multi-Agent Memory from a Computer Architecture Perspective" (arXiv:2603.10062)：**"We argue that the most pressing open challenge is multi-agent memory consistency."** 同一论文把 MCP 这类 context-I/O 协议描述为"必要但不充分"。论文 v1 曾说 "The largest conceptual gap is consistency."，v2 删除了该句，仅保留摘要中的 "most pressing open challenge"——作者自己也在收敛论点的强度。
- SAMEP (arXiv:2507.10562)：提出位于 MCP 和 A2A 之外的持久 memory 层，动机是 "ephemeral memory limitations, preventing effective collaboration and knowledge sharing across sessions and agent boundaries"。
- Portable Agent Memory (arXiv:2605.11032)：提出记忆模型 M=(E, S, P, W, I)（Episodic/Semantic/Procedural/Working/Identity）、Merkle-DAG 溯源、capability-based 访问控制。均为 preprint，非标准。
- 其它未标准化提案：memorywire (arXiv:2606.01138)、UMP、WAMP、memcommons v0.1。

## 标准现状 (截至 2026 年 7 月)

> 截至 2026 年 7 月，没有经批准的 agent memory 互操作标准。标准化处于萌芽且碎片化的状态。一个 W3C Community Group "AI Agent Memory Interoperability" (2026-05-18 提议) 存在——但 Community Groups 不在标准轨道上，且它比其名字更窄：由单一厂商发起，其章程将其合规范围限定为该厂商的一个 IETF Independent Submission（无正式地位，将于 2026-11-28 到期），公开邮件列表到 2026 年 7 月仅 5 条消息（4 条来自主席），2026-07-10 共识电话无人记录到他人同意。IETF 没有为 memory 交换成立工作组。Linux Foundation 也没有此类项目（LF 与 Agentic AI Foundation 本身就托管 MCP 与 A2A）。

> 所以开放问题不是 agent 是否需要持久 memory，而是谁将定义让独立系统交换 memory 的 address/record/evidence/consistency/permission 语义。在那之前，每个多 agent 部署都以 ad hoc 方式回答这五个问题——每个 ad hoc 答案都会固化成又一个不兼容的事实标准。

## 引用文献

- A2A specification, MCP 2025-06-18/2025-11-25
- arXiv:2510.01285 (shared memory patterns), arXiv:2507.01701
- OWASP Agentic Security Initiative (genai.owasp.org)
