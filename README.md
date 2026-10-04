<div align="center">

<img src="assets/branding/ullage-logo.png" alt="Ullage logo: a brass U-shaped capacity gauge on charcoal" width="128" height="128">

# Ullage

**One place to see, and shrink, the context window of every coding agent you use.**

</div>

Claude Code, Codex and the rest each show context differently, or not at all.
Ullage reads them all the same way and shows, in your Mac's menu bar, how full
each session's context window is and what's filling it. It also lets you
install, switch on and measure popular context-saving tools like rtk, Serena and
claude-mem.

**Limitations**

- **Local sessions only.** Ullage reads the files agents write on your Mac, so
  cloud and web sessions (Claude Code on the web, Codex cloud, Copilot's coding
  agent) aren't included.
- **Some agents don't write token counts Ullage can read.** Cursor, Copilot CLI,
  Factory Droid and Zed show activity but no gauge.
- **macOS** for the menu bar app; the `ullage` command line also runs on Linux.

> **Ullage** — the empty space left at the top of a barrel or tank. Here, the
> room still left in the context window.

## What it looks like

<div align="center">

<img src="docs/screenshots/popover.png" alt="The Ullage popover: a session with 360k left of a 1M window, 63% used, Open in Claude, the context-per-turn chart with a compaction and cache-rebuild triangles, then one line each for Context, Session information, Agents, Context tools and Plan limits, with Open Ullage and Explain at the bottom" width="360">

</div>

<div align="center">

