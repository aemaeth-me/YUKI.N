# Comparing the memory implementations of Claude and ChatGPT

URL: https://simonwillison.net/2025/Sep/12/claude-memory/
Author: Simon Willison
Published: 2025-09-12

---

"Claude Memory: A Different Philosophy" (via) Shlok Khemani has been doing excellent work reverse-engineering LLM systems and documenting his discoveries. Last week he wrote about ChatGPT memory. This week it's Claude.

> Claude's memory system has two fundamental characteristics. First, it starts every conversation with a blank slate, without any preloaded user profiles or conversation history. Memory only activates when you explicitly invoke it. Second, Claude recalls by only referring to your raw conversation history. There are no AI-generated summaries or compressed profiles—just real-time searches through your actual past chats.

Claude's memory is implemented as two new function tools that are made available for a Claude to call:

> **conversation_search**: Search through past user conversations to find relevant context and information
> **recent_chats**: Retrieve recent chat conversations with customizable sort order (chronological or reverse chronological), optional pagination using 'before' and 'after' datetime filters, and project filtering

The good news here is transparency - Claude's memory feature is implemented as visible tool calls, which means you can see exactly when and how it is accessing previous context.

This helps address my big complaint about ChatGPT memory (see "I really don't like ChatGPT's new memory dossier" back in May) - I like to understand as much as possible about what's going into my context so I can better anticipate how it is likely to affect the model.

The OpenAI system is very different: rather than letting the model decide when to access memory via tools, OpenAI instead automatically include details of previous conversations at the start of every conversation.

> Recent Conversation Content is a history of your latest conversations with ChatGPT, each timestamped with topic and selected messages. [...] Interestingly, only the user's messages are surfaced, not the assistant's responses.

One of my big worries about memory was that it could harm my "clean slate" approach to chats: if I'm working on code and the model starts going down the wrong path (getting stuck in a bug loop for example) I'll start a fresh chat to wipe that rotten context away. I had worried that ChatGPT memory would bring that bad context along to the next chat, but omitting the LLM responses makes that much less of a risk than I had anticipated.

**Update**: In "Bringing memory to teams at work" Anthropic revealed an additional memory feature, currently only available to Team and Enterprise accounts, with a feature checkbox labeled "Generate memory of chat history" that looks much more similar to the OpenAI implementation:

> With memory, Claude focuses on learning your professional context and work patterns to maximize productivity. It remembers your team's processes, client needs, project details, and priorities.
> Claude uses a memory summary to capture all its memories in one place for you to view and edit.

This version of Claude memory also takes Claude Projects into account:

> If you use projects, Claude creates a separate memory for each project. This ensures that your product launch planning stays separate from client work, and confidential discussions remain separate from general operations.
