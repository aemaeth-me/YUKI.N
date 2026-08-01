# Agents (excerpt)

URL: https://huyenchip.com/2025/01/07/agents.html
Author: Chip Huyen
Published: 2025-01-07
Note: 原文约 8000 词，此处保存与 Memory 主题直接相关的原文段落与关键论点。

---

Intelligent agents are considered by many to be the ultimate goal of AI. ... An agent is anything that can perceive its environment and act upon that environment. (Russell & Norvig, AIMA 1995)

An agent is characterized by the environment it operates in and the set of actions it can perform. The set of actions an AI agent can perform is augmented by the tools it has access to. ... RAG systems are agents—text retrievers, image retrievers, and SQL executors are their tools.

Compared to non-agent use cases, agents typically require more powerful models for two reasons:

* **Compound mistakes**: an agent often needs to perform multiple steps to accomplish a task, and the overall accuracy decreases as the number of steps increases. If the model's accuracy is 95% per step, over 10 steps, the accuracy will drop to 60%, and over 100 steps, the accuracy will be only 0.6%.
* **Higher stakes**: with access to tools, agents are capable of performing more impactful tasks, but any failure could have more severe consequences.

### On tool selection (tool loadout / context confusion)

The set of tools an agent has access to is its tool inventory. ... More tools give an agent more capabilities. However, the more tools there are, the more challenging it is to understand and utilize them well.

> An interesting mode of planning failure is caused by errors in reflection. The agent is convinced that it's accomplished a task when it hasn't. For example, you ask the agent to assign 50 people to 30 hotel rooms. The agent might assign only 40 people and insist that the task has been accomplished.

### On planning

To avoid fruitless execution, planning should be decoupled from execution. You ask the agent to first generate a plan, and only after this plan is validated is it executed.

### Conclusion — Memory 的定位

At its core, the concept of an agent is fairly simple. An agent is defined by the environment it operates in and the set of tools it has access to. In an AI-powered agent, the AI model is the brain that leverages its tools and feedback from the environment to plan how best to accomplish a task. Access to tools makes a model vastly more capable, so the agentic pattern is inevitable.

> The agentic pattern often deals with information that exceeds a model's context limit. A memory system that supplements the model's context in handling information can significantly enhance an agent's capabilities. Since this post is already long, I'll explore how a memory system works in a future blog post.
