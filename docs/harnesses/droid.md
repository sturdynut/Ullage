# Factory Droid (`droid`)

Parser: `Sources/UllageCore/Harnesses/Droid.swift` (`DroidParser`, version 1).

**Verified on disk: no.** There is no `~/.factory` on this Mac. Droid is
closed source, so everything below comes from three open-source parsers that
read real Droid files. Each claim names its source.

- **tokscale**: `crates/tokscale-core/src/sessions/droid.rs` ([junhoyeo/tokscale](https://github.com/junhoyeo/tokscale), `main`, 2026-10-04)
- **ccusage**: `rust/adapters/droid/src/{paths,parser}.rs` ([ryoppippi/ccusage](https://github.com/ryoppippi/ccusage))
- **CodeBurn**: `src/providers/droid.ts` and `docs/providers/droid.md` ([getagentseal/codeburn](https://github.com/getagentseal/codeburn))
- **OpenUsage** docs: <https://openusage.sh/docs/providers/droid/>

## Where it stores data

`~/.factory/sessions/<cwd-slug>/<uuid>.jsonl` holds the event log.
`<uuid>.settings.json` sits beside it (OpenUsage; tokscale `droid.rs:142-149`).

Droid documents no environment override. Ullage honours `FACTORY_DIR`, the
convention CodeBurn uses (`droid.ts:69`). ccusage uses its own
`DROID_SESSIONS_DIR` (`paths.rs:5`, `23-33`).

## Record shape

`<uuid>.jsonl` has one JSON object per line:

| `type` | Fields used | Source |
|---|---|---|
| `session_start` | `id`, `title`, `cwd` | CodeBurn `droid.ts:59-66`, `156-158` |
| `message` | `id`, `timestamp`, `message.role`, `message.content[]` | tokscale `droid.rs:295-319`; CodeBurn `droid.ts:161-192` |
| content block `tool_use` | `id`, `name` (`Execute`, `Read`, `Edit`, `Create`, `Grep`, `Task`, …), `input` | CodeBurn `droid.ts:17-34`, `180-186` |
| `compaction_state` | `timestamp` | tokscale `droid.rs:283-286` |

`<uuid>.settings.json` contains `model`, `providerLock`,
`providerLockTimestamp`, and `tokenUsage{inputTokens, outputTokens,
cacheCreationTokens, cacheReadTokens, thinkingTokens}` (tokscale
`droid.rs:15-39`; ccusage `parser.rs:96-117`). These figures are the
**session's running total**, rewritten in place (tokscale `droid.rs:167-176`).

## Field → counter mapping

None. tokscale says so directly: "Droid records no token counts anywhere in the
`*.jsonl` — only the cumulative total in `*.settings.json`"
(`droid.rs:236-237`). CodeBurn agrees: "Droid does not report per-message
tokens" (`docs/providers/droid.md`; `droid.ts:211-216`). The other tools fill
this gap by spreading the total across turns: evenly in CodeBurn, by transcript
bytes in tokscale. Either way, the per-turn figures are invented. Storing the
total as a single row would also be wrong, since it would read as one prompt
millions of tokens long.

Ullage therefore treats Droid as **activity only**, as it does Cursor:

| Droid | Ullage |
|---|---|
| assistant `message` | one row: `confidence = unmeasured`, all four counters 0, `contextTokens = 0`, `windowLimit = nil` |
| `message.timestamp` | `ts` |
| `session_start.id` (else the file stem) | `sessionId` |
| `session_start.cwd` | `cwd`, `project` = basename |
| `tool_use` blocks | `ToolCallRow`; `Execute.input.command` becomes the target, and `mcp__server__tool` names are classified as MCP |
| `compaction_state` | `EventKind.compaction` |

The dedupe key is `droid:<session>:<message id>`. The file is re-read whole
on change, because the session id and cwd come from the first line.

## What it does NOT record

- **Per-call tokens and the context window.** There is no gauge and no occupancy.
- **The model per call.** `settings.json` holds only the session's latest
  model, and tokscale/CodeBurn otherwise scrape a `Model:` string out of
  system-reminder text. Rows carry `model = nil`.
- **Tool-result sizes.** These are not parsed. The result shape is unconfirmed.
- The `settings.json` totals are not ingested. If Ullage gains a
  session-total concept, they would fit there, labelled `cumulative`.
