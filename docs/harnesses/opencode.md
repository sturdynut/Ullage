# OpenCode (`opencode`)

Source read: `github.com/sst/opencode` (redirects to the current org), commit
`907b3bc` (2026-10-02). Paths below are relative to that repo. Parser:
`Sources/UllageCore/Harnesses/OpenCode.swift`, `OpenCodeReader.version = 1`.

**Verified on disk: no.** There was no `~/.local/share/opencode` on the Mac
this was written on. Everything here comes from the writer's source code. The
tests build a SQLite fixture from OpenCode's own migration DDL.

## Where it stores data

- One SQLite database (WAL): `$XDG_DATA_HOME/opencode/opencode.db`. The XDG
  default is `~/.local/share`, and that is also the default on macOS
  (`xdg-basedir`, `packages/core/src/global.ts:3,11`).
- `OPENCODE_DB` overrides the file: an absolute path, or a path relative to the
  data dir. `:memory:` means nothing is written to disk
  (`packages/core/src/database/database.ts:43-55`).
- Builds on a channel other than `latest`/`beta`/`prod` write
  `opencode-<channel>.db` (`database.ts:54`).
- The root Ullage watches is the data **directory**, because writes land in
  `opencode.db-wal`. `owns` claims only `…/opencode/opencode.db`,
  `…/opencode/opencode-*.db` and the exact `OPENCODE_DB` file. The data dir also
  holds `log/direct/*.jsonl` traces and `repos/` and `worktree/` checkouts;
  `Harness.owning` no longer hands those to the Claude fallback.

### Legacy JSON storage: out of scope

Before v1.2 there was one JSON file per record:
`storage/{session,message,part}/…/*.json`. The v1.2.0 migration
(`packages/opencode/src/storage/json-migration.ts` at tag `v1.2.0`, lines
113-120) copies every session, message and part into SQLite with the same ids,
and it **does not delete the files**.

Reading both would count every pre-1.2 call twice, because the JSON message
files carry message-level usage while the DB is read per step. Anyone still on
OpenCode <1.2 gets their history read once they upgrade and OpenCode migrates
it. A pure-legacy install is not read.

## Record shape

Tables (`packages/core/src/session/sql.ts:22-98`; DDL in
`packages/core/src/database/migration/20260127222353_familiar_lady_ursula.ts`):

- `session(id, project_id, parent_id, directory, title, …, time_created, …)`:
  `parent_id` is set for subagent sessions.
- `message(id, session_id, time_created, time_updated, data)`: `data` is the
  message JSON without `id`/`sessionID`.
- `part(id, message_id, session_id, time_created, time_updated, data)`: `data`
  is the part JSON without `id`/`sessionID`/`messageID`. `time_created` is the
  time of the first write, in ms (`packages/core/src/session/projector.ts:309-326`).

The v2 `session_message` / `event` tables exist but are a separate,
repeatedly-reset projection (`20260622170816_reset_v2_session_state.ts`), so
they are not read.

Assistant message `data` (`packages/schema/src/v1/session.ts:453-485`):
`role:"assistant"`, `time{created, completed?}` (ms), `parentID`, `modelID`,
`providerID`, `mode`, `agent`, `path{cwd, root}`, `summary?`, `cost`,
`tokens{total?, input, output, reasoning, cache{read, write}}`, `variant?`,
`finish?`, `error?`.

Parts used (`session.ts`):

- `step-finish` (`:240-256`): `reason`, `cost`, `tokens{…}` (same shape).
- `tool` (`:315-322`): `callID`, `tool`, `state{status, input, output|error,
  metadata, time{start,end}}`.
- `compaction` (`:195-201`): `auto`, `overflow?`, `tail_start_id?`. It sits on
  the *user* message that asked for compaction.

## One call per `step-finish`

The prompt loop creates one assistant message per loop iteration
(`packages/opencode/src/session/prompt.ts:1185-1200`). At every LLM
`step-finish` the processor writes a `step-finish` part with that step's usage,
then *overwrites* `message.tokens` with the same usage
(`packages/opencode/src/session/processor.ts:452-470`). The session totals are
summed from `step-finish` parts (`projector.ts:36-41`).

So:

- Each `step-finish` part is one model call. Its dedupe key is
  `opencode:<partID>`, and its `ts` is the part's `time_created`.
