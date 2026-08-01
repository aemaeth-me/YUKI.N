# Universal Memory Protocol - a shared format for agent memory

URL: https://news.ycombinator.com/item?id=None
Points: 41 | None comments

---
**OP edihasaj**: https://universalmemoryprotocol.io/

**edihasaj**: AI agents can already use tools and coordinate, but their memory is fragmented across project files, agent notes, local stores, databases, and vendor-specific systems. Move to a new tool and the context is gone.<p>UMP v0.1 is a shared format plus a simple way to read, write, update, and move agent memory across tools. The goal is memory that's user-owned, auditable, and extensible across agents and runtimes, instead of locked inside one vendor.<p>It's early (v0.1) and I'd love feedback on the format and where it breaks down. Repo and spec are linked from the site.

  **0123456789ABCDE**: integration with 3rd parties (mcp, skills) worked because there was no way github/jira type services would support >2 integrations<p>any other <i>feature</i> being compatible between harnesses makes transitioning from one to another too easy<p>so, the only way memory will work, similar to {AGENTS,CLAUDE}.md, is if everyone uses: base path + markdown files

**nullc**: Sorry to be a debbie downer, but this reads like LLM slop rather than engineering work.  I don't just mean the language on the page-- although that too (not an X it's a Y, over and over again)--  but the absence of the artifacts of ActualEngineering(tm) rather than just a flood of vibes.<p>For example, I would expect to see tables or figures showing task success rates on some benchmarks for agents augmented with and without this proposal, perhaps before and after fine tuning, or running against alternatives or to the extent that there are no alternatives against variations of this design that were considered and rejected.<p>Otherwise what reason is there to think that this design is better than some alternative or even any good at all? Perhaps it causes agents to hallucinate like crazy-- who knows if it hasn't been tested.<p>Work like that is what makes efforts like this worth sharing and worth reading about--  anyone can spend a few minutes and ask their favorite LLM to design such a framework and get something that looks "credible".   But in a post LLM world credible alone is externally indistinguishable from anti-social time wasting slop.

**crooked-v**: > Injection-resistant by mandate<p>> Memory is attacker-controllable input. The spec requires a verify, filter, frame rehydration pipeline. Never string-interpolated into the prompt.<p>Uhhh... so who wants to tell them how LLMs work?

**avaer**: This seems way too complicated and unnecessary. Agents are perfectly capable of discovering memories on the FS, following agent instructions.<p>I guess this adds indexing and querying but most coding agents have good solutions for this already, and it works automagically for everything, not just memories.<p>What we could use instead is a file system layout standard, which could subsume memories and a lot more. I don't think that's needed either, but it would probably solve more problems than this.

**lucrbvi**: <a href="https://xkcd.com/927/" rel="nofollow">https://xkcd.com/927/</a>

**fizx**: The ratio of proofreading to grandiosity is impressive.

**aeon_ai**: It is 2026.<p>Average people build their own harnesses, and imagine themselves the pioneers of industry. They propose protocols. They code, feverishly, into the night, driven by their vision for the future.<p>It used to be that 'idea guys' were limited by execution. We now feel the avalanche of these ideas, even maybe executed half-decently, fall upon deaf ears and zero market.

  **spacebacon**: Yes<p><a href="https://github.com/space-bacon/SRT" rel="nofollow">https://github.com/space-bacon/SRT</a><p>I can read any models every thought. No one cares. Not the narrative.

    **Retr0id**: What does it do?

      **spacebacon**: In very simple terms it can provide a full and live audit on how any frozen model arrives to any answer.

        **Retr0id**: What does "frozen model" mean in this context?

          **spacebacon**: A frozen model means the original language models weights are not touched. No fine tuning.

    **skeledrew**: Saw this shared a few days ago, skimmed it, didn't understand it. See it again now, another skim, still don't understand. I think it could use a ELI15 or something.

      **spacebacon**: It’s the babel fish from hitchhikers guide to the galaxy that can also be the pov gun.

    **dang**: I'm afraid we've had to ban this account for the time being. We've been getting complaints from readers that the comments posted by the account are a combination of off-topic and excessively promotional. After looking this over, I agree.<p>I have no idea if this is relevant, but sometimes HN commenters go through phases where they overdo this kind of posting for personal reasons. If that is the case here, then if and when it changes, you'd be welcome to email hn@ycombinator.com and we can look into unbanning your account at that point.

**samdjstephens**: I can see the value in a protocol here, but the issue is these efforts are only as good as the industry adoption that they gain: who is using this?<p>MCP came from Anthropic, A2A from Google so they had big tech backing from day 1.<p>As a developer, I wouldn’t touch this without confidence I can get gains down the line from interoperability.

