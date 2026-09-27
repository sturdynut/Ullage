# Claude Code transcript format

**Status: checked against 264 real transcripts on 2026-09-12** (Claude Code
2.1.270). Everything below matched the disk except the two items under
"Divergences found", both fixed in parser version 2. The format is internal to
Claude Code and changes between versions, so re-run the recon after upgrades:

```bash
scripts/recon.sh > docs/observed-$(date +%Y-%m-%d).md
scripts/recon.sh fixture ~/.claude/projects/<dir>/<session>.jsonl
```

**If the disk disagrees with anything below, the disk wins.** Note the
divergence here, fix the parser, and bump `ClaudeCodeParser.version`.

| observed on | Claude Code version | by |
|---|---|---|
| 2026-09-12 | 2.1.270 | Matti Salokangas, 264 transcripts / 96 sessions |
| 2026-09-13 | 2.1.x | Subagents: 23 subagent transcripts / 23 sidecars, see "Subagents" |

## Divergences found (2026-09-12)

1. **Window limits.** Every Claude 5 model id arrives *without* a `[1m]`
   suffix on `message.model`, and the lookup table had no Claude 5 entries, so
   every session on this machine fell to the 200k fallback and showed 200-470%
   occupancy. The disk proves the plain ids run a 1M window — see "Window
   limits" below. Table updated.
2. **Thinking tokens are broken out** after all, at
   `message.usage.output_tokens_details.thinking_tokens` (not at the two
   top-level names the parser looked for). Parser now reads it. Not present on
   every entry (older `claude-fable-5` entries lack `output_tokens_details`).

Also observed, no change needed:

- **The same `message.id` appears 2-4 times** as consecutive assistant lines
  (one per streamed content block) with identical `usage`. The `dedupe_key`
  upsert collapses them: 41,437 parsed lines became 15,068 `call` rows.
- `usage` also carries `cache_creation.ephemeral_1h_input_tokens` /
  `ephemeral_5m_input_tokens`, `iterations[]`, `speed`, `inference_geo`, and
  `server_tool_use.web_fetch_requests`. None are stored yet.
- Line types seen that the parser skips: `attachment`, `permission-mode`,
  `mode`, `bridge-session`, `atis-latch`, `last-prompt`, `ai-title`,
  `custom-title`, `agent-name`, `pr-link`, `frame-link`, `queue-operation`,
  `file-history-snapshot`, `file-history-delta`, `artifact-autoreact-ledger`,
  `artifact-comment-monitor`, `cost-state`. `system` subtypes seen:
  `turn_duration`, `stop_hook_summary`, `away_summary`, `compact_boundary`.
- `cost-state` (present in 15 sessions) carries a per-model `modelUsage`
  rollup keyed by the *configured* id, which is where a `[1m]` suffix shows up
  if one is in effect. Candidate cross-check for the totals later.
- Assistant entries also carry `effort`, `entrypoint`, `requestId`,
  `session_id` (duplicate of `sessionId`), `userType`.
- Subagent transcripts live one level down:
  `<session>/subagents/agent-<id>.jsonl`.

---

## Location

```
~/.claude/projects/<sanitized-cwd>/<session-id>.jsonl
```

`<sanitized-cwd>` is the working directory with every non-alphanumeric
character replaced by `-`, truncated to 200 characters with a hash appended if
longer (`ClaudePaths.sanitize(cwd:)`). Ingestion never needs to reverse it: the
`cwd` field on each entry is authoritative and is what the `project` column
comes from.

`CLAUDE_CONFIG_DIR` overrides `~/.claude`. `CLAUDE_CONFIG_DIRS` (colon-
delimited, multiple roots) also exists upstream; it is out of scope for v1, but
`ClaudePaths.configDirectories` already returns a list so adding it is not a
redesign.

## Subagents (2026-09-13)

A subagent is **not** a turn of the session that spawned it. It has its own
context window, starting empty, and Claude Code writes it to its own file:

```
~/.claude/projects/<sanitized-cwd>/<session-id>/subagents/agent-<agentId>.jsonl
~/.claude/projects/<sanitized-cwd>/<session-id>/subagents/agent-<agentId>.meta.json
```

Every line in that file carries the **parent's** `sessionId`, so a parser that
keys on session alone merges four concurrent windows into one series: turn
numbering interleaves and deltas are taken between prompts that never followed
each other (observed: deltas of −56,331 in a real session). The stream key is
`(sessionId, agentId)`, and `agentId` is NULL for the main thread.

Fields that only appear on subagent lines:

| Field | Column | Notes |
|---|---|---|
| `agentId` | `call.agent_id`, `event.agent_id` | On *every* line of the file. The stream key |
| `attributionAgent` | `call.agent` | The agent's type: `Explore`, `general-purpose`, … |
| `isSidechain: true` | `is_sidechain` | Also set on older inline sidechain lines |

The `.meta.json` sidecar is four keys and is the best source of identity,
because it survives a parent transcript that has aged out, a background agent
whose result never reported completion, and a forked session that replays the
spawn under a different session id:

