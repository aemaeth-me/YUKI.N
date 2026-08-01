# Memory: Long-term knowledge with MemoryService — Google ADK

Source: https://adk.dev/sessions/memory/
Also: https://cloud.google.com/blog/topics/developers-practitioners/remember-this-agent-state-and-memory-with-adk (Aug 2025)

## Three-tier memory model

- **Session**: the current conversation thread (chronological events).
- **State (`session.state`)**: data within the current conversation — a key-value "scratchpad". Serializable key-value pairs (keys are strings; values must be serializable basic types).
- **Memory (MemoryService)**: searchable, cross-session long-term knowledge store — a knowledge base the agent can search.

## State scoping via key prefixes

| Prefix | Scope | Persistence |
| --- | --- | --- |
| No prefix | Current session (id) | Only if SessionService persistent |
| `user:` | Tied to user_id, shared across all sessions for that user (same app_name) | Persistent with Database/VertexAI |
| `app:` | Tied to app_name, shared across all users/sessions | Persistent with Database/VertexAI |
| `temp:` | Current invocation only | Not persistent, discarded after invocation |

State updates flow through `EventActions.state_delta` when events are appended (via `append_event`), ensuring tracking, persistence, and thread-safety. Use `output_key` to write agent output to state; `{placeholders}` to inject state into instructions.

## MemoryService role

`BaseMemoryService` interface:
- **Ingesting:** `add_session_to_memory(session)` (capture essence of a completed conversation); `add_events_to_memory(events)` (delta of events, mid-session writes); `add_memory(MemoryEntry)` (explicit fine-grained facts).
- **Searching:** `search_memory(app_name, user_id, query)` returns `SearchMemoryResponse` with list of `MemoryEntry` (content + optional author, timestamp, custom_metadata).

## Three implementations

| Feature | InMemoryMemoryService | VertexAiMemoryBankService | VertexAiRagMemoryService |
| --- | --- | --- | --- |
| Persistence | None | Yes, managed by Agent Platform | Yes, stored in Knowledge Engine |
| Memory extraction | Stores full conversation (keyword match search) | LLM-extracted meaningful memories, consolidated with existing memories | Full conversation, vector similarity over raw transcripts |
| When to use | Prototyping | Agent remembers/learns from past interactions | Existing RAG infra / raw transcript retrieval |

## Memory Bank (Vertex AI Memory Bank)

- Fully managed Google Cloud service for persistent memory of conversational agents.
- **Generating Memories**: at end of conversation, send session events to Memory Bank which intelligently processes/stores information as "memories" (uses Gemini model to extract key information).
- **Retrieving Memories**: agent issues search query against Memory Bank; vector-based similarity search by keyword.
- `add_memory` with `enable_consolidation=True` → `memories.generate` API consolidates new memory items with existing related memories (reduces redundancy, builds coherent knowledge base).
- Multimodal: can ingest images, videos, audio, "understand" them, and retrieve them later.
- URI config: `agentengine://<agent_engine_id>`.

## Using memory in an agent

Two pre-built tools:
- **Preload memory**: automatically retrieves memory at the beginning of each turn (like a callback).
- **Load memory**: retrieves memory when the agent decides it would be helpful.

Workflow: Session interaction → `add_session_to_memory(session)` (e.g., in after-agent callback) → agent uses memory-retrieval tool → `search_memory` → results returned to agent.

## Agent Engine / runtime notes

- `VertexAiSessionService`: store session data in Agent Engine.
- `DatabaseSessionService`: SQL (SQLite, MySQL, PostgreSQL).
- In-memory defaults lost on restart; production needs external persistence.
- One memory service per `adk web` / `adk api_server` via `--memory_service_uri`.

## Short vs long-term (blog framing)

- Short-term memory = within one session (state scratchpad).
- Long-term memory = persist across sessions (memory service) — "talking to the same customer service representative every time."
- In-memory long-term memory retrieves raw event history — can overwhelm model context with too much; Memory Bank extracts just key memories.
