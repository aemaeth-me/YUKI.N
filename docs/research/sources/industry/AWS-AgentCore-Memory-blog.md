# Amazon Bedrock AgentCore Memory: Building context-aware agents | AWS ML Blog

Source: https://aws.amazon.com/blogs/machine-learning/amazon-bedrock-agentcore-memory-building-context-aware-agents/
Published: August 13, 2025 (introduced at AWS Summit New York City 2025)

## The memory problem in AI agents

- Context window constraints: limited capacity to process conversation history.
- State management complexity: custom solutions for tracking history, preferences, agent state.
- Memory recall challenges: storing raw conversation data isn't enough — need intelligent extraction and structured organization.
- Persistence without intelligence: most solutions focus on storage, not intelligent memory formation.

## Five design principles

1. **Abstracted storage**: handles storage complexity for short- and long-term info without managing infrastructure.
2. **Security**: encrypted at rest and in transit.
3. **Continuity**: events within sessions stored in chronological order.
4. **Data organization and access control**: hierarchical namespaces for structured organization + fine-grained access control.
5. **Scalability and performance**: large volumes of memory data with low latency.

## Core components

### 1. Memory resource
Logical container encapsulating raw events + processed long-term memories. Event expiry duration configurable (up to 365 days). Encryption: AWS managed keys by default or customer managed KMS keys.

### 2. Short-term memory
Raw interaction data as immutable events, organized by actor and session. Event types: "Conversational" (USER/ASSISTANT/TOOL) or "blob" (binary content for checkpoints/agent state). Only Conversational events used for long-term memory extraction. Identifiers: `memoryId` (auto-created), `actorId` (entities: users/agents/projects), `sessionId` (groups related events).

### 3. Long-term memory
Extracted insights, preferences, knowledge derived from raw events. Asynchronous extraction after events created, using memory strategies.

### 3.a Namespaces
Hierarchical structure like file system paths. Purposes: organizational structure (preferences, summaries, entities), access control, multi-tenant isolation (`/org_id/user_id/preferences/`), focused retrieval. Dynamic placeholders: `{actorId}`, `{sessionId}`, `{strategyId}`.

### 3.b Memory strategies (the intelligence layer)
Define what's extracted, how processed, where stored. All strategies ignore PII from long-term memory records by default. 3 built-in strategies:
- **Semantic Strategy**: facts and knowledge ("The customer's company has 500 employees across 3 office locations").
- **Summary Strategy**: running summary of a conversation, scoped to a session.
- **User Preferences Strategy**: user preferences/choices/styles ("User prefers Python").
- **Custom memory strategies**: choose a specific LLM, override prompt for extraction/consolidation.

## Advanced features

- **Branching**: alternative conversation paths from a specific point in event history. Use cases: message editing, what-if scenarios, alternative approaches. Creates new named branch with same actor_id/session_id; specify branch name and rootEventId.
- **Checkpointing**: save/mark specific states (blob events under different isolation) for multi-session tasks, workflow resumption, conversation bookmarks. Checkpoint events ignored for long-term extraction.

## Best practices

1. **Structured memory architecture**: distinct memory types for different needs; hierarchical namespaces; TTL settings (support chats 30 days, preferences much longer).
2. **Memory strategies**: built-in for common needs; custom for specific use cases; extract only relevant info.
3. **Efficient memory operations**: retrieve memories within each interaction (context hydration); targeted retrieval (list events for raw context, summaries for session context, semantic search for related records); store promptly via CreateEvent. Note: long-term extraction/consolidation is asynchronous → refresh delays.
4. **Security and privacy**: actors/namespaces for organization; IAM least-privilege; KMS for sensitive data; guardrails against prompt injection and **memory poisoning**.
5. **Observability**: event tracking/logging; monitor extraction patterns; review memory architecture periodically.
