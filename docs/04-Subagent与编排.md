# 04 Subagent 与编排

## 三层模型

```text
主 Agent（主对话的 Run）      聊天、判断、提议派发
  └── 任务 Agent（任务的 Run）  一项持久工作的 Orchestrator
        └── Worker（Subagent Run）  Run 内的临时执行者
```

- **Worker 是临时的**：父 Run 结束（完成/失败/取消）时，其未完成 Worker
  全部被级联取消。需要「比父 Run 活得久」的工作，请派发任务而非 Worker。
- Worker 默认不可再委派（`YUKI_SUBAGENT_DEPTH=1`）。
- Worker 只读记忆：不能写记忆、改人格、发起睡眠。

## Agent 如何使用 Worker

主 Agent 与任务 Agent 都有一族工具：

| 工具 | 用途 |
| --- | --- |
| `sub_agent` | 同步委派：阻塞等待 Worker 的最终答案 |
| `sub_agent_spawn` | 异步派出 Worker，立即返回 agentId |
| `sub_agent_send` | 向运行中的 Worker 注入引导 |
| `sub_agent_status` / `sub_agent_list` | 查询状态与结果 |
| `sub_agent_wait` | 阻塞等待一个/多个 Worker 完成并取回结果 |
| `sub_agent_cancel` | 取消 Worker |

异步 Worker 完成时，父 Run 会收到一条 `[worker ...]` 完成通知（下一轮
自然看到），工作台的 Run 树里也能实时看到每个 Worker 的状态卡。

## 你如何使用 Worker

不需要通过父 Agent。工作台上任何 Worker 状态卡都可以直接：

- **[steer]**：向这个 Worker 注入一句引导（它下一轮收到）。
- **[取消]**：终止这个 Worker。
- **[监控]**：进入它的 Run 监控（状态、交付与变更）。

## 限制

- 单个 Run 同时活跃的异步 Worker 上限：`YUKI_SUBAGENT_MAX_PARALLEL`
  （默认 4）。Agent 超出时会收到明确错误并自行等待重试。
- Worker 的事件不混入父对话流；它的过程产物（文件、artifact）照常计入
  交付与变更台账。
- Worker 不产生持久主体：不出现在任务列表，不形成长期身份。它的经历
  通过 delegationId 关联到派生的那次工具调用，进入这位 Yuki 的长期记忆
  审计链。
