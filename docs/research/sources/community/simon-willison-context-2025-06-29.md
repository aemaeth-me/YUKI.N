# How to Fix Your Context

URL: https://simonwillison.net/2025/Jun/29/how-to-fix-your-context/
Author: Simon Willison
Published: 2025-06-29

---

"How to Fix Your Context". Drew Breunig has been publishing some very detailed notes on context engineering recently. In "How Long Contexts Fail" he described four common patterns for context rot, which he summarizes like so:

> * **Context Poisoning**: When a hallucination or other error makes it into the context, where it is repeatedly referenced.
> * **Context Distraction**: When a context grows so long that the model over-focuses on the context, neglecting what it learned during training.
> * **Context Confusion**: When superfluous information in the context is used by the model to generate a low-quality response.
> * **Context Clash**: When you accrue new information and tools in your context that conflicts with other information in the prompt.

In this follow-up he introduces neat ideas (and more new terminology) for addressing those problems.

**Tool Loadout** describes selecting a subset of tools to enable for a prompt, based on research that shows anything beyond 20 can confuse some models.

**Context Quarantine** is "the act of isolating contexts in their own dedicated threads" - I've called this sub-agents in the past, it's the pattern used by Claude Code and explored in depth in Anthropic's multi-agent research paper.

**Context Pruning** is "removing irrelevant or otherwise unneeded information from the context", and **Context Summarization** is the act of boiling down an accrued context into a condensed summary. These techniques become particularly important as conversations get longer and run closer to the model's token limits.

**Context Offloading** is "the act of storing information outside the LLM's context". I've seen several systems implement their own "memory" tool for saving and then revisiting notes as they work, but an even more interesting example recently is how various coding agents create and update `plan.md` files as they work through larger problems.

Drew's conclusion:

> The key insight across all the above tactics is that context is not free. Every token in the context influences the model's behavior, for better or worse. The massive context windows of modern LLMs are a powerful capability, but they're not an excuse to be sloppy with information management.
