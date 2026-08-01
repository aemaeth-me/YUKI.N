# Mem0 raises $24M to build the memory layer for AI

URL: https://mem0.ai/series-a
Author: Mem0
Published: 2025-10-28

---

We live in extraordinary times. AI can now write complex software from natural language prompts, solve IMO problems, analyze thousand-page contracts in minutes... Yet these same systems suffer from a fundamental flaw: they can't truly remember anything. Sure, individual chat sessions can recall earlier messages. But real memory—the kind that builds deep understanding over time, transfers seamlessly between contexts, and enables genuine personalization—remains elusive.

> Most interactions still start largely from scratch. Users paste the same context into ChatGPT over and over. They watch coding assistants suggest the same rejected patterns dozens of times. They re-explain their preferences to customer support bots that helped them yesterday. Our most sophisticated intelligence is trapped in digital amnesia.

Today, we're announcing our $24M raise across Seed and Series A. Our Seed round was led by Kindred Ventures, and our Series A was led by Basis Set Ventures, with participation from Peak XV Partners, GitHub Fund, and Y Combinator. Angel investors include Scott Belsky, Dharmesh Shah, Olivier Pomel (Datadog), Paul Copplestone (Supabase), James Hawkins (PostHog), Thomas Dohmke (ex-GitHub), and Lukas Biewald (Weights & Biases).

## Memory is deceptively hard

> When developers realize their AI applications need memory, their first instinct is to build it themselves. It seems straightforward: store interactions, retrieve relevant context. A weekend project at most.
> Then reality sets in. Simple semantic search fails to preserve nuanced context. New preferences clash with old ones. Recent information gets buried under stale data. Duplicates multiply. What starts as a simple project becomes months of engineering work tackling problems that only surface at scale.

## What is Mem0

Mem0 is production-ready memory infrastructure that any developer can integrate with just three lines of code:

> We extract memories from interactions, categorize them, layer in metrics like decay and confidence, and update them intelligently when conflicting facts emerge. During retrieval, we use sophisticated algorithms that make sense of these factors and surface only the relevant memories in the context of the interaction.

Adoption numbers: 41,000 GitHub stars, 14 million Python package downloads. API calls growing from 35 million in Q1 to 186 million in Q3 2025. CrewAI, Flowise, Langflow integrate Mem0 natively. AWS selected Mem0 as the exclusive memory provider for their Agent SDK.

## Three principles guiding the vision

1. **Make It Work** — "Just like every application needs a database, every agentic application needs memory."
2. **Make It Neutral** — "The last thing you want is your memory—the accumulated understanding of your users—locked to a single provider. Mem0 stays neutral. One memory layer that works across every model, every framework, every platform."
3. **Make It Portable** — "Today, memories are trapped in silos... Just as contacts became portable across devices and services, memory will too. Users will demand their context travels with them." (记者称之为 "memory passport")
