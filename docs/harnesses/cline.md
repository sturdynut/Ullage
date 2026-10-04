# Cline, Roo Code and Kilo Code (`cline`, `roo-code`, `kilo-code`)

**Verified on disk: no.** The Mac this was written on has `~/.cline/data`
(cache, logs, settings) but no `tasks/` or `sessions/`, and no
`saoudrizwan.claude-dev`, `rooveterinaryinc.roo-cline` or `kilocode.kilo-code`
folder under any editor's `globalStorage`. Everything below comes from the
writers' source, read at:

- `cline/cline` `main` @ 39ff235 (extension 4.1.22, CLI 3.0.68), and tag
  `v3.89.2` (the last classic extension) — paths below marked *v3*.
- `RooCodeInc/Roo-Code` `main` (3.53.0).
- `Kilo-Org/kilocode-legacy` `main` (5.16.2) — Kilo Code before its rewrite.
- `Kilo-Org/kilocode` `main` (7.8.3).

Code: `Sources/UllageCore/Harnesses/ClineFamily.swift` (paths, the shared
`ClineTaskReader`, the three harnesses) and `ClineSessions.swift` (Cline's SDK
format). Tests: `Tests/UllageCoreTests/HarnessClineTests.swift`.

## Two formats

| Format | Written by | Ullage reader |
|---|---|---|
| Classic task: `tasks/<taskId>/ui_messages.json` | Cline ≤ 4.0.1 (4.0.1 shipped the 3.89.2 code), Roo Code (all versions), Kilo Code ≤ 5.x | `ClineTaskReader`, one per vendor (`ClineFlavor`) |
| SDK session: `sessions/<id>/<id>.messages.json` | Cline ≥ 4.1 (VS Code extension and CLI) | `ClineSessionReader` |

Cline 4.0.0 moved the extension onto the Cline SDK; 4.0.1 rolled that back and
4.1 brought it again (cline `CHANGELOG.md`, "4.0.0" and the 4.0.1 rollback
note). The SDK extension no longer writes `ui_messages.json`:
`apps/vscode/src/sdk/sdk-task-control-coordinator.ts:126` — "SDK session
persistence owns conversation history. Do not write classic ui_messages.json".

Kilo Code 7 is a rewrite on an opencode-derived core that keeps sessions in
`$XDG_DATA_HOME/kilo/kilo.db` (`kilocode` `packages/core/src/global.ts:12,22`,
`packages/opencode/src/storage/db.ts:35`). **That database is not read here**;
the `kilo-code` harness covers only tasks left by Kilo Code 5 and earlier.

## Where

Classic tasks live under `<storage>/tasks/<taskId>/`:

- `<storage>` = `<editor>/User/globalStorage/<extension id>` for editors
  `Code`, `Code - Insiders`, `Cursor`, `Windsurf`, `VSCodium`, `Trae`, under
  `~/Library/Application Support` (macOS) or `$XDG_CONFIG_HOME`/`~/.config`
  (Linux). Extension ids: `saoudrizwan.claude-dev` (Cline),
  `rooveterinaryinc.roo-cline` (Roo Code), `kilocode.kilo-code` (Kilo Code).
- Cline outside VS Code (JetBrains/standalone, CLI before the SDK):
  `~/.cline/data/tasks/` — `CLINE_DATA_DIR`, else `$CLINE_DIR/data`
  (`apps/vscode/src/shared/storage/storage-context.ts:93-100`).
- Roo Code / Kilo Code `customStoragePath` setting
  (`roo-cline.customStoragePath`, `kilo-code.customStoragePath`;
  Roo `src/utils/storage.ts:14-46`, `:53-57`) — read from each editor's
  `settings.json`.
- Roo Code's CLI: `~/.vscode-mock/global-storage/tasks/`
  (Roo `packages/vscode-shim/src/context/ExtensionContext.ts:81-85`,
  `apps/cli/src/lib/task-history/index.ts:8`).

