# Microsoft Agent Framework — Memory & Persistence

Sources:
- https://learn.microsoft.com/en-us/agent-framework/get-started/memory (Step 4: Memory & Persistence)
- https://learn.microsoft.com/en-us/agent-framework/integrations/chat-history-memory-provider
- https://learn.microsoft.com/en-us/agent-framework/integrations/neo4j-memory
- https://microsoft.github.io/ai-agents-for-beginners/13-agent-memory/

## Overview

Microsoft Agent Framework (successor to AutoGen/Semantic Kernel agent abstractions, GA 2025) handles memory via **Context Providers** and **History Providers**:
- Default: agents store chat history in an `InMemoryChatHistoryProvider` or in the underlying AI service.
- Session = built-in short-term memory: conversation context available while the session is reused, but not persisted when session ends or app restarts.
- Long-term memory for facts/preferences that survive across sessions — via database, vector index, or another persistent store.

## Key abstractions

- **ContextProvider** (Python: `ContextProvider`; Go: `agent.ContextProvider`): injects context before a run (`before_run`/`provide`) and extracts/stores memory after (`after_run`/`store`). State is stored in the session's `state` dict (`AgentSession.StateBag`).
- **HistoryProvider**: manages chat history storage/loading.
- **AI Context Providers** (`AIContextProviders` in C#): attach RAG and memory to `ChatClientAgent`.

## Chat History Memory Provider (semantic memory over a vector store)

- `ChatHistoryMemoryProvider` — AI Context Provider that stores all chat history in a vector store and retrieves related messages to augment the current conversation (semantic similarity search).
- Two phases:
  1. **Storage**: after each agent invocation, new request/response messages stored in vector store with embeddings.
  2. **Retrieval**: before each invocation (or on-demand via function calling), searches for semantically similar messages and injects as context.
- **Scoping**: messages scoped using configurable identifiers (application, agent, user, session). `storageScope` = how new messages are tagged; `searchScope` = filter criteria when searching (can be broader — e.g., store per-session, search across all sessions for a user).
- **Search behavior**: `BeforeAIInvoke` (default, auto-search before each invocation) or `OnDemandFunctionCalling` (exposes a function tool the model can invoke).
- Options: MaxResults (default 3), ContextPrompt ("## Memories\nConsider the following memories..."), message filters, redaction for telemetry.
- Vector store via `Microsoft.Extensions.VectorData.Abstractions` (InMemory, Azure AI Search, Qdrant, Pinecone, Redis, Weaviate, etc.).

## Neo4j Memory Provider (knowledge graph memory)

- Persistent memory backed by a knowledge graph. Stores/recalls agent interactions, automatically extracting entities and building a knowledge graph over time.
- Three types of memory:
  - **Short-term**: conversation history and recent context.
  - **Long-term**: entities, preferences, and facts extracted from interactions.
  - **Reasoning memory**: past reasoning traces and tool usage patterns.
- Bidirectional: `Neo4jMemoryContextProvider` recalls relevant memory before each run and persists new memory after.
- Entity extraction pipeline (`AutoExtractOnPersist`), preference learning, memory tools (`MemoryToolFactory`) for explicit search/remember/recall.

## Memory tooling ecosystem (Microsoft's education docs)

- **Mem0**: persistent memory layer; two-phase memory pipeline (extraction: LLM summarizes conversation and extracts new memories; update: LLM-driven add/modify/delete) storing in a hybrid data store (vector, graph, key-value).
- **Cognee**: open-source semantic memory transforming data into queryable knowledge graphs backed by embeddings; dual-store architecture (vector similarity + graph relationships); hybrid retrieval.
- **Azure AI Search**: backend for structured RAG memory; Structured RAG for dense structured info from conversation histories, emails, images.
- **Whiteboard memory** (e.g., MEM0 whiteboard).

## Design patterns highlighted

- PII masking middleware (mask before LLM, unmask after).
- Background knowledge-graph extractor (tail conversation transcripts; LLM extracts facts; embeddings; upsert into semantic memory) — keeps agent reply latency low.
- Token truncation context provider — evicts unstamped historical messages to meet token budget.
