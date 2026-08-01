# Memories — Codex (OpenAI, ChatGPT Learn docs)

Source: https://learn.chatgpt.com/docs/customization/memories

## Overview

Memories let ChatGPT and Codex carry useful context from earlier work into future work. ChatGPT web uses ChatGPT memory; local Codex clients use a separate local memory store and controls.

- Keep required team guidance in AGENTS.md or checked-in documentation. Treat memories as a helpful recall layer, not as the only source for rules that must always apply.

## How local Codex memories work

- After enabling, Codex turns useful context from eligible prior chats into local memory files.
- Codex skips active or short-lived sessions; redacts secrets from generated memory fields; updates memories in the background instead of immediately at end of every chat.
- Waits until a chat has been idle long enough (avoids summarizing work still in progress).
- Skips background pass when Codex rate-limit remaining % is below configured threshold.

## Local memory storage

- Stored under Codex home directory (default `~/.codex`).
- Main memory files under `~/.codex/memories/` — include summaries, durable entries, recent inputs, and supporting evidence from prior chats.
- Treat as generated state; inspect for troubleshooting; don't rely on editing by hand.

## Control per chat

- `/memories` command in ChatGPT desktop app and Codex TUI: choose whether current chat can use existing memories and whether the chat can generate future memories.
- Local Codex memories off by default; enable in Settings > Personalization > "Enable memories"; or `[features] memories = true` in config.toml.

## Memory config settings

- `memories.generate_memories`: whether newly created chats can be stored as memory-generation inputs.
- `memories.use_memories`: whether Codex injects existing memories into future sessions.
- `memories.disable_on_external_context`: keeps chats that used external context (MCP tool calls, web search, tool search) out of memory generation.
- `memories.min_rate_limit_remaining_percent`: minimum rate-limit remaining before memory generation starts.
- `memories.extract_model`: model used for per-chat memory extraction.
- `memories.consolidation_model`: model used for global memory consolidation.

## Chronicle (related)

Desktop-only feature that helps Codex recover recent working context from your screen to build up memory.

## Relationship to sandbox memory

This local Codex memory uses a two-phase design (per-chat extraction → global consolidation), analogous to the sandbox agent memory (Phase 1 conversation extraction → Phase 2 layout consolidation into MEMORY.md / memory_summary.md).
