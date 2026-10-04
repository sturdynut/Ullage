# GitHub Copilot in VS Code (`copilot-vscode`)

**Verified on disk: no.** This Mac has VS Code with Copilot Chat installed but
no persisted chat sessions (`workspaceStorage/*/chatSessions/` absent;
`state.vscdb` key `interactive.sessions` is `[]`) and no debug logs. Everything
below comes from source: `microsoft/vscode` at `24a4117` (Copilot Chat now
lives in that repo under `extensions/copilot`; the old
`microsoft/vscode-copilot-chat` repo is archived). Paths below are relative to
that checkout.

Reader: `Sources/UllageCore/Harnesses/CopilotVSCode.swift`
(`CopilotVSCodeReader`, a `TranscriptDocumentReader`, version 1).

## Where it stores data

Per editor user directory — macOS `~/Library/Application Support/<Product>/User`,
Linux `$XDG_CONFIG_HOME|~/.config/<Product>/User`, `<Product>` one of `Code`,
`Code - Insiders`, `VSCodium`. VS Code's own `VSCODE_APPDATA` (replaces the
app-data root) and `VSCODE_PORTABLE` (`<portable>/user-data/User`) are honoured.

| File | Writer |
|---|---|
| `workspaceStorage/<hash>/chatSessions/<sessionId>.json` / `.jsonl` | `src/vs/workbench/contrib/chat/common/model/chatSessionStore.ts:73` |
| `globalStorage/emptyWindowChatSessions/<sessionId>.json` / `.jsonl` | same, `:72` (window with no folder) |
| `workspaceStorage/<hash>/workspace.json` → `{"folder": "file:///…"}` | VS Code workspace storage; used for `cwd` |
| `…/GitHub.copilot-chat/debug-logs/<sessionId>/main.jsonl` (workspace storage, else `globalStorage/github.copilot-chat/`) | `extensions/copilot/src/extension/chat/vscode-node/chatDebugFileLoggerService.ts:24,191-226` |
| `…/debug-logs/<parentSessionId>/<label>-<childSessionId>.jsonl` (subagents) | same, `:295` |

`owns` matches only those shapes, and only under a `Code`/`Code - Insiders`/
`VSCodium`/`user-data` product directory, so a VS Code fork (Cursor keeps
`Cursor/User/workspaceStorage/…`) is never claimed.

## Record shape

### Chat session

`.json` is the whole `ISerializableChatData` (version 3). `.jsonl` is a
mutation log (`objectMutationLog.ts:195-215, 345-400`): `{"kind":0,"v":<state>}`
first, then `{"kind":1,"k":[path],"v":x}` (set), `{"kind":2,"k":[path],"v":[…],"i":n}`
(truncate array to `n`, then push), `{"kind":3,"k":[path]}` (delete). The reader
replays them; an op whose path does not resolve is skipped.

Document: `sessionId`, `creationDate` (epoch ms), `workingDirectory?` (URI),
`requests[]` (`chatModel.ts:2196-2228`, `toJSON` at `:3600-3610`). Each request
is `ISerializableChatRequestData` (`:2066`) with the response's fields spread
into it (`:3593`, response `toJSON` at `:1926-1953`; the `.jsonl` schema writes
the same keys, `chatSessionOperationLog.ts:132-175`):

| Field | Meaning (source) |
|---|---|
| `requestId`, `timestamp` (epoch ms), `responseTimestamp` | |
| `modelId` | picker id, e.g. `copilot/gpt-4.1` |
| `modelConfiguration.reasoningEffort` | effort, when the model has one |
| `promptTokens` | `usage.promptTokens` (`chatModel.ts:1943`). Copilot Chat sets it from the **latest model call's** `prompt_tokens` (`extensions/copilot/src/extension/intents/node/toolCallingLoop.ts:2002`); `IChatUsage` documents it as describing only the most recent call (`chatService.ts:174-176`). OpenAI-style: cached tokens **included** (`platform/networking/common/openai.ts:28-46`). |
| `completionTokens` | running total over the request's calls (`chatModel.ts:1788-1793`) |
| `contextUsage {currentTokens, tokenLimit}` | optional; written only when the provider supplies it (`chatService.ts:187`) |
| `latestModelCall {cacheWriteTokens, reasoningTokens, …}` | optional, latest call only |
| `modelTotals[] {model, inputTokens, cachedTokens, outputTokens}` | **sums over every call of the turn, subagents included** (`chatService.ts:174-184`); agent-host sessions only |
| `result.metadata` | Copilot's `IResultMetadata` (`extensions/copilot/src/extension/prompt/common/conversation.ts:387-443`): `resolvedModel`, `promptTokens?`, `outputTokens?`, `toolCallRounds[].toolCalls[] {id, name, arguments}`, `summary` / `summaries` (compaction) |
| `response[]` | rendered parts; tool calls are `{kind:"toolInvocationSerialized", toolId, toolCallId, source:{type, serverLabel?}}` (`chatService.ts:1196-1215`) |

