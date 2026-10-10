# GitHub Copilot CLI (`copilot-cli`)

**Verified on disk: no.** There is no `~/.copilot` on this Mac. The CLI is
closed source and the npm package `@github/copilot` (1.0.91) is now only a
loader for a native binary, so the record shape is taken from the published
session-event schema in `github/copilot-sdk` at `ef04633`
(`nodejs/src/generated/session-events.ts`), plus VS Code's Copilot CLI
integration (`microsoft/vscode` at `24a4117`,
`extensions/copilot/src/extension/chatSessions/copilotcli/node/cliHelpers.ts`).

Parser: `Sources/UllageCore/Harnesses/CopilotCLI.swift` (`CopilotCLIParser`, version 1).

## Where it stores data

`$COPILOT_HOME/session-state/<sessionId>/events.jsonl`, `COPILOT_HOME`
defaulting to `~/.copilot` (`cliHelpers.ts:12,28`; SDK README "`baseDirectory`
… Sets `COPILOT_HOME`"). `owns` requires exactly
`…/session-state/<id>/events.jsonl`.

## Record shape

One event per line (`session-events.ts:1540-1566`, same envelope for every type):
`{type, data, id, timestamp (ISO), parentId, agentId?, ephemeral?}`. `agentId`
is set for events from a sub-agent instance. Events marked `ephemeral: true`
in the schema are never persisted.

| Event | Used fields |
|---|---|
| `session.start` / `session.resume` | `data.sessionId`, `data.selectedModel`, `data.reasoningEffort`, `data.context.cwd` (`:1570-1650`) |
| `session.context_changed` | `data.cwd` |
| `session.model_change` | `data.newModel`, `data.reasoningEffort` |
| `assistant.turn_start` | `data.turnId`, `data.model` |
| `assistant.message` | `data.apiCallId` (shared by every chunk of one model call), `data.messageId`, `data.model`, `data.outputTokens` ("actual output token count from the API response"), `data.toolRequests[] {toolCallId, name, arguments, mcpServerName?}` (`:5564-5640, 5892`) |
| `session.compaction_complete` | `data.success`, `preCompactionTokens`, `postCompactionTokens`, `tokenLimit`, `trigger` (`:3476`) |
| `assistant.usage` | **ephemeral** (`:6114-6123`) — per-call input/cache tokens are never written |
| `session.usage_info` | **ephemeral** (`:3280-3289`) — the live context size/limit is never written |
| `session.shutdown` | `data.modelMetrics.<model>.usage {inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens}` — **session totals** (`:2977-3010, 3122`); `currentTokens` at shutdown |

## Field → counter mapping

One row per model call (`copilot-cli:<sessionId>:<apiCallId>`, falling back to
`messageId`); chunks of one call upsert onto the same row, output taking the max.

| Ullage | From |
|---|---|
| `input`, `cache_read`, `cache_write`, `context_tokens` | 0 — not on disk |
| `output` | `assistant.message.outputTokens` (measured) |
| `confidence` | `unmeasured`; `window_limit` nil; no occupancy (rule 3) |
| `model` | message `model`, else its turn's `model`, else the latest `model_change`/`selectedModel` |
| `effort` | `reasoningEffort` from start / model change |
| `agent_id` | envelope `agentId` (rule 1) |
| `cwd`/`project` | `context.cwd` |
| tools | `toolRequests`; `mcpServerName` → `mcp` |
| compaction | `session.compaction_complete` with `success != false`; detail keeps the CLI's own before/after token counts and limit, never the summary text |

`session.shutdown` totals are not read into any row: a total across calls is
not a context size (rule 2), and a call row's prompt counters would make it one.
`session.truncation` and compaction `tokenLimit` name the window but come with
the CLI's own tokenizer counts, not API usage, so no occupancy is derived.

## What it does not record (on disk)

Per-call prompt tokens, cache reads/writes, the context window beside a call,
tool result sizes.
