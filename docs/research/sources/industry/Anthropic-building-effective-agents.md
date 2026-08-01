# Building Effective AI Agents | Anthropic

Source: https://www.anthropic.com/engineering/building-effective-agents
Published: 2024 (original) / "Building Effective AI Agents" (research)

## Workflows vs Agents

- **Workflows**: LLMs and tools orchestrated through predefined code paths.
- **Agents**: LLMs dynamically direct their own processes and tool usage, maintaining control over how they accomplish tasks.

Recommendation: find the simplest solution possible; only increase complexity when needed. Agentic systems trade latency and cost for better task performance.

## Building block: The augmented LLM

The basic building block is an LLM enhanced with augmentations such as **retrieval, tools, and memory**. Current models can actively use these capabilities — generating their own search queries, selecting appropriate tools, and determining what information to retain.

## Patterns

- Prompt chaining
- Routing
- Parallelization (sectioning, voting)
- Orchestrator-workers
- Evaluator-optimizer
- Agents (autonomous)

## Agents

Agents are typically just LLMs using tools based on environmental feedback in a loop. It is crucial to design toolsets and their documentation clearly. Key: agents gain "ground truth" from the environment at each step (tool call results, code execution) to assess progress.

Three core principles:
1. Maintain **simplicity** in agent design.
2. Prioritize **transparency** by explicitly showing the agent's planning steps.
3. Carefully craft the agent-computer interface (ACI) through thorough tool documentation and testing.

## Frameworks (mention)

Claude Agent SDK; Strands Agents SDK by AWS; Rivet; Vellum. Suggestion: start with LLM APIs directly; if you use a framework, understand the underlying code.

## Appendix: Prompt engineering your tools

Tools enable Claude to interact with external services. Tool definitions deserve as much prompt engineering attention as overall prompts. Design for the model: obvious usage, example usage, edge cases, clear boundaries from other tools. Poka-yoke tools (e.g., always require absolute filepaths).
