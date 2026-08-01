# I built a multi-agent memory consistency layer after the Claude Code leak

URL: https://news.ycombinator.com/item?id=None
Points: 3 | None comments

---
**OP simplyjosh56**: https://github.com/Agentscreator/Engram

**simplyjosh56**: Claude Code just leaked. I went through the architecture to understand how agentic systems coordinate and I noticed a problem. Shared memory across agents.
Every agent session starts from scratch. Your agent re-discovers why certain architectural decisions were made, re-learns which approaches already failed, and re-figures out which constraints are non-negotiable. Meanwhile, another engineer’s agent did the same thing last week.
Individual agent memory is already solved. But theres still a hard problem: ensuring multiple agents agree on what’s true.
Engram is built to solve exactly that. It’s an MCP server that gives all your agents a shared, persistent knowledge base—one that survives across sessions, syncs across engineers, and detects when agents develop conflicting beliefs about the same codebase.
Existing memory tools only solve this per agent or per session. They don’t address what happens when Agent A and Agent B—running in different sessions for different engineers—develop conflicting beliefs about the same system.
There are 400+ MCP servers that provide individual agent memory. Engram is not that. Engram is a consistency layer.
Recent research from the University of San Diego confirms that shared multi-agent memory is a critical open problem.
As multi-agent systems scale:
Every agent starts from zero.
Agents across engineers repeatedly rediscover the same failures, constraints, and decisions.
Contradictory beliefs emerge silently, causing unnecessary failures
Built on the lessons from Claude Code, Engram adds a shared, persistent memory layer on top of orchestration frameworks, and offers shared agent memory across all engineers
I’d love feedback and contributions.

**gAI**: I hope we continue to see workflow and tool improvements based on the leak for a good while.

**ravila4**: Did Claude come up with the name? I noticed that it loves to suggest “engram” as a name for projects. There’s also a ton of “engram” repos on github in recent months.
