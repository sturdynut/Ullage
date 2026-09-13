# Agent Telemetry — Tracer Bullet Build Plan

**Handoff spec.** You are building the first vertical slice of a macOS menu bar app that shows AI coding agent token and context usage. This document is the complete brief. Read all of it before writing code.

---

## 1. Definition of done

A menu bar item that displays the live context-window occupancy of the most recently active Claude Code session, as a percentage, updating within ~2 seconds of a turn completing — with every underlying API call persisted as a row in a local SQLite database.

That is the whole tracer bullet. It is end-to-end: file watch → parse → persist → render. Nothing is stubbed, but almost everything is narrow.

**Acceptance:** open a Claude Code session, work in it for a few turns, run `/context` inside Claude Code, and compare. The menu bar number should track it. If it does, the slice is done.

---

## 1a. Do this before anything else

Claude Code deletes session transcripts older than `cleanupPeriodDays` at startup. **The default is 30 days, deletion is silent, and pruned sessions are unrecoverable.**

Set this in `~/.claude/settings.json` right now:

```json
{ "cleanupPeriodDays": 3650 }
```

Two consequences for this project:

1. Every day without a backfill is a day of history that quietly ages out. Backfill is a real milestone (M2.5), not a nice-to-have.
2. Once this app ingests reliably, it becomes the durable archive — the database outlives the source files. That raises the bar on parser correctness: a bug that drops rows is losing data that no longer exists anywhere else.

---

## 2. Non-goals

The v1 tracer bullet (M0–M4) deliberately shipped none of these. Items now
**done** in later slices are marked; the rest remain out of scope.

