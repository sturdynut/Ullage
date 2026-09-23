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
a debug CLI. Everything is local; nothing is uploaded, with three deliberate exceptions and
no others. `ullage otlp` exports to an OpenTelemetry collector when invoked —
never in the background, never from the app. And `ullage serve`, *once a device
has subscribed to alerts*, sends a notification through that device's push
service; the body is encrypted to the device's own key, so the relay carries
ciphertext, but the fact and timing of a send are visible to it. Nothing
subscribes by default. And with *Check Claude plan limits* switched on (off by
default), the app asks `api.anthropic.com/api/oauth/usage` for plan limits every
5 minutes with Claude Code's own OAuth token, read from the Keychain and never
refreshed; `ullage limits --fetch` does the same once. Serving itself uploads nothing: the page is bound to
127.0.0.1 and `tailscale serve` fronts it for your own devices.

### Harness support

| Harness | Reads | Occupancy | Notes |
|---|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | exact | Window from `WindowLimits` lookup; subagents included, each its own window |
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
swift test                 # 161 tests on macOS; 155 on Linux (six need CryptoKit)
scripts/install-app.sh     # build, bundle Ullage.app, install to /Applications
.build/debug/ullage backfill   # ingest everything on disk
```

CLI: `ingest`, `backfill`, `watch`, `sessions`, `latest`, `history [--days N]`,
`composition <session>`, `agents <session>`, `env <session>`, `serve`,
`push [--test]`, `otlp`, `limits [--fetch]`, `info`.

- **Core builds and tests on Linux.** `Sources/UllageCore` and `Sources/ullage`
  have no macOS-only imports, with one guarded exception: `WebPush.swift` is
  `#if canImport(CryptoKit)` and everything that calls into it is guarded the
  same way. `Sources/UllageApp` is `#if os(macOS)` throughout.
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

1. **A subagent is its own context stream, never a turn of its parent.** Its
   lines live in `<session>/subagents/agent-<id>.jsonl` and carry the *parent's*
   `sessionId`, so the key for turn index, context delta and occupancy is
   `(session_id, agent_id)` — `agent_id IS NULL` being the main thread. The menu
   bar gauge filters to the main thread: an agent's window is not the session's,
   however recently it spoke.
2. **Keep the four token counters separate forever** (`input`, `output`,
   `cache_read`, `cache_write`). A heavy session is ~99% cache reads, so any
   single "total tokens" number is a cache-read number in disguise. Charts pick
   one counter; they never sum them.
3. **Never estimate a measurement.** If a harness does not report tokens, the
   row carries `confidence = unmeasured`, a nil window, and no occupancy — it
   does not get a guessed percentage. `confidence` exists precisely to keep an
   estimate-only source from contaminating exact rows.
4. **`output_tokens` is a mid-stream snapshot and undercounts.** The upsert takes
   `MAX(existing, incoming)`. Never invent a correction factor — store what was
   reported.
5. **Transcript formats are not contracts.** They are private and versioned.
   Guard every field access, default missing counters to 0, count and skip
   malformed lines, never throw out of a parser. Unknown line types are expected.
6. **Estimated figures are labelled as estimates.** Tool-result and CLAUDE.md
   sizes are length estimates (~4 bytes/token), never real token counts.
7. **A counter's meaning travels with it.** `gen_ai.usage.input_tokens` means
   the whole prompt; Claude's `input_tokens` means the uncached remainder. The
   OTLP export sends `context_tokens` under the standard name and the four
   counters under `ullage.tokens` — see `docs/OPENTELEMETRY.md`. Exporting a
   number under a name that means something else is the same error as
   estimating one, committed in a dashboard where nobody can see it.
8. **If the disk disagrees with the parser, the disk wins.** After a harness
   upgrade, re-run `scripts/recon.sh`, record divergences in
   `docs/OBSERVED-FORMAT.md`, fix the parser, and bump its `version`.
9. **Plan limits are percentages, never tokens.** Neither vendor states a
   subscription limit in tokens, so none is derived. A reading taken before
   its window reset says nothing about now and is shown as reset, not as a
   number; the tokens shown beside a limit are Ullage's own count, a floor, and
   only beside plan-wide limits (a per-model limit's window would count every
   model). Claude's come from the undocumented `/api/oauth/usage` — parse it
   like a transcript, and never refresh Claude Code's token.

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
- **The agent tree is assembled from two sides, in either order.** The child's
  transcript and its `.meta.json` sidecar give identity, type and the name the
  parent wrote; the parent's `toolUseResult` gives how the run ended. Neither
  overwrites the other with nil, and the *parent agent* is derived on read from
  `tool_call` → `call.agent_id` so ingest order cannot strand an edge. Nesting
  falls out of that join for free.
- **Two things send, and both are pulled or opted into.** `ullage otlp` is
  the export: it runs when invoked, `--dry-run` prints the exact payloads, and
  nothing runs it in the background. OTLP JSON is written by hand
  (`OpenTelemetry.swift`) rather than by taking a dependency: the package has
  none beyond system SQLite, and an exporter should not drag gRPC into a menu
  bar app. Metrics are cumulative and therefore idempotent; spans are not, so
  they follow a per-endpoint cursor. The other sender is `serve`'s alert push,
  which only exists once a device has subscribed from the page, and only ever
  goes to that device's push service, encrypted to that device's key. There is
  no third.
- **`serve` binds loopback and offers no way not to.** Reaching it from a
  phone is `tailscale serve`'s job, which means exposure is granted and revoked
  outside Ullage and there is no flag anyone can leave switched on by accident.
  The page is a string constant in Core (`WebPage.swift`) so the CLI and the app
  can both serve it without a resource bundle, and it fetches `state.json`,
  whose shape is built by `ServeSnapshot` from the *same* `MenuBarFormatter` the
  menu bar uses — a second set of display rules would be a second set of bugs.
  The host allowlist is not decoration: a loopback server with no `Host` check
  is readable by any web page the user visits, via DNS rebinding.
- **Alerts are edge-triggered, and the edge is persisted.** Level-triggered is
  the obvious implementation and the wrong one: it notifies on every turn above
  the threshold. `AlertRule` fires once per rung per stream, re-arms when a
  compaction drops the window below all of them, and records what it said in
  `push_alert` so restarting `serve` does not re-announce. Main thread only
  (rule 1), measured rows only (rule 3), and recent rows only — a backfill
  crosses 85% thousands of times and none of it is news.
- **Push crypto is the one macOS-only thing in Core.** `WebPush.swift` is behind
  `#if canImport(CryptoKit)` rather than taking `swift-crypto` as the package's
  first dependency; a Linux box serves the gauge and cannot push, which is the
  right trade for a machine with no menu bar either. It was verified against
  node's `http_ece` — the library `web-push` uses — which decrypts what it
  produces, and the VAPID JWT against `crypto.verify`. Note `UllageCore` ships
  its own `SHA256`, so CryptoKit's needs qualifying as `CryptoKit.SHA256`.
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
- `docs/` — observed transcript format, the OTLP export reference, the original
  plan, screenshots.
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
