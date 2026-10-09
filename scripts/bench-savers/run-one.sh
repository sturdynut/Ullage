#!/bin/bash
# run-one.sh <setup> <task> <rep> — one headless session, graded. Called by bench.sh.
setup=$1 task=$2 rep=$3
id="$setup-$task-$rep-$model"
dir="$WORK/runs/$id"
rm -rf "$dir"; cp -cR "$WORK/base" "$dir" 2>/dev/null || cp -R "$WORK/base" "$dir"
cd "$dir" || exit 1

cfg="$WORK/cfg/$setup.json"
jq '{hooks}' "$cfg" > .bench-settings.json
jq '{mcpServers: .mcp}' "$cfg" > .bench-mcp.json
plugin_args=(); for d in $(jq -r '.plugins[]' "$cfg"); do plugin_args+=(--plugin-dir "$d"); done
# The instructions a tool's installer puts in CLAUDE.md, where it puts them.
if [ "$setup" != base ]; then
  IFS=+ read -ra tools <<< "$setup"
  for t in "${tools[@]}"; do [ -f "$HERE/instructions/$t.md" ] && { echo; cat "$HERE/instructions/$t.md"; } >> CLAUDE.md; done
fi

# A usage limit is waited out, not scored.
for attempt in 1 2 3 4 5 6; do
  start=$(date +%s)
  claude -p "$(cat "$HERE/tasks/$task.txt")" --model "$model" \
    --setting-sources project --settings .bench-settings.json \
    --strict-mcp-config --mcp-config .bench-mcp.json "${plugin_args[@]}" \
    --dangerously-skip-permissions --max-budget-usd 15 \
    --output-format stream-json --verbose > .bench-stream.jsonl 2> .bench-stderr.txt
  secs=$(( $(date +%s) - start ))
  result=$(grep '"type":"result"' .bench-stream.jsonl | tail -1)
  if grep -qiE 'rate.?limit|usage limit|overloaded' <<< "$result$(cat .bench-stderr.txt)" && [ "$(jq -r '.is_error // true' <<< "${result:-{\}}")" = true ]; then
    echo "$id: usage limit, waiting 15 min (attempt $attempt)"; sleep 900; continue
  fi
  break
done

text=$(jq -r '.result // ""' <<< "${result:-{\}}")
has() { grep -Eq -- "$1" <<< "$text"; }
score=0 parts=0
point() { parts=$((parts+1)); "$@" && score=$((score+1)); }
F="$WORK/fixture.db" U=.build/debug/ullage
case $task in
  t1) for k in CacheRebuild.swift detect '50_?000|50,000' '0\.5|50%' 'hour|3600|3,600|60 \* 60'; do point has "$k"; done ;;
  t2) point eval 'git diff --quiet HEAD -- Tests/UllageCoreTests/BenchTokenFormatTests.swift && swift test --filter TokenFormat >/dev/null 2>&1' ;;
  t3) for k in 'FSEventsWatcher|DirectoryWatch' SessionTailer Ingestor ClaudeCodeParser 'Store|upsert' latestCall MenuBarState MenuBarModel; do point has "$k"; done ;;
  t4) for k in ClaudeCodeParser CodexParser Aider Amp ClineFamily CopilotCLI CopilotVSCode Crush Droid GeminiCLI Goose OpenCode 'Pi\.swift' QwenCode Zed CursorParser; do point has "$k"; done ;;
  t5) swift build >/dev/null 2>&1; j=$($U sessions --json --db "$F" 2>/dev/null)
      point jq -e 'type=="array" and length>0 and all(.[]; has("project") and has("session_id") and has("calls") and has("context_tokens") and has("input") and has("output") and has("cache_read") and has("cache_write") and has("last_ts"))' <<< "$j"
      rows=$($U sessions --db "$F" | awk 'NR>1 && NF==0 {exit} NR>1 {n++} END {print n+0}')
      point test "$(jq length <<< "$j" 2>/dev/null)" = "$rows"
      point eval 'swift test >/dev/null 2>&1' ;;
  t6) swift build >/dev/null 2>&1; S=$($U latest --db "$F" | awk '/^session/ {print $2}')
      for c in sessions latest history "composition $S"; do point eval "$U $c --json --db '$F' 2>/dev/null | jq -e 'type==\"array\" or type==\"object\"' >/dev/null"; done ;;
esac
score=$(echo "scale=2; $score / $parts" | bc)

# Tokens as Ullage counts them, stored with the result: transcripts age out
# of ~/.claude/projects, the results file is the record. Every call in the
# session, subagents included, one counter at a time.
session=$(jq -r '.session_id // empty' <<< "${result:-{\}}")
transcripts=$(dirname "$(find ~/.claude/projects -maxdepth 2 -name "$session.jsonl" 2>/dev/null | head -1)")
measured='{}'
if [ -n "$session" ] && [ "$transcripts" != . ]; then
  db="$WORK/measure-$id.db"
  "$ULLAGE" ingest "$transcripts" --db "$db" >/dev/null 2>&1
  measured=$(sqlite3 -json "$db" "SELECT SUM(input) input, SUM(output) output, SUM(cache_read) cache_read, SUM(cache_write) cache_write,
      SUM(input + cache_write + cache_read) sent, COUNT(*) calls,
      MAX(CASE WHEN agent_id IS NULL THEN context_tokens END) peak FROM call WHERE session_id = '$session'" | jq '.[0]')
  rm -f "$db" "$db-wal" "$db-shm"
fi

jq -c --arg id "$id" --arg setup "$setup" --arg task "$task" --argjson rep "$rep" --arg model "$model" \
  --arg commit "$(git -C "$WORK/base" rev-parse --short HEAD~1)" --argjson score "$score" --argjson secs "$secs" --argjson tokens "${measured:-{\}}" \
  '{id:$id, setup:$setup, task:$task, rep:$rep, model:$model, commit:$commit, score:$score, secs:$secs,
    session:.session_id, cost:.total_cost_usd, turns:.num_turns, is_error:.is_error, at:(now|todate), tokens:$tokens}' \
  <<< "${result:-{\}}" >> "$results"
echo "$id score=$score secs=$secs"