```json
{"agentType":"general-purpose","description":"Generate UI via claude CLI",
 "toolUseId":"toolu_01WCf4AXqWoUx6DA3JJ4LVxN","spawnDepth":1}
```

`description` is the label the spawning agent wrote — the only human-readable
name an agent has.

### The spawn, from the parent's side

The spawning tool is `Agent` (it was `Task`; both appear on disk depending on
the version). Its input is `{description, subagent_type, prompt}`. The
`tool_result` line for it carries a sibling `toolUseResult` object naming the
child exactly:

```json
{"status":"completed","agentId":"a86066d140435af09","agentType":"Explore",
 "resolvedModel":"claude-opus-5[1m]","totalDurationMs":161328,
 "totalTokens":68593,"totalToolUseCount":40,"usage":{…},"toolStats":{…}}
```

- `agentId` is the exact join to the child's transcript. No heuristics needed.
- `status` is `completed`, or `async_launched` for an agent started in the
  background — 21 of 23 observed spawns were `async_launched`, and those carry
  no totals at all, so an agent's own rows are the only measurement of it.
- `totalTokens` is **one turn's four counters summed** (1 + 3,623 + 60,066 +
  4,903 = 68,593 for the entry above). It is a cache-read number in disguise and
  is deliberately not stored.
- The agent that spawned an agent is whichever stream made the `Agent` call, so
  nesting resolves through `tool_call` → `call.agent_id` with no extra format
  support. Observed depth on this machine: 1. `spawnDepth` in the sidecar says
  the format expects more.

## Line format

One JSON object per line, appended as the session runs. The last line of a live
file is routinely a partial write.

Types the parser acts on:

| `type` | Handling |
|---|---|
| `assistant` | One `call` row, plus one `tool_call` row per `tool_use` block |
| `user` | `tool_result` blocks are joined back onto their `tool_call`; plain prompts are ignored |
| `summary` | One `event` row (`kind = 'summary'`). Carries **no `sessionId`** — the filename stem is used |
| `system` with `subtype: "compact_boundary"` | One `event` row (`kind = 'compaction'`) |

Any entry carrying `compactMetadata` or `isCompactSummary: true` is also treated
as a compaction boundary, since which of the three shapes appears depends on the
Claude Code version.

Everything else — `file-history-snapshot`, hook output, and whatever gets added
next — is skipped silently. Unknown types are expected, not errors.

## Fields used on an assistant entry

| Field | Column | Notes |
|---|---|---|
| `message.id` | `dedupe_key` | `msg_...`. No id, no row: double-counting is worse than dropping |
| `message.model` | `model` | Window-limit lookup key |
| `message.usage.input_tokens` | `input` | Uncached prompt remainder only |
| `message.usage.cache_creation_input_tokens` | `cache_write` | Prompt tokens written to cache |
| `message.usage.cache_read_input_tokens` | `cache_read` | Prompt tokens served from cache |
| `message.usage.output_tokens` | `output` | Mid-stream snapshot, undercounts — see below |
| `message.usage.service_tier` | `service_tier` | For pricing later |
| `message.usage.server_tool_use.web_search_requests` | `web_search` | |
| `message.stop_reason` | `stop_reason` | |
| `timestamp` | `ts` | ISO 8601, normalised to UTC with milliseconds so `ORDER BY ts` is correct |
| `sessionId` | `session_id` | |
| `cwd` | `cwd`, `project` | `project` is the basename |
| `uuid`, `parentUuid` | `uuid`, `parent_uuid` | Stored for fork detection later |
| `isSidechain` | `is_sidechain` | Subagent turn — see "Subagents" |
| `agentId` | `agent_id` | Subagent lines only; the context-stream key |
| `attributionAgent` | `agent` | Subagent type, e.g. `Explore` |
| `durationMs` | `duration_ms` | Not always present |

Thinking tokens: `reasoning` is read from
`usage.output_tokens_details.thinking_tokens` (observed 2026-09-12), falling
back to `usage.thinking_tokens` / `usage.reasoning_output_tokens`, and is
otherwise NULL — never estimated.

## The formula

```
context_tokens = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
occupancy      = context_tokens / window_limit
```

All three are prompt tokens. `input_tokens` alone is the remainder that was
neither read from nor written to cache; using it by itself undercounts occupancy
by an order of magnitude on a cached session.

**Verified by hand 2026-09-12** (Claude Code 2.1.270, `claude-fable-5-1`):
`/context` reported `129.1k/1m tokens (13%)` while the menu bar showed
`129,096 / 1,000,000` for the same turn. The formula matches `/context` to the
token. Re-check after Claude Code upgrades: the recon script prints exactly
this number for the newest transcript.

## Window limits

`message.model` is the id the API echoed back, which never carries Claude
Code's `[1m]` selector. On 2026-09-12 the peak `context_tokens` per model id
across all 264 transcripts was:

