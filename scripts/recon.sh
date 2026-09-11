#!/usr/bin/env bash
# M0 reconnaissance — run this on the Mac that has the transcripts.
#
# The transcript format is internal to Claude Code and changes between
# versions: everything the parser assumes is a hypothesis until this script
# confirms it against the disk. If the disk disagrees with the docs, the disk
# wins.
#
#   scripts/recon.sh                      report on the newest transcripts
#   scripts/recon.sh fixture FILE [OUT]   scrub a real transcript into a fixture
set -euo pipefail

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECTS_DIR="$CONFIG_DIR/projects"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }

newest_transcripts() {
  # Largest recently-modified transcripts, most recent first.
  find "$PROJECTS_DIR" -name '*.jsonl' -type f -print0 2>/dev/null \
    | xargs -0 ls -S 2>/dev/null | head -n "${1:-3}"
}

check_retention() {
  echo "## Retention"
  echo
  local settings="$CONFIG_DIR/settings.json"
  if [[ ! -f "$settings" ]]; then
    echo "!! $settings does not exist."
  else
    local days
    days="$(jq -r '.cleanupPeriodDays // "unset"' "$settings" 2>/dev/null || echo "unparseable")"
    echo "cleanupPeriodDays: $days"
    if [[ "$days" == "unset" || "$days" == "unparseable" ]]; then
      echo
      echo "!! Claude Code deletes transcripts older than 30 days at startup, silently"
      echo "!! and unrecoverably. Set this before anything else:"
      echo "!!   { \"cleanupPeriodDays\": 3650 }"
    fi
  fi
  echo
  local oldest
  oldest="$(find "$PROJECTS_DIR" -name '*.jsonl' -type f -exec stat -f '%m %N' {} + 2>/dev/null \
    || find "$PROJECTS_DIR" -name '*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null)"
  if [[ -n "$oldest" ]]; then
    echo "transcripts:  $(echo "$oldest" | wc -l | tr -d ' ') files"
    echo "oldest:       $(echo "$oldest" | sort -n | head -1 | cut -d' ' -f2-)"
  fi
  echo
}

report() {
  need jq
  echo "# Claude Code transcript reconnaissance"
  echo
  echo "generated:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "claude:       $(claude --version 2>/dev/null || echo 'not on PATH')"
  echo "config dir:   $CONFIG_DIR"
  echo
  [[ -d "$PROJECTS_DIR" ]] || { echo "No projects directory at $PROJECTS_DIR"; exit 1; }
  check_retention

  local files
  files="$(newest_transcripts 3)"
  [[ -n "$files" ]] || { echo "No .jsonl transcripts found."; exit 1; }

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    echo "## $file"
    echo
    echo "### Line types"
    echo '```'
    jq -r '.type // "«no type»"' < "$file" 2>/dev/null | sort | uniq -c | sort -rn
    echo '```'
    echo
    echo "### Keys on an assistant entry"
    echo '```'
    jq -c 'select(.type == "assistant") | keys' < "$file" 2>/dev/null | head -1
    echo '```'
    echo
    echo "### usage shape (the fields the whole product depends on)"
    echo '```'
    jq -c 'select(.type == "assistant") | .message.usage' < "$file" 2>/dev/null | head -5
    echo '```'
    echo
    echo "### Last turn's context_tokens (compare against /context in a live session)"
    echo '```'
    jq -s -r '
      map(select(.type == "assistant") | .message.usage) | last
      | if . == null then "no assistant entries"
        else
          "input              \(.input_tokens // 0)\n" +
          "cache_creation     \(.cache_creation_input_tokens // 0)\n" +
          "cache_read         \(.cache_read_input_tokens // 0)\n" +
          "-----------------------------\n" +
          "context_tokens     \((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))\n" +
          "output (unreliable) \(.output_tokens // 0)"
        end' < "$file" 2>/dev/null
    echo '```'
    echo
    echo "### Tool names invoked"
    echo '```'
    jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' \
      < "$file" 2>/dev/null | sort | uniq -c | sort -rn | head -20
    echo '```'
    echo
  done <<< "$files"

  echo "## Next"
  echo
  echo "1. Record what you saw above in docs/OBSERVED-FORMAT.md, with the version."
  echo "2. Scrub 2-3 of these into fixtures:  scripts/recon.sh fixture <file>"
  echo "3. Run /context in a live session and check it against context_tokens above."
}

# Replaces the text of every payload-bearing field with same-length filler, so
# token and length estimates stay meaningful while prompts and file contents do
# not get committed. Structure, ids, timestamps and usage counters survive.
fixture() {
  need jq
  local source="${1:?usage: recon.sh fixture FILE [OUT]}"
  local out="${2:-Tests/Fixtures/$(basename "$source")}"
  mkdir -p "$(dirname "$out")"
  jq -c '
    def filler: if type == "string" then (if length == 0 then "" else ("x" * length) end) else . end;
    def payload: ["text","content","summary","command","description","file_path","path","pattern",
                  "query","url","old_string","new_string","prompt","stdout","stderr","data"];
    walk(
      if type == "object"
      then reduce payload[] as $k (.; if (.[$k]? | type) == "string" then .[$k] = (.[$k] | filler) else . end)
      else . end
    )
    | if has("cwd") then .cwd = "/Users/dev/" + (.cwd | split("/") | last) else . end
    | if has("gitBranch") then .gitBranch = "main" else . end
  ' < "$source" > "$out"
  echo "wrote $out ($(wc -l < "$out" | tr -d ' ') lines)"
  echo
  echo "Read it before committing. Scrubbing is best-effort: anything in a key"
  echo "not listed above came through untouched."
}

case "${1:-report}" in
  report) report ;;
  fixture) shift; fixture "$@" ;;
  *) echo "usage: recon.sh [report | fixture FILE [OUT]]" >&2; exit 2 ;;
esac
