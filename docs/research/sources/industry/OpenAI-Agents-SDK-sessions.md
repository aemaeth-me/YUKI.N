# Sessions (Short-term memory) — OpenAI Agents SDK

Source: https://openai.github.io/openai-agents-python/sessions/

## Overview

The Agents SDK provides built-in session memory to automatically maintain conversation history across multiple agent runs, eliminating the need to manually handle `.to_input_list()` between turns.

Sessions stores conversation history for a specific session, allowing agents to maintain context without requiring explicit manual memory management. Particularly useful for building chat applications or multi-turn conversations.

Use sessions when you want the SDK to manage client-side memory for you. Sessions cannot be combined with `conversation_id`, `previous_response_id`, or `auto_previous_response_id` in the same run.

## Core session behavior

When session memory is enabled:
1. **Before each run**: The runner automatically retrieves the conversation history for the session and prepends it to the input items.
2. **After each run**: All new items generated during the run (user input, assistant responses, tool calls, etc.) are automatically stored in the session.
3. **Context preservation**: Each subsequent run with the same session includes the full conversation history.

## Control history merging

- `RunConfig.session_input_callback`: customize merge of session history + new input before the model call. The returned list controls the model input for that turn, but the SDK still persists only items that belong to the new turn.
- `SessionSettings(limit=N)`: retrieve only the most recent N items. `limit=None` (default) retrieves all.

## Memory operations

- `get_items(limit)` — retrieve conversation history
- `add_items(items)` — add new items
- `pop_item()` — remove and return the most recent item (useful for corrections/undo)
- `clear_session()` — clear all items

## Built-in session implementations

| Session type | Best for | Notes |
| --- | --- | --- |
| `SQLiteSession` | Local dev and simple apps | Built-in, lightweight, file-backed or in-memory |
| `AsyncSQLiteSession` | Async SQLite with aiosqlite | Extension backend |
| `RedisSession` | Shared memory across workers/services | Low-latency distributed deployments |
| `SQLAlchemySession` | Production apps with existing databases | Works with SQLAlchemy-supported databases |
| `MongoDBSession` | MongoDB / multi-process storage | Async pymongo; atomic seq counter |
| `DaprSession` | Cloud-native with Dapr sidecars | Multiple state stores + TTL + consistency |
| `OpenAIConversationsSession` | Server-managed storage in OpenAI | Conversations API-backed history |
| `OpenAIResponsesCompactionSession` | Long conversations with automatic compaction | Wrapper around another session backend; uses Responses API `responses.compact` |
| `AdvancedSQLiteSession` | SQLite plus branching/analytics | Branching, usage analytics |
| `EncryptedSession` | Encryption + TTL on top of another session | Wrapper |

## Compaction (OpenAIResponsesCompactionSession)

- Compacts stored conversation history with the Responses API (`responses.compact`).
- `compaction_mode="previous_response_id"` works best when chaining turns with Responses API response IDs; `compaction_mode="input"` rebuilds the compaction request from current session items; default `"auto"`.
- Auto-compaction runs after each turn once a candidate threshold is reached. It clears and rewrites session history (can block streaming).
- `run_compaction({"force": True})` for application-defined forced checkpoints.

## Conversation continuation strategies (running-agents guide)

Four common ways to carry state into the next turn:
| Strategy | Where state lives | What you pass |
| `result.history` | Your application | The replay-ready history |
| `session` | Your storage + the SDK | The same session |
| `conversationId` | OpenAI Conversations API | Same conversation ID + only the new turn |
| `previousResponseId` | OpenAI Responses API | Last response ID + only the new turn |

Most applications pick one strategy per conversation. Mixing local replay with server-managed state can duplicate context.
