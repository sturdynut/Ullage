# CLAUDE.md

Guidance for working in this repository. Read
[docs/TRACER-BULLET-PLAN.md](docs/TRACER-BULLET-PLAN.md) for the why and
[docs/OBSERVED-FORMAT.md](docs/OBSERVED-FORMAT.md) for what the transcripts
actually look like on disk.

## What this is

Ullage reads Claude Code session transcripts (`~/.claude/projects/**/*.jsonl`),
persists every API call as a row in a local SQLite database, and shows how full
the live session's context window is — a macOS menu bar item backed by a
Swift-package collector and a debug CLI.

## Build, test, run

```bash
swift build            # debug
swift test             # 68 tests, all pass on Linux and macOS
scripts/install-app.sh # build the app, wrap it in Ullage.app, install to /Applications
```

- **Core builds and tests on Linux.** `Sources/UllageCore` and
  `Sources/ullage` have no macOS-only imports. `Sources/UllageApp` is
  `#if os(macOS)` throughout; SwiftUI and Swift Charts are only compiled on a
  Mac. Every rule that could live in Core does, so it is testable without a UI —
  the display logic (`MenuBarState`), the chart series (`SessionHistory`), and
  the window decomposition (`Composition`) are all pure and tested.
- **Run the app on a Mac with `scripts/install-app.sh`**, not `swift run` — a
  menu bar item needs the `.app` bundle (LSUIElement, the bundle identifier).
  The script waits for a running copy to quit before reinstalling.
- The database is at
  `~/Library/Application Support/com.sturdynut.ullage/telemetry.db`. Override
  with `--db` or `$ULLAGE_DB`; override the transcript source with
  `$CLAUDE_CONFIG_DIR`. Tests always use a temp database.

## Non-negotiable rules

These come from real traps in the data. Breaking one produces numbers that look
plausible and are wrong.

1. **Keep the four token counters separate forever** (`input`, `output`,
   `cache_read`, `cache_write`). A heavy session is ~99% cache reads, so any
   single "total tokens" number is a cache-read number in disguise. Charts pick
   one counter; they never sum them.
2. **`context_tokens = input + cache_creation + cache_read`.** All three are
   prompt-side. `input_tokens` alone undercounts occupancy by an order of
   magnitude. This one formula is the entire product; it is verified against
   `/context` in `docs/OBSERVED-FORMAT.md`.
3. **`output_tokens` is a mid-stream snapshot and undercounts.** The upsert
   takes `MAX(existing, incoming)`. Never invent a correction factor — store
   what was reported.
4. **The transcript format is not a contract.** Guard every field access,
   default missing counters to 0, count and skip malformed lines, never throw
   out of the parser. Unknown line types are expected, not errors.
5. **Estimated figures are labelled as estimates.** Tool-result and CLAUDE.md
   sizes are length estimates (~4 bytes/token), never real token counts. The
   `confidence` column keeps a future vendor's estimates from contaminating
   Claude Code's exact rows. `resultTokens` is always an estimate.
6. **If the disk disagrees with the parser, the disk wins.** After a Claude Code
   upgrade, re-run `scripts/recon.sh`, record divergences in
   `docs/OBSERVED-FORMAT.md`, fix the parser, and bump
   `ClaudeCodeParser.version`.

## Conventions

- **Logic in Core, not in views.** A rule that decides what to show is written
  and tested in `UllageCore`; the SwiftUI layer only renders it. This is why
  `MenuBarState`, `SessionHistory` and `Composition` exist as plain structs.
- **Fixed order for anything colour-coded.** Composition segments and history
  projects keep a stable order so a colour follows an entity, never its rank;
  the long tail of projects folds into "Other" rather than cycling hues.
- **Compaction is a first-class event.** Context falls off a cliff at a
  compaction boundary; `context_delta` is NULL across it, the chart marks it,
  and composition restarts the window at the post-compaction summary.
- Each memory/fact belongs where it can be reconstructed. `session_env` is the
  exception: MCP servers, skills and CLAUDE.md are snapshotted at ingest because
  nothing on disk records what they were when a session ran.

## Layout

- `Sources/UllageCore` — parser, ingestor, store, all display/analysis logic.
- `Sources/ullage` — the debug CLI (`ingest`, `backfill`, `watch`, `sessions`,
  `latest`, `env`, `history`, `composition`, `info`).
- `Sources/UllageApp` — menu bar popover + history window (macOS only).
- `Tests/UllageCoreTests` — everything above, driven off temp databases and
  fixtures.
- `docs/` — the plan and the observed transcript format.
- `scripts/recon.sh` — transcript reconnaissance and fixture scrubbing.
