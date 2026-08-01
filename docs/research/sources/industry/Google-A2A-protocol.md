# Agent2Agent (A2A) Protocol — Google / Linux Foundation

Sources:
- https://a2a-protocol.org/v1.0.0/specification/
- https://developers.googleblog.com/en/a2a-a-new-era-of-agent-interoperability/ (Apr 9, 2025)
- https://github.com/google/A2A

## What it is

A2A is an open protocol initiated by Google (donated to the Linux Foundation) enabling communication and interoperability between disparate AI agent systems. Complements Anthropic's MCP (which provides tools/context to agents). A2A addresses challenges of deploying large-scale multi-agent systems.

Latest released version: 1.0.0.

## Key concepts

- **Agent Card**: JSON metadata document published by an A2A Server describing identity, capabilities, skills, service endpoint, authentication requirements. Agents advertise capabilities, letting client agents discover the best agent for a task. Published at `/.well-known/agent-card.json`. Fields: name, description, version, supported_interfaces, capabilities (streaming, push_notifications, extended_agent_card, extensions), skills, security_schemes/requirements, default input/output modes.
- **Task management**: communication is oriented toward task completion; a "task" object has a lifecycle (submitted → working → completed). Long-running tasks keep agents in sync on status. Output of a task is an "artifact".
- **Parts**: each message includes "parts" — fully formed content with specified content type; agents negotiate correct formats and UI capabilities (forms, cards).
- **No shared internal state / memory in the protocol itself**: A2A's design goal is "securely without exposing internal state." Memory/state is NOT part of the protocol — it is the agent's internal responsibility. Google ADK's Session/Memory services (InMemory/VertexAiMemoryBank) back the agents, and A2A's context_id maps to ADK session_id in the example executor.

## Bindings & SDKs

- JSON-RPC 2.0 (HTTP/SSE), gRPC, HTTP/REST.
- Official SDKs: Python (a2a-sdk), JS/TS (@a2a-js/sdk), Java, Go, C#/.NET.
- Integrations: LangGraph, CrewAI, Google ADK, Genkit, AG2, BeeAI, PydanticAI, etc.

## Relationship to memory

- A2A protocol has no memory abstraction per se — memory lives in the agent implementation (e.g., ADK SessionService + MemoryService). The protocol's `context_id`/`message` metadata can carry identity (user_id) for the backing session/memory store.
- Google's ADK A2A example wires the A2A executor to ADK Runner with InMemorySessionService + InMemoryMemoryService.
