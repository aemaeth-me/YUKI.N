# Dreaming: Better memory for a more helpful ChatGPT | OpenAI

Source: https://openai.com/index/chatgpt-memory-dreaming/
Published: June 4, 2026

## Key Points

Today we're beginning to roll out a more capable and scalable system for synthesizing memory, developed to tackle the staleness, correctness, and scalability challenges that we observe when memory is applied to the hundreds of millions of users and multi-year time horizons in ChatGPT.

Memory is what helps ChatGPT learn your preferences, projects, and constraints, allowing future conversations to start from shared context rather than from scratch.

This update is available to Plus and Pro users in the US today, and will roll out to additional countries and Free and Go users over the coming weeks.

## How memory has evolved

- Memory first launched in April 2024 (also known as saved memories). The feature let you ask ChatGPT to remember information and carry it forward into future chats.
- Saved memories were only written during the conversation and relied on strong cues to decide when to trigger memory, such as an instruction to "remember I'm traveling to Singapore in July." In practice, interacting with this system could feel like talking to someone who took a few notes, but still forgot everything that wasn't written down. Saved memories also tend to go stale over time and eventually become incorrect or irrelevant.
- In April 2025, we updated ChatGPT's memory by giving the model the ability to reference chat context outside of the saved memories list; this was done by introducing the first version of **dreaming**—a method for ChatGPT to *automatically* curate memories in the background by referencing chat history.
- In contrast to saved memories, dreaming leverages a background process that allows ChatGPT to learn from many conversations and synthesize ChatGPT's memory state in order to always provide the freshest, most relevant context to your conversations. Dreaming also makes it easier for memory to include context that occurs naturally in conversation, without relying on explicit requests to remember something.
- Over the last year, dreaming *supplemented* saved memories to create a step-function improvement in ChatGPT's ability to personalize responses and offset the staleness of saved memories. However, it historically was never sufficient as a standalone memory system.
- Today, we are launching a significantly more capable and compute-efficient memory architecture built on top of dreaming.
- The memories synthesized by dreaming are reviewable through a summary of them made visible in the memory summary page. From the memory summary, you can quickly glean the highlights of what ChatGPT knows about you, add or update information about yourself, and provide instructions on what topics ChatGPT should bring up and when. If you want to drill down into a particular area to learn more, just chat with the model.

## How we evaluate memory

What "good memory" looks like in ChatGPT:

1. **Carry forward useful context:** You tell ChatGPT something once, and it remembers that information in your subsequent chats.
2. **Follow preferences and constraints:** If you describe a preference (e.g., you're vegetarian), then ChatGPT should take actions that are consistent with that preference going forward.
3. **Stay current over time:** Memory should account for the passage of time. Imagine "The user is planning their birthday party for next Saturday"; eventually, Sunday arrives.

Evaluated versions: 2024 (Saved memories), 2025 (Saved memories + Dreaming V0), 2026 (Dreaming V3).

- Carrying forward context: eval where model must recall factual information about the user; new dreaming-based system improves the model's ability to recall relevant facts.
- Following preferences: improved ability to apply relevant preferences from past conversations.
- Staying current over time: with dreaming, memories are automatically updated as time passes, allowing ChatGPT to revise its memory from "You're going to Singapore in July" to "You went to Singapore in July 2026" when the trip ends. Dreaming provides a substantial lift in this area.

## A more scalable foundation for the future

- While dreaming-based memory has been available to Plus and Pro users for some time, we are only now able to offer Free users a version that meets our quality bar and is practical to serve at scale.
- Recent improvements reduced the compute required to serve dreaming to Free users by approximately 5x, making it possible to begin rolling out dreaming to Free users over the coming weeks and to increase memory capacity for Plus and Pro users.
- Looking ahead, dreaming now provides us with a shared memory foundation for all users. This update represents our most capable memory system yet.
