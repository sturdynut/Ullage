# Amp (`amp`)

Amp is Sourcegraph's coding agent ([ampcode.com](https://ampcode.com)).
Reader: `Sources/UllageCore/Harnesses/Amp.swift` (`AmpThreadReader`, a
`TranscriptDocumentReader`, version 1).

**Verified on disk: no.** No Amp data exists on this Mac. Amp's CLI is closed
source, so the format comes from the open-source parsers listed below, which
read real thread files.

- **ccusage**: `rust/adapters/amp/src/{paths,parser}.rs` ([ryoppippi/ccusage](https://github.com/ryoppippi/ccusage), `main`, 2026-10-04)
- **tokscale**: `crates/tokscale-core/src/sessions/amp.rs` ([junhoyeo/tokscale](https://github.com/junhoyeo/tokscale))
- **CodeBurn**: [PR #1578](https://github.com/getagentseal/codeburn/pull/1578), `src/providers/amp.ts` and `docs/providers/amp.md`
- **deja-vu** issues [#4355](https://github.com/vshulcz/deja-vu/issues/4355) (Amp stopped writing threads) and [#4356](https://github.com/vshulcz/deja-vu/issues/4356) (message and tool block shape)

## Where it stores data

Each thread is one JSON document, `~/.local/share/amp/threads/<T-id>.json`.

- `AMP_DATA_DIR` is Amp's own override. It takes a comma-separated list
  (ccusage `paths.rs:5-22`; CodeBurn `amp.ts:35-38`).
- `$XDG_DATA_HOME/amp` is used when that variable is set (deja-vu #4355; tokscale `clients.rs:463-467`, `PathRoot::XdgData`).

Amp rewrites the whole document as a thread grows, so Ullage reads it as a
document: the whole file is read on every change, and dedupe keys make that
idempotent.

**Amp builds from 0.0.1774963753 (2026-03-31) on no longer write this folder.**
Threads now live on ampcode.com (deja-vu #4355). Ullage can only read threads
from before that date. Current Amp has no local source.

## Record shape

| Path | Fields used | Source |
|---|---|---|
| top level | `id`, `created` (ms), `messages[]`, `usageLedger.events[]`, `env.initial.trees[].uri` | ccusage `parser.rs:19-37`; tokscale `amp.rs:64-71`; deja-vu #4356 |
| `usageLedger.events[]` | `id`, `timestamp`, `model`, `tokens{input, output, total?}`, `toMessageId`, `fromMessageId`, `operationType`, `credits` | ccusage `parser.rs:50-71`; tokscale `amp.rs:11-24` |
| `messages[]` | `role`, `messageId` (int), `content[]`, `usage` | ccusage `parser.rs:73-87` |
| `message.usage` | `model`, `inputTokens`, `outputTokens`, `cacheCreationInputTokens`, `cacheReadInputTokens`, `totalInputTokens`, `timestamp`, `credits` | ccusage `parser.rs:251-259`, fixture `378-389`; tokscale `amp.rs:37-49` |
| `tool_use` block | `id`, `name`, `input` (`Bash`: `cmd`, `cwd`; file tools: `path`) | deja-vu #4356 |
| `tool_result` block (user message) | `toolUseID`, `run.status`, `run.result` | deja-vu #4356 |

## Field → counter mapping

`inputTokens` is the **uncached remainder** (Anthropic semantics). The ccusage
fixture taken from a real thread shows `inputTokens 10 +
cacheCreationInputTokens 986 + cacheReadInputTokens 11372 = totalInputTokens
12368` (`parser.rs:383-389`).

**Ledger first.** When a thread has a ledger, each event is one request.
CodeBurn and ccusage both treat it as the per-request record (`parser.rs:104-116`).

| Amp | Ullage |
|---|---|
| `event.tokens.input` | `input` |
| `event.tokens.output` | `output` |
| billed message (`toMessageId` → `messages[].messageId`) `usage.cacheReadInputTokens` | `cacheRead` |
| same message `usage.cacheCreationInputTokens` | `cacheWrite` |
| `input + cacheRead + cacheWrite` | `contextTokens` |
| `event.model` (else `usage.model`) | `model`; window = `WindowLimits.knownLimit(model)` |
| `event.timestamp` (else `usage.timestamp`, then `created`, then file mtime) | `ts` |
| `env.initial.trees[0].uri` (`file://`) | `cwd`, `project` |

An event whose `toMessageId` does not resolve has no cache counts, so its
prompt size is unknown. That row is kept as `estimated` with `windowLimit =
nil`, which means it never drives a gauge. It is not shown as a small prompt.

**No ledger.** Each assistant message with `usage` becomes a row, with all four
counters taken from that message. These rows use the same dedupe key as the
ledger path (`amp:<thread>:m<messageId>`), so a thread that gains a ledger
later keeps its rows.

Tool calls come from the assistant message's `tool_use` blocks. Results come
from `tool_result` blocks on the next user message, as length estimates (rule 6).

## What it does NOT record

- **The context window.** Ullage looks it up. A `maxInputTokens` field may
  exist in `usage`, but no parser confirms it, so Ullage does not use it.
- **Compaction or subagent structure.** None is confirmed, so none is read.
- **Reasoning tokens** are not reported separately.
- `credits` is Amp's billing unit, not tokens, and is not stored.
