# Effective context engineering for AI agents | Anthropic

Source: https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
Published: September 29, 2025

## Key thesis

Context engineering is the natural progression of prompt engineering. Context engineering refers to the set of strategies for curating and maintaining the optimal set of tokens (information) during LLM inference, including all the other information that may land there outside of the prompts.

Guiding principle: **good context engineering means finding the smallest possible set of high-signal tokens that maximize the likelihood of some desired outcome.**

## Why it matters: context rot

- Needle-in-a-haystack benchmarking revealed "context rot": as the number of tokens in the context window increases, the model's ability to accurately recall information from that context decreases.
- LLMs have an "attention budget" — every new token depletes it. Transformer n² pairwise attention means context size and attention focus have a natural tension.
- Models are trained on distributions where shorter sequences are more common; position encoding interpolation allows longer sequences with some degradation. Result: a performance gradient rather than a hard cliff.
- Context must be treated as a finite resource with diminishing marginal returns.

## The anatomy of effective context

**System prompts**: at the "right altitude" — a Goldilocks zone between hardcoded brittle if-else logic (fragile) and vague high-level guidance (no concrete signals). Organize into distinct sections (background, instructions, tool guidance, output description) with XML tags or Markdown headers. Start minimal with the best model, add instructions based on observed failure modes.

**Tools**: define the contract between agents and their information/action space. Tools should be token-efficient, self-contained, robust, minimal functional overlap, descriptive unambiguous parameters. Common failure mode: bloated tool sets → ambiguous decision points. "If a human engineer can't definitively say which tool should be used, an AI agent can't be expected to do better."

**Examples (few-shot)**: curate a diverse set of canonical examples rather than a laundry list of edge cases.

## Context retrieval and agentic search

- Shift from embedding-based pre-inference-time retrieval to augmenting with **"just in time" context strategies**.
- Just-in-time: maintain lightweight identifiers (file paths, stored queries, web links) and dynamically load data into context at runtime using tools. Mirrors human cognition — external organization and indexing (file systems, inboxes, bookmarks).
- **Progressive disclosure**: agents incrementally discover relevant context through exploration; file sizes suggest complexity, naming conventions hint at purpose, timestamps proxy for relevance. Self-managed context window.
- Trade-off: runtime exploration is slower than retrieving pre-computed data.
- **Hybrid strategy**: retrieve some data up front for speed + autonomous exploration at discretion. Claude Code example: CLAUDE.md files naively dropped into context up front; glob/grep navigate just-in-time.

## Long-horizon tasks: three techniques

1. **Compaction**: take a conversation nearing the context window limit, summarize contents, reinitiate a new context window with the summary. First lever for long-term coherence. The art lies in what to keep vs discard — overly aggressive compaction loses subtle critical context. Recommendation: tune the prompt on complex agent traces; start by maximizing recall, then iterate for precision. Example of low-hanging fruit: tool result clearing (once a tool result has been used, no need to see the raw result again).
2. **Structured note-taking (agentic memory)**: agent regularly writes notes persisted to memory outside the context window, pulled back in later. Persistent memory with minimal overhead. Examples: Claude Code to-do list, NOTES.md, Claude playing Pokémon (agent maintains tallies across thousands of game steps, maps of explored regions, combat strategy notes; reads own notes after context resets). Memory tool released in public beta (Sonnet 4.5 launch, Sept 2025).
3. **Sub-agent architectures**: specialized sub-agents handle focused tasks with clean context windows; main agent coordinates with high-level plan. Each subagent explores extensively (tens of thousands of tokens) but returns condensed summary (1,000-2,000 tokens). Separation of concerns; detailed search context isolated within subagents.

## Choosing between techniques

- Compaction: conversational flow for extensive back-and-forth.
- Note-taking: iterative development with clear milestones.
- Multi-agent: complex research/analysis where parallel exploration pays.

## Conclusion

As models become more capable, the challenge isn't just crafting the perfect prompt — it's thoughtfully curating what information enters the model's limited attention budget at each step. "Find the smallest set of high-signal tokens that maximize the likelihood of your desired outcome."
