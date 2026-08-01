# Open source memory layer so any AI agent can do what Claude.ai and ChatGPT do

URL: https://news.ycombinator.com/item?id=None
Points: 185 | None comments

---
**OP alash3al**: https://alash3al.github.io/stash?_v01

**alash3al**: Platform memory is locked to one model and one company. Stash brings the same capability to any agent — local, cloud, or custom. MCP server, 28 tools, background consolidation, Apache 2.0.

**great_psy**: LLM Memeory (in general, any implementation) is good in theory.<p>In practice, as it grows it gets just as messy as not having it.<p>In the example you have on front page you say “continue working on my project”, but you’re rarely working on just one project, you might want to have 5 or 10 in memory, each one made sense to have at the time.<p>So now you still have to say, “continue working on the sass project”, sure there’s some context around details, but you pay for it by filling up your llm context , and doing extra mcp calls

  **dennisy**: True! But this is a very naive implementation, a proper implementation could surpass these challenges.

    **awestroke**: Well let's talk again when the problems have been solved, then. Until then, manually curated skills and documentation will beat this

  **vasco**: And once you're being specific about what it needs to remember you are 0 steps away from having just told AI to write and read files with the "memory"

**dennisy**: Congratulations on the launch!<p>There is lots of competition in this space, how is your tool different?

**_pdp_**: Well the project is promising something without providing any details how exactly this is achieved which to me is always a huge red flag.<p>Digging deeper I can see it is effectively pg_vector plus mcp with two functions: "recall" and "remember".<p>It is effectively a RAG.<p>You can make the argument that perhaps the data structure matters but all of these "memory" systems effectively do the same and none of them have so far proven that retrieval is improved compared to baseline vector db search.

  **hirako2000**: It's a cool website..it says memory. It shows LLM suck and this product magically just works.<p>In a way, if it does accomplish that, it is a vectordb needing glorification.

**clutter55561**: Isn’t “memory” just another markdown file that the LLM reads when starting a new session?<p>I keep two files in each project - AGENTS (generic) and PROJECT (duh). All the “memory” is manually curated in PROJECT, no messy consolidation, no Russian roulette.<p>I do understand that this is different because the vector search and selective unstash, but the messy consolidation risk remains.<p>Also not sure about tools that further detach us from the driver seat. To me, this seems to encourage vibe coding instead of engineering-plus-execution.<p>Not a criticism on the product itself, just rambling.

**adithyassekhar**: Is this only for vibecoders who work alone?<p>If I am working on a real project with real people, it won’t have the complete memory of the project. I won’t have the complete memory. My memory will be outdated when other PRs are merged. I only care about my tickets.<p>I am starting to think this is not meant for that kind of work.

**bobkb**: There is already memory palace ?

