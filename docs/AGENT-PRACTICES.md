# Working with agents: context, skills and subagents

Habits that keep a coding agent's context small, its cache warm and its answers
sharp, and when to reach for a skill or a subagent. Checked against Anthropic's
and OpenAI's docs, practitioner write-ups and published research in October
2026. Harness behaviour changes quickly, so anything tied to a version is dated
here and should be re-checked before it is relied on.

Where Ullage measures the effect of a habit, the habit says where to look.

## The three that matter most

1. **Keep the context small.** Start lean, filter tool output, point the agent
   at exact files, and use subagents only for exploration that should come back
   as a summary.
2. **Don't break the cache.** Pick the model at the start, know how long your
   cache lasts, and compact or clear before a break that outlasts it.
3. **Keep state in files, not the chat.** Plan in a spec file, do one task per
   session, and restart from the file with `/clear`.

Everything below is a case of one of these.

## Context

- Every turn sends the whole context again, so its size is paid on every turn.
  A heavy session is 93–97% cache reads by token count.
- Quality drops with absolute length, from a few thousand tokens on hard tasks
  (RULER, NoLiMa, Chroma's context rot). No study supports a "stay under N% of
  the window" rule; smaller is better well before the window is full.
- Keep CLAUDE.md or AGENTS.md short (Anthropic suggests under 200 lines). Move
  instructions that only apply sometimes into skills.
- Prefer CLI tools like `gh` over MCP servers where both work, and drop servers
  you don't use.
- Filter tool output, for example with a hook that returns only failing tests.
- Name the files, functions and exact errors instead of asking the agent to
  find them.
- Ask side questions with `/btw`, so the answer never enters the context.

In Ullage: the Context page (`ullage composition <session>`) shows what fills
the window, and `ullage env <session>` shows the MCP servers, skills and
CLAUDE.md a session started with.

## Cache

- The cache only reuses the start of the request that matches the previous one:
  tools, then system prompt, then messages. A change early on re-caches
  everything after it.
- A rebuild writes the whole context again at 1.25× (five-minute cache) or 2×
  (one-hour cache) the input price; a cache read costs 0.1× on most models and
  less on the newest.
- In Claude Code, switching model always rebuilds. Turning on fast mode,
  compacting and upgrading Claude Code also rebuild; changing effort rebuilds on
  older models. MCP servers, plugin skills and output styles can change
  mid-session without a rebuild.
- For a cheaper model partway through, use a subagent instead of `/model`.
- Claude Code's cache lasts one hour for the main conversation on a
  subscription, and five minutes on an API key, usage credits, a cloud provider,
  and for subagents. OpenAI's lasts from minutes to 24 hours depending on the
  model.
- Before a break longer than that, compact while the cache is still warm, or
  write a handoff note and `/clear`. Compacting after the cache has expired
  re-reads everything at full price.
- In Codex, keep the model, reasoning effort and tool list stable.

In Ullage: a rebuild is a triangle on the chart, named by its cause (see
[Cache rebuilds](../README.md#cache-rebuilds)); `ullage rebuilds --days 30`
shows how often each cause happens.

## Sessions

- For anything non-trivial, research and plan into a spec file first, then
  implement in a fresh session. Write progress back to the file.
- Run `/clear` between unrelated tasks rather than waiting for auto-compaction.
- Correct early. After two failed corrections, `/clear` and start again with a
  better prompt.
- Use `/rewind` to drop a dead end; it keeps the cache, and compacting does not.
- If you do compact, say what to keep: `/compact keep the plan and the failing
  test`.
- Give the agent a check it can run (tests, a build, a linter), not only a
  description of done.

## Skills

A skill holds **know-how**. Its name and description sit in every request; its
body loads when it is used and then stays in the context of whoever used it.

- Keep descriptions short and specific. All skill descriptions share a budget of
  about 1% of the window, and the description is how the right skill gets
  picked.
- Move occasional instructions out of CLAUDE.md into skills, so they cost a line
  until they are needed.
- Scope by folder. Skills in `apps/web/.claude/skills/` load only once the agent
  reads or edits a file there, so a backend-only session never sees them.
- Set `disable-model-invocation: true` on a skill only you should trigger. Note
  that such a skill cannot be preloaded into a subagent.
- Set `context: fork` (with `agent:`) on a skill whose work is mostly reading,
  so it runs in its own context and returns only its result.

## Agents

An agent is a **place for work to happen**: a separate context with its own
tools, model and permissions. It sees only the brief you give it, and only its
summary comes back.

- **Delegate reading, not writing.** Searches, research, log digging and diff
  review suit an agent: it reads a lot and returns a little. Keep one agent
  writing the code.
- **Build agents around tasks, not roles.** A reviewer, test runner or codebase
  searcher works. A "UI engineer" or "backend engineer" persona doesn't: every
  vendor example is a task, and persona prompts don't measurably improve
  accuracy. Put domain knowledge in skills instead.
- Define a custom agent only once you keep writing the same brief.
- Keep agent descriptions short; they sit in every request like skill
  descriptions do. The body loads only when the agent runs.
- **Write a brief that stands alone:** the goal, the files, the constraints, a
  check it can run, and what to return and how long. Vague briefs cause
  duplicated work and gaps.
- Ask for a distilled result, often 1–2k tokens, never raw output.
- Restrict tools to what the task needs, and use a smaller model for simple
  tasks.
- A fork inherits your conversation and reuses your cache; a fresh subagent
  starts cold. Use a fork when the work needs the same context.
- End with a check that the goal was met. Missing or wrong verification is about
  a quarter of multi-agent failures.

**Don't use an agent for** iterative back-and-forth, steps that depend on each
other, quick targeted edits, or anything where waiting matters.

**What it costs.** About 4× the tokens of chat for one agent, about 15× for a
multi-agent system, and about 7× for agent teams in plan mode. Much of the
measured multi-agent gain is that extra compute: at an equal token budget a
single agent matched or beat multi-agent setups on multi-step reasoning.
Splitting helps on independent branches and hurts on sequential, shared-context
work, which is most coding.

In Ullage: each agent is its own stream on the Agents page
(`ullage agents <session>`), with its own window and its own turns, never
counted as turns of its parent.

## Skill or agent?

| The work | Use |
|---|---|
| Needs your conversation, or the result *is* the work (writing code, iterating on a design) | A skill in the main thread |
| Lots of reading for a small answer (search, audit, reviewing a diff) | An agent, or a skill with `context: fork` |
| Needs different tools, model or permissions | An agent |
| Know-how that several agents need | A skill the agents load |

For example, rather than a "UI engineer" agent: UI skills, scoped to the UI
folder, used in the main thread, plus a "UI reviewer" agent that checks a diff
against the design system and returns only violations.

## Parallel agents

- Give each agent its own git worktree and its own files. Worktrees don't
  separate ports or databases, so give each its own.
- Run only as many as you can review; most people manage two or three.
- Merge one branch at a time and run CI after each. Each branch can pass while
  the combination fails.
- Trust CI output, not the agent's summary. Agents have been seen deleting
  failing tests, and a test command that matched nothing still exited 0.
- Keep security, auth and incident work out of unattended agents.
- Shut down idle teammates and cloud sessions; scheduled tasks and check-ins
  resend the full context even when you aren't typing.

## Where people disagree

- **Compacting.** Some experienced users never compact, because summaries lose
  details, and always restart from a plan file. Compacting before a break is
  cheap while the cache is warm, but `/clear` costs nothing.
- **Subagents.** Critics call them a black box that re-reads code. Both camps
  agree they pay off for a wide search that comes back as a summary.
- **Window targets.** "Stay under 40% of the window" is one practitioner's
  heuristic, not a measured threshold.

## Sources

- Claude Code: [best practices](https://code.claude.com/docs/en/best-practices),
  [costs](https://code.claude.com/docs/en/costs),
  [prompt caching](https://code.claude.com/docs/en/prompt-caching),
  [skills](https://code.claude.com/docs/en/skills),
  [subagents](https://code.claude.com/docs/en/sub-agents),
  [agent teams](https://code.claude.com/docs/en/agent-teams),
  [worktrees](https://code.claude.com/docs/en/worktrees)
- Anthropic: [prompt caching pricing](https://platform.claude.com/docs/en/build-with-claude/prompt-caching),
  [building effective agents](https://www.anthropic.com/engineering/building-effective-agents),
  [multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system),
  [effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- OpenAI: [prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching),
  [Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents.md),
  [Agents SDK multi-agent](https://openai.github.io/openai-agents-python/multi_agent/)
- Practitioners: [Manus](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus),
  [HumanLayer](https://github.com/humanlayer/advanced-context-engineering-for-coding-agents/blob/main/ace-fca.md),
  [Cognition](https://cognition.com/blog/dont-build-multi-agents),
  [Armin Ronacher](https://lucumr.pocoo.org/2025/7/30/things-that-didnt-work/),
  [Simon Willison](https://simonwillison.net/2025/Oct/5/parallel-coding-agents/),
  [Mario Zechner](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/)
- Research: [RULER](https://arxiv.org/abs/2404.06654),
  [NoLiMa](https://arxiv.org/abs/2502.05167),
  [context rot](https://www.trychroma.com/research/context-rot),
  [multi-agent failures (MAST)](https://arxiv.org/abs/2503.13657),
  [180-configuration multi-agent study](https://arxiv.org/abs/2512.08296),
  [single vs multi-agent at equal tokens](https://arxiv.org/abs/2604.02460),
  [personas and accuracy](https://arxiv.org/abs/2311.10054)
