# Pi (`pi`)

Pi is the `coding-agent` package of [badlogic/pi-mono](https://github.com/badlogic/pi-mono).
Parser: `Sources/UllageCore/Harnesses/Pi.swift` (`PiParser`, version 1).

**Verified on disk: no.** No Pi data on this Mac. The format is read from
Pi's own writer and docs (pi-mono `main`, cloned 2026-10-04). Paths below are
relative to that repo.

## Where it stores data

`~/.pi/agent/sessions/--<cwd-slug>--/<timestamp>_<session-id>.jsonl`, one
append-only JSONL file per session (`packages/coding-agent/docs/session-format.md:8-14`).

- `PI_CODING_AGENT_DIR` moves `~/.pi/agent`, and sessions sit in `sessions/`
  under it (`src/config.ts:545-546`, `566-571`, `610-611`).
- `PI_CODING_AGENT_SESSION_DIR` moves the sessions folder itself
  (`docs/environment-variables.md:82`). Ullage honours both, with this one first.
- `--session-dir` and the `sessionDir` setting are not followed. They apply per
  run, and a relative `sessionDir` is resolved against each cwd
  (`docs/settings.md:64`).

Writes are `appendFileSync` of one JSON line (`src/core/session-manager.ts:1186-1187`).
The whole file is rewritten only when an old version is migrated
(`session-manager.ts:1092-1093`, `1124-1133`). The header line holds the
session id and cwd, so the file is re-read from the top whenever it changes
(`tail: false`), the same way Codex files are.

## Record shape

| Entry | Fields used | Source |
|---|---|---|
| `session` header | `id`, `timestamp`, `cwd`, `parentSession?` | `session-manager.ts:43-50` |
| `message` | `id`, `parentId`, `timestamp` (ISO), `message` (`AgentMessage`) | `session-manager.ts:57-67` |
| assistant `message.message` | `model`, `provider`, `usage`, `stopReason`, `thinkingLevel?`, `content[]` | `packages/ai/src/types.ts:548-572` |
| `usage` | `input`, `output`, `cacheRead`, `cacheWrite`, `reasoning?`, `totalTokens`, `cost{}` | `types.ts:429-450` |
| tool call (content block) | `type: "toolCall"`, `id`, `name`, `arguments` | `types.ts:419-427` |
| `toolResult` message | `toolCallId`, `toolName`, `content[]`, `isError` | `types.ts:596-609` |
| `compaction` | `id`, `timestamp`, `tokensBefore`, `firstKeptEntryId` | `session-manager.ts:91-104` |
| `thinking_level_change` | `thinkingLevel` | `session-manager.ts:69-72` |
| `model_change`, `usage`, `branch_summary`, `custom*`, `label`, `session_info`, `context_edit` | not turned into rows | `session-format.md:97-207` |

## Field → counter mapping

pi-ai normalises every provider, so `input` is the **uncached remainder**.
The anthropic adapter copies `input_tokens` (`packages/ai/src/api/anthropic-messages.ts:680-682`).
The OpenAI Responses adapter sets `input = input_tokens - cached - cache_write`
(`api/openai-responses-shared.ts:564-570`). Chat Completions does the same
(`api/openai-completions.ts:1530-1552`), and so do Google
(`api/google-generative-ai.ts:235-238`) and Mistral (`api/mistral-conversations.ts:606-608`).

| Pi | Ullage |
|---|---|
| `usage.input` | `input` |
| `usage.cacheRead` | `cacheRead` |
| `usage.cacheWrite` | `cacheWrite` |
| `usage.output` | `output` (already includes reasoning, `types.ts:436-441`) |
| `usage.reasoning` | `reasoning`, stored beside `output` as Codex's is |
| `input + cacheRead + cacheWrite` | `contextTokens` |
| `message.model` | `model`; window = `WindowLimits.knownLimit(model)`, nil for models Ullage doesn't know |
| `message.thinkingLevel` (else the last `thinking_level_change`) | `effort` |
| `message.stopReason` | `stopReason` |
| entry `id` / `parentId` | `uuid` / `parentUuid` |

Rows are `exact`. The dedupe key is `pi:<session-id>:<entry-id>`. Legacy v1
entries have no id, so their key falls back to the message timestamp.

## Branches and forks

- **Branches in one file.** A session is a tree (`id`/`parentId`,
  `session-format.md:209-222`). Each assistant entry on any branch was a real
  request, so each becomes its own row. When `/tree` resumes from an earlier
  entry, the next turn's context can drop without a compaction. Ullage shows
  that drop as recorded and does not label it.
- **Fork or branch into a new file.** `/fork` and branched sessions write a new
  header with `parentSession` and copy the earlier entries verbatim, ids and
  timestamps included (`session-manager.ts:1681`, `1846-1862`). Ullage skips
  entries dated before the new header while the parent file still exists. Each
  request is then counted once, in the session that made it (tokscale makes the
  same point: `crates/tokscale-core/src/sessions/pi.rs:408-413`). If the parent
  file is gone, the copies are kept, because nothing else would count them.

## What it does NOT record

- **No context window.** Pi keeps it in its model registry, not in the
  session, so Ullage looks it up. Pi runs many providers, and a model missing
  from `WindowLimits` gets no gauge.
- **No subagents** in core Pi.
- **Not turned into rows:** `usage` entries (for example `cache_warm`) and the
  summary calls behind `compaction` / `branch_summary`. Pi counts these toward
  spend (`session-format.md:113-121`, `135`, `160`), but they are requests
  outside the conversation's window. Ullage's spend for Pi is therefore a floor.
- An aborted assistant message with all-zero usage measured nothing and is skipped.
- Tool-result sizes are length estimates (rule 6).