**dwb**: I’m certainly on the lookout for something like this and I’m happy to see your account has published software from before the LLM boom as well. I guess I’d like some kind of LLM-use-statement attached to projects: did you use an LLM to generate this, and if so, how much and what stages (design, build, test)? How carefully did you review the output? Do you feel the quality is at least what you could have produced by yourself? That sort of thing.<p>Not casting aspersions on you personally, I’d really like this from every project, and would do the same myself.

  **dennisy**: This is a fair question, but not one I feel we can let people self answer.<p>I doubt many people will honestly admit they did no design, testing and that they believe the code is sub par.<p>It does give me an idea that maybe we need a third party system which can try and answer some of the questions you are asking… of course it too would be LLM driven and quite subjective.

    **dwb**: > I doubt many people will honestly admit they did no design, testing and that they believe the code is sub par.<p>Well no, but if people want to see a statement like this, and given that most people will want to be at least halfway honest and not admit to slop, maybe it will help nudge things in the right direction.

    **embedding-shape**: > I doubt many people will honestly admit they did no design, testing and that they believe the code is sub par<p>I'd doubt any engineer that doesn't call most of their own code subpar after a week or two after looking back. "Hacking" also famously involves little design or (automated) testing too, so sharing something like that doesn't mean much, unless you're trying to launch a business, but I see no evidence of that for this project.

  **chickensong**: What's the point? You can make good or bad software, with or without LLMs. Do you ask a carpenter if they use a hammer or nail gun? Did they only use the nail gun for the roof and the deck?<p>If you care that much and don't have a foundation of trust, you need to either verify the construction is good, or build it yourself. Anything else is just wishful thinking.

    **hirako2000**: We do ask whether it's handmade or factory.<p>We even ask when cakes are made in house or frozen even though they look and taste great (at first).

    **dwb**: It’s not all-or-nothing: a statement like what I want would be part of the assurance, not the whole thing.

      **chickensong**: It's meaningless though. It's performative virtue signalling with no assurance. Some people will produce great/poor quality regardless of the tools used. For ever vibe coder barfing up spaghetti, there's an engineer using the same tools to enhance their craft.<p>If you want assurance, look for other signals IMHO.

        **dwb**: Code quality is indeed a virtue that I would like signalled and partly assured, through the means of the author feeling the social pressure of performing an explanation of their use of LLMs, and wanting to not appear careless. In my direct experience, the way you use these tools has a big effect on the outcome, and that’s the information I’d like conveyed here. Clearly it doesn’t cover people who would have produced rubbish anyway, but it isn’t intended to be complete.

          **chickensong**: Fair enough, we all have our preferences and opinions. What signals would you be looking for to make your judgement call?<p>> it doesn’t cover people who would have produced rubbish anyway<p>How do you determine this though?<p>If it becomes common for people to include an AI usage profile, what does that really do? I can say I followed best practices, steered design, supervised the LLM, reviewed the code, etc... but those are just a stranger's words with little value, and my code might still be garbage.

            **dwb**: If you keep saying things that don't hold up, that tends to harm your reputation. Do I really need to explain basic social dynamics? Sure, maybe I'm wrong and this totally wouldn't work. Maybe (probably) not enough people think it's a good idea and it never happens. Maybe everyone just decides to lie through their teeth. Maybe there's no significant relationship between how carefully you use an LLM and the quality of the product. But I thought it was worth suggesting.

              **chickensong**: I get the social dynamics, and I agree that we need more signals to build trust, even if I disagree on this particular signal.<p>I think enhancing SDLC visibility could be valuable, which is somewhat related to your original suggestion, though I'm not sure how to validate something like that since workflows and tests tend to be unique. I suppose we have badges like 'build:passing' that aren't standard, but are somewhat adopted and show that some extra effort went into setting that up. It would be nice to have something a bit more standardized and verifiable though.<p>Anyway, I appreciate your engaged responses, and even if we don't see eye to eye on the LLM signal, I think we both want the same thing, which is increased trust in third-party software. I hope we get there someday, even if it seems we're moving in the opposite direction right now.

  **codebolt**: There are many ways to use an LLM to generate a piece of software. I base most of my projects these days around sets of Markdown files where I use AI first to research, then plan and finally track the progress of implementation (which I do step-wise with the plan, always reviewing as I go along). If I was asked to provide documentation for my workflow those files would be it. My code is 99% generated, but I take care to ensure the LLM generates it in a way that I am happy with. I'd argue the result is often better than what I'd have managed on my own.

    **dwb**: Yep pretty much same, although if I’m lax at any point of the reviewing (in-progress or final), I’d say the quality quickly drops to below my average manual effort, and then I don’t even have the benefit of thinking it all through as directly. I think getting really quality results out of LLM code generation for non-trivial projects still needs quite a bit of discipline and work.

  **looksjjhg**: I’m sorry this sounds a bit too entitled - no one is putting a gun to your head to use this project and you know you can always read the code and review it yourself and make an educated decision on whether you want to use it or not

    **dwb**: I don’t think I’m entitled to what I suggested, I don’t see how you’re reading that.

      **milkshakes**: it's free code.
