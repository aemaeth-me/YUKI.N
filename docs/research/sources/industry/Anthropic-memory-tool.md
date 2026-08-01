# Memory tool — Claude Platform Docs | Anthropic

Source: https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool

## Overview

The memory tool lets Claude store and retrieve information across conversations in a directory of memory files. Claude can create, read, update, and delete files that persist between sessions, building up knowledge over time without keeping everything in the context window.

Memory supports just-in-time context retrieval. Rather than loading all relevant information up front, an agent records what it learns in memory files and reads them back on demand. This keeps the active context focused on the current task.

The memory tool operates **client-side**: Claude requests file operations, and your application executes them. You control where and how the data is stored through your own infrastructure.

## How it works

- When the memory tool is enabled, Claude automatically checks its memory directory before starting a task. It stores what it learns in files under `/memories` and reads them back in later conversations to continue earlier work.
- The `/memories` path is a prefix your handler maps onto real storage (per-user directory or keys in a database). Memory lives entirely in your application.
- A later conversation continues from the same memory when it sends the same `tools` entry and your handler serves the same store.
- Available on all Claude 4 and later models.
- Generally available on the Messages API: no beta header required.

## Usage

1. Add the memory tool to your request: `{"type": "memory_20250818", "name": "memory"}`. The `name` must be `memory`; you don't define an input schema for an Anthropic-provided tool.
2. Implement a client-side handler for each memory command. Handler must reject paths outside `/memories`.

SDK helpers: subclass `BetaAbstractMemoryTool` (Python/C#), `betaMemoryTool` (TypeScript), or `BetaMemoryToolHandler` (Java) to back memory with your own storage (files on disk, database, cloud storage, encrypted files). Python and TypeScript ship `BetaLocalFilesystemMemoryTool`.

## Tool commands

- **view** — shows directory contents or file contents with optional line ranges (`view_range`). Directories: listing files up to 2 levels deep with human-readable sizes, excludes hidden items and node_modules. Files: line-numbered contents; files over 16,000 chars truncated; image files (.jpg/.jpeg/.png) displayed.
- **create** — creates a new file (create or overwrite).
- **str_replace** — replaces text in a file (new_str optional — omitted deletes).
- **insert** — inserts text at a specific line.
- **delete** — deletes a file or directory (recursive); cannot delete `/memories` root.
- **rename** — renames or moves a file or directory; cannot rename `/memories` root.

## System prompt addition

When the memory tool is present, the API automatically adds an instruction to the system prompt about using the memory directory.

## Security safeguards

- Claude usually refuses to write sensitive information to memory files. For stronger guarantees, add validation that strips sensitive data before your handler writes.
- Track memory file sizes and cap growth; cap characters the `view` command returns; periodically delete memory files not accessed in a long time.
- **Path traversal protection:** validate all paths start with `/memories`, resolve to canonical form, reject `../` patterns and URL-encoded traversal, use built-in path security utilities.

## Context editing integration

The memory tool pairs with context editing to manage long-running conversations:
- Context editing clears specific tool results on the client.
- Compaction summarizes the whole conversation server-side (when approaching context window limit).
- For long-running agents consider using both: compaction keeps the active context small without client-side bookkeeping, and memory preserves the information that must survive summarization.

## Multisession software development pattern

Deliberate memory file setup (recovery mechanism):
1. **Initializer session:** sets up memory files before substantive work — progress log, feature checklist, reference to startup script.
2. **Subsequent sessions:** each new session opens by reading those memory files, restoring project state without re-exploring.
3. **End-of-session update:** updates the progress log with what was completed and what remains.

Work on one feature at a time; mark complete only after end-to-end verification. (See "Effective harnesses for long-running agents".)
