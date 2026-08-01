# Managing context on the Claude Developer Platform | Anthropic

Source: https://www.anthropic.com/news/context-management
Published: September 29, 2025

## Summary

Introducing context editing and the memory tool to help developers build more effective agents that handle long-running tasks. With Claude Sonnet 4.5, these capabilities enable developers to build agents capable of handling long-running tasks at higher performance and without hitting context limits or losing critical information.

## Context editing

Automatically clears stale tool calls and results from within the context window when approaching token limits. As the agent accumulates tool results, context editing removes stale content while preserving the conversation flow, effectively extending how long agents can run without manual intervention. Also increases effective model performance as Claude focuses only on relevant context.

## Memory tool

Enables Claude to store and consult information outside the context window through a file-based system. Claude can create, read, update, and delete files in a dedicated memory directory stored in your infrastructure that persists across conversations. This allows agents to:
- Build up knowledge bases over time
- Maintain project state across sessions
- Reference previous learnings without keeping everything in context

The memory tool operates entirely client-side through tool calls. Developers manage the storage backend — complete control over where data is stored and how it's persisted.

Claude Sonnet 4.5 enhances both capabilities with built-in context awareness — tracking available tokens throughout conversations to manage context more effectively.

## Use cases

- **Coding:** Context editing clears old file reads and test results while memory preserves debugging insights and architectural decisions.
- **Research:** Memory stores key findings while context editing removes old search results.
- **Data processing:** Agents store intermediate results in memory while context editing clears raw data.

## Performance improvements (public eval data)

- On an internal evaluation set for agentic search: combining the memory tool with context editing improved performance by **39%** over baseline. Context editing alone delivered a **29%** improvement.
- In a 100-turn web search evaluation, context editing enabled agents to complete workflows that would otherwise fail due to context exhaustion — while reducing token consumption by **84%**.

## Availability

Available today in public beta on the Claude Developer Platform, natively and in Amazon Bedrock and Google Cloud's Vertex AI.
