# Memory for Claude Managed Agents | Anthropic

Source: https://claude.com/blog/claude-managed-agents-memory
Published: April 23, 2026

## Overview

Memory on Claude Managed Agents available in public beta. Agents can now learn from every session, using an intelligence-optimized memory layer that balances performance with flexibility. Memories stored as files — developers can export them, manage via API, keep full control.

## How memory works

- Built-in, intelligence-optimized memory layer that lets agents learn from every session.
- Optimized against internal benchmarks for long-running agents that improve across sessions and share what they've learned with each other.
- **Filesystem-based**: memory mounts directly onto a filesystem, so Claude relies on the same bash and code execution capabilities. With filesystem-based memory, latest models (e.g., Opus 4.7) save more comprehensive, well-organized memories and are more discerning about what to remember for a given task.
- Each Managed Agents session starts with fresh context by default; memory stores let the agent carry information across sessions (user preferences, project conventions, prior mistakes, domain context).

## Portable memories for production

- Enterprise: scoped permissions, audit logs, full programmatic control.
- Stores can be shared across multiple agents with different access scopes (org-wide read-only store + per-user read/write stores).
- Multiple agents can work concurrently against the same store without overwriting each other.
- Memories are files: exportable, independently managed via API. All changes tracked with a detailed audit log — which agent and session a memory came from. Roll back to an earlier version or redact content from history.
- Updates surface in Claude Console as session events — trace what an agent learned and where it came from.

## Customer results (public eval data)

- **Rakuten**: task-based long-running agents learn from every session, avoiding repeated mistakes — **97% fewer first-pass errors, 27% lower cost, 34% lower latency** (workspace-scoped, observable).
- **Wisedocs**: document verification pipeline, cross-session memory to spot and remember recurring document issues — verification **30% faster**.
- **Netflix**: agents carry context across sessions (insights that took multiple turns to uncover, corrections from a human mid-conversation) instead of manually updating prompts and skills.
- **Ando**: capturing how each organization interacts instead of building memory infrastructure.

## API (from platform docs — managed agents memory)

- **Memory store**: workspace-scoped collection of text documents optimized for Claude. Attached to a session → mounted as a directory inside the session's sandbox (e.g., `/mnt/memory/<slug>/`). Agent reads/writes with standard file tools; note describing each mount added to system prompt.
- Each memory addressed by a path; read/edited directly via API or Console (tuning, importing, exporting).
- Memory stores attached in the session's `resources[]` array at session creation; cannot be added/removed from a running session.
- Memory store endpoints use `agent-memory-2026-07-22` beta header.
- Operations: memories.create (create at path, no overwrite), memories.update, memory stores: create/retrieve/update/list/archive/delete.

## Related: Opus 4.7 memory note (April 16, 2026)

- Opus 4.7 is better at using file system-based memory. Remembers important notes across long, multi-session work, and uses them to move on to new tasks that need less up-front context.
