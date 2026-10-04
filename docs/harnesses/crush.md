# Crush (`crush`, charmbracelet/crush)

**Status:** latest only, exact (with a caveat), no cache split. **Verified on disk:** no.
No Crush data exists on the development Mac.

## Where

Per project: `<data_directory>/crush.db`, default `<project>/.crush/crush.db`
(`internal/db/connect.go:93`, `internal/config/config.go:25`). The path is
resolved to absolute (`internal/config/load.go:596`). Crush registers each
project it runs in (`internal/cmd/root.go:302`) in `projects.json`
(`internal/projects/projects.go:14`), which sits beside the global data file:
`$CRUSH_GLOBAL_DATA`, else `$XDG_DATA_HOME/crush`, else `~/.local/share/crush`
(`load.go:1259`). Entries are `{"path", "data_dir", "last_accessed"}`, and each
`data_dir` is a root.

## Shape

`sessions` (`internal/db/migrations/20250424200609_initial.sql`): `id`,
`parent_session_id`, `prompt_tokens`, `completion_tokens`, `updated_at` (unix s).
`messages.model` names the model per assistant message.

`prompt_tokens` is **overwritten after every step** with
`InputTokens + CacheReadTokens + CacheCreationTokens` of that step
(`internal/agent/agent.go:2076-2087`). It is the latest context, already
summed, with no per-call history and no split. After a summary it is set to 0 (`agent.go:1538`).

## Mapping

One row per session, `crush:<session>`, updated in place:
`contextTokens = input = prompt_tokens`, cache counters 0, `output = completion_tokens`,
model = newest assistant message's `model`, window via
`WindowLimits.knownLimit`. `parent_session_id` gives session = parent and
agent = child. `prompt_tokens = 0` → `unmeasured`, no window. `cwd` is the parent of
`.crush` (none for a custom data directory).

## Caveats

- When a provider returns no usage, Crush estimates it
  (`fallbackStepUsage`, `agent.go:1086`) and stores the result in the same
  column. The flag that marks this (`EstimatedUsage`) lives only in memory, so
  such rows read as `exact`.
- Cache is folded into `input`, so cache-rebuild detection never fires for Crush.

## Not recorded / not read

Per-call history, the cache split, the window, and tool calls (they are in
`messages.parts`, not read).
