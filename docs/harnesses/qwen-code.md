# Qwen Code (`qwen-code`)

**Verified on disk: no.** No `~/.qwen` on the Mac this was written on.
Everything below is read from the writer's source, QwenLM/qwen-code at
`9915c7f` (2026-10-04); paths are relative to `packages/core/src/`.

Code: `Sources/UllageCore/Harnesses/QwenCode.swift` (`QwenPaths`,
`QwenCodeParser`, `Harness.qwenCode`).

Qwen Code forked from Gemini CLI, but **its recording format no longer resembles
Gemini CLI's**: it is a Claude-Code-like stream of self-contained records, not
Gemini's message log with `$set`/`$patch`. So it has its own line parser; only
the Gemini `Part` helpers (`GeminiContent`) are shared.

## Where it stores data

| What | Path | Source |
|---|---|---|
| Runtime dir | `$QWEN_RUNTIME_DIR`, else `$QWEN_HOME`, else `~/.qwen` | `config/storage.ts:172-203` |
| Project dir | `<runtime>/projects/<cwd with every non-alphanumeric → '-'>` | `config/storage.ts:615-622`, `utils/paths.ts:388-392` |
| Session | `<project>/chats/<sessionId>.jsonl` | `services/chatRecordingService.ts:1309-1325` |
| Subagent | `<project>/subagents/<sessionId>/agent-<agentId>.jsonl` + `agent-<agentId>.meta.json` | `agents/agent-transcript.ts:64-110` |

`owns` claims only `…/projects/<slug>/chats/<id>.jsonl` and
`…/projects/<slug>/subagents/<session>/agent-<id>.jsonl` under `/.qwen/` or the
environment's runtime dir; never `<id>.runtime.json` or Claude's files.

## Record shape

`ChatRecord` (`services/chatRecordingService.ts:340-528`), one per line, appended:

```
{ uuid, parentUuid, sessionId, timestamp, type: "user"|"assistant"|"tool_result"|"system",
  subtype?, cwd, version, gitBranch?, promptId?, message?: Content,
  usageMetadata?, model?, contextWindowSize?, toolCallResult?, systemPayload?,
  agentId?, agentName?, isSidechain?, forkedFrom?, ... }
```

- `assistant` (`recordAssistantTurn`, `:2580-2618`): one model response;
  `message.parts` holds text and `functionCall {id, name, args}` parts;
  `usageMetadata` is Gemini's `GenerateContentResponseUsageMetadata`;
  `contextWindowSize` comes from the content-generator config
  (`core/llm-chat.ts:6670-6702`), which is the user's override or
  `tokenLimit(model, 'input')` (`models/modelsConfig.ts:478`), whose fallback
  for an unknown model is 200,000 (`core/tokenLimits.ts:13, 410-418`).
- `tool_result` (`recordToolResult`, `:2746-2843`): `message.parts` with
  `functionResponse`, `toolCallResult {callId, status, error?, resultDisplay, …}`.
- `system` / `chat_compression` (`recordChatCompression`, `:2896-2915`):
  `systemPayload {info, compressedHistory}`.
- Subagent lines (`agents/agent-transcript.ts:707-830`) carry the *parent's*
  `sessionId`, plus `agentId`, `agentName`, `isSidechain: true`; a round's
  usage is on an `assistant` record with text only, and each tool call is a
  separate `assistant` record without usage. No `model` on the line; the
  sidecar has it (`AgentMeta.model`, `:175-178`).
- `/branch` copies records verbatim into the new session with `forkedFrom`
  set (`:509-527`).

## Mapping

Tailed (`.lines(tail: true)`): every record carries its own session, cwd,
model and timestamp. Dedupe key `qwen-code:<sessionId>:<uuid>`.

`promptTokenCount` is normalised to the whole prompt for every provider:
Gemini natively, OpenAI's `prompt_tokens` (cached included,
`core/openaiContentGenerator/converter.ts:1425-1478`), the Responses API's
`input_tokens` (`openaiResponsesContentGenerator/responses-converter.ts:495-515`),
and Anthropic's three input counters summed
(`anthropicContentGenerator/usage.ts:30-75`).

| Field | Counter | Why |
|---|---|---|
| `promptTokenCount − cachedContentTokenCount` | `input` | prompt includes cached |
| `cachedContentTokenCount` | `cacheRead` | |
| — | `cacheWrite = 0` | not reported apart; an Anthropic model's cache writes are inside `promptTokenCount`, so they land in `input` |
| `promptTokenCount` | `contextTokens` | |
| `candidatesTokenCount` | `output` | |
| `thoughtsTokenCount` | not stored | for OpenAI-compatible providers without `reasoning_tokens` Qwen Code fills it with a text-length estimate (`converter.ts:1444-1455`), and the record does not say which (rule 3) |
| `contextWindowSize` | `windowLimit` | the window Qwen Code itself used; else `WindowLimits.knownLimit(model)` |
| no `promptTokenCount` (provider sent only a total) | `confidence = unmeasured`, window nil, prompt-side 0 | |

- Tools: `functionCall` parts → `ToolCallRow` id `qwen-code:<session>:<callId>`;
  `mcp__server__tool` names (`tools/mcp-tool.ts:1168`) via
  `ClaudeCodeParser.classify`; `agent` → agent, `skill` → skill. A subagent's
  usage-less tool-call record is attached to its round's call (re-emitted with
  the same dedupe key); a main-thread one rides on the next call.
- `tool_result` → `ToolResultObservation` (length estimate of the
  `functionResponse`, `isError` from `status == "error"` or an `error`).
- `chat_compression` → `compaction` event.
- Subagents: `agentId` from the line (rule 1), `agent` = `agentName`, model
  from the `.meta.json` sidecar. The spawn link to the parent's `agent` call is
  not made: the parent's result does not name the agent id.
- Records with `forkedFrom` are skipped; the originals are counted in the parent.

## What it does not record

- Cache writes; reasoning tokens reliably (see above).
- Effort, plan limits.

## Window limits needed

None for main-thread rows (window is reported). Subagent rows need a lookup
for Qwen's own models; `core/tokenLimits.ts` holds Qwen's table (e.g. the
`qwen3-coder` family). Not proposed here without checking each model's
published window.
