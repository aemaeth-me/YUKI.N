# Amazon Bedrock AgentCore — Memory types (official docs)

Source: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/memory-types.html

## Short-term memory

- Stores raw interactions that help the agent maintain context within a single session.
- Captures the entire conversation history as a series of events (each customer question/agent response saved as a separate event, or in batches).
- Lets the agent reload the entire conversation as it happened, maintaining context even if the service restarts or the customer returns later.
- API: `CreateEvent` (capture interaction; events can be conversational exchanges or structured info), associated with a session via `sessionId` (defined by you or system-generated). Use `sessionId` in future requests to maintain context.
- Retrieval: `ListSessions` (locate previous interactions), `ListEvents` (retrieve conversation history), `GetEvent` (specific information from key moments).
- **Event metadata**: attach key-value metadata to events (e.g., location for a travel booking agent). Use `ListEvents` with metadata filters to efficiently retrieve events without scanning entire sessions. Event metadata is NOT meant for sensitive content (not encrypted with customer managed key).

## Long-term memory

- Records store structured information extracted from raw agent interactions, retained across multiple sessions.
- Preserves only key insights: summaries of conversations, facts and knowledge, user preferences.
- Generation is an **asynchronous background process** that automatically extracts insights after raw conversation/context is stored in short-term memory via `CreateEvent`. Doesn't interrupt live interactions.
- Two operations:
  - **Extraction**: extracts information from raw interactions.
  - **Consolidation**: consolidates newly extracted information with existing information in AgentCore Memory.
- Retrieval: `GetMemoryRecord`, `ListMemoryRecords`, `RetrieveMemoryRecords` (performs **semantic search** to find memory records most relevant to the query).

Example: customer mentions preferred shoe brand → stored as long-term memory → later conversations can recall and suggest it.
