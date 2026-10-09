# Benchmarking context tools

A tool's own ledger says what it kept out. This says what a session actually
cost with it, against the same session without it: same tasks, same repo,
measured by Ullage from the transcripts.

```bash
scripts/bench-savers/bench.sh base rtk codegraph          # Sonnet, t1–t5, 3 reps each
scripts/bench-savers/bench.sh --screen base newtool       # quick look: Haiku, t1–t4, 1 rep
scripts/bench-savers/bench.sh --tasks t6 base rtk         # the long, output-heavy task
scripts/bench-savers/bench.sh base rtk+caveman            # a stack
scripts/bench-savers/analyze.py results/*-sonnet.jsonl    # compare again, any time
```

A setup is `base` (no tools), a tool id from `ullage tools`, or ids joined with
`+`. The tool must be installed, on or off: its hooks, MCP servers and plugins
are taken from Claude Code's config (or the copy Ullage parked when it was
switched off) by `ullage savers config <tool>`. A tool whose installer writes
instructions into CLAUDE.md gets them from `instructions/<id>.md`.

## How a run is isolated

Each run is a headless `claude -p` in a fresh clone of this repo at a pinned
commit (`BENCH_COMMIT`), so answers can be graded the same way next month.
`--setting-sources project`, `--strict-mcp-config` and explicit
`--plugin-dir`s mean only the setup's own wiring loads, never the rest of your
config. Your `~/.claude/CLAUDE.md` is moved aside for the run and put back on
exit (a run interrupted hard leaves `CLAUDE.md.bench-aside`; the next run
refuses to start until it is restored). A usage limit is waited out, not
scored.

## Tasks

| Task | What | Graded by |
|---|---|---|
| t1 | find the cache-rebuild rule and its thresholds | names and numbers in the answer |
| t2 | make a failing test pass | the test passes, unedited |
| t3 | trace a transcript line to the menu bar | types named in the answer |
| t4 | how each harness maps its token counters | parsers named in the answer |
| t5 | add `sessions --json`, run the suite | JSON shape, row count, `swift test` |
| t6 | add `--json` to four commands, reading full build and test output | each command's JSON |

t1–t5 run 3–12 calls each. t6 runs about 30, with contexts up to 400k, so it
needs a model with a large window: not Haiku.

## Results

`results/<date>-<model>.jsonl`, one row per run, with Ullage's four counters
for the whole session (subagents included), the grade, and Claude Code's
list-price cost (quota on a subscription, not money), and the version of each
tool in the setup. They are checked in, so a tool's result can be compared
across its versions, and a copy goes to `bench-results.jsonl` next to Ullage's
database, where `ullage savers` reads it: each tool's latest measurement, and
"re-run" once the installed version is not the one measured.

Read them with care:

- **Run-to-run spread is wide.** One model choice — reading a whole test log
  or filtering it — moved a run's cost 3–4×. Differences under ~10% need more
  than 3 reps.
- **Short tasks favour no tool.** Every tool adds a fixed cost to each prompt
  (rtk ~0.35k tokens, codegraph ~5k, the Headroom proxy ~15k), and a 5-call
  task has little output to shrink.
- **A tool the model never calls is measured as loaded.** Headroom's MCP
  server was never called in any run.
- **Memory tools are measured cold.** claude-mem's value across sessions is
  not in these numbers.
