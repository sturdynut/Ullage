# Aider (`aider`)

**Status:** approximate: estimated figures and no gauge. **Verified on disk:** no.
This Mac has `~/.aider` (analytics and caches only) and no chat history in `~/Code`.

## Where

`.aider.chat.history.md` at each git root, on by default
(`aider/args.py:274`, `--chat-history-file`). Aider keeps **no global list of
repos**, so Ullage has nothing to discover them from. Two ways in:

- `ULLAGE_AIDER_REPOS=/path/repo1:/path/repo2` (a directory, or a `.md` path
  for a custom history file). Each entry becomes a watched root.
- `ullage ingest /path/repo/.aider.chat.history.md`.

The roots are files, and hidden ones. The app's first sweep
(`SessionTailer.start` → `ingestDirectory`) enumerates directories only, so an
Aider history is picked up when it next changes or by `ullage ingest`, not at launch.

## Shape (Markdown, appended)

- Session header: `# aider chat started at YYYY-MM-DD HH:MM:SS` in **local time**,
  no zone (`aider/io.py:336`).
- Aider's own output is echoed as `> ` blockquotes (`io.py` `tool_output`):
  - banner (`base_coder.py:207`): `> Model: <name> with <fmt> edit format…`, or
    `> Main model: …` when a weak model is set.
  - after each reply (`base_coder.py:1994`):
    `> Tokens: 12k sent, 1.5k cache write, 8.2k cache hit, 1.2k received.`
    The cache parts appear only when non-zero. Cost follows on the same line or the next.
- User input: `#### <text>` (`io.py:775`).

## Mapping

| Text | Counter |
|---|---|
| `cache hit` | cacheRead |
| `cache write` | cacheWrite |
| `sent` − hit − write (floored at 0) | input |
| `received` | output |

`contextTokens = input + cacheRead + cacheWrite`. Numbers use `format_tokens`
(`aider/utils.py:279`): `834`, `1.2k`, `12k`, so they are rounded. Every row is
`confidence = estimated`, `windowLimit = nil`.

"sent" is `completion.usage.prompt_tokens`, plus `cache_creation_input_tokens`
when the provider reports cache fields. Ullage treats it as the whole prompt,
cache included, which is LiteLLM's OpenAI-style meaning. If a provider's
`prompt_tokens` excludes cache reads, `input` undercounts. `sent` also **sums
every completion behind one reply** (`message_tokens_sent` is reset only in
`show_usage_report`, `base_coder.py:2102`), so a reply with reflections or
retries overstates the prompt.

`#### /clear` and `#### /reset` become `clear` events. Session id:
`aider-<sha256(path)[0..8]>-<start UTC yyyyMMddHHmmss>`. Dedupe:
`aider:<session>:<reply ordinal>`. Replies carry their session's start time,
because Aider writes no time per reply.

## Not supported: `--analytics-log`

The opt-in analytics JSONL logs `message_send` events with exact
`prompt_tokens`/`completion_tokens` (the same per-reply sum, no cache split) and
a model name that may be redacted. Its path is whatever the user passed
(`args.py:575`). There is no default and no session id or cwd in the events, so
the rows could not be tied to a session. It is not read.

## Not recorded

The context window, tool calls, per-reply timestamps, and compaction (Aider's
history summarization leaves no mark).
