# Amazon Bedrock AgentCore — Memory, Policy, Evaluations | AWS

Sources:
- https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/memory.html
- https://aws.amazon.com/blogs/aws/amazon-bedrock-agentcore-adds-quality-evaluations-and-policy-controls-for-deploying-trusted-ai-agents/
- https://aws.amazon.com/about-aws/whats-new/2025/12/amazon-bedrock-agentcore-policy-evaluations-preview/
- https://www.aboutamazon.com/news/aws/aws-amazon-bedrock-agent-core-ai-agents
- https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/release-notes.html

## AgentCore Memory (overview)

AgentCore Memory is a fully managed service that gives AI agents the ability to remember past interactions, enabling more intelligent, context-aware, and personalized conversations. Handles both short-term context and long-term knowledge retention without building complex infrastructure.

Addresses a fundamental challenge in agentic AI: **statelessness**. Supports a variety of SDKs and agent frameworks.

## Two memory types

- **Short-term memory**: captures turn-by-turn interactions within a single session — immediate context without repeating info.
- **Long-term memory**: automatically extracts and stores key insights from conversations across multiple sessions — user preferences, important facts, session summaries — persistent knowledge across sessions.

## Memory strategies

Long-term memory in AgentCore uses strategies:
- (Episodic) **Episodic memory strategy** (Dec 2025, GA): agents learn from past experiences and apply lessons to future interactions.
  - Captures **structured episodes** that record the context, reasoning process, actions taken, and outcomes of agent interactions.
  - A **reflection agent** analyzes these episodes to extract broader insights and patterns.
  - When facing similar tasks, agents retrieve these learnings to improve decision-making consistency and reduce processing time.
  - Reduces the need for custom instructions by including in the agent context only the specific learnings an agent needs.
  - Example: agent books airport transportation 45 min before flight when traveling alone; three months later, traveling to same destination with kids → automatically schedules pickup two hours early, remembering previous family trip challenges.
- Structured metadata filtering on long-term memory: attach structured attributes to memory records; narrow retrieval to matching values (priority, department, tags, time range). Indexed keys declared when creating a memory; metadata schemas configured on strategies for automatic LLM extraction from conversations.
- Resource-based policies for memory resources (granular access control).
- Memory record streaming: push-based notifications when memory records created/updated/deleted (event-driven architecture).

## Policy in AgentCore (preview Dec 2025; GA March 3, 2026)

- Defines clear boundaries for agent actions by intercepting AgentCore Gateway tool calls before they run, using policies with fine-grained permissions.
- Active, real-time, deterministic controls that operate outside of the agent code.
- Teams create policies using **natural language that automatically convert to Cedar** (AWS open-source policy language) — dev/compliance/security teams set up, understand, and audit rules without writing custom code.

## AgentCore Evaluations (preview Dec 2025; GA March 31, 2026)

- Monitors quality of agents based on real-world behavior using built-in evaluators (13 built-in evaluators) for dimensions such as correctness, helpfulness, tool selection, accuracy + custom model-based scoring.
- Unified dashboard powered by Amazon CloudWatch.

## AgentCore Harness

- Managed AgentCore harness GA in all supported regions. `CreateHarness` + `InvokeHarness` — no orchestration code. **GA adds built-in memory by default**, or bring your own.
- Supports model providers through LiteLLM and Bedrock.

## Adoption / quotes

- "Most AI agents today lack critical memory... 'memory' is often limited to a short-term context that resets with each interaction."
- S&P Global: "managing state and maintaining consistent context became increasingly difficult, highlighting the need for a unified memory layer. Amazon Bedrock AgentCore Memory provided the solution through seamless, centralized state checkpointing across our multi-agent orchestration stack."
- Swisscom uses AgentCore Runtime + Identity + Memory for tracking customer interactions.
- 5 months after preview: organizations including Amazon Devices, Cohere Health, Cox Automotive, Heroku, Natera, MongoDB, PGA TOUR, Pulumi, Thomson Reuters, Workday, Snorkel, Swisscom using AgentCore; 2M+ downloads.

## Pricing

- AgentCore offers consumption-based pricing with no upfront costs.