| model id (as on disk) | calls | calls > 200k | peak context_tokens |
|---|---|---|---|
| `claude-opus-5` | 19,898 | 12,385 | 999,246 |
| `claude-fable-5-1` | 2,866 | 794 | 940,662 |
| `claude-fable-5` | 2,819 | 2,237 | 765,894 |
| `claude-sonnet-5` | 610 | 414 | 494,429 |
| `claude-opus-4-8` | 1,231 | 335 | 384,906 |
| `claude-haiku-4-5-20251001` | 60 | 0 | 37,025 |
| `claude-sonnet-4-6` | 4 | 0 | 23,434 |

28 sessions exceeded 200k; 25 of them have no `[1m]` anywhere in their
`cost-state.modelUsage`, and one `cost-state` lists `claude-opus-5` and
`claude-opus-5[1m]` as *separate* entries with 1.1 billion cache-read tokens
under the plain one. So on this build the plain Claude 5 ids (and opus-4-8)
already mean a 1M window; `WindowLimits.table` says so. `claude-sonnet-4-6`
never went past 200k here and is left unlisted (fallback, flagged "assumed").

## Traps encoded in the parser

1. **Cache reads dominate.** The four counters stay separate in the schema
   forever. Any single "total tokens" number is, in practice, a cache-read
   number.
2. **`output_tokens` is a mid-stream snapshot** and can undercount real output
   by roughly 2x; the same `message.id` may reappear with a larger value. The
   upsert takes `MAX(existing, incoming)` for output only. No correction factor
   is applied anywhere — what was reported is what is stored.
3. **The format is not a contract.** Every field access is guarded, missing
   counters default to 0, malformed lines are counted and skipped.
4. **Subagents.** Everything rolls into the parent session's totals and `agent`
   stays NULL, but `is_sidechain` is recorded so splitting them later is a query
   change, not a re-ingest.

## Fields deliberately not parsed yet

`toolUseResult` (the structured mirror of a tool result), `gitBranch`,
`requestId`, and the file-snapshot entries. `version` is read, but it is not a
`call` column: it goes to `session_env.claude_version`.

## Configuration captured alongside the transcript

`session_env` is filled from the filesystem, not from the transcript, on first
sight of a session: `mcpServers` names from `~/.claude.json`, `settings.json`,
`.mcp.json` and the project's `.claude/settings*.json`; skill directory names
that contain a `SKILL.md`; and `CLAUDE.md` from user memory plus every level
from the outermost project directory down to the cwd, with `@path` imports
expanded inline (depth-bounded, cycle-safe). A line is treated as an import only
when it is exactly `@path` — an email address or a mention inside prose is left
alone.

## Plan limits (2026-09-23)

Subscription limits, reported as percentages used. Neither harness states a
limit in tokens.

**Codex** writes them into the rollout on every `event_msg` / `token_count`
line, beside `info` (which can be null on these lines):

```json
"rate_limits": {
  "limit_id": "codex", "limit_name": null,
  "primary":   {"used_percent": 9.0,  "window_minutes": 300,   "resets_at": 1790146000},
  "secondary": {"used_percent": 68.0, "window_minutes": 10080, "resets_at": 1790416067},
  "credits": {"has_credits": false, "unlimited": false, "balance": "0"},
  "plan_type": "plus", "rate_limit_reached_type": null
}
```

`resets_at` is epoch seconds. A second `limit_id` (seen: `base_model_inference`,
named `gpt-reserve`) is a per-model allowance with its own primary/secondary.
Older rollouts (2025-12) have the same shape with `limit_id: null`.

**Claude Code** records nothing about limits in transcripts until one is hit;
then a synthetic assistant line (`model: "<synthetic>"`, `error: "rate_limit"`,
`apiErrorStatus: 429`) carries
`quotaLimits: {status: "rejected", resetsAt: <epoch s>, rateLimitType: "seven_day_overage_included", ...}`.
Not parsed yet.

Live figures come from `GET https://api.anthropic.com/api/oauth/usage` with
`Authorization: Bearer <claudeAiOauth.accessToken>` and
`anthropic-beta: oauth-2025-04-20` — what `/usage` calls (Claude Code 2.1.280).
The token lives in the Keychain item `Claude Code-credentials` (JSON:
`claudeAiOauth.{accessToken, refreshToken, expiresAt (ms), subscriptionType}`),
or `~/.claude/.credentials.json` where there is no Keychain. The body:

```json
{
  "five_hour": {"utilization": 73.0, "resets_at": "2026-09-23T06:50:00.313012+00:00", ...},
  "seven_day": {"utilization": 29.0, "resets_at": "2026-09-28T08:00:00.313033+00:00", ...},
  "seven_day_opus": null, "seven_day_sonnet": null, "<code-named keys>": ...,
  "limits": [
    {"kind": "session",       "group": "session", "percent": 73, "resets_at": "...", "scope": null, "is_active": true},
    {"kind": "weekly_all",    "group": "weekly",  "percent": 29, "resets_at": "...", "scope": null},
    {"kind": "weekly_scoped", "group": "weekly",  "percent": 42, "resets_at": "...",
     "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
  ],
  "extra_usage": {...}, "spend": {...}, "seven_day_breakdown": {...}
}
```

`limits` is parsed; the top-level windows are the fallback. `utilization` and
`percent` are 0–100. Code-named keys (`nimbus_quill`, `tangelo`, …) are ignored.

