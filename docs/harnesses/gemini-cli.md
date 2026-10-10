# Gemini CLI (`gemini-cli`)

**Verified on disk: no.** No Gemini CLI data exists on the Mac this was written
on (`~/.gemini` holds only `GEMINI.md` and Antigravity's folder). Everything
below is read from the writer's source, google-gemini/gemini-cli at
`fb972b2` (2026-10-02); paths are relative to `packages/core/src/`.

Code: `Sources/UllageCore/Harnesses/GeminiCLI.swift` (`GeminiPaths`,
`GeminiCLIReader`, `Harness.geminiCLI`).

## Where it stores data

| What | Path | Source |
|---|---|---|
| Runtime dir | `~/.gemini`; `$GEMINI_CLI_HOME` replaces `~`; `~/.cache/.gemini` under `SANDBOX=sandbox-exec` | `config/storage.ts:54-108`, `utils/paths.ts:22-28` |
| Project dir | `<runtime>/tmp/<slug>/` (legacy: sha256 of the path) | `config/storage.ts:195-197, 230-234, 310-324` |
| Main session | `<project>/chats/session-<yyyy-mm-ddThh-mm>-<shortId>.jsonl` | `services/chatRecordingService.ts:777-799` |
| Subagent | `<project>/chats/<parentSessionId>/<subagentSessionId>.jsonl` | `services/chatRecordingService.ts:762-790` |
| Legacy session | `<project>/chats/session-….json`, one JSON document; migrated to `….jsonl` on resume (the `.json` stays) | `services/chatRecordingService.ts:708-732, 1566-1600` |
| cwd | `<runtime>/tmp/<slug>/.project_root` (text), or `<runtime>/projects.json` `{"projects":{path: slug}}` | `config/projectRegistry.ts:16-24, 375-400`, `config/storage.ts:289-299` |

Both runtime roots are swept. `owns` claims only `/.gemini/tmp/<slug>/chats/session-*.json[l]`
and `/.gemini/tmp/<slug>/chats/<parent>/<id>.jsonl`.

The registry stores the path through `normalizePath`, which **lower-cases it on
macOS and Windows** (`utils/paths.ts:347-352`), so `cwd` and `project` are
lower-case there.

## Record shape

The `.jsonl` is an append-only log replayed by the CLI's own loader
(`services/chatRecordingService.ts:302-547`). Each line is one of:

- **Metadata** (first line): `{sessionId, projectHash, startTime, lastUpdated, kind: "main"|"subagent", directories?}` (`:810-819`).
- **Message**: `{id, timestamp, type: "user"|"gemini"|"info"|"error"|"warning", content, displayContent?}`; a `gemini` message adds `model`, `tokens`, `toolCalls`, `thoughts` (`services/chatRecordingTypes.ts:44-87`).
- **`{"$set": {...}}`**: metadata update, e.g. `lastUpdated` after every message (`:979-985`); a deprecated form carries a full `messages` checkpoint.
- **`{"$patch": {id?, toolCalls?, updates?, removeIds?, orderIds?}}`**: history sync — tool results filled in, messages removed or reordered (`:1341-1508`).
- **`{"$rewindTo": id}`**: drop that message and everything after it (`:1296-1339`).

`tokens` (`services/chatRecordingTypes.ts:19-26`, filled at `:1087-1116`):

```
{ input: promptTokenCount, output: candidatesTokenCount, cached: cachedContentTokenCount,
  thoughts: thoughtsTokenCount, tool: toolUsePromptTokenCount, total: totalTokenCount }
```

**The trap:** a message is re-appended whole every time it changes. A `gemini`
message is first appended with `tokens: null` (`recordMessage`, `:1029-1060`),
then again with tokens once usage arrives (`recordMessageTokens`, `:1101-1105`),
and again each time tool calls are merged into it (`recordToolCalls`,
`:1118-1180`). The last version of a message id wins.

`toolCalls[]` (`services/chatRecordingTypes.ts:54-67`, built at
`core/geminiChat.ts:1690-1711`): `{id, name, args, result (Part[]), status:
"success"|"error"|"cancelled"|…, timestamp, agentId?, displayName, description, resultDisplay}`.
`agentId` is set when the call ran a subagent, and equals that subagent's
session id (`agents/local-executor.ts:148-149, 330`), i.e. its file stem.

## Mapping

Read as a document (`.document`): the file is replayed on every change, each
message id's final version becomes at most one row, keyed
`gemini-cli:<sessionId>:<messageId>`, so re-reads and the migrated `.json`/`.jsonl`
pair dedupe.

| Field | Counter | Why |
|---|---|---|
| `tokens.input − tokens.cached` | `input` | Gemini API: `promptTokenCount` *includes* `cachedContentTokenCount` |
| `tokens.cached` | `cacheRead` | |
| — | `cacheWrite = 0` | Gemini reports no cache writes |
| `tokens.input` | `contextTokens` | the CLI checks its window against `promptTokenCount` alone (`core/client.ts:705-710`, `core/geminiChat.ts:1640-1645`) |
| `tokens.output` | `output` | `candidatesTokenCount`, which excludes thoughts |
| `tokens.thoughts` | `reasoning` | never added to output |
| `tokens.tool` | not counted | `toolUsePromptTokenCount` (server-side tool prompts, e.g. search grounding) is outside `promptTokenCount` and outside the window the CLI tracks |
| `model` | `model` | |
| `timestamp` | `ts` | |
| — | `windowLimit` | `WindowLimits.knownLimit(model)`; nil until Gemini models are in the table |

- Session: metadata `sessionId`. A subagent file gets `sessionId = <parent dir>`
  and `agentId = <its own sessionId>` (rule 1).
- Tool calls → `ToolCallRow` with id `gemini-cli:<session>:<callId>`;
  `mcp_<server>_<tool>` is MCP (server segment has no `_`,
  `tools/mcp-tool.ts:37-73`), `activate_skill` a skill, `invoke_agent` or any
  call with `agentId` an agent. `target` from `file_path`/`dir_path`/`command`/
  `pattern`/`query`/…; `resultTokens` is a length estimate of the
  `functionResponse.response` (rule 6); `isError = status == "error"`.
- A call carrying `agentId` also emits the spawn link (`AgentSpawnInfo`, type
  from `args.agent_name`).
- **Compaction:** the CLI writes no compression marker. Compression
  (`core/client.ts:1236-1250`) restarts the chat on the same file and syncs the
  new history, which appends a `$patch` with `removeIds`. Ullage emits a
  `compaction` event for any `$patch.removeIds`, placed before the next call
  (and only once one exists). Other history rewrites that drop messages
  (context-manager rendering, `manageHistory`) are marked the same way — the
  context drop is real either way.
- `$rewindTo` and removed messages do **not** delete rows: those requests were
  made and their counts are real.
- `gemini` messages without tokens (synthetic history, failed requests) and
  zero-token usage are skipped.

## What it does not record

- Cache writes.
- The context window (looked up from the model).
- Reasoning effort, plan limits, hooks/MCP configuration per session.
- A compression marker (see above).

## Window limits needed

Not in `WindowLimits.table` yet, so Gemini rows have no occupancy until added.
From `utils/tokenLimits.ts:20-38` (which cites
https://ai.google.dev/gemini-api/docs/models) and `config/models.ts:59-108`:

| Prefix | Window |
|---|---|
| `gemini-2.5` | 1,048,576 |
| `gemini-3` | 1,048,576 |
| `gemma-4` | 256,000 |