if you're so concerned about the quality, you can read it yourself.

        **dwb**: And if anyone is so put out by my suggestion (that I said I'd hold myself to as well), they can just ignore me and move on. I posted a comment on a public forum about what I'd like, I'm not the boss of anyone.

          **looksjjhg**: There a huge difference between suggestions and demands.
I posted a comment about the tone of your comment you can also ignore it.

            **dwb**: Statements that start “I guess I’d like…” are not demands.

    **jrm4**: Weird. The project is <i>obviously</i> holding itself out to be some amazing awesome new thing. Extraordinary claims at least <i>invite</i> questions like this.<p>Or are you all suggesting we should be comfortable with, and never question,  flowery unchallenged advertising copy?

**Incipient**: I still haven't found useful "memory". It's either an agents.md with a high level summary, which is fairly useless for specific details (eg "editing this element needs to mark this other element as a draft") or something detailed and explaining the nitty gritty, which seems to give too much detail such that it gets ignored, or detail from one functional area contaminates the intended changes in another functional area.<p>The only approach I've found that works is no memory, and manually choosing the context that matters for a given agent session/prompt.

  **clutter55561**: All the memories Claude created for me fell in the category remember-to-not-forget, so I disabled it altogether.

  **jvwww**: Yeah I feel the same way. Wonder when/if we'll get continual learning from these models. I feel like they are smart enough already but their lack of real memory makes them a pain to deal with.

    **hirako2000**: Google Gemini does this sort of thing. External to the model k presume. And it's very annoying.<p>A friend told me he would like Claude to remember his personality, which is exactly what Gemini is trying to do.<p>A machine pretending to be human is disturbing enough. A machine pretending to understand you will spiral very far into spitting out exactly what we want to read.

  **zby**: I have a wishlist for these systems: <a href="https://zby.github.io/commonplace/notes/designing-agent-memory-systems/" rel="nofollow">https://zby.github.io/commonplace/notes/designing-agent-memo...</a>

  **jjfoooo4**: Even as someone highly interested in memory I don’t see it as a useful tool for coding. The source of truth for what a repo does or should do is the repo itself.<p>What you’re describing sounds more like code review guidelines, which can be explicitly brought into context at specific times during a change. A memory system is both too complex and less accurate for this

**kgeist**: >Stash makes your AI remember you. Every session. Forever.<p>How does it fight context pollution?

**tedggh**: A few things seem to work well for me (Codex):<p>1) An up-to-date detailed functional specification.<p>2) A codebase structured and organized in multiple projects.<p>3) Well documented code including good naming conventions; each class, variable or function name should clearly state what its purpose is, no matter how long and silly the name is. These naming conventions are part of a coding guidelines section in Agent.md.<p>My functional specification acts as the Project.md for the agent.<p>Then before each agentic code review I create a tree of my project directory and I merged it with the codebase into one single file, and add the timestamp to the file name. This last bit seems to matter to avoid the LLM to refer to older versions and it’s also useful to do quick diffs without sending the agent to git.<p>So far this simple workflow has been working very well in a fairly large and complex codebase.<p>Not very efficient tokens wise, but it just works.<p>By the way I don’t need to merge the entire codebase every time, I may decide to leave projects out because I consider them done and tested or irrelevant to the area I want to be working on.<p>However I do include them in the printed directory tree so the agent at least knows about them and could request seeing a particular file if it needs to.

  **swingboy**: Interesting approach. How do you do the merging? Is it manual? Just changed files? A hybrid?

**braiamp**: What the heck is happening on this site with the pointer disappearing? For some reason the body tag has "cursor: none" which is never good.

  **eleventen**: The traditional cursor is so 2025. It's predictable. Familiar. <i>old</i>.<p>AI is the future, so we need cursors of the future that simulate the frustrating lag and imprecision of LLMS. Dots chase other little dots around and do inscrutable little animations.<p>Actual answer: You need javascript to see their dumb custom cursor.

  **finaard**: I didn't read much of the page - just was scrolling a bit to see what the fuck that thing is doing, and that was more than enough to know that I'll never touch whatever those people are doing.

**jFriedensreich**: All these agent memory systems seem so simultaneously over and under engineered and like a certain dead end. I cannot imagine any reality in which this does not rot and get out of sync with what the latest model need. For the one time you build a payment provider how many session will be tilted towards thinking about payments because of the "don't use stripe" memory?

  **stavros**: I've treated this as an information problem and wrote a small utility that explicitly does <i>not</i> store most things (<a href="https://github.com/skorokithakis/gnosis" rel="nofollow">https://github.com/skorokithakis/gnosis</a>). Basically, the premise is that the things the LLM knows will always be there, so store nothing the LLM said, the code will always be there so the code-relevant things should be comments, but there are things that will be neither, and that are never captured.<p>When we create anything, what we ended up <i>not</i> doing is often more important than what we <i>did</i> end up doing. My utility runs at the end of the session and captures all the alternatives we rejected, and the associated rationales, and stores that as system knowledge.<p>Basically, I want to capture all these things that my coworkers know, but that I can't just grep the code for. So far it's worked well, but it's still early.

  **devmor**: I have a bespoke memory system that I wrote myself and it avoids this problem entirely by making every memory a contextual search space. The “don’t use stripe” memory would only be recalled into context if the model was prompted to do something with payment processing.

  **cush**: What's worse is how obvious the author hasn't even used it themselves. Completely unproven memory layer. No due diligence - just a fancy marketing site with outrageous claims