### Debug log (opt-in)

Setting **`github.copilot.chat.agentDebugLog.fileLogging.enabled`** (default
`false`, tagged experimental; `extensions/copilot/package.json:5234`). One
`IDebugLogEntry` per line (`platform/chat/common/chatDebugFileLoggerService.ts:155-178`):
`{v, rIdx, ts (epoch ms), dur, sid, type, name, spanId, parentSpanId, status, attrs}`.

- `type:"llm_request"` (`chatDebugFileLoggerService.ts:1004-1060`): `attrs.model`,
  `attrs.debugName`, `attrs.inputTokens` = span `gen_ai.usage.input_tokens` =
  `prompt_tokens` (cache included; `extension/prompt/node/chatMLFetcher.ts:424`),
  `attrs.cachedTokens` = `prompt_tokens_details.cached_tokens` (`:430`),
  `attrs.outputTokens`. Cache writes are on the span but not copied into the log.
  `attrs.inputMessages` holds the prompt text; Ullage never reads it.
- `type:"tool_call"` (`:980-1000`): `name` = tool name, `attrs.args`.
- Conversation calls are named `<location>/<intent>` or `tool/runSubagent-…`
  (`extension/prompt/node/defaultIntentRequestHandler.ts:704-706`); helpers
  (`title`, `progressMessages`, `summarizeConversationHistory`, …) have no `/`.

## Field → counter mapping

**Chat session request → one call row** (`copilot-vscode:<sessionId>:<requestId>`):

| Ullage | From |
|---|---|
| `input` | `promptTokens` (else `result.metadata.promptTokens`) — the whole prompt; **not split**, nothing per-call says how much was cached |
| `cache_read`, `cache_write` | 0 (capability `cacheSplit: false`) |
| `context_tokens` | same as `input` |
| `output` | `completionTokens` (else `result.metadata.outputTokens`) — the request's total |
| `window_limit` | `contextUsage.tokenLimit` only. **No lookup**: Copilot serves models with its own prompt limits (smaller than the vendors' for many models), so `WindowLimits` would be the wrong denominator |
| `model` | `result.metadata.resolvedModel`, else `modelId` with the provider prefix removed |
| `effort` | `modelConfiguration.reasoningEffort` |
| `cwd`/`project` | `workingDirectory`, else `workspace.json` `folder` |
| `confidence` | `exact` when a prompt count exists; otherwise `unmeasured`, context 0, no window |
| tools | `toolInvocationSerialized` parts; `source.type == "mcp"` → `mcp` with `serverLabel`; target from the matching `toolCallRounds` call's arguments (`filePath`/`path`/`command`…), ids matched after dropping VS Code's `__vscode-N` suffix |
| compaction | `result.metadata.summary`/`summaries` present → one `compaction` event |

`modelTotals` is never read into a row: it is a sum across calls (rule 2).

**Debug log `llm_request` → one call row per model call** (`copilot-vscode:<sessionId>:<spanId>`):
`input = inputTokens − cachedTokens`, `cache_read = cachedTokens`,
`cache_write = 0`, `context_tokens = inputTokens`, `output = outputTokens`,
`exact`, window nil (the log records the output cap, not the window). Failed
calls and helper calls are skipped. Rows in `<label>-<child>.jsonl` carry
`agent_id = sid` (rule 1). `tool_call` lines attach to the preceding call.

**Dedupe between the two:** when a session's debug log exists and holds a
conversation call, that session's chat file emits no call rows (compaction
events still come from the chat file only).

## What it does not record

- Per-call prompt sizes outside the debug log: one reading per request.
- Cached-token split in the chat file.
- A context window, except `contextUsage` on providers that report it.
- Tool result sizes.

## Open doubts

- If the chat file is ingested before the debug log is first flushed (the
  log flushes every 4 s by default), that request's request-reading row stays
  beside the debug-log rows: one extra point at the same prompt size.
- The debug log's `sid` is Copilot's `chatSessionId`; the reader assumes it
  equals the chat file's `sessionId`. Not verified on disk.
- Copilot Chat also writes `GitHub.copilot-chat/transcripts/<sessionId>.jsonl`
  (`extension/chat/vscode-node/sessionTranscriptService.ts`), content only, no
  usage; not read.
