# CLAUDE.md

Guidance for working in this repository.

**Start here:** this file, then [`README.md`](README.md) for the product, then
[`docs/OBSERVED-FORMAT.md`](docs/OBSERVED-FORMAT.md) for what transcripts
actually look like on disk. [`docs/TRACER-BULLET-PLAN.md`](docs/TRACER-BULLET-PLAN.md)
is the original plan and is historical — the milestones in it are all done.

## What this is

Ullage reads AI coding-agent session transcripts from disk, persists every API
call as a row in a local SQLite database, and shows how full the live session's
context window is. A macOS menu bar app backed by a Swift-package collector and
a debug CLI. Everything is local; nothing is uploaded.

### Harness support

| Harness | Reads | Occupancy | Notes |
|---|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | exact | Window from `WindowLimits` lookup |
| OpenAI Codex CLI | `~/.codex/sessions/**/*.jsonl` | exact | Window reported per turn, no lookup |
| Cursor | `~/.cursor/**/agent-transcripts/**/*.jsonl` | **none** | Activity only; stores no tokens/window/model/timestamps |

Not supported: GitHub Copilot, Zed, Aider, Gemini, and every cloud/web session
of any harness. **The rule that predicts supportability:** local-first CLI
agents write the API usage block and context window into their transcripts
because they need them offline; subscription-metered IDEs compute usage
server-side and keep only conversation content locally.

## Quick start

```bash
swift build
swift test                 # 79 tests; pass on Linux and macOS
scripts/install-app.sh     # build, bundle Ullage.app, install to /Applications
.build/debug/ullage backfill   # ingest everything on disk
```

CLI: `ingest`, `backfill`, `watch`, `sessions`, `latest`, `history [--days N]`,
`composition <session>`, `env <session>`, `info`.

- **Core builds and tests on Linux.** `Sources/UllageCore` and `Sources/ullage`
  have no macOS-only imports. `Sources/UllageApp` is `#if os(macOS)` throughout.
  Any rule that can live in Core does, so it is testable without a UI.
- **Run the app via `scripts/install-app.sh`, not `swift run`** — a menu bar item
  needs the `.app` bundle (LSUIElement, bundle id, icon). The script quits a
  running copy and waits for it to exit before reinstalling.
- Database: `~/Library/Application Support/com.sturdynut.ullage/telemetry.db`
  (WAL). Override with `--db` or `$ULLAGE_DB`; move the source with
  `$CLAUDE_CONFIG_DIR` / `$CODEX_HOME` / `$CURSOR_HOME`. Tests use temp databases.

## The one formula

```
context_tokens = input + cache_write + cache_read     // all prompt-side
occupancy      = context_tokens / window_limit
```

Verified by hand against Claude Code's `/context`: it showed `129.1k/1m (13%)`
while Ullage showed `129,096 / 1,000,000` for the same turn.

**Token semantics differ per harness — this is the single easiest thing to get
wrong.** Claude's `input_tokens` is only the *uncached remainder*, so the three
counters are summed. Codex's `input_tokens` is the *whole prompt, cached
included*, so it is split back into the four counters (`input = total - cached -
cache_write`) which then sum to the same total. Cursor reports nothing.

## Non-negotiable rules

These come from real traps in the data. Breaking one produces numbers that look
plausible and are wrong.

1. **Keep the four token counters separate forever** (`input`, `output`,
   `cache_read`, `cache_write`). A heavy session is ~99% cache reads, so any
   single "total tokens" number is a cache-read number in disguise. Charts pick
   one counter; they never sum them.
2. **Never estimate a measurement.** If a harness does not report tokens, the
   row carries `confidence = unmeasured`, a nil window, and no occupancy — it
   does not get a guessed percentage. `confidence` exists precisely to keep an
   estimate-only source from contaminating exact rows.
3. **`output_tokens` is a mid-stream snapshot and undercounts.** The upsert takes
   `MAX(existing, incoming)`. Never invent a correction factor — store what was
   reported.
4. **Transcript formats are not contracts.** They are private and versioned.
   Guard every field access, default missing counters to 0, count and skip
   malformed lines, never throw out of a parser. Unknown line types are expected.
5. **Estimated figures are labelled as estimates.** Tool-result and CLAUDE.md
   sizes are length estimates (~4 bytes/token), never real token counts.
6. **If the disk disagrees with the parser, the disk wins.** After a harness
   upgrade, re-run `scripts/recon.sh`, record divergences in
   `docs/OBSERVED-FORMAT.md`, fix the parser, and bump its `version`.

