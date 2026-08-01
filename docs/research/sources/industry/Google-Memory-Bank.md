# Agent Platform Memory Bank — Google Cloud (Gemini Enterprise Agent Platform)

Source: https://cloud.google.com/gemini-enterprise-agent-platform/scale/memory-bank
(Formerly Vertex AI Agent Engine Memory Bank)

## What it is

Memory Bank lets you dynamically generate long-term memories based on conversations between the user and your agent. Memories are personalized information that persists across multiple sessions. For each scope (identity), Memory Bank maintains an isolated collection of memories. Each memory is an independent, self-contained piece of information that can expand the context available to the agent.

Memory object shape: `{ name, scope: {agent_name, user}, fact: "..." }`.

## Features

### Memory generation (LLM-driven)
- **Memory extraction**: extract only the most meaningful information from source data.
- **Memory consolidation**: consolidate newly extracted info with existing memories; memories evolve as new info ingested. Can also consolidate pre-extracted memories (agent- or human-in-the-loop meaningful).
- **Asynchronous generation**: generate memories in the background so agent doesn't wait.
- **Continuous event ingestion**: stream conversation events; auto-triggers memory generation based on batching rules.
- **Customizable extraction**: configure what is "meaningful" via topics + few-shot examples.
- **Multimodal understanding**: process multimodal info to generate/persist textual insights.

### Managed storage and retrieval
- **Data isolation across identities**: consolidation/retrieval isolated to a specific identity (scope-based).
- **Persistent and accessible storage**: accessible from Agent Runtime, local environment, or other deployments.
- **Similarity search**: retrieve memories via similarity search scoped to a specific identity.
- **Automatic expiration (TTL)**: stale information auto-deleted.
- **Memory revisions**: automatically create/maintain revisions — inspect how memories transform as new information is ingested.
- **Restrictive permissions**: IAM conditions restrict which principals can read/write specific scopes.

### Agent integration
- **ADK integration**: `VertexAiMemoryBankService` + built-in ADK tools (`preload_memory`, `load_memory`).
- **Other frameworks**: wrap Memory Bank code in tools/callbacks.

## Use cases

- Long-term personalization (customer service agent remembers past tickets/preferences).
- LLM-driven knowledge extraction (research agent consolidates key findings from papers).
- **Dynamic & evolving context**: "Whereas RAG has a static, external knowledge base, Memory Bank can evolve based on context provided by the agent." Knowledge source isn't static.

## Example flow with Sessions

1. `CreateSession` at start of conversation (session has user ID).
2. `AppendEvent` as user interacts (user messages, agent responses, tool actions).
3. `ListEvents` to retrieve conversation history.
4. `GenerateMemories` at interval (end of session/turn) — facts about user auto-extracted from conversation history; OR `CreateMemory` — agent writes memories directly (memory-as-a-tool, more control over what facts are extracted).
5. `RetrieveMemories` — retrieve all (simple) or most relevant (similarity search); insert into prompt.

## Security risks: memory poisoning

- Memory poisoning occurs when false information is stored in Memory Bank; agent may operate on false/malicious info in future sessions.
- Mitigations: Model Armor to inspect prompts; adversarial testing / red teaming; sandbox execution with access control and human review.

## Update / deletion model

- Memories evolve via consolidation; TTL expires stale info; revisions track transformations; IAM conditions control read/write. No explicit user-facing "forget" API surfaced here beyond TTL/deletion of memories.
