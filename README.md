# Ullage

Token and context-window telemetry for AI coding agents, headed for a macOS
menu bar item that shows how full the context window of your live Claude Code
session is.

This repository implements the tracer bullet described in
[docs/TRACER-BULLET-PLAN.md](docs/TRACER-BULLET-PLAN.md): file watch → parse →
persist → render, end to end, with every API call kept as a row in a local
SQLite database.

| Slice | What it is | State |
|---|---|---|
| M0 | Reconnaissance against real transcripts | done 2026-09-12, see `docs/OBSERVED-FORMAT.md` |
| M1 | Parser + schema, including tool calls and the cross-line `tool_result` join | done |
| M2 | Ingest CLI | done |
| M2.5 | Backfill + `session_env` snapshot | done |
| M3 | Tailer — FSEvents on macOS, polling elsewhere | done |
| M4 | Menu bar item | done, running |

56 tests, all green on Linux. The collector, the CLI and every display rule are
covered; the two macOS-only pieces (the FSEvents watcher and the SwiftUI views)
are compiled out on this platform and have never been built. Treat the first
`swift build` on a Mac as part of the work, not a formality.

## Before anything else

Claude Code deletes session transcripts older than `cleanupPeriodDays` at
startup. The default is 30 days, the deletion is silent, and pruned sessions
are unrecoverable. In `~/.claude/settings.json`:

```json
{ "cleanupPeriodDays": 3650 }
```

Every day without a backfill is a day of history that quietly ages out.

## Build and run

Requires Swift 6 (Xcode 16) and, for the eventual app, macOS 14+. The collector
itself has no macOS-only dependencies and builds and tests on Linux too.

```bash
swift build
swift test

# Everything on disk, plus what is still missing
.build/debug/ullage backfill

# Tail live: prints exactly what the menu bar would be showing
.build/debug/ullage watch

.build/debug/ullage ingest [path ...]   # one directory or file
.build/debug/ullage sessions            # per-session totals
.build/debug/ullage latest              # the single row that drives the menu bar
.build/debug/ullage env <session>       # that session's configuration snapshot
.build/debug/ullage info                # resolved paths, retention, row counts
```

### The menu bar app

```bash
scripts/install-app.sh    # builds, wraps in Ullage.app, installs to /Applications
open /Applications/Ullage.app
```

Pass a directory to install elsewhere (`scripts/install-app.sh ~/Applications`).
To have it start at login, add Ullage under System Settings > General > Login
Items. For development, `open Package.swift` and run the UllageApp scheme in
Xcode instead.

It shows `72%`, or `72% ⚠︎` above 85%, or a dimmed `circle.dotted` glyph when
nothing has happened for 30 minutes — a number that looks live but is four
hours old is worse than no number. The menu behind it carries the session,
project, model, context and last delta. There is no popover, no chart and no
multi-session view; those are all later.

It runs unsandboxed: reading `~/.claude` from a sandboxed app needs
entitlements, and packaging, signing and notarization are deliberately not part
of this slice.

The database lands at
`~/Library/Application Support/com.sturdynut.ullage/telemetry.db` (WAL mode).
`--db <path>` or `ULLAGE_DB` moves it; `CLAUDE_CONFIG_DIR` moves the source.

Ingestion is incremental and idempotent: each file's byte offset is stored in
`file_cursor` and every row is keyed by the API `message.id`, so re-running
`ingest` over the same transcripts changes nothing. The tailer sweeps the whole
tree once at startup before it starts watching, because the app is not always
running and a transcript appended while it was not is only picked up by reading
from the stored cursor.

Answers to the plan's open questions, all of them the stated defaults: the
headline number follows the **most recently active** session, `Task`-spawned
subagent usage **rolls into the parent** session (`is_sidechain` is recorded, so
splitting it later is a query change rather than a re-ingest), and **30 minutes**
without a turn counts as idle (`MenuBarFormatter.idleThreshold`).

## Verifying the number (M0, still outstanding)

The parser was written on a machine with no `~/.claude` directory, so every
field name in it is a hypothesis taken from the plan rather than something
observed. Run this on your Mac before trusting a single row:

```bash
scripts/recon.sh                                      # what is actually on disk
scripts/recon.sh fixture ~/.claude/projects/<dir>/<session>.jsonl
```

The report prints the line types present, the `usage` shape, and the last
turn's `context_tokens`. Open a Claude Code session, run `/context` inside it,
and compare. If they disagree, fix the parser before building anything on top:
that formula is the entire product. Record what you saw in
[docs/OBSERVED-FORMAT.md](docs/OBSERVED-FORMAT.md) and bump
`ClaudeCodeParser.version` on any parser change.

The committed fixtures are **synthetic** — hand-built to the shape the plan
describes. Replacing them with scrubbed real transcripts is part of closing M0.

## Layout

```
Sources/UllageCore/     the collector — no UI imports, so lifting it into a
                        separate daemon later stays mechanical
  ClaudeCodeParser      pure line -> rows, never throws
  Ingestor              cursors, turn indexes, context deltas, the tool_result
                        join, the session_env snapshot
  Store                 SQLite schema and the queries the UI needs
  WindowLimits          model string -> context window, longest-prefix match
  SessionEnvironment    MCP servers, skills and CLAUDE.md as they are right now
  DirectoryWatcher      FSEvents on macOS, mtime polling elsewhere
  SessionTailer         debounce, serial ingest, startup sweep
  MenuBarState          what the menu bar shows, decided without a UI
Sources/ullage/         debug CLI
Sources/UllageApp/      SwiftUI MenuBarExtra (macOS only)
Tests/                  fixture parse, idempotency, partial line, rotation,
                        unknown types, tool-result join, MCP name parsing,
                        tailing an appended file, the idle rule, SHA-256 vectors
scripts/recon.sh        M0 reconnaissance and fixture scrubbing
```

## Notes on the schema

Full DDL is in `Store.swift`, straight from the plan. Three things that look
like over-collection and are not:

- The four token counters stay separate forever. A heavy session is ~99% cache
  reads, so any column that sums them is a cache-read column wearing a disguise.
- `confidence` is `'exact'` on every Claude Code row. It exists so that when a
  vendor that only estimates arrives, its numbers cannot silently contaminate a
  total.
- `context_delta` is this turn's context minus the previous turn's. You cannot
  split a prompt blob by tool, but you can attribute the change — and it needs
  no tokenizer. It is NULL on a session's first turn and after a compaction
  boundary, where the drop is an artifact rather than a measurement.

`session_env` is captured on first sight of a session: the configured MCP
servers, the available skills, and the full text of `CLAUDE.md` with `@imports`
expanded, hashed and sized. It is the one table whose data cannot be
reconstructed later — nothing on disk records what that configuration was when a
session ran, and it is the denominator for the whole ghost-token question. For
an old transcript the snapshot is taken at ingest time and `captured_at` says
so, which is exactly why backfilling early matters.

## What is deliberately not here

No cost or pricing, no charts, no context *composition* drill-down, no
multi-session UI, no compaction or forked-session reconciliation, no packaging.
The schema keeps enough to make all of them additive later; the UI renders
almost none of it.