**ting0**: It's not clear to me how or why this works, and how it compares to just using md files in my project. For something like this, we really need benchmarks.

**aprilnya**: I clicked this thinking “oh, cool, someone finally made a portable version of the Claude.ai* memory system!”
 Spoiler, no, it’s not it at all, it’s just a “store”/“remember” memory system… as opposed to the Claude.ai memory system, where it doesn’t make the model actively have to write memories on its own, but rather has a model in the background go through your chat history and generate a summary from it.<p>I’ve found the latter approach to work much, much better than simple “store”/“remember” systems.<p>So, it just feels misleading to say this can do what Claude.ai’s can do…<p>(I’ve been looking for a memory system that works the same for a while, so that I can switch away from Claude.ai to something else like LibreChat, but I just haven’t found any. Might be the only thing keeping me on Claude at this point.)<p>-<p>*I say Claude.ai because that’s specifically what has the system; Claude Code doesn’t have this system

  **kimjune01**: I agree. silent agent doing agentic things async is what would be helpful, not requiring a modification to the main prompt

    **aprilnya**: Yeah. The other advantage is a summary-based memory also just… “pieces together” things that a “store”/“remember” memory wouldn’t, because they’re things that the actual main agent would not think to store. i.e. small disconnected things across conversations that alone, would not end up in memory because they’re insignificant. But when there’s an agent looking at multiple conversations at once it can actually reason about this stuff and piece it together.

  **kuboble**: That's an interesting concept. 
So it's like if you're an agent chatting with a user,  you have an army of assistants who overhear the conversation and record important facts,  or search relevant facts on some database and decide on the fly when to interrupt you with "this memory X looks relevant". Sounds easy enough if tokens were free, but an interesting problem to do it efficiently.

    **eterm**: That's exactly what claude-code does these days. If you AFK for ~5 minutes it also produces a summary of where you are, which is useful if you're juggling multiple windows.

    **mncharity**: Burst-parallel non-frontier models can resemble "tokens were free". And there one might potentially augment not just conversations, but CoT - retroactively by submitting messages with altered reasoning strings, or inline with the inference loop watching CoT and attempting non-distracting injection.

    **jjfoooo4**: Simple vector similarity plus a cheap model to filter results works pretty well. Though ofc t does add tokens to your primary chat, which is the basic tradeoff of memory systems in general (in addition to latency)

  **flippyhead**: I really want to try this approach. I'm curious because this has not been my experience at all. I created <a href="https://github.com/flippyhead/ai-brain" rel="nofollow">https://github.com/flippyhead/ai-brain</a> mostly just for myself and a few friends use it. But so far, telling the AI (via CLAUDE.md) to look for relevant memories and to think about when and how to save them has worked very well. It can create structures based on decided priorities, notes for the future, that feel like they'd be very different if it was just trying to summarize everything.

    **hebetude**: I use Claude code hooks to prompt and store memories. It’s taken a lot of iterations mostly on the definition of “significant” events being stored in memory. Indeed, it works very well now but I’m hesitant to start from scratch on some guys tool. 