Cline SDK sessions: `CLINE_SESSION_DATA_DIR`, else `<cline data>/sessions`
(`sdk/packages/shared/src/storage/paths.ts:179-193`). Per session
`<id>/<id>.messages.json`, `<id>/<id>.json` (manifest), optionally
`<id>.compaction.json`; a subagent's messages are
`<root id>/<agentId>.messages.json` (`sdk/packages/core/src/services/session-artifacts.ts:74-80,136-144`).

`owns` claims only `…/tasks/<id>/ui_messages.json` under one of those
locations (or any folder named for the extension id), and `*.messages.json`
under a Cline sessions folder. Sibling files are read as side information,
never as transcripts.

## Classic record shape

`ui_messages.json` is the whole `ClineMessage[]`, rewritten atomically on
every change (Cline *v3* `core/storage/disk.ts:278-286`; Roo
`src/core/task-persistence/taskMessages.ts:52-56`). Each message
(*v3* `shared/ExtensionMessage.ts:118-135`; Roo
`packages/types/src/message.ts:249-274`):

```
{ ts: <ms epoch, unique per task>, type: "say"|"ask", say?, ask?, text?, partial?,
  modelInfo?: {modelId, providerId, mode},          // Cline only, *v3* core/task/index.ts:839-843
  conversationHistoryDeletedRange?: [start, end],  // Cline only, *v3* core/task/message-state.ts:205
  contextCondense?: {cost, prevContextTokens, newContextTokens, summary}, // Roo/Kilo
  apiProtocol?: "anthropic"|"openai" }             // Roo/Kilo
```

One `say: "api_req_started"` per model request. Its `text` is JSON
(`ClineApiReqInfo`, *v3* `ExtensionMessage.ts:345-360`, Roo
`packages/types/src/vscode-extension-host.ts:780-790`):

```
{ request?, tokensIn, tokensOut, cacheWrites, cacheReads, cost, cancelReason?, streamingFailedMessage?, apiProtocol? }
```

It is first written as a placeholder with no counts (Roo `Task.ts:2527-2531`)
and filled in when the stream ends (Roo `Task.ts:2660-2669`; Cline *v3*
`core/task/utils.ts:33-39`). Placeholders and `partial: true` messages are
skipped; the next rewrite brings the filled-in version.

### Field → counter

| Counter | From |
|---|---|
| `output` | `tokensOut` |
| `cacheRead` | `cacheReads` |
| `cacheWrite` | `cacheWrites` |
| `input` | `tokensIn`, *or* `tokensIn − cacheReads − cacheWrites` — see below |

**What `tokensIn` means differs by vendor and date** (rules 2 and 7):

- **Cline (classic)**: the uncached remainder. Cline's own context figure sums
  all four (*v3* `shared/getApiMetrics.ts:81-89`), and the SDK adapter states
  the convention: "Classic Cline/webview metrics expect tokensIn, cacheReads,
  and cacheWrites to be disjoint buckets" (`apps/vscode/src/sdk/message-translator.ts:98-101`).
  Most providers normalise to that (Anthropic `providers/anthropic.ts:191`,
  OpenRouter `openrouter.ts:196`, OpenAI native `openai-native.ts:77`,
  DeepSeek, Gemini, Cline). Some pass OpenAI `prompt_tokens` (cache included)
  *with* a cached count: `openai` (`openai.ts:172-174`), `litellm`
  (`litellm.ts:379`), `doubao`, `fireworks`, `hicap`, `lmstudio`, `qwen`,
  `xai`, `zai`. For those provider ids (from the message's
  `modelInfo.providerId`, else `task_metadata.json`) the cache is split back
  out. Cline's own gauge double-counts these; Ullage does not.
