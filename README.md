# Ullage

Token and context-window telemetry for AI coding agents, headed for a macOS
menu bar item that shows how full the context window of your live Claude Code
session is.

This repository currently contains the first two slices of the tracer bullet
described in [docs/TRACER-BULLET-PLAN.md](docs/TRACER-BULLET-PLAN.md):

| Slice | What it is | State |
|---|---|---|
| **M1** | Parser + schema, including tool calls and the cross-line `tool_result` join | done, 35 tests |
| **M2** | Ingest CLI: point it at a directory, get rows in SQLite and per-session totals | done |
| M0 | Reconnaissance against real transcripts | **tooling ready, not run** — see below |
| M2.5 | Backfill + `session_env` snapshot | not started |
| M3 | `FSEvents` tailer | not started |
| M4 | Menu bar | not started |

There is no UI yet, on purpose: a menu bar showing a wrong number is harder to
debug than a CLI printing one.

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

# Ingest every transcript under ~/.claude/projects
.build/debug/ullage ingest

# Or a specific directory or file
.build/debug/ullage ingest ~/.claude/projects/-Users-you-someproject

.build/debug/ullage sessions   # per-session totals
.build/debug/ullage latest     # the single row that will drive the menu bar
.build/debug/ullage info       # resolved paths and row counts
```

The database lands at
`~/Library/Application Support/com.sturdynut.ullage/telemetry.db` (WAL mode).
`--db <path>` or `ULLAGE_DB` moves it; `CLAUDE_CONFIG_DIR` moves the source.

Ingestion is incremental and idempotent: each file's byte offset is stored in
`file_cursor` and every row is keyed by the API `message.id`, so re-running
`ingest` over the same transcripts changes nothing.

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
  Ingestor              cursors, turn indexes, context deltas, the tool_result join
  Store                 SQLite schema and the two queries the UI needs
  WindowLimits          model string -> context window, longest-prefix match
Sources/ullage/         debug CLI (M2)
Tests/                  fixture parse, idempotency, partial line, rotation,
                        unknown types, tool-result join, MCP name parsing
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

`session_env` is created but not yet populated; that is M2.5, and it is the one
table whose data cannot be reconstructed later.
