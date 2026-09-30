<div align="center">

<img src="assets/branding/ullage-logo.png" alt="Ullage logo: a brass U-shaped capacity gauge on charcoal" width="128" height="128">

# Ullage

**See how full your Claude Code context window is, live, from the menu bar.**

</div>

Ullage watches your Claude Code and OpenAI Codex CLI session transcripts, keeps
every API call in a local SQLite database, and shows the context window's fill
level as a percentage in the macOS menu bar. It also lists Cursor agent activity,
though Cursor records no token counts locally so it has no fill percentage. Click it to break the current session down turn by turn
and see what is actually taking up the window. A separate history window charts
your activity across days and projects.

Everything stays on your machine. Nothing is uploaded, and nothing is sent
anywhere unless you ask for it. Three things can: `ullage otlp` exports for
aggregating across machines, runs only when you run it, and `--dry-run` prints
exactly what would leave first; once you subscribe a phone to alerts, a
notification goes to that phone — encrypted to it, via its push service — when
a window fills up; and if you switch on Claude plan limits, Ullage asks
Anthropic for them the way Claude Code's `/usage` does, sending Claude Code's
own sign-in to api.anthropic.com and nothing else. None of these happens until
you set it up.

Ullage only reads Claude Code's config, with one exception: when you flip a
[token saver](#token-savers) switch, it edits Claude Code's user settings to
switch that one tool on or off. It backs the file up first and never throws
anything away.

> **Ullage** — the empty space left at the top of a barrel or tank. Here, the
> room still left in the context window.

## What it looks like

<div align="center">

<img src="docs/screenshots/popover.png" alt="The Ullage popover: the session's project, path and model; 781k left in a 1M window over a marked occupancy bar with the context-per-turn chart directly beneath it; a context-composition bar of baseline, tool results, output and other with its legend; a one-line session summary; and plan limits as one row per harness showing what is left in each limit" width="380">

</div>

- **Menu bar:** a gauge icon whose needle rises with occupancy, followed by the
  percentage &nbsp;<img src="docs/screenshots/menu-bar.png" alt="Ullage menu bar item showing a gauge icon and 44%" height="18" valign="middle">&nbsp;. It
  turns amber past 85%. Once a session has been idle for 30 minutes the
  percentage fades: you can still read the last value, and it doesn't look
  current.
- **Popover** — click the menu bar item. The top stays put while the rest
  scrolls, so the session is always named even when the popover is taller than
  the screen:
  - **which session**: its project, the full working directory (so two
    worktrees or checkouts with the same folder name are told apart), and the
    model;
  - **the room left in the window**, in tokens, over a bar marked at 85% and at
    the session's own peak, with the exact `used / window` beneath it;
  - directly under that, **context tokens per turn**, where the band above the
    line is the room left, captioned with what each turn now re-sends against
    the first (`591k left · each turn re-sends 409k, 38× the first`), with the 85% line and a marker wherever a compaction
    dropped the window (hover for the exact turn, tokens, and change).

  Below it, every section collapses to **one row of its key figures** and
  expands to the full view (click the section's rule; each remembers how you
  left it):
  - **Context composition**: what the used part of the window is made of,
    always in the same order and colours. Collapsed, the four totals in one
    row (`● Baseline 48k · ● Tools ≈41k · ● Output 85k · ● Other ≈55k`), with `≈` on
    every estimate. Expanded, a treemap (tool results split by the tool that
    produced them, the baseline into CLAUDE.md and the rest), the four totals,
    the baseline's parts (CLAUDE.md, MCP servers, skills), every tool in the
    window, and the targets **called most** (`Bash git status ×12`), and what is **along for
    the ride**: tool results from 50+ turns ago that are still re-sent every turn,
    and files read more than once, with the tokens in their earlier copies (all
    `≈`; 50 is a rule of thumb, not a measurement). The ⤢
    button, or a click on the row or treemap, opens the
    [composition explorer](#composition-explorer).
  - **Token savers**: collapsed, problems first, then how many are on and off
    (`rtk not running · Headroom idle · 1 on`).
    Expanded, each tool's on/off switch, where its figure comes from, and an
    Install… option for the ones you don't have. See
    [Token savers](#token-savers).
  - **Session information**: collapsed, the last turn's change, turn count and
    last-active time (`last turn +951 · turns 112 · idle 5:27 PM`), led by
    `re-cached 2×` when something the session did made it cache its context
    again. Expanded, a table that adds the session id and every cache rebuild
    by cause.
  - **Agents**: collapsed, how many there are, how many haven't finished, and
    whose window is fullest. Expanded, the tree of **subagents the session
    spawned**, each named by the description the agent above it wrote and each
    with **its own window and occupancy**. Click one and the chart, the
    composition and the session information switch to its context, and say
    so. The tree stays open while an agent is selected.
  - **Plan limits**: collapsed, each harness's tightest limit in one row
    (`Claude 5h 88% left · Codex week 100% left`). Expanded, every limit with its
    bar, when it resets, and what Ullage itself saw in that window. See
    [Plan limits](#plan-limits).

  It follows the most recently active session and holds still on it while the
  popover is open. The chevron at the top switches session — grouped by
  project, since a session id is not a name, with each entry's path — and
  stays accented while one is pinned.
- **Composition explorer** — the composition treemap at window size, one level
  at a time. See [below](#composition-explorer).
- **History window** — the History button opens activity per day stacked by
  project over 7, 30, 90, or 365 days, switchable between turns, output tokens,
  and cache reads; a table of every session in range with its path and agent
  count; and
  the selected session's agent tree, chart and full composition.

### Composition explorer

<div align="center">

<img src="docs/screenshots/composition-explorer.png" alt="The composition explorer opened to Tool results, then Bash, sized by calls: python3 23 calls, sed 18, grep 13, then install-app.sh, cat, sqlite3 and smaller commands, with a table of calls, estimated tokens and share of the window beside the treemap" width="760">

</div>

What the window holds, big enough to open every tile. It starts at the four
segments; click one to open it, and the breadcrumb or Escape goes back up:

- **Tool results** opens to every tool in the window — nothing folds into
  "N more" here — with MCP tools grouped under their server.
- **A tool** opens to what it was called on: Bash by program and subcommand
  (`git status`, `swift test`, `sqlite3`; a leading `cd`, variable assignments,
  quotes and pipes are read the way the shell reads them), file tools by path,
  search and fetch tools by pattern or URL. Failed calls are counted on hover.
- **A Bash program** opens to the exact commands it ran.
- **Tokens / Calls** sizes the tiles and sorts the table by how much of the
  window each takes, or by how often it was called — what is called most is
  not always what fills the window.

The table beside the treemap lists every tile, including ones too small to
label. The explorer is live: it follows the session (or agent) the popover
shows and keeps its place as turns arrive. Token figures here are the same
length estimates as the popover's, never counted tokens.

## Install

Requires macOS 14 or later, and Swift 6 (Xcode 16) to build.

```bash
git clone https://github.com/sturdynut/Ullage.git
cd Ullage
scripts/install-app.sh          # builds, bundles Ullage.app, installs to /Applications
open /Applications/Ullage.app
```

Pass a directory to install elsewhere, e.g. `scripts/install-app.sh ~/Applications`.

Because the app is ad-hoc signed rather than notarized, the first launch may draw
a Gatekeeper warning; right-click the app and choose **Open**, or approve it once
under System Settings → Privacy & Security. To start it at login, add Ullage
under System Settings → General → Login Items.

### Before you lose history

Claude Code deletes session transcripts older than `cleanupPeriodDays` at
startup. The default is 30 days, the deletion is silent, and pruned sessions
cannot be recovered. Raise it in `~/.claude/settings.json` **before** you rely on
Ullage for history:

```json
{ "cleanupPeriodDays": 3650 }
```

Then pull your existing sessions into the database so the charts have history:

```bash
swift build
.build/debug/ullage backfill
```

## Using it

Ullage runs quietly in the menu bar and updates within a couple of seconds of
each turn. There is nothing to configure. Open the popover for the live session,
or the History window for the longer view.

### Command line

The same data is available from a CLI, handy for scripting or a quick look
without the app:

```bash
ullage backfill              # ingest everything on disk, report what is missing
ullage watch                 # tail live; prints what the menu bar would show
ullage sessions              # per-session totals, grouped by project
ullage agents <session>      # the subagent tree, each agent's own window
ullage latest                # the single row driving the menu bar
ullage history [--days N]    # activity per day and project (default 30)
ullage composition <session> # what a session's window is made of
ullage serve [--port N]      # serve the gauge to a browser on 127.0.0.1
ullage push [--test]         # devices subscribed to alerts; --test buzzes them
ullage otlp --endpoint URL    # export everything measured to an OTLP collector
ullage env <session>         # a session's configuration snapshot
ullage limits [--fetch]      # plan limits left; --fetch asks Anthropic for Claude's
ullage savers [session]      # token savers: switched on, and what each did
ullage savers --days 30      # each saver across every session in the range
ullage rebuilds [session]    # turns that re-cached most of their context, and why
ullage rebuilds --days 30    # the same across sessions, by cause
ullage savers disable rtk --dry-run   # what switching one off would change
ullage savers install caveman         # the tool's own install commands, after asking
ullage info                  # resolved paths, retention, row counts
```

`agents` prints the main thread and, indented beneath it, every subagent the
session spawned: the name the spawning agent gave it, its type, its turns, and
how full **its own** window got. A subagent starts from an empty context, so its
occupancy is never the session's — and the menu bar gauge never follows one.

`composition` breaks the current window into a baseline (system prompt, tool
schemas, skills, CLAUDE.md, and the opening prompt — or the summary after a
compaction), tool results, assistant output, and the remainder, then lists the
tools whose results are in the window. Every figure but the window total is an
estimate and is labelled as one.

### Plan limits

Subscriptions meter usage in rolling windows — a 5-hour one and a weekly one,
plus per-model allowances — and both vendors report them only as a percentage
used. Neither states a limit in tokens, so Ullage shows **% left and when it
resets**, never an invented token budget. Beside each plan-wide limit it shows
what it saw you use in that window, with the four counters kept apart; that is a
floor, since the limit also counts usage Ullage cannot see (chat, other
machines).

- **Codex** writes its limits into its own transcripts on every turn, so they
  appear with no setup and no network. They are as fresh as your last Codex
  turn; an older reading says how old it is, and one from before the window
  reset says so instead of showing a number that is no longer true.
- **Claude** records nothing about limits on disk until you hit one. Switch on
  *Check Claude plan limits* (popover ⋯ menu, off by default) and Ullage asks
  `api.anthropic.com/api/oauth/usage` — the undocumented endpoint behind
  `/usage` — every 5 minutes, with Claude Code's own sign-in from the Keychain.
  It only reads that sign-in and never renews it; if it has expired, the popover
  says so until Claude Code's next request renews it. The endpoint is not a
  public API and may change; if it does, the limits disappear rather than show
  a wrong number.

### Token savers

[rtk](https://github.com/rtk-ai/rtk), [Tokenade](https://github.com/pi-infected/tokenade-npm),
[caveman](https://github.com/juliusbrussee/caveman) and
[Headroom](https://github.com/headroomlabs-ai/headroom) all exist to spend fewer
tokens. Ullage shows what each one actually did and lets you switch it on or off.
It never adds up a single "tokens saved" number, because nothing on disk records
what a session would have cost without the tool.

- **Did it run?** Claude Code logs every hook it runs in the transcript: the
  command, the tool call it ran for, the command it was rewritten to, and any
  error. Ullage reads those logs directly, so it can tell when a tool's hook
  ran but failed. For example, rtk's hook keeps running after the `rtk` binary
  is gone, and prints "rtk is not installed" every time.
- **rtk and Tokenade** filter tool output before the model sees it, so Ullage
  only ever sees the smaller version. Their savings come from their own logs
  (rtk's `history.db`, Tokenade's `~/.tokenade/gain.jsonl`), matched to a
  session by directory and time. They are shown with `≈` as that tool's own
  claim: rtk counts bytes ÷ 4, and Tokenade doesn't say how it counts. When
  both rewrite the same Bash call, the popover warns that their figures
  overlap and can't be added together.
- **caveman** shortens the model's replies, and Ullage measures output tokens
  exactly. It compares the median output per turn with caveman on and with it
  off, over the same directory's last 30 days of main-thread turns. That is a
  comparison of different work, not a saving, and it is labelled as one. It
  needs 20 turns on each side.
- **Headroom** is an MCP server. Ullage shows whether it was loaded and
  whether it was ever called; a loaded server that is never called still puts
  its tool definitions in every prompt.

The ⤢ button on the section opens the **Token savers window**. It shows each
tool over this session, 7 days or 30 days:
- what the transcripts prove: sessions it ran in, hook runs, rewrites, failures
  with the last error message, and MCP calls;
- for rtk and Tokenade, their own count per command (before, after and saved,
  all marked `≈`);
- for caveman, the two medians with their sample sizes, plus this session's
  output per reply, coloured by whether caveman was on;
- for Headroom, the sessions where it was loaded but never used.

`ullage savers --days 30` prints the same summary.

**The switches** change Claude Code's user config (`~/.claude/settings.json`,
`~/.claude.json`), and only when you click one or run `ullage savers
enable|disable`:

| Tool | Switching it off | Switching it on |
|---|---|---|
| caveman | sets its `enabledPlugins` flag to false | sets the flag back to true |
| rtk, Tokenade | moves its hooks, unchanged, into `parked-savers.json` next to Ullage's database | puts the hooks back from there |
| Headroom (and Tokenade's MCP server) | moves its `mcpServers` entry into the same file | puts the entry back |

**Installing and uninstalling** is always your call. Tools that are already
installed get a row. The others are listed under **Install…** in the section,
or you can use `ullage savers install|uninstall <name>`. Either way you see the
tool's own documented commands first, and nothing runs until you confirm. The
app runs them in Terminal, so you can watch, and so a browser sign-in
(Tokenade) or a Homebrew prompt works. Uninstalling uses whichever package
manager installed the tool (Homebrew, npm, pipx, uv, cargo), found from where
its binary really lives.

| Tool | Install | Uninstall |
|---|---|---|
| rtk | `brew install rtk` (or rtk's install script), then `rtk init -g` | `rtk init -g --uninstall`, then its package manager |
| Tokenade | `npm install -g @tokenade/cli`, `tokenade install`, `tokenade login` | `tokenade uninstall`, `npm uninstall -g @tokenade/cli` |
| caveman | `claude plugin marketplace add JuliusBrussee/caveman`, `claude plugin install caveman@caveman` | `claude plugin uninstall caveman@caveman`, then remove the marketplace |
| Headroom | `uv tool install "headroom-ai[mcp]"` (or pipx), `claude mcp add --scope user headroom -- headroom mcp serve` | `claude mcp remove --scope user headroom`, then its package manager |

A step is skipped if what it sets up is already there. When the run in Terminal
finishes, the tool's row says whether it worked ("caveman installed · on from
the next session", or which step stopped it), even if the popover was closed at
the time.

A switch you flip shows "Off from the next session" on its own row, with
**Undo** until you close the popover.

Each file is backed up to `backups/` next to the database before it is written.
Sessions already running keep what they loaded; the change applies from the
next one. Project-level config (`.claude/settings.json`, `.mcp.json`) is never
touched.

### Aggregating across machines and harnesses

`ullage otlp` sends what Ullage has measured to any collector that speaks
OTLP/HTTP — the OpenTelemetry Collector, Grafana, Honeycomb, Datadog, Jaeger —
so several machines and several harnesses can be looked at in one place.
Sessions become traces, with each turn a span and **each subagent a span under
the turn that spawned it**; tokens, window sizes and occupancy become metrics
under the `gen_ai.*` semantic conventions.

```bash
ullage otlp --dry-run --days 1        # read exactly what would be sent
ullage otlp --endpoint http://localhost:4318
```

Nothing leaves the machine through this unless you run that command: there is
no background exporter and no telemetry about Ullage itself. (The only other
thing that ever leaves is an alert to a phone you subscribed — see below.) Two details matter and are
covered in [`docs/OPENTELEMETRY.md`](docs/OPENTELEMETRY.md) — the export sends
the *whole prompt* as `gen_ai.usage.input_tokens` (Claude's own `input_tokens`
is just the uncached remainder, and exporting that under the standard name would
understate a cached session by three orders of magnitude), and a harness that
reports no tokens exports activity only rather than a misleading zero.

The database is at
`~/Library/Application Support/com.sturdynut.ullage/telemetry.db` (WAL mode).
`--db <path>` or `$ULLAGE_DB` moves it; `$CLAUDE_CONFIG_DIR` moves the transcript
source. Ingestion is incremental and idempotent: re-running it over the same
transcripts changes nothing.

### Reading it from a phone

A menu bar is only useful in front of the Mac. `ullage serve` puts the same
gauge on a web page — the live occupancy, what it is made of, and every recent
session — so a session you are driving from somewhere else is still visible.

```bash
ullage serve                 # http://127.0.0.1:7878, and tails transcripts too
ullage serve --no-watch      # when the app is already running and ingesting
```

It binds **127.0.0.1 and nothing else**, and there is deliberately no flag to
change that. To reach it from a phone, put [Tailscale](https://tailscale.com) in
front:

```bash
tailscale serve --bg 7878    # https://<machine>.<tailnet>.ts.net
```

That gives a real HTTPS certificate for the machine's tailnet name, reachable
only from your own devices — no port forwarding, no LAN exposure, and revoking
it is `tailscale serve --https=443 off`. Ullage itself never opens a socket the
rest of the network can see, so who may reach the page is Tailscale's decision
rather than a flag you have to remember you set.

The page reuses the display rules rather than reimplementing them: the same
floored percentage, the same amber threshold, and the same refusal to show a
number that has gone stale — if the Mac sleeps or drops off the tailnet, the
gauge dims and says so instead of leaving a confident percentage on screen.
Sessions whose harness reports no window show a dash, never `0%`.

### Alerts

Watching a gauge on a phone is the wrong shape for the thing you actually want,
which is to be told at 85% and otherwise left alone. Add the page to the phone's
Home Screen, open it from there, and tap **Enable alerts**; the device is then
notified when a window crosses 85% and again at 95%.

Once per crossing, not once per turn — a notification on every turn from 85% to
the end teaches you to swipe them away. A compaction re-arms it. Subagents never
alert (their window is not the one about to run out), and a harness that reports
no window never alerts at all.

The Home Screen step is not optional: iOS only permits notifications inside an
installed web app, never a plain Safari tab, which is also why the HTTPS from
Tailscale matters. Nothing is sent until a device subscribes — there is no
default recipient — and the notification body is encrypted to that device's own
key, so the push service relaying it (Apple's, for an iPhone) cannot read it.

```bash
ullage push            # which devices are subscribed, and how the last send went
ullage push --test     # buzz them all, to prove it works
```

[`docs/PHONE.md`](docs/PHONE.md) has the setup in full.

## Cache rebuilds

Claude caches the conversation between turns, so each turn only pays full price
for what is new. Some turns re-cache almost everything instead. Ullage flags a
turn whose cache write is over half its context (50k tokens or more, and not
straight after a compaction), marks it on the chart with a triangle, and names
the cause from what changed since the turn before:

| Cause | What changed | Marker |
|---|---|---|
| expired | more than an hour since the previous turn: the cache timed out | grey |
| model changed | a different model answered, e.g. `claude-opus-5-5 → claude-fable-5-1` | orange |
| effort changed | the recorded effort changed, e.g. `high → max` | orange |
| command | `/model`, `/effort`, `/fast`, `/config` or similar was typed in between | orange |
| unknown | nothing on disk explains it | grey |

The size shown is that turn's own measured cache write. Nothing is converted to
money or called waste. An expired cache after a break is expected, and an
unexplained one is not pinned on you, so only the three causes the session
itself produced count toward the `re-cached N×` warning in the collapsed line.
The turn straight after a compaction or `/clear` re-caches its new, smaller
context on purpose and is never counted.

## How the number is computed

The context window is the size of the prompt sent each turn:

```
context_tokens = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
occupancy      = context_tokens / window_limit
```

All three are prompt-side. `input_tokens` alone is only the uncached remainder
and undercounts by an order of magnitude on a cached session. The four token
counters (input, output, cache read, cache write) are kept separate everywhere:
a heavy session is almost entirely cache reads, so any single "total tokens"
number would just be a cache-read figure in disguise. `output_tokens` is stored
as reported, with no correction factor.

Verified by hand against Claude Code's own `/context`: it reported
`129.1k/1m (13%)` while Ullage showed `129,096 / 1,000,000` for the same turn.

Codex reports usage differently — its `input_tokens` is the whole prompt, cached
tokens included, and it states the model's context window on every turn. Ullage
splits that prompt back into the same four counters and reads the window from the
transcript, so no lookup table is needed for Codex and the rows stay exact.

Cursor reports none of this on disk, so its rows carry activity but no tokens and
no window; there is no percentage to compute for a Cursor session.

## Current limitations

- **Full support for two harnesses: Claude Code and the OpenAI Codex CLI.**
  Ullage reads Claude Code's `~/.claude/projects` transcripts and Codex's
  `~/.codex/sessions` rollouts, both with exact occupancy. The `vendor` and
  `confidence` columns keep each harness's numbers distinct.
- **Cursor is activity-only.** Cursor is a server-backed IDE: its token and
  context accounting lives on Cursor's servers, and the local agent transcripts
  (`~/.cursor/**/agent-transcripts`) hold conversation content but no token
  counts, model, window, or timestamps. Ullage lists Cursor sessions with their
  turn and tool counts (timed by the file, `confidence = unmeasured`) but shows
  no occupancy, and a Cursor session never drives the menu bar gauge. GitHub
  Copilot, Aider, and the rest are not read at all.
- **Cloud and web sessions are invisible.** Both harnesses can run in the cloud
  (Claude Code on the web, Codex cloud tasks); those transcripts stay on the
  server with no public per-session usage API, so only sessions that write to
  local disk are seen. `claude --teleport <id>` pulls a cloud Claude session
  down as a one-time local copy, which Ullage then reads.
- **The transcript formats are private and versioned**, not public contracts,
  and change between releases. Validated against Claude Code 2.1.270 and Codex
  CLI 0.145–0.146; after an upgrade a window size or field location can shift.
  `scripts/recon.sh` re-checks the Claude format against your disk, and
  [`docs/OBSERVED-FORMAT.md`](docs/OBSERVED-FORMAT.md) records what was seen.
- **Claude window sizes are a lookup table** (Codex reports its window exactly on
  every turn). A Claude model Ullage does not recognize falls back to 200k and is
  flagged as assumed, so its percentage may be wrong until the table is updated.
- **macOS 14+ only**, and the app is unsigned and un-notarized — a local build,
  not a distributed release.
- **The menu bar item can be hidden.** On Macs with a notch and many menu bar
  apps, macOS may tuck Ullage's item out of sight; a menu bar manager can pin it.
- Composition figures other than the window total are **length-based estimates**,
  not exact token counts, and subagent (`Task`) usage rolls into its parent
  session.

## Building from source

The collector (`Sources/UllageCore`) and the CLI (`Sources/ullage`) have no
macOS-only dependencies and build and test on Linux as well as macOS. The app
(`Sources/UllageApp`) is macOS only.

```bash
swift build
swift test        # runs on Linux or macOS
```

Layout:

```
Sources/UllageCore/    parsers (Claude Code, Codex, Cursor), ingestor, SQLite
                       store, and all analysis/display logic (kept UI-free)
Sources/ullage/        the command-line tool
Sources/UllageApp/     the SwiftUI menu bar popover and history window (macOS)
Tests/                 unit tests for the collector and every display rule
scripts/recon.sh       inspect the on-disk transcript format
scripts/install-app.sh build, bundle, and install the app
docs/                  the observed transcript format
```