- **Roo Code ≥ 3.29.5 / Kilo Code ≥ 4.119.0**: the whole prompt for every
  provider — `tokensIn: costResult.totalInputTokens` (Roo `Task.ts:2662`, Kilo
  legacy `Task.ts:2895`), where `totalInputTokens = input + cacheWrite +
  cacheRead` for Anthropic and the provider total for OpenAI
  (Roo `src/shared/cost.ts:76-78,100-113`; Roo's own context figure:
  `packages/core/src/message-utils/consolidateTokenUsage.ts:86-89`). The cache
  is split back out. Changed in RooCodeInc/Roo-Code#8954, merged 2025-10-31,
  released 3.29.5 (2025-11-01); Kilo took it in v4.119.0 (2025-11-12).
- **Roo / Kilo before that**: Anthropic-protocol requests recorded the
  uncached remainder. The record carries no version, so the reader uses:
  `tokensIn` below `cacheReads + cacheWrites` is always the remainder; an
  Anthropic-protocol request dated before the release is the remainder;
  everything else is the total.

`contextTokens = input + cacheRead + cacheWrite`. `confidence = exact`.
Reasoning is not recorded separately.

### Model and window

No harness here writes the context window, so `windowLimit =
WindowLimits.knownLimit(model)` — nil (no gauge) for a model Ullage doesn't
know, including gateway spellings like `anthropic/claude-sonnet-4.5`.

- Cline: `modelInfo.modelId` on the message (recent 3.x); else
  `task_metadata.json` `model_usage[]` — `{ts, model_id, model_provider_id,
  mode}`, appended whenever the model changes (*v3*
  `core/context/context-tracking/ModelContextTracker.ts:10-36`,
  `ContextTrackerTypes.ts`), the latest entry before the next request; else
  the task's `modelId` in `<storage>/state/taskHistory.json`
  (*v3* `core/storage/disk.ts:380`, `shared/HistoryItem.ts:19`). Very old
  tasks have none of these: no model, no gauge.
- Roo / Kilo: the UI messages carry no model. Each request's prompt carries it
  in the environment details, `<model>${modelId}</model>` (Roo
  `src/core/environment/getEnvironmentDetails.ts:227`, Kilo legacy `:295`),
  in a user message of `api_conversation_history.json` stamped with `ts`.
  The model for a request is the last one stamped before the next request.

### cwd

Cline: `cwdOnTaskInitialization` in `state/taskHistory.json`
(*v3* `shared/HistoryItem.ts:14`). Roo: `workspace` in the task's
`history_item.json` (Roo `src/core/task-persistence/TaskHistoryStore.ts:347`,
`packages/types/src/history.ts:20`). Fallback for all three: the first
`# Current Working Directory (<path>) Files` (Cline, *v3*
`core/task/index.ts:3553`) or `# Current Workspace Directory (<path>) Files`
(Roo `getEnvironmentDetails.ts:230`) in the prompt. Multi-root Cline
workspaces print a name, not a path, and leave cwd nil.

### Tools

Each attaches to the preceding `api_req_started` (the request whose response
asked for it); `id = <vendor>:<taskId>:tool:<ts>`.

| Message | ToolCallRow |
|---|---|
| `say`/`ask` `"tool"`, text `{tool, path?}` (*v3* `ExtensionMessage.ts:197-222`, Roo `vscode-extension-host.ts:693-733`) | name = `tool`, target = `path`; `skill`/`useSkill` → skill, `newTask` → agent |
| `say`/`ask` `"command"`, text = the command | `command`, target = command |
| `say`/`ask` `"use_mcp_server"`, text `{serverName, type, toolName, uri?}` | `mcp__<server>__<tool>`, kind mcp |
| `say`/`ask` `"browser_action_launch"` | `browser_action`, target = URL |

No tool result sizes are recorded (`toolResults: false`).

### Compaction

- Roo / Kilo: `say: "condense_context"` with `contextCondense` (Roo
  `Task.ts:1696,3804,4039`) and `say: "sliding_window_truncation"`. Detail
  keeps `prevContextTokens`/`newContextTokens`, never the summary text.
