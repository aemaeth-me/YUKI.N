# How Long Contexts Fail

URL: https://www.dbreunig.com/2025/06/22/how-contexts-fail-and-how-to-fix-them.html
Author: Drew Breunig
Published: 2025-06-22

---

As frontier model context windows continue to grow, with many supporting up to 1 million tokens, I see many excited discussions about how long context windows will unlock the agents of our dreams. After all, with a large enough window, you can simply throw everything into a prompt you might need – tools, documents, instructions, and more – and let the model take care of the rest.

Long contexts kneecapped RAG enthusiasm (no need to find the best doc when you can fit it all in the prompt!), enabled MCP hype (connect to every tool and models can do any job!), and fueled enthusiasm for agents.

But in reality, longer contexts do not generate better responses. Overloading your context can cause your agents and applications to fail in surprising ways. Contexts can become poisoned, distracting, confusing, or conflicting.

## Four failure modes

### Context Poisoning
When a hallucination or other error makes it into the context, where it is repeatedly referenced.

> An especially egregious form of this issue can take place with "context poisoning" – where many parts of the context (goals, summary) are "poisoned" with misinformation about the game state, which can often take a very long time to undo. As a result, the model can become fixated on achieving impossible or irrelevant goals. (Gemini 2.5 technical report)

### Context Distraction
When a context grows so long that the model over-focuses on the context, neglecting what it learned during training.

> While Gemini 2.5 Pro supports 1M+ token context... it was observed that as the context grew significantly beyond 100k tokens, the agent showed a tendency toward favoring repeating actions from its vast history rather than synthesizing novel plans. This phenomenon, albeit anecdotal, highlights an important distinction between long-context for retrieval and long-context for multi-step, generative reasoning.

A Databricks study found that model correctness began to fall around 32k for Llama 3.1 405b, and earlier for smaller models.

> If models start to misbehave long before their context windows are filled, what's the point of super large context windows? In a nutshell: summarization and fact retrieval.

### Context Confusion
When superfluous content in the context is used by the model to generate a low-quality response.

> It turns out there can be such a thing as too many tools. The Berkeley Function-Calling Leaderboard shows that every model performs worse when provided with more than one tool.

Example: quantized Llama 3.1 8b failed the GeoEngine benchmark with all 46 tools, but succeeded with only 19 tools — well within the 16k context window.

> The problem is: if you put something in the context the model has to pay attention to it. It may be irrelevant information or needless tool definitions, but the model will take it into account.

### Context Clash
When you accrue new information and tools in your context that conflicts with other information in the context.

A Microsoft/Salesforce paper 'sharded' benchmark prompts across multiple messages; results dropped on average 39% (o3: 98.1 → 64.1).

> We find that LLMs often make assumptions in early turns and prematurely attempt to generate final solutions, on which they overly rely. In simpler terms, we discover that when LLMs take a wrong turn in a conversation, they get lost and do not recover.

## Conclusion

> But as we've seen, bigger contexts create new failure modes. Context poisoning embeds errors that compound over time. Context distraction causes agents to lean heavily on their context and repeat past actions rather than push forward. Context confusion leads to irrelevant tool or document usage. Context clash creates internal contradictions that derail reasoning.
> These failures hit agents hardest because agents operate in exactly the scenarios where contexts balloon: gathering information from multiple sources, making sequential tool calls, engaging in multi-turn reasoning, and accumulating extensive histories.
