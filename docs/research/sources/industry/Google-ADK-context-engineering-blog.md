# Architecting efficient context-aware multi-agent framework for production | Google Developers Blog

Source: https://developers.googleblog.com/architecting-efficient-context-aware-multi-agent-framework-for-production/
Published: December 4, 2025

## Thesis

Context engineering — treating context as a first-class system with its own architecture, lifecycle, and constraints.

The naive pattern (append everything into one giant prompt) collapses under three-way pressure:
1. **Cost and latency spirals**: model cost and time-to-first-token grow quickly with context size.
2. **Signal degradation ("lost in the middle")**: context flooded with irrelevant logs, stale tool outputs, deprecated state distracts the model.
3. **Physical limits**: real workloads (full RAG results, intermediate artifacts, long conversation traces) overflow even largest fixed windows.

"Throwing more tokens at the problem buys time, but it doesn't change the shape of the curve."

## Design thesis: context as a compiled view

- **Sessions, memory, and artifacts (files)** are the *sources* — the full, structured state.
- **Flows and processors** are the *compiler pipeline* — a sequence of passes that transform that state.
- The **working context** is the *compiled view* shipped to the LLM for one invocation.

Three design principles:
1. **Separate storage from presentation**: durable state (Sessions) vs per-call views (working context).
2. **Explicit transformations**: context built through named, ordered processors (observable, testable).
3. **Scope by default**: every model call and sub-agent sees minimum context required; agents reach for more via tools.

## Tiered model (structure)

- **Working context** — the immediate prompt for this model call (system instructions, identity, selected history, tool outputs, optional memory results, artifact references). Ephemeral, configurable, model-agnostic.
- **Session** — durable log of the interaction: every message, reply, tool call, tool result, control signal, error as structured Event objects. Ground truth.
- **Memory** — long-lived, searchable knowledge that outlives a single session (user preferences, past conversations).
- **Artifacts** — large binary/textual data (files, logs, images), addressed by name and version, not pasted into prompt. Handle pattern: agents see only lightweight reference; use `LoadArtifactsTool` to load on demand; ephemeral expansion (offloaded after call).

## Flows and processors

Every LLM agent is backed by an LLM Flow with ordered processors. `contents` processor transforms Session into history portion of working context: **Selection** (filter irrelevant events), **Transformation** (flatten into Content objects with correct roles), **Injection** (write formatted history into llm_request.contents).

## Context compaction & filtering

- At configurable threshold, ADK triggers an asynchronous process: LLM summarizes older events over a sliding window (compaction intervals + overlap size), writes summary back into Session as a new event with "compaction" action. Prunes or de-prioritizes raw events.
- Compaction operates on the Event stream itself → benefits cascade (scalability, clean views, decoupling).
- **Filtering**: prebuilt plugins drop/trim context based on deterministic rules.

## Context caching

- Separates context into stable prefixes (system instructions, identity, long-lived summaries) and variable suffixes (latest turn, tool outputs). `static instruction` primitive guarantees immutability for cache prefix.

## Relevance: agentic management

- Human engineers define architecture (where data lives, how summarized, what filters). Agent decides dynamically when to "reach" for memory blocks or artifacts.
- **Reactive recall**: agent calls `load_memory_tool` to search corpus when it recognizes a knowledge gap.
- **Proactive recall**: pre-processor runs similarity search on latest input, injects likely relevant snippets via `preload_memory_tool` before model invocation.
- Replaces "context stuffing" anti-pattern with "memory-based" workflow.

## Multi-agent context

- Agents as Tools: callee sees only specific instructions + necessary artifacts, no history.
- Agent Transfer (Hierarchy): sub-agent inherits view over Session. `include_contents` knob controls context flow (default = full working context; none = no prior history).
- **Conversation translation on handoff**: prior "Assistant" messages re-cast as narrative context (`[For context]: Agent B said...`), tool calls from other agents marked/summarized — prevents new agent from hallucinating it performed prior actions.