- An assistant message with **no** `step-finish` but non-zero `tokens` (older
  shape) is one call, keyed `opencode:<messageID>`, with
  `ts = time.completed ?? time.created`.
- All-zero usage (aborted or errored before any step) is not a request and is
  skipped.

## Field → counter mapping

`Session.getUsage` (`packages/opencode/src/session/session.ts:338-377`) gets
AI SDK v6 usage, where `inputTokens` includes cached tokens for **every**
provider. It stores:

| stored | meaning | Ullage |
|---|---|---|
| `tokens.input` | `inputTokens − cache.read − cache.write`, the uncached remainder | `input` |
| `tokens.cache.read` | `cacheReadInputTokens` | `cacheRead` |
| `tokens.cache.write` | `cacheWriteInputTokens` or the provider metadata (anthropic, vertex, bedrock, venice) | `cacheWrite` |
| `tokens.output` | `outputTokens − reasoning` | `output` |
| `tokens.reasoning` | reasoning tokens | `reasoning` (never added to output) |

`contextTokens = input + cacheRead + cacheWrite`, which equals the provider's
inclusive prompt count (`session.ts:379`, `const contextTokens = inputTokens`).

Rows written by older versions keep the same meaning for `input`. v1.2.0
subtracted cache only for non-Anthropic providers, because Anthropic and
Bedrock already reported the remainder (`session/index.ts` at `v1.2.0`, lines
689-695). Older rows' `output` may still *include* reasoning for OpenAI-style
providers, since the subtraction is newer. It is stored as reported (rule 4).

Other fields:

- `model` = `modelID`.
- `effort` = `variant`: OpenCode's variants are reasoning-effort names, e.g.
  `high`, `max`, `none` (`packages/opencode/src/provider/transform.ts:790`).
- `cwd` = `path.cwd`, falling back to `session.directory`. `project` = the
  basename of `cwd`.
- `stopReason` = `finish`. `uuid`/`parentUuid` = the message id and `parentID`.
- **Window:** OpenCode knows each model's limit from models.dev, but writes it
  to no message or part. `windowLimit = WindowLimits.knownLimit(for: modelID)`,
  so an unknown model gets nil, never the fallback.
- **Subagents (rule 1):** the `task` tool creates a child session with
  `parent_id` (`packages/opencode/src/tool/task.ts:156-172`). A child's calls
  carry the root session's id as `sessionId` and the child session id as
  `agentId`, and `agent` is the message's `agent`, e.g. `explore`. Nested
  children resolve to the root. The parent's `task` tool part has
  `state.metadata.sessionId` (`task.ts:185-195`), which is emitted as an
  `AgentSpawnInfo`, the exact edge in the agent tree.
- **Compaction:** the compaction call is an assistant message with
  `summary: true`, `mode: "compaction"` (`packages/opencode/src/session/compaction.ts:391-420`).
  - Its own step is a real call over the whole conversation.
  - Once it has finished without error, a `compaction` event is emitted at
    `max(time.completed, its last step + 1 ms)`. That way the cliff lands on the
    next turn, not on the summary call.
  - `detail` = `{auto, overflow}` from the `compaction` part on its parent user
    message.
- **Tools → `ToolCallRow`:**
  - `id = opencode:<partID>`. A tool part is attached to the step whose
    `step-finish` follows it.
  - `kind`: `task` is agent, `skill` is skill, and OpenCode's own tools are
    builtin. Any other name with an underscore is MCP: OpenCode names MCP tools
    `<server>_<tool>` (`packages/opencode/src/mcp/catalog.ts:119`), and
    `mcpServer` is the text before the first `_`. A server whose own name
    contains `_` is cut short.
  - `target` = `filePath` / `command` / `description` / `pattern` / `url` from
    `state.input`.
  - `resultTokens` is a length estimate of `state.output` or `state.error`
    (rule 6). `isError` = `status == "error"`.

## What it does not record

- The context window, as described above.
- Plan or rate limits.
- Hooks, MCP servers or plugins as run events, so there are no context tools.
- Whether a request was served from a long-context tier.
- Per-call wall-clock duration as a field. Tool times exist, the call's do not.
- Tool results that OpenCode later compacted keep only what OpenCode left in
  `output`.