- Any vendor other than Claude Code (Codex is next, Cursor is third) — still out
- Cost or pricing calculation of any kind — still out
- Charts, sparklines, time-series views — **done (M5 context-per-turn, M6 history)**
- Context *composition* drill-down (what's in the window — the marquee feature) — **done (M7)**
- Multi-session UI, tabs, or a popover — **done (M5 popover + picker, M6 history window)**
- Packaging, code signing, notarization, auto-update — partial: `scripts/install-app.sh`
  ad-hoc signs a local bundle; no notarization or auto-update
- Compaction handling — **done** (events marked, deltas nulled across boundaries,
  composition restarts at the summary); forked-session reconciliation still out

The v1 rule still holds for what remains: persist enough data that they become
additive later, render almost none of it.

---

## 3. Stack

**Single Swift process.** SwiftUI `MenuBarExtra` for the UI, `FSEventStream` for file watching, SQLite for storage (GRDB.swift is fine; the raw C API is also fine).

Rationale: no IPC, no second runtime, no launch-agent plumbing for v1. FSEvents is native. The whole thing is one `.app` you can run from Xcode.

**Escape hatch, do not build yet:** when vendor #3 arrives, the collector will likely want to split into a separate daemon. Keep parsing logic in its own module with no UI imports so that extraction is mechanical.

Minimum target: macOS 14.

---

## 4. Step 0 — Reconnaissance (do this first, before any code)

**The file format described below is internal to Claude Code and changes between versions.** Anthropic's own documentation says scripts that parse these files directly can break on any release. Treat everything in section 5 as a hypothesis to confirm, not as fact.

Before writing the parser:

```bash
ls ~/.claude/projects/
# pick the most recently modified project dir, then the largest .jsonl in it

# What line types exist?
jq -r '.type' < SESSION.jsonl | sort | uniq -c

# What does an assistant entry actually look like?
jq -c 'select(.type == "assistant")' < SESSION.jsonl | head -3

# Where does usage live and what are the exact key names?
jq -c 'select(.type == "assistant") | .message.usage' < SESSION.jsonl | head -5
```

Then:

1. Copy 2–3 real session files into `Tests/Fixtures/` (scrub anything sensitive — prompts and file contents are in there).
2. Write down the field names you actually observed in `docs/OBSERVED-FORMAT.md`, with the Claude Code version you observed them on (`claude --version`).
3. If anything below contradicts what you see on disk, **the disk wins.** Note the divergence and proceed.

---

## 5. Data source contract

### Location

```
~/.claude/projects/<sanitized-cwd>/<session-id>.jsonl
```

`<sanitized-cwd>` is the working directory path with non-alphanumeric characters replaced by `-`. If that exceeds 200 characters it is truncated to 200 with a hash of the full path appended.

Honor the `CLAUDE_CONFIG_DIR` environment variable if set; default to `~/.claude`. (`CLAUDE_CONFIG_DIRS`, a colon-delimited multi-directory variant, exists too — out of scope for v1, but don't design it out.)

### Line format

One JSON object per line, appended as the session runs. Line types include assistant messages, user messages, tool results, compaction boundaries, summary insertions, hook output, and file snapshots. **You only care about `type == "assistant"` for v1.** Skip everything else silently — do not throw on unknown types, new ones get added.

### The fields you need

Expected shape on an assistant entry (confirm in step 0):

| Field | Purpose |
|---|---|
| `message.id` | API message ID (`msg_...`). Your dedupe key. |
| `message.model` | Model string, for window-limit lookup. |
| `message.usage.input_tokens` | Uncached prompt tokens. |
| `message.usage.cache_creation_input_tokens` | Prompt tokens written to cache. |
| `message.usage.cache_read_input_tokens` | Prompt tokens served from cache. |
| `message.usage.output_tokens` | Generated tokens. **See trap 2.** |
| `timestamp` | ISO 8601. |
| `sessionId` | Session identifier. |
| `cwd` | Working directory — use this for the project label, not the sanitized dirname. |
| `uuid` / `parentUuid` | Message threading. Store them; you'll want them for fork detection later. |

---

## 6. The one formula that matters

```
context_tokens = input_tokens
               + cache_creation_input_tokens
               + cache_read_input_tokens
```

All three are prompt tokens. `input_tokens` is only the remainder that was neither read from nor written to cache — using it alone will undercount occupancy by an order of magnitude on a cached session.

```
occupancy = context_tokens / window_limit
```

**Verify this empirically in step 0 or immediately after.** Run `/context` in a live Claude Code session and compare against the sum from the last assistant entry in that session's JSONL. If they disagree, figure out why before building the UI on top of it. This formula is the entire product; get it right.

### Window limits

Small lookup table keyed by model string, with a default fallback of 200,000 and a longest-prefix match so unknown point releases still resolve. Do not hardcode a single constant — some models have much larger windows, and picking wrong makes the headline number silently wrong.

---

## 7. Schema

```sql
CREATE TABLE call (
  dedupe_key       TEXT PRIMARY KEY,   -- message.id
  ts               TEXT NOT NULL,      -- ISO 8601 UTC
  vendor           TEXT NOT NULL,      -- 'claude-code'
  agent            TEXT,               -- subagent name, NULL for main thread
  session_id       TEXT NOT NULL,
  project          TEXT,               -- basename of cwd
  cwd              TEXT,
  model            TEXT,
  input            INTEGER NOT NULL DEFAULT 0,
  output           INTEGER NOT NULL DEFAULT 0,
  cache_read       INTEGER NOT NULL DEFAULT 0,
  cache_write      INTEGER NOT NULL DEFAULT 0,
  reasoning        INTEGER,            -- thinking tokens where broken out
  web_search       INTEGER,            -- server_tool_use counts, if present
  context_tokens   INTEGER NOT NULL,   -- computed, section 6
  window_limit     INTEGER,
  turn_index       INTEGER,
  context_delta    INTEGER,            -- context_tokens minus previous turn's
  service_tier     TEXT,               -- affects pricing later
  stop_reason      TEXT,
  duration_ms      INTEGER,            -- if present on the entry
  is_sidechain     INTEGER,            -- subagent turn
  uuid             TEXT,
  parent_uuid      TEXT,
  source_file      TEXT NOT NULL,
  confidence       TEXT NOT NULL,      -- 'exact' | 'estimated' | 'cumulative'
  parser_version   INTEGER NOT NULL
);

CREATE INDEX call_ts        ON call(ts);
CREATE INDEX call_session   ON call(session_id, ts);

CREATE TABLE tool_call (
  id             TEXT PRIMARY KEY,     -- tool_use block id
  call_id        TEXT NOT NULL REFERENCES call(dedupe_key),
  session_id     TEXT NOT NULL,
  ts             TEXT NOT NULL,
  name           TEXT NOT NULL,        -- Read, Edit, Bash, Task, Skill, mcp__x__y
  kind           TEXT NOT NULL,        -- 'builtin' | 'mcp' | 'skill' | 'agent'
  mcp_server     TEXT,                 -- parsed from mcp__<server>__<tool>
  target         TEXT,                 -- file path, command, subagent name
  result_tokens  INTEGER,              -- estimated size of the tool_result
  is_error       INTEGER,
  parser_version INTEGER NOT NULL
);

CREATE INDEX tool_call_session ON tool_call(session_id, ts);
CREATE INDEX tool_call_name    ON tool_call(name);

CREATE TABLE event (
  id           TEXT PRIMARY KEY,
  session_id   TEXT NOT NULL,
  ts           TEXT NOT NULL,
  kind         TEXT NOT NULL,   -- 'compaction' | 'summary' | 'clear' | 'session_start'
  detail       TEXT             -- raw JSON, decide the shape later
);

CREATE INDEX event_session ON event(session_id, ts);

CREATE TABLE session_env (
  session_id      TEXT PRIMARY KEY,
  captured_at     TEXT NOT NULL,
  claude_version  TEXT,
  mcp_servers     TEXT,   -- JSON array of configured server names
  skills          TEXT,   -- JSON array of available skill names
  claude_md_hash  TEXT,
  claude_md_bytes INTEGER,
  claude_md_body  TEXT    -- full text, imports expanded
);

CREATE TABLE file_cursor (
  path         TEXT PRIMARY KEY,
  inode        INTEGER NOT NULL,
  byte_offset  INTEGER NOT NULL,
  size         INTEGER NOT NULL,
  mtime        REAL NOT NULL
);
```

Store at `~/Library/Application Support/<bundle-id>/telemetry.db`. Enable WAL mode.

### Why the extra tables exist now

Everything in `call` and `tool_call` is backfillable from the transcripts — as long as the transcripts still exist (section 1a). Getting these fields slightly wrong is recoverable: fix the parser, re-ingest.

**`session_env` is the exception, and it is the most important table in this schema.** Nothing on disk records which MCP servers were configured, which skills existed, or what `CLAUDE.md` said at the time a session ran. That state mutates constantly and leaves no history. A month from now you cannot reconstruct why a session in September carried 40k of tool schemas — unless you snapshot it as you go.

This is the denominator for the entire ghost-token analysis: MCP definitions and `CLAUDE.md` ride in the prompt on every single turn whether or not anything invokes them. Without `session_env` you can measure that a session was heavy; with it you can say what made it heavy.

Snapshot on first sight of a new `session_id`. Dedupe by `claude_md_hash` if storage becomes a concern — but it won't, this is kilobytes.

**`context_delta`** is `context_tokens` minus the previous turn's, within the session. You cannot split a prompt blob by tool, but you can attribute the *change*: this turn added 14k and this turn ran one Read. That's the cheapest useful attribution available and it needs no tokenizer of your own. Compute it at ingest, ordered by `turn_index`, and null it on the first turn of a session and after any compaction event.

**`event`** exists so occupancy charts don't look broken. When compaction fires, `context_tokens` drops off a cliff between adjacent turns. Without a marker, that reads as a bug. With one, it's the single most interesting thing on the timeline — it's the answer to "why did it forget?"

### Fields that carry weight beyond v1

These must not be dropped as "unused":

- **`dedupe_key`** — JSONL is append-only and forked sessions replay parent events. Without this you will double-count. Use `INSERT ... ON CONFLICT(dedupe_key) DO UPDATE` so the last write for a message ID wins (see trap 2).
- **`confidence`** — every Claude Code row is `'exact'`. This column exists so that when Cursor arrives, its estimated figures cannot silently contaminate a total. Adding it later means backfilling every row.
- **`parser_version`** — bump on every parser change. When the upstream format shifts, this tells you which rows to distrust.

---

## 8. Components

### 8.1 `SessionTailer`

Watches the projects directory tree with `FSEventStreamCreate` (`kFSEventStreamCreateFlagFileEvents`, latency ~0.3s).

On an event for a `.jsonl` path:
1. Look up `file_cursor` by path.
2. If no cursor, or `stat.st_ino` differs from stored inode, or current `size < stored byte_offset` → the file is new, rotated, or truncated. Read from offset 0.
3. Otherwise seek to `byte_offset` and read forward.
4. Parse only complete lines. **A trailing partial line is normal** — Claude Code is mid-write. Do not advance the cursor past the last newline you actually consumed.
5. Update the cursor in the same transaction as the inserted rows.

Debounce: coalesce events per path over ~250ms.

### 8.2 `ClaudeCodeParser`

Pure function: `(lineData, sourceFile) -> ParsedLine?` where `ParsedLine` is one of a call (with its tool calls), a tool result, or an event.

- Never throw on malformed JSON or unknown fields — log and skip. A single bad line must not stop ingestion.
- Compute `context_tokens` here. `context_delta` is computed at insert time, since it needs the previous row.

**Tool calls.** Assistant entries carry `tool_use` blocks in `message.content`. Emit one `tool_call` row per block. Classify `kind` by name: `mcp__<server>__<tool>` is MCP (parse the server out of the middle segment), the Skill tool is a skill, Task is an agent spawn, everything else is builtin.

**Tool results.** These land on a *later* `type: "user"` entry, matched to the invocation by tool_use id. This cross-line join is the genuinely awkward part of the parser and the reason to build it in M1 rather than bolt it on. Keep a bounded in-memory map of pending tool_use ids while ingesting a file; write `result_tokens` and `is_error` back on match.

`result_tokens` is a length-based estimate, not a real count — a Read of a large file is where context actually goes, and this is the only handle on it. Mark it as an estimate in your own head; it does not get a `confidence` column because it is always estimated.

### 8.3 `Store`

Thin SQLite wrapper. Two writes (upsert calls, update cursor) and one read:

```sql
SELECT context_tokens, window_limit, session_id, model, ts
FROM call
WHERE ts = (SELECT MAX(ts) FROM call)
LIMIT 1;
```

That single row drives the entire v1 UI.

### 8.4 `MenuBarExtra`

Title only, no popover. Format: `72%`, or `72% ⚠︎` above 85%.

If no call has been seen in the last 30 minutes, show a dimmed idle glyph rather than a stale percentage. A number that looks live but is four hours old is worse than no number.

---

## 9. Traps

These are known and will cost you a day each if you meet them cold.

**1. Cache reads dominate everything.** A heavy session can be ~99% cache reads — billions of cache-read tokens against millions of input and output. Any chart or total that sums the four counters into one number is, in practice, a cache-read chart. Not a v1 problem because v1 shows occupancy, not totals. It becomes the central problem the moment anyone adds a "total tokens" display, so keep the four counters separate in the schema forever.

**2. `output_tokens` is a mid-stream snapshot.** There is a known bug where the JSONL never records a final `message_stop` event, so `output_tokens` reflects a partial state and undercounts real output by roughly 2x. Multiple lines may carry the same `message.id` with increasing values. Mitigation: upsert on `dedupe_key` so the highest/last value wins, and treat output as unreliable. **Do not invent a correction factor.** Store what was reported. This does not affect v1's headline number, which is prompt-side only.

**3. The format is not a contract.** See step 0. Guard every field access, default missing counters to 0, and fail soft.

**4. Subagents.** `Task`-spawned subagents may write their own entries or their own files. For v1, count everything into the same session totals and leave `agent` NULL. Just don't build anything that assumes one session equals one thread.

**5. Sandbox and permissions.** Reading `~/.claude` from a sandboxed app requires entitlements. For v1, run unsandboxed from Xcode. Note it as a packaging task; don't solve it now.

---

## 10. Build order

| # | Milestone | Done when |
|---|---|---|
| M0 | Reconnaissance + `cleanupPeriodDays` set | `docs/OBSERVED-FORMAT.md` written, fixtures committed |
| M1 | Parser + schema, incl. tool calls and the tool_result join | Unit test parses a fixture and asserts exact token sums and tool-call counts |
| M2 | Ingest CLI | A debug command ingests a directory and prints per-session totals |
| M2.5 | Backfill + `session_env` snapshot | Every existing transcript on disk is in the database |
| M3 | Tailer | Appending to a file mid-run produces new rows without re-reading the file |
| M4 | Menu bar | Live percentage tracks `/context` in a real session |

M1 and M2 are where the real risk lives. M2.5 is time-sensitive for the reason in section 1a. M4 is an afternoon.

Note that M1 through M2.5 have no UI at all. Resist the urge to reorder — a menu bar showing a wrong number is harder to debug than a CLI printing one.

---

## 11. Tests

- **Fixture parse** — known file in, asserted row count and per-counter sums out.
- **Idempotency** — ingest the same file twice, assert row count is unchanged. This is the single most important test in the suite.
- **Partial line** — feed a file whose last line is truncated mid-JSON; assert no row is emitted for it and the cursor does not advance past it. Then append the remainder and assert the row appears.
- **Rotation** — truncate a watched file; assert re-read from zero rather than silent stall.
- **Unknown line type** — inject a line with a `type` value the parser has never seen; assert it is skipped and ingestion continues.
- **Tool result join** — a fixture where the `tool_result` lands several lines after the `tool_use`; assert `result_tokens` is populated. Then a fixture where the result never arrives (session killed mid-tool); assert the row still exists with a null result rather than being dropped or blocking ingestion.
- **MCP name parsing** — `mcp__github__create_issue` classifies as kind `mcp` with server `github`.
- **Ground truth** — manual, but required before calling M4 done: compare against `/context` in a live session.

---

## 12. Questions for the human before M4

1. With 3–5 parallel sessions running, should the menu bar show the max occupancy, the most recently active session, or a stacked glyph?
2. Should `Task`-spawned subagent usage roll into the parent session or be tracked separately?
3. What counts as "active" for the idle timeout — 30 minutes is a guess.

Don't block on these. Default to most-recently-active, roll subagents into the parent, 30 minutes.

---

## 13. Prior art worth 30 minutes

CodeBurn (`npx codeburn`) reads the same files and ships a Swift menu bar app. Its `src/providers/claude.ts` is a working reference implementation of the parsing described here, and `codeburn context` does the composition drill-down that is this project's eventual differentiator.

Read it for the edge cases. Do not copy code — the licensing and the architecture both point elsewhere — but every quirk it handles is a quirk that is real.