**evil-olive**: initial commit 2 days ago [0] added 5500 lines in a single shot. shows every sign of being entirely LLM-generated.<p>with apologies to Andy Warhol - in the future, everyone will have a universal protocol for agent memory that is on the HN front page for 15 minutes.<p>0: <a href="https://github.com/edihasaj/universal-memory-protocol/commit/44e03c92b221cd3fda1bced9a88137ce482a79a7" rel="nofollow">https://github.com/edihasaj/universal-memory-protocol/commit...</a>

**fractorial**: I would love to know how many countless others on HN, like me, find themselves reading about a very they have built and have been using for months talked about like it’s a revolutionary new idea.

**maddmann**: People are getting so mentally lazy.

**cpard**: * …tools, UMP does for memory - negotiated operations over a portable, signed, bi-temporal record … *<p>What is a bi-temporal record? I don’t think I’ve heard the term before and I’d love to learn more.

  **msteffen**: IIUC, the most basic version is when you have a log where every entry has both “date added” and “effective date,” so you can add stuff to the log retroactively. For example, “the user just informed us yesterday that they moved last year” -> address date added=yesterday, date effective=last year

    **skeledrew**: I have similar setup in Orgzly (kinda in Emacs too but it's buggy and not not as useful there) where a note has a "created time" property that's always automatically applied. And then there's the "closed time" applied when I set note the state to "done", which I sometimes modify depending on what the note is for and thus what "done" means.

    **cpard**: Thank you!

**bryanlarsen**: How about just a memory dir in your project's git folder?  Agents can run grep just fine.

**up2isomorphism**: I don’t even want a shared agent memory.

**oathvz**: I have not seen a bigger slop of repos and projects

**conception**: You are at stage “Memory Architect”.  <a href="https://delightful-marigold-803f7f.netlify.app/" rel="nofollow">https://delightful-marigold-803f7f.netlify.app/</a>

  **aogaili**: So this page is just to shame people using LLMs and to make you feel better?

    **conception**: More to point out everyone has the same LLM discovery patterns. But none of the methods seems to have observable, measured improvements over the basics and tend to regress back.

      **aogaili**: The tech is barely two years old and people are exploring the usage.<p>I think it's better to keep an open mind instead of claiming to have seen the pattern. Indeed, there is a lot of hype and delusion but there is genuine progress and it's clear as the sun, anyone claiming anything else is equally risky of being delusional at the other end of the spectrum.

      **Garlef**: > everyone has the same LLM discovery patterns<p>there's so much discussion about AI and "everyone" might just be reading the same things.<p>this is a good indication not to treat this particular phrasing of a discovery path as canonical

**slashdave**: Doesn't this just sound like a glorified file system?

**docheinestages**: Why should something like this make it to the front page?

  **aogaili**: Because agent memory is a real issue if you tried to build any agent. But yeah a universal protocol by a small player will not solve it.

**aogaili**: A lot of shaming and negative comments. Mainly people annoyed that this is created with LLM usage. Comments like, the author is grandiose, he/she is delusional, the repo was committed yesterday etc.<p>It seems to be a lot of folks in the community are just lethargic to anything created by LLMs.<p>But regarding the idea itself, the author basically abstracted and use MCP as the server/interface. I worked a bit on the memory issue of agents, and I do understand the pain point. So I just looked at the article as a source of aspiration, another interesting idea etc..before LLMs, the author could have just said in a blog, oh why not have a universal protocol for memory? But now the author can actually do it, try it, share it with others, and for one see this as a progress, it might inspire other people.

  **evil-olive**: > It seems to be a lot of folks in the community are just lethargic to anything created by LLMs.<p>I dislike "overpromise and underdeliver". LLMs can of course be used for other things, but for the type of person who overpromises and underdelivers, LLMs seem to be particularly attractive, and act as a force-multiplier.<p>> before LLMs, the author could have just said in a blog, oh why not have a universal protocol for memory?<p>a blog post would at least have been <i>honest</i>. "here's an idea I had, what do you think?"<p>likewise, a blog post plus a link to a GitHub repo containing a <i>prototype</i> would have been fine, as long as the prototype is clearly labeled as such. "here's an idea I had, plus a sketch of how a concrete implementation might work, what do you think?"<p>what LLMs enable is overpromise-and-underdeliver-as-a-service. this idea could have been a blog post, or a simple prototype, but what we get instead is a fancy-looking website, with its own domain, for this half-baked idea.<p>if you take the polished website at face value, you would be misled into thinking that the idea itself is also polished. hence the comments exercising some critical thinking and pointing out that this "universal protocol"...doesn't actually have any real-world usage, anywhere in the universe.

**Garlef**: Not sure if this is the right abstraction: The recall seems to need a search term.<p>But would it not be more sensible to assume that the full conversation (+ system parts) CAN inform the recall and some neural network picks the right memory bits?<p>So my fear would be that something like this, if adapted, drags the development into a local optimum that is hard/impossible to get out of.