I think demos are going to need reviews here on out. Vibe coded projects look too legit but it’s a waste of time to test the 100 that come out each day

      **flippyhead**: I hear you. I've been slowly building up my own tool (linked above) and keep feeling like someone is going to soon release something that a lot of people will agree should be an independent standard. I'm reluctant to host it with someone else so it needs to be opensource. But then again what I've got is working well for me.

    **joemazerino**: The biggest issue for me is recalling during conversation context, not jotting information down. I've solved this by including a tag for when to nudge the agent to recall something.<p>ie: "$recall words"<p>it works but its clunky

  **planet_1649c**: Oh my pi does it. And it does it really well.

  **conception**: Just write a hook that runs claude -p after whatever you want and update whatever memory system you want. You can use a channel to inject back what topics were update or what have you.

    **cortesoft**: I am not sure how using Claude -p is going to help you imitate Claude’s memory system for any ai agent…

    **aprilnya**: Sure, but the idea is not to have this in Claude Code, the idea is to be able to use something like LibreChat with proper memory. I don’t really need that good of a memory system for my coding agent, it’s definitely more something I need for my chat agent.

  **hedgehog**: How do you benchmark that? The problem with extracting memories in the background is it's hard to make that work with the prefix cache. You can go a long way with a simple 2-stage LOG.md (detailed log of tasks & lessons) + MEMORY.md (log items that are promoted when the log itself gets truncated) + a stop hook to ensure this runs at the end of a turn.

  **qznc**: In the recent Claude Code leak, there was apparently something called "autoDream", a "background memory consolidation engine" according to this: <a href="https://kuber.studio/blog/AI/Claude-Code's-Entire-Source-Code-Got-Leaked-via-a-Sourcemap-in-npm,-Let's-Talk-About-it" rel="nofollow">https://kuber.studio/blog/AI/Claude-Code's-Entire-Source-Cod...</a>

  **giancarlostoro**: Which is weird because if I remember correctly, there are summaries already generated by Claude on your hard drive of things you have done in the past.

  **jjfoooo4**: I favor automatic recall, invisible to the agent. For memory creation, I find tool calls do a pretty good job, though I also like automatic memory creation on context compression.<p>I think with automatic creation you need async consolidation (calling it dreaming is a little dramatic for my taste).<p>My implementation is at Elroy.bot, I recently wrote about different approaches to agent memory here: <a href="https://tombedor.dev/approaches-to-agent-memory/" rel="nofollow">https://tombedor.dev/approaches-to-agent-memory/</a>

  **cookiengineer**: Shameless drop: My own agentic environment is also using a summarizer to sum up agent histories when they overflow in their context windows. Additionally, all short lived agents are based on requirements (WIP) as a centralized point for code, unit tests, and architecture.<p>(Everything is tailored to Go as a language)<p>Works pretty good so far, the user only interacts with the planner. I'm working atm on the requirements to have a spec driven workflow. Web UI is the most polished atm because of ability to have agent tabs on the side for better overview.<p>In case anyone is interested in this attempt:<p>[1] <a href="https://github.com/cookiengineer/exocomp" rel="nofollow">https://github.com/cookiengineer/exocomp</a>

**bearjaws**: Wow another day, another memory system for AI agents!<p>How many are we up to now? Has to be hundreds of them.

  **dominotw**: its the todomvc of ai user. i made one for myself too. I try not to tell anyone about it .

**kimjune01**: this is a patch on top of the broken flat-compaction caching algorithm used by coding agents. Why not fix the cache algorithm directly? Union-find is a better impl june.kim/union-find-compaction

**dominotw**: is this backed by a hollywood celebrity ?

**zby**: Reviewed: <a href="https://zby.github.io/commonplace/agent-memory-systems/reviews/stash/" rel="nofollow">https://zby.github.io/commonplace/agent-memory-systems/revie...</a><p>Together with the other hundred llm memory systems: <a href="https://zby.github.io/commonplace/agent-memory-systems/" rel="nofollow">https://zby.github.io/commonplace/agent-memory-systems/</a><p>I have also written a wishlist for these systems: <a href="https://zby.github.io/commonplace/notes/designing-agent-memory-systems/" rel="nofollow">https://zby.github.io/commonplace/notes/designing-agent-memo...</a>

**OsrsNeedsf2P**: I'd like to use this for our locally running game agent[0] but the PostgreSQL and other dependencies is a show stopper. Why so complex?<p>[0] Ziva.sh is a desktop app that brings agentic features to game engines. We can't just bundle a running DB and we won't be sending this sensitive info to a cloud

**cush**: Now that building software is effectively free, it's astounding that we're still trying to pitch things like this using a vibe-coded fancy marketing site. Who has time to use these and wait weeks or months to find out if they actually work? There's no proof in the site this is better than RAG or even a folder of memory files and grep, yet makes all these fantastic claims (while scrolling at 14fps). This wasn't even coded 24 hours ago... It's honestly so lazy.

**Dinuda**: here is a production grade solution I made. I was doing AI courses for kids and this was benifitial to do collab sessions between chatgpt and claude. It also sync's their memory automatically. Check it out: <a href="https://tallei.com" rel="nofollow">https://tallei.com</a>