- Cline: a change in `conversationHistoryDeletedRange` between messages — set
  by truncation, `/smol` and auto-condense alike
  (*v3* `core/task/index.ts:2008-2017`, `ContextManager.ts:240-290`).

Automatic condensing and truncation run in a request's setup, *after* its
`api_req_started` was written, so the event is dated 1 ms before that request
and its delta is null. A manual condense (after the request already produced
output) keeps its own time.

## Cline SDK record shape

`<id>.messages.json` is rewritten whole
(`sdk/packages/core/src/session/stores/session-manifest-store.ts:220-238`):

```
{ version: 1, updated_at, agent: "lead"|"subagent"|"teammate", sessionId, taskType?, origin, messages: [...] }
```

(`services/session-data.ts:334-358`; a bare array is also accepted,
`runtime/host/runtime-host-support.ts:62`). Each message
(`sdk/packages/shared/src/llms/messages.ts:140-170`):

```
{ id, role: "user"|"assistant", content: string | blocks, ts,
  modelInfo?: {id, provider, family?},
  metrics?: {inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, cost},
  metadata? }
```

`metrics` on an assistant message is that one model call's usage, a delta of
the running totals (`sdk/packages/agents/src/agent-runtime.ts:436-480,2014-2016`).
`inputTokens` **includes** cache reads and writes — "SDK provider usage reports
inputTokens as the full request size, with cache reads/writes included"
(`apps/vscode/src/sdk/message-translator.ts:98-101`; the SDK's own pricing
subtracts them, `sdk/packages/llms/src/providers/ai-sdk.ts:1166-1169`). So
`input = inputTokens − cacheRead − cacheWrite`.

- One call per assistant message that is not `metadata.displayOnly`
  (error banners, `session-runtime-orchestrator.ts:822-830`). No `metrics` →
  `confidence = unmeasured`, no window.
- Model: `modelInfo.id`, else the manifest's `model`. cwd: manifest `cwd`
  (`session/models/session-manifest.ts:6-28`).
- Tools: `tool_use` blocks `{id, name, input}`. MCP tools are
  `<server>__<tool>` (`extensions/mcp/name-transform.ts:24`); `skills` →
  skill, `spawn_agent` → agent. Target: `path`, first of
  `files`/`paths`/`commands`.
- Compaction: a user message with `metadata.kind == "compaction_summary"`
  (`extensions/context/compaction-shared.ts:42-50,770-790`), dated
  `generatedAt`; detail keeps `tokensBefore`.
- Subagents (rule 1): a file whose stem is not the folder's session id is an
  agent — `sessionId` = the root session, `agentId` = the stem
  (`session/models/session-graph.ts:9-67`).

## Keys

- Session id: the task folder name (classic) or the session folder name (SDK).
- Call: `<vendor>:<taskId>:<ts>` (classic — `ts` is the webview's unique list
  key); `cline:<sessionId>:<agentId|main>:<message id>` (SDK).
- Re-reading a rewritten document upserts the same keys; a request seen first
  as a placeholder is picked up when it is filled in.

## Not recorded

- The context window (any of them).
- The model, in Roo/Kilo UI messages (recovered from the prompt) and in very
  old Cline tasks.
- Reasoning tokens (classic folds them into `tokensOut`; the SDK drops them
  when persisting `metrics`, `runtime/config/agent-message-codec.ts:322-331`).
- Tool result sizes; plan limits; effort; hooks/MCP configuration.
- Roo subtasks are separate tasks (`parentTaskId` in `history_item.json`), so
  each is its own session rather than an agent of its parent.
- Classic Cline Bedrock requests for some models report an input *estimate*
  (*v3* `providers/bedrock.ts:425-435`); the record does not say which, so
  those rows are stored as reported.
- Cline 4.1 also indexes sessions in `~/.cline/data/db/sessions.db`; the
  JSON files hold everything read here, so the database is not opened.
