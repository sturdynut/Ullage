# Claude Code transcript format

**Status: UNVERIFIED against real transcripts.**

This file is supposed to record what was *observed* on disk. It currently
records what the parser *assumes*, because the parser was written on a machine
with no `~/.claude` directory. Nothing here has been checked against a real
session yet, and the format is internal to Claude Code and changes between
versions.

Closing M0 means running the recon script on the Mac that has the transcripts
and editing this file to say what was actually there:

```bash
scripts/recon.sh > docs/observed-$(date +%Y-%m-%d).md
scripts/recon.sh fixture ~/.claude/projects/<dir>/<session>.jsonl
```

**If the disk disagrees with anything below, the disk wins.** Note the
divergence here, fix the parser, and bump `ClaudeCodeParser.version`.

| observed on | Claude Code version | by |
|---|---|---|
| _not yet_ | _unknown_ | — |

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
| `isSidechain` | `is_sidechain` | Subagent turn |
| `durationMs` | `duration_ms` | Not always present |

Thinking tokens are not broken out in Anthropic usage today. `reasoning` is read
from `usage.thinking_tokens` / `usage.reasoning_output_tokens` if either ever
appears, and is otherwise NULL — never estimated.

## The formula

```
context_tokens = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
occupancy      = context_tokens / window_limit
```

All three are prompt tokens. `input_tokens` alone is the remainder that was
neither read from nor written to cache; using it by itself undercounts occupancy
by an order of magnitude on a cached session.

**Still to verify by hand:** run `/context` in a live session and compare it
against `context_tokens` on that session's last assistant entry. The recon
script prints exactly that number. If they disagree, stop and find out why —
this formula is the entire product.

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
`version`, `requestId`, and the file-snapshot entries. The `version` field is
the obvious input to `session_env.claude_version` in M2.5.