## Architecture and conventions

- **One parser per harness, one row shape.** `ClaudeCodeParser`, `CodexParser`
  and `CursorParser` all emit `ParsedLine` (calls, tool results, events).
  `TranscriptFormat.detect(path:)` routes a file to the right one, so the store,
  CLI and UI stay vendor-agnostic. Add a harness by adding a parser, not by
  branching downstream.
- **Self-contained lines can be tailed; others cannot.** Claude lines each carry
  their own session, model and cwd, so files are read incrementally from a byte
  cursor. Codex and Cursor lines are not self-contained (model/cwd/timestamps
  come from earlier lines or the file itself), so those formats set
  `reingestsWholeFile` and are re-read from zero on change. Dedupe keys make
  that idempotent.
- **Window-less rows never drive the gauge.** `latestCall()` filters
  `window_limit IS NOT NULL` so a Cursor session cannot hijack the menu bar
  percentage, while still appearing in `sessions` and history.
- **Logic in Core, not in views.** A rule that decides what to show is written
  and tested in `UllageCore`; SwiftUI only renders it. Hence `MenuBarState`,
  `SessionHistory`, `Composition` as plain structs.
- **Fixed order for anything colour-coded.** Composition segments and history
  projects keep a stable order so a colour follows an entity, never its rank;
  the long tail folds into "Other" rather than cycling hues.
- **Compaction is a first-class event.** Context falls off a cliff at a
  compaction boundary: `context_delta` is NULL across it, charts mark it, and
  composition restarts the window at the post-compaction summary.
- **`session_env` is the one irreproducible table.** MCP servers, skills and
  CLAUDE.md are snapshotted at ingest because nothing on disk records what they
  were when a session ran. It is Claude-Code-only; other vendors skip it.

## Adding a new harness

Done twice (Codex, Cursor); follow the same path.

1. **Investigate before coding.** Find the harness's local data and answer one
   question: *does it record per-turn prompt tokens and the context window?*
   Grep its data directory for `token`, `usage`, `context_window`. If the answer
   is no, it is activity-only at best — say so rather than estimating.
2. **Write a parser** in `Sources/UllageCore` conforming to
   `TranscriptLineParser`, emitting `ParsedLine`. Set `vendor`, the right
   `confidence`, and a `version`. Keep it stateful only if the format requires it.
3. **Route it:** add a case to `TranscriptFormat` (`detect`, `makeParser`,
   `reingestsWholeFile`) and a `*Paths` enum, then add its root to
   `TranscriptSources.roots()` so the tailer, CLI and `info` all see it.
4. **Test against real data first**, then write unit tests driven through the
   parser (so they run on Linux). Validate with `ullage ingest <dir> --db /tmp/x`
   and check `sessions` / `composition` output looks sane.
5. **Update the docs — always, in the same change:** `README.md` (intro line,
   the supported-harness and limitations bullets), this file's harness table, and
   the GitHub repo description via
   `gh repo edit sturdynut/Ullage --description "..."`. Keep the not-supported
   list honest.

## Workflow

Work on a branch; open a PR into `main` and merge it. The repo's own default
branch is `claude/two-slices-link-empty-repo-51t02z`, but `main` is kept current
— update both when they diverge. Reinstall with `scripts/install-app.sh` after
any app change so what is running matches what is committed.

## Layout

- `Sources/UllageCore` — parsers, ingestor, SQLite store, all analysis/display logic.
- `Sources/ullage` — the debug CLI.
- `Sources/UllageApp` — menu bar popover + history window (macOS only).
- `Tests/UllageCoreTests` — everything above, off temp databases and fixtures.
- `docs/` — observed transcript format, the original plan, screenshots.
- `scripts/recon.sh` — transcript reconnaissance and fixture scrubbing.
- `scripts/install-app.sh` — build, bundle, sign, install the app.

## Gotchas

- A SwiftUI `Text` with an inline SF Symbol **drops the symbol** inside
  `MenuBarExtra`. The menu bar label is drawn as a template `NSImage` instead.
- `head` closing a pipe under `set -o pipefail` kills the producer with SIGPIPE
  and aborts the script; `scripts/recon.sh` tolerates that on every truncated
  pipeline.
- Claude Code deletes transcripts older than `cleanupPeriodDays` (default 30)
  silently. Anyone relying on history should set it to 3650 first.
