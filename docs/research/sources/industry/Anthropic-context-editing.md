# Context editing — Claude Platform Docs | Anthropic

Source: https://platform.claude.com/docs/en/build-with-claude/context-editing

## Overview

Context editing allows selectively clearing specific content from conversation history as it grows. Rationale: "context is a finite resource with diminishing returns, and irrelevant content degrades model focus." Context editing gives fine-grained runtime control over curation.

For most use cases, server-side compaction is the primary strategy; context editing for fine-grained control.

## Strategies

| Approach | Where it runs | Strategies |
| --- | --- | --- |
| **Server-side** | API | Tool result clearing (`clear_tool_uses_20250919`); Thinking block clearing (`clear_thinking_20251015`) |
| **Client-side** | SDK | Compaction (Python/TypeScript/Ruby `tool_runner`) |

Beta: context editing in beta, enable with header `context-management-2025-06-27`.

## Tool result clearing (`clear_tool_uses_20250919`)

- Clears tool results when conversation context grows beyond configured threshold. Older tool results (file contents, search results) no longer needed once processed.
- Replaces each cleared result with placeholder text so Claude knows it was removed.
- Default: only tool results cleared; optionally `clear_tool_inputs=true` to clear tool calls (parameters) too.
- Config: `trigger` (default 100,000 input tokens, can be `input_tokens` or `tool_uses`), `keep` (default 3 tool uses), `clear_at_least`, `exclude_tools`, `clear_tool_inputs`.

## Thinking block clearing (`clear_thinking_20251015`)

- Manages `thinking` blocks when extended thinking enabled. Keep more thinking blocks for reasoning continuity or clear aggressively to save context.
- Config: `keep` — `{type: "thinking_turns", value: N}` or `"all"`. Default varies by model class (Opus 4.5+/Sonnet 4.6+: keep all; earlier: last turn only).

## Server-side application

- Applied server-side before the prompt reaches Claude. Client maintains full, unmodified history; no need to sync with edited version.

## Prompt caching interaction

- Tool result clearing invalidates cached prefixes when content cleared; use `clear_at_least` to ensure minimum tokens cleared to make invalidation worthwhile.
- Thinking block clearing: keeping thinking blocks preserves cache; clearing invalidates at point of clearing.

## Combining with the memory tool

- When conversation context approaches the clearing threshold, Claude receives an automatic warning to preserve important information — saves tool results/context to memory files before they're cleared.
- Allows: preserving important context; maintaining long-running workflows; accessing information on demand from memory files.
- Example: file editing workflow — Claude summarizes completed changes to memory files as context grows.

## Client-side compaction (SDK) — deprecated in favor of server-side

- Anthropic recommends server-side compaction (`compact_20260112` edit) over SDK compaction.
- SDK compaction: monitors token usage after each response; when threshold exceeded, summary prompt injected as user turn; Claude generates structured summary in `<summary></summary>` tags; SDK replaces entire message history with summary.
- Config: `enabled`, `context_token_threshold` (default 100,000), `model` (default same as main), `summary_prompt`.
- Built-in summary prompt structure: Task Overview, Current State, Important Discoveries, Next Steps, Context to Preserve.

## Compaction (`compact_20260112`)

- Server-side; triggers at token threshold (minimum 50K; default 150K per cookbook); returns typed `compaction` content block; handles tool-use pairing across summary boundary; serialize block back and API drops everything before it on next request.
