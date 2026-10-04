# Zed agent (`zed`)

**Status:** activity only in practice. **Verified on disk:** schema only. A
`threads.db` exists on the development Mac and its schema matches below, but
it held no threads, so no thread data has been read.

## Where

`<data_dir>/threads/threads.db` (`crates/agent/src/db.rs:446`), where `data_dir`
is `~/Library/Application Support/Zed` on macOS and
`$FLATPAK_XDG_DATA_HOME|$XDG_DATA_HOME|~/.local/share` + `/zed` on Linux
(`crates/paths/src/paths.rs:144`). `ZED_DATA_DIR` points Ullage elsewhere.

## Shape

```sql
CREATE TABLE threads (id TEXT PRIMARY KEY, summary TEXT NOT NULL, updated_at TEXT NOT NULL,
  data_type TEXT NOT NULL, data BLOB NOT NULL,
  parent_id TEXT, folder_paths TEXT, folder_paths_order TEXT, created_at TEXT);
```

- `updated_at`: RFC 3339 (`db.rs:513`).
- `parent_id`: set for a subagent thread → `session_id = parent_id`, `agent_id = id` (rule 1).
- `folder_paths`: newline-separated workspace paths; the first is used as `cwd`.
- `data`: the whole `DbThread` as JSON, **zstd-compressed**; `save_thread`
  always writes `data_type = 'zstd'` (`db.rs:536`). `'json'` only appears in old rows.

Inside `data`, `request_token_usage` (`db.rs:65`) maps each user message id to the
`TokenUsage` of the last request in that turn (`thread.rs:2388`):
`input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
`cache_read_input_tokens` (`crates/language_model_core/src/language_model_core.rs:526`),
which are four disjoint counters. The model is `model.model`.

## Mapping

| Row kind | When | Counters | Window |
|---|---|---|---|
| activity (`unmeasured`) | `data_type = 'zstd'`, or JSON with no usage | all 0 | nil |
| per request (`exact`) | `data_type = 'json'` | `input_tokens`→input, `cache_read_input_tokens`→cacheRead, `cache_creation_input_tokens`→cacheWrite, `output_tokens`→output | `WindowLimits.knownLimit(model)` |

Dedupe keys: `zed:<thread>` (activity) and `zed:<thread>:<user message id>`.

An entry with only `input_tokens` (no output and no cache) is skipped. It is
`mark_token_limit_exceeded` (`thread.rs:2406`) recording the model's maximum
as a placeholder after an overflow, so it is not a measurement.

## Not recorded / not read

- **Token data for any thread Zed writes today.** Foundation has no zstd and
  the package takes no dependencies, so compressed rows can only be read as activity.
  Supporting them needs a zstd decoder in Core (pure Swift, or behind
  `#if canImport`).
- No per-message timestamps: every row of a thread carries `updated_at`.
- Tool calls, compaction (`Message::Compaction`) and the window: none are read.
