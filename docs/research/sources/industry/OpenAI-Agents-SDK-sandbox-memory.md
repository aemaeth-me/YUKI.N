# Agent memory — OpenAI Agents SDK (Sandbox agents, beta)

Source: https://openai.github.io/openai-agents-python/sandbox/memory/

## Concept

Memory lets future sandbox-agent runs learn from prior runs. It is separate from the SDK's conversational Session memory (which stores message history). Memory distills lessons from prior runs into files in the sandbox workspace. (Beta)

Memory can reduce three kinds of cost for future runs:
1. Agent cost: less exploration needed → fewer tokens/time to completion.
2. User cost: remembered feedback/corrections reduce human intervention.
3. Context cost: no need to find previous thread or re-type context → shorter task descriptions.

## Enable

Add `Memory()` as a capability to the sandbox agent. If read is enabled, `Memory()` requires `Shell()` (agent reads/searches memory files when injected summary isn't enough). Live memory update (default on) requires `Filesystem()` so the agent can update `memories/MEMORY.md`.

Memory artifacts stored under `memories/` in the sandbox workspace. `Memory(generate=None)` = read-only; `Memory(read=None)` = generate-only.

## Read memory — progressive disclosure

- At start of run, SDK injects a small summary (`memory_summary.md`) of useful tips, user preferences, available memories into the agent's developer prompt — enough to decide if prior work may be relevant.
- When prior work looks relevant, the agent searches the memory index (`MEMORY.md`) for keywords, and opens prior rollout summaries (`rollout_summaries/`) only when more detail is needed.
- Memory can become stale. Agents are instructed to treat memories as guidance only and trust the current environment. `live_update` enabled by default: agent can update `MEMORY.md` in the same run if it discovers stale memory.

## Generate memory — two phases

After a run finishes, the sandbox runtime appends the run segment to a conversation file. Accumulated conversation files processed when the sandbox session closes.

- **Phase 1 — conversation extraction:** a memory-generating model processes one accumulated conversation file → conversation summary (system/developer/reasoning content omitted; long conversations truncated with beginning and end preserved) + a raw memory extract (compact notes for Phase 2).
- **Phase 2 — layout consolidation:** a consolidation agent reads raw memories for one memory layout, opens conversation summaries for more evidence, extracts patterns into `MEMORY.md` and `memory_summary.md`.

Workspace layout:
```
workspace/
├── sessions/<rollout-id>.jsonl
└── memories/
    ├── memory_summary.md
    ├── MEMORY.md
    ├── raw_memories.md (intermediate)
    ├── phase_two_selection.json (intermediate)
    ├── raw_memories/<rollout-id>.md
    ├── rollout_summaries/<rollout-id>_<slug>.md
    └── skills/
```

Config: `MemoryGenerateConfig(extra_prompt=..., max_raw_memories_for_consolidation=256)`. If recent raw memories exceed the cap, Phase 2 keeps only newest memories — this forgetting mechanism helps memories reflect the newest environment.

## Multi-turn conversations

Pass the same SDK Session (`session=conversation_session`) so both runs append to one memory conversation file. Memory conversation ID resolution order: (1) `conversation_id`, (2) `session.session_id`, (3) `RunConfig.group_id`, (4) generated per-run ID.

## Memory isolation / layouts

Memory isolation is based on `MemoryLayoutConfig`, not agent name. Agents with the same layout + same memory conversation ID share one memory conversation and one consolidated memory. Different layouts keep separate files. E.g., separate GTM vs engineering memory.
