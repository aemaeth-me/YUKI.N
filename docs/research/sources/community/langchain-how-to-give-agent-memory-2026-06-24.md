# How To Give Your Agent Memory

URL: https://www.langchain.com/blog/how-to-give-your-agent-memory
Author: LangChain (LangSmith)
Published: 2026-06-24

---

Building a loop so that your agent can learn from previous actions allows you to create delightful agentic experiences that learn with the user. This is often called memory. Memory can be the difference between your users having to constantly repeat corrections instead of the agent remembering how to do something correctly after the first time it is told.

## What is memory?

Memory is durable context that an agent can retrieve across runs to guide its behavior. It may include facts, preferences, past interactions, instructions, skills, examples, and learned patterns.

A trace, transcript, or log is useful evidence of what happened. It becomes memory only when the relevant lesson is converted into context the agent can retrieve on a later run and use to change its behavior.

Two scopes:
- **Short-term memory** is the context available while the agent is doing the task in front of it: the current thread, recent messages, tool results, retrieved documents, intermediate reasoning artifacts, and temporary files or state.
- **Long-term memory** is context that persists beyond the current run: facts, preferences, examples, workflows, policies, instructions, and skills.

The relationship between the two is a read-and-write cycle. As the run unfolds, working memory changes. After the run, the trace gives us evidence of what happened. Most of that evidence should remain history, but some of it may contain useful signal.

A useful taxonomy (borrowed from cognitive science, arXiv:2309.02427):

* **Semantic memory** is what the agent knows: facts, preferences, and general knowledge.
* **Episodic memory** is what the agent has experienced: past interactions, examples, actions, and outcomes.
* **Procedural memory** is how the agent should behave: instructions, workflows, policies, skills, and tool-use rules.

> Many of the most visible improvements in agent behavior come from procedural memory. When an agent repeatedly formats answers incorrectly, calls tools in the wrong order, delegates to the wrong subagent, or ignores a tone rule, the fix is often procedural.

## The memory loop: capture traces, analyze traces, update memory

1. **Capture traces** — the evidence layer (user input, model calls, tool I/O, retrieval, routing, latency, errors, feedback).
2. **Analyze traces** — find signal from feedback/eval failures and recurring patterns. The tricky part is diagnosis; the same symptom can point to different fixes.
3. **Update memory** — decide whether future context needs to change (fix an issue, or remember a preference/example/pattern).

## Design principles for useful memory (from experience)

1. **Not everything should be a memory update.** Most trace data should remain history. Only a small subset should become durable context.
2. **Make sure future runs actually read the update!** If the runtime caches prompts, tools, or skills, memory commits need a refresh path.
3. **Protect important behavior with evals.** If a memory update matters enough to shape future behavior, it is worth having a way to detect regression.