<img src="docs/screenshots/main-window.png" alt="The main window: a sidebar of Overview, Context, Session, Agents, Context tools, History and Plan limits; the Overview shows the session headline and bar, a large context-per-turn chart, and cards for each section" width="760">

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
    worktrees or checkouts with the same folder name are told apart), the
    model and its effort (`claude-opus-5-5 · high`), and **Open in Claude** or
    **Open in Codex** to continue it where you can type into it;
  - **the room left in the window**, in tokens, over a bar marked at 85% and at
    the session's own peak, with the exact `used / window` beneath it. For an
    agent that doesn't record token counts (Cursor, Zed), a line says so in
    place of the gauge;
  - directly under that, **context tokens per turn**, where the band above the
    line is the room left, captioned with what each turn now re-sends against
    the first (`591k left · each turn re-sends 409k, 38× the first`), with the
    85% line, a dotted line wherever a compaction dropped the window, and a
    triangle wherever a turn had to re-cache the whole conversation: orange
    when the session caused it (a model or effort switch), grey when the cache
    simply expired (hover for the exact turn, tokens, and cause; see
    [Cache rebuilds](#cache-rebuilds)).

  Below it, each section is **one row of its key figures**; clicking a row
  opens that section's page in the main window. **Open Ullage** opens the
  window on its Overview, and **Explain**, at the bottom right, opens one sheet
  with a section for the chart and for each part of the popover: the questions
  you might have, each answered with what it is, why it matters and what to do.
  - **Context**: the four totals, always in the same order and
    colours (`● Baseline 48k · ● Tools ≈41k · ● Output 85k · ● Other ≈55k`),
    `≈` on every estimate, with the section's rule drawn as their proportions.
  - **Session information**: the last turn's change and the turn count
    (`last turn +951 · turns 112`), led by `re-cached 2×` when something the
    session did made it cache its context again.
  - **Agents**: how many there are, how many haven't finished, and whose window
    is fullest.
  - **Context tools**: problems first, then how many are on and off
    (`rtk not running · Headroom idle · 1 on`).
  - **Plan limits**: each harness's tightest limit (`Claude 5h 88% left · Codex
    week 100% left`).

  It follows the most recently active session and holds still on it while the
  popover is open. The chevron at the top switches session — grouped by
  project, since a session id is not a name, with each entry's path — and
  stays accented while one is pinned.
- **Main window** — everything the popover summarizes, at full size. A
  sidebar of pages, the session picker and Open in Claude in the toolbar, and
  Explain at the foot of the sidebar:
  - **Overview**: the headline, a large chart with a key to its triangles, and
    a card per section that opens its page, plus **Along for the ride**.
  - **Context**: the [explorer](#context-explorer) treemap,
    then the four totals, the baseline's parts (CLAUDE.md, MCP servers,
    skills), every tool in the window, the targets **called most** (`Bash git
    status ×12`), and what is **along for the ride**: tool results from 50+
    turns ago still re-sent every turn, and files read more than once (all
    `≈`; 50 is a rule of thumb, not a measurement).
  - **Session**: the chart at full size, every figure, and each cache rebuild
    with its turn, size and cause. For an agent other than Claude Code, **What
    it records** lists what that agent doesn't write down (no cache split, no
    subagents, no gauge) so a missing figure never looks like a zero.
  - **Agents**: the tree of **subagents the session spawned**, each named by
    the description the agent above it wrote and each with **its own window and
    occupancy**. Click one and the chart, Context and Session figures switch
    to its context, here and in the popover.
  - **Context tools**: each tool's switch, install and uninstall, and its
    figures over this session, 7 or 30 days. See [Context tools](#context-tools).
  - **History**: activity per day stacked by project, model or effort over 7,
    30, 90 or 365 days, switchable between turns, output tokens and cache
    reads; every session in range with its path and agent count; and the
    selected session's agent tree, chart and full Context breakdown.
  - **Plan limits**: every limit with its bar, when it resets, and what Ullage
    itself saw in that window, with the *Check Claude plan limits* switch. See
    [Plan limits](#plan-limits).

### Context explorer

<div align="center">

<img src="docs/screenshots/composition-explorer.png" alt="The Context explorer opened to Tool results, then Bash, sized by calls: python3 23 calls, sed 18, grep 13, then install-app.sh, cat, sqlite3 and smaller commands, with a table of calls, estimated tokens and share of the window beside the treemap" width="760">

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
label. The explorer sits at the top of the main window's Context
page. It is live: it follows the session (or agent) shown and keeps its place
as turns arrive. Token figures here are the same
length estimates as the popover's, never counted tokens.

## Privacy

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
[context tool](#context-tools) switch, it edits Claude Code's user settings to
switch that one tool on or off. It backs the file up first and never throws
anything away. Installing or uninstalling a context tool runs that tool's own
commands, in Terminal, after showing them to you.

## Install

Requires macOS 14 or later, and Swift 6 (Xcode 16) to build.

### With Homebrew

```bash
brew install sturdynut/tap/ullage
ln -sf "$(brew --prefix)/opt/ullage/Ullage.app" /Applications/Ullage.app
open /Applications/Ullage.app
```

Homebrew builds Ullage from source on your Mac, so there's no Gatekeeper
warning. It installs the `ullage` command and `Ullage.app`; the `ln` puts the
app in Applications. To serve the [phone page](#reading-it-from-a-phone) in the
background, and again at every login:

```bash
brew services start ullage      # runs `ullage serve --no-watch` on 127.0.0.1:7878
```

`--no-watch` because the app already ingests; use `ullage serve` on its own if
the app isn't running. Update with `brew upgrade ullage`.

### From source

```bash
git clone https://github.com/sturdynut/Ullage.git
cd Ullage
scripts/install-app.sh          # builds, bundles Ullage.app, installs to /Applications
open /Applications/Ullage.app
```

Pass a directory to install elsewhere, e.g. `scripts/install-app.sh ~/Applications`.

Because the app is ad-hoc signed rather than notarized, a copy you didn't build
yourself may draw
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
ullage backfill        # from source: swift build && .build/debug/ullage backfill
```

## Using it

Ullage runs quietly in the menu bar and updates within a couple of seconds of
each turn. There is nothing to configure. Open the popover for a glance at the
live session, or the main window (**Open Ullage**) for everything at full size.

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
ullage composition <session> # what a session's context is made of
ullage serve [--port N]      # serve the gauge to a browser on 127.0.0.1
ullage push [--test]         # devices subscribed to alerts; --test buzzes them
ullage otlp --endpoint URL    # export everything measured to an OTLP collector
ullage env <session>         # a session's configuration snapshot
ullage limits [--fetch]      # plan limits left; --fetch asks Anthropic for Claude's
ullage savers [session]      # context tools: switched on, and what each did
ullage savers --days 30      # each tool across every session in the range
ullage tools                 # every context tool Ullage knows, built in or your own
ullage harnesses             # every coding agent Ullage reads, and what each records
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

### Context tools

[rtk](https://github.com/rtk-ai/rtk), [Tokenade](https://github.com/pi-infected/tokenade-npm),
[caveman](https://github.com/juliusbrussee/caveman) and
[Headroom](https://github.com/headroomlabs-ai/headroom) shrink what goes into
the window; [Serena](https://github.com/oraios/serena),
[codegraph](https://github.com/colbymchenry/codegraph) and
[claude-context](https://github.com/zilliztech/claude-context) let the model look
code up instead of reading whole files; and
[claude-mem](https://github.com/thedotmack/claude-mem) carries notes between
sessions. Ullage shows what each one actually did and lets you switch it on or off.
Each tool is a description, not code: add your own as a JSON file in
`~/.config/ullage/tools/` ([docs/CONTEXT-TOOLS.md](docs/CONTEXT-TOOLS.md)), and
`ullage tools` lists what loaded.
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
- **Serena, codegraph and claude-context** are code search. Ullage counts their
  lookups (MCP calls, and `codegraph` commands run in Bash) and roughly how much
  they returned, instead of whole files. claude-context sends your code to
  OpenAI and Zilliz Cloud by default; its install says so before anything runs.
- **claude-mem** carries notes between sessions. Ullage shows roughly how much
  it added to the context at session start, which is then sent with every turn.

The main window's **Context tools** page shows each tool over this session, 7
days or 30 days:
- what the transcripts prove: sessions it ran in, hook runs, rewrites, failures
  with the last error message, and MCP calls;
- for rtk and Tokenade, their own count per command (before, after and saved,
  all marked `≈`);
- for caveman, the two medians with their sample sizes, plus this session's
  output per reply, coloured by whether caveman was on;
- for Headroom, the sessions where it was loaded but never used;
- for code search tools, their lookups and what they returned;
- for claude-mem, what it injected per session and its memory searches.

`ullage savers --days 30` prints the same summary.

**The switches** change Claude Code's user config (`~/.claude/settings.json`,
`~/.claude.json`), and only when you click one or run `ullage savers
enable|disable`:

| Tool | Switching it off | Switching it on |
|---|---|---|
| caveman | sets its `enabledPlugins` flag to false | sets the flag back to true |
| rtk, Tokenade | moves its hooks, unchanged, into `parked-savers.json` next to Ullage's database | puts the hooks back from there |
| claude-mem | sets its `enabledPlugins` flag to false | sets the flag back to true |
| Headroom, Serena, codegraph, claude-context (and Tokenade's MCP server) | moves its `mcpServers` entry into the same file | puts the entry back |

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
| Serena | `uv tool install -p 3.13 serena-agent`, `claude mcp add --scope user serena -- serena start-mcp-server --context claude-code --project-from-cwd` | `claude mcp remove --scope user serena`, then its package manager |
| codegraph | `npm install -g @colbymchenry/codegraph` (or its install script), `codegraph install --target=claude --yes` | `codegraph uninstall --keep-cli`, then its package manager |
| claude-context | `claude mcp add --scope user claude-context … -- npx @zilliz/claude-context-mcp@latest`, with your OpenAI and Zilliz keys | `claude mcp remove --scope user claude-context` |
| claude-mem | `claude plugin marketplace add thedotmack/claude-mem`, `claude plugin install claude-mem@thedotmack` | `npx claude-mem uninstall` |

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
`--db <path>` or `$ULLAGE_DB` moves it; `$CLAUDE_CONFIG_DIR`, `$CODEX_HOME` and
`$CURSOR_HOME` move those agents' transcripts. Ingestion is incremental and idempotent: re-running it over the same
transcripts changes nothing.

### Reading it from a phone

<div align="center">

<img src="docs/screenshots/phone.png" alt="The phone page: the Ullage session with 602k left of a 1M window, 39% used, the context chart with grey and orange cache-rebuild triangles and a compaction, then Context, Session information (re-cached 2×), Agents, Context tools (Headroom idle), Plan limits and Sessions each collapsed to one line, Open in Claude and Explain, and Alerts on for this device" width="300">
&nbsp;&nbsp;
<img src="docs/screenshots/phone-help.png" alt="The phone page's help: How to read Ullage, with The chart open and its questions listed, each beside the mark it explains; What's an orange triangle? is open, saying it is a cache rebuild you caused and why it costs full price or more" width="300">

</div>

A menu bar is only useful in front of the Mac. `ullage serve` puts Ullage on a
web page laid out like the main window, one page at a time: an Overview with
the room left and the context chart, then a row per section (Context,
Session information, Agents, Context tools, Plan limits, and Sessions) that
slides its page in. A page closes with "‹ Overview" or the phone's back
gesture, and has its own address (`#page=savers`) you can bookmark. Sessions
lists every recent session with its path; pick one to look at it instead of
the latest. Below the rows, **Open in Claude** (for a session on Remote
Control) takes you to it on claude.ai or the Claude app, and **Open in Codex**
opens a Codex session's thread in the Codex app — the places to `/clear`,
`/compact` or run a skill in it. The Codex link is the app's own
`codex://threads/<id>`, so it works wherever the Codex app is installed.

The context tools section works here too: switches with Undo, and install or
uninstall, after the page shows the tool's exact commands. Installs run in a
Terminal window on the Mac, and the page reports how they went; a plan that
needs someone at the Mac (Tokenade's browser sign-in) says so instead of
starting. That one endpoint answers only to the page itself: it checks the
request's origin and a header another site cannot add, so a web page you
happen to have open cannot flip a switch.

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

The other agents are read the same way: each one's counters are split into the
same four, whichever way it reports them. Where an agent writes its window
(Codex, Qwen Code, Copilot) that is used; otherwise the window comes from the
model, from a table generated from [models.dev](https://models.dev)
(`scripts/model-windows.py`). A model that isn't in it gets no gauge rather
than a guessed window.

Cursor, Zed, Copilot CLI and Factory Droid record no per-turn token counts
Ullage can read, so their rows carry activity but no tokens and no window;
there is no percentage to compute for those sessions.

## Current limitations

- **Eighteen harnesses.** Claude Code and Codex are exact; Cursor is activity
  only (its token accounting lives on Cursor's servers). OpenCode, Pi, Amp, Gemini CLI, Qwen Code, Goose and Cline,
  Roo Code and Kilo Code record every call; Copilot in VS Code one reading per
  request; Crush the latest turn; Aider rounded figures (shown as estimates, no
  gauge); Factory Droid, Copilot CLI and Zed activity only. Each session
  says what its harness doesn't record. `ullage harnesses` lists them all. Kiro, Continue, Windsurf, Warp and cloud
  sessions are not read (`docs/harnesses/unsupported.md`).
- **Cloud and web sessions are invisible.** Agents can run in the cloud
  (Claude Code on the web, Codex cloud tasks); those transcripts stay on the
  server with no public per-session usage API, so only sessions that write to
  local disk are seen. `claude --teleport <id>` pulls a cloud Claude session
  down as a one-time local copy, which Ullage then reads.
- **The transcript formats are private and versioned**, not public contracts,
  and change between releases. Validated against Claude Code 2.1.270 and Codex
  CLI 0.145–0.146; after an upgrade a window size or field location can shift.
  `scripts/recon.sh` re-checks the Claude format against your disk, and
  [`docs/OBSERVED-FORMAT.md`](docs/OBSERVED-FORMAT.md) records what was seen.
- **Window sizes are a lookup table** for agents that don't write theirs down.
  A Claude model Ullage doesn't recognize falls back to 200k and is flagged as
  assumed; any other unknown model gets no gauge until the table is updated.
- **macOS 14+ only** for the app. It's ad-hoc signed, not notarized: Homebrew
  builds it from source on your Mac, so there's no Gatekeeper warning.
- **The menu bar item can be hidden.** On Macs with a notch and many menu bar
  apps, macOS may tuck Ullage's item out of sight; a menu bar manager can pin it.
- Context figures other than the window total are **length-based estimates**,
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
Sources/UllageCore/    harness adapters and parsers (Harnesses/), context tool
                       descriptors, ingestor, SQLite store, and all
                       analysis/display logic (kept UI-free)
Sources/ullage/        the command-line tool
Sources/UllageApp/     the SwiftUI menu bar popover and main window (macOS)
Tests/                 unit tests for the collector and every display rule
scripts/recon.sh       inspect the on-disk transcript format
scripts/install-app.sh build, bundle, and install the app
scripts/model-windows.py  regenerate model windows from models.dev
scripts/test-plan.py   rebuild the test checklist (docs/TESTING.csv)
docs/                  transcript formats (harnesses/), context tools, OTLP, phone
```

## License

Ullage is source-available under the [PolyForm Shield License 1.0.0](LICENSE.md).
In short: you can use it for anything, including at work, and change it for
your own use, but you can't sell it, offer it as a service, or build a product
that competes with it. The license text is what counts; this summary isn't
legal advice.

Copyright 2026 Matti Salokangas.
