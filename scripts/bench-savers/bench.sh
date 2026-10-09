#!/bin/bash
# Measure context tools against plain Claude Code on fixed tasks.
#
#   scripts/bench-savers/bench.sh [options] <setup>...
#     setup     base | <tool id> | <tool>+<tool>   (ids from `ullage tools`)
#     --model   sonnet (default) | haiku | opus
#     --tasks   t1,t2,t3,t4,t5   (default; t6 is the long, output-heavy one)
#     --reps    3 (default)
#     --jobs    6 parallel runs (default)
#     --screen  quick pass: haiku, t1-t4, 1 rep
#
# Every run is a headless `claude -p` in a fresh clone of this repo at
# BENCH_COMMIT, with the user's settings, MCP servers and plugins switched
# off and only the setup's own wiring loaded (`ullage savers config`). The
# user's ~/.claude/CLAUDE.md is moved aside for the duration and put back on
# exit, so instructions written for one tool don't steer every run.
# Results append to results/<date>-<model>.jsonl; analyze.py compares them.
set -eo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BENCH_COMMIT=6573fa2
model=sonnet tasks=t1,t2,t3,t4,t5 reps=3 jobs=6 setups=()
while [ $# -gt 0 ]; do
  case $1 in
    --model) model=$2; shift ;;
    --tasks) tasks=$2; shift ;;
    --reps) reps=$2; shift ;;
    --jobs) jobs=$2; shift ;;
    --screen) model=haiku tasks=t1,t2,t3,t4 reps=1 ;;
    -h|--help) sed -n 2,19p "$0"; exit 0 ;;
    *) setups+=("$1") ;;
  esac
  shift
done
[ ${#setups[@]} -gt 0 ] || { sed -n 2,19p "$0"; exit 1; }

WORK=${BENCH_WORK:-${TMPDIR:-/tmp}/ullage-bench}
mkdir -p "$WORK/runs" "$WORK/cfg"
ULLAGE="$REPO/.build/debug/ullage"
(cd "$REPO" && swift build >/dev/null)

# The repo as it was when the tasks and their answers were written, with the
# failing test task t2 starts from, built once and cloned per run.
if [ ! -d "$WORK/base/.build" ]; then
  rm -rf "$WORK/base"
  git clone -q "$REPO" "$WORK/base"
  git -C "$WORK/base" checkout -q "$BENCH_COMMIT"
  cp "$HERE/BenchTokenFormatTests.swift" "$WORK/base/Tests/UllageCoreTests/"
  git -C "$WORK/base" add -A
  git -C "$WORK/base" -c user.name=bench -c user.email=bench@localhost commit -qm "bench: failing test for t2"
  (cd "$WORK/base" && swift build --build-tests >/dev/null)
  rm -f "$WORK/fixture.db"
  "$ULLAGE" ingest "$REPO/Tests/Fixtures" --db "$WORK/fixture.db" >/dev/null
fi

# One config per setup: each tool's wiring merged, plus any MCP servers its
# plugins declare (--strict-mcp-config would otherwise drop them).
for setup in "${setups[@]}"; do
  out="$WORK/cfg/$setup.json"
  if [ "$setup" = base ]; then echo '{"hooks":{},"mcp":{},"plugins":[]}' > "$out"; continue; fi
  IFS=+ read -ra tools <<< "$setup"
  for t in "${tools[@]}"; do "$ULLAGE" savers config "$t" > "$WORK/cfg/$t.tool.json" || exit 1; done
  jq -n 'reduce inputs as $w ({hooks:{},mcp:{},plugins:[]};
      .hooks = (reduce ($w.hooks|to_entries[]) as $e (.hooks; .[$e.key] += $e.value))
      | .mcp += $w.mcp | .plugins += $w.plugins)' $(printf "$WORK/cfg/%s.tool.json " "${tools[@]}") > "$out"
  for dir in $(jq -r '.plugins[]' "$out"); do
    [ -f "$dir/.mcp.json" ] && jq --slurpfile p "$dir/.mcp.json" '.mcp += ($p[0].mcpServers // {})' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
  done
  if [ "$(jq '(.hooks|length) + (.mcp|length) + (.plugins|length)' "$out")" = 0 ]; then
    echo "$setup: nothing to load — is it installed? (\`ullage savers config <tool>\`)"; exit 1
  fi
done

CLAUDE_MD=~/.claude/CLAUDE.md
if [ -f "$CLAUDE_MD" ]; then
  [ -e "$CLAUDE_MD.bench-aside" ] && { echo "$CLAUDE_MD.bench-aside exists: a previous run did not finish. Restore it first."; exit 1; }
  mv "$CLAUDE_MD" "$CLAUDE_MD.bench-aside"
  trap 'mv "$CLAUDE_MD.bench-aside" "$CLAUDE_MD"' EXIT
  trap 'exit 130' INT TERM
fi

export WORK HERE ULLAGE model
results="$HERE/results/$(date +%Y-%m-%d)-$model.jsonl"
export results
# A copy where `ullage savers` reads it, to show each tool's last measurement.
BENCH_RESULTS="$HOME/Library/Application Support/com.sturdynut.ullage/bench-results.jsonl"
[ -n "$ULLAGE_DB" ] && BENCH_RESULTS="$(dirname "$ULLAGE_DB")/bench-results.jsonl"
mkdir -p "$(dirname "$BENCH_RESULTS")"
export BENCH_RESULTS
for setup in "${setups[@]}"; do
  for task in ${tasks//,/ }; do
    for rep in $(seq 1 "$reps"); do echo "$setup $task $rep"; done
  done
done | sort -R | xargs -P "$jobs" -L 1 "$HERE/run-one.sh"
echo "results: $results"
python3 "$HERE/analyze.py" "$results"
