# Goose (`goose`, block/goose)

**Status:** every call, exact, window looked up. **Verified on disk:** no. No
Goose data exists on the development Mac. The reader is written against the source
(schema v16) and tested on a synthesized database.

## Where

`Paths::data_dir()/sessions/sessions.db` (`crates/goose/src/session/session_manager.rs:30`).
`data_dir` uses etcetera's `choose_app_strategy`, which is **XDG on macOS
too** (`crates/goose/src/config/paths.rs:22`): `$XDG_DATA_HOME/goose` or
`~/.local/share/goose`. An absolute `GOOSE_PATH_ROOT` replaces it with
`<root>/data` (`paths.rs:44`). Older `sessions/*.jsonl` files are only read by
Goose to migrate them into the database (`session/legacy.rs`), so Ullage does
not read them either.

## Shape

`usage_ledger` (`session_manager.rs:1084`), one row per provider response,
written by `insert_usage_ledger_row` (`:901`):

```
id INTEGER PK AUTOINCREMENT, session_id, created_timestamp INTEGER (unix s),
model, input_tokens, output_tokens, total_tokens, cache_read_tokens,
cache_write_tokens, cost, cost_source, is_compaction
```

`sessions` (`:1028`) gives `working_dir`, `parent_session_id`,
`model_config_json` (`model_name`), and the latest-turn columns
`input_tokens … cache_write_tokens`. Those are overwritten per call
(`record_usage_metrics`, `:2354`).

**Goose's `input_tokens` is the whole prompt.** `Usage` documents that the cache
fields are subsets of it, and that Anthropic/Bedrock parsers fold cache into it
(`crates/goose-provider-types/src/conversation/token_usage.rs:88-93`).

## Mapping

| Goose | Ullage |
|---|---|
| `input_tokens − cache_read − cache_write` (≥ 0) | input |
| `cache_read_tokens` | cacheRead |
| `cache_write_tokens` | cacheWrite |
| `output_tokens` | output |
| `model` (else `model_config_json.model_name`) | model, window via `WindowLimits.knownLimit` |
| `parent_session_id` | session = parent, agent = child (rule 1) |
| `is_compaction = 1` | a `compaction` event, not a call |

Skipped: `cost_source = 'carried_forward'` rows. Goose synthesizes these once
to carry pre-ledger totals forward (`:2381`), so each is a sum, not a call. Rows with
no input and no output are also skipped. Dedupe: `goose:<session>:<ledger id>`.

**Fallback:** a database with no `usage_ledger` (older Goose) yields one
row per session from the `sessions` columns, keyed `goose:<session>` and
updated in place (latest only).

## Not recorded / not read

The context window (`ModelConfig.context_limit` is `#[serde(skip)]`), sub-second
times, and tool calls (they are in `messages.content_json`, not read).
