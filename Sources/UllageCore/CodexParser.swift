import Foundation

/// Parses OpenAI Codex CLI session rollouts into the same rows as the Claude
/// Code parser, so the store, the CLI and the UI need no vendor branches.
///
/// Stateful on purpose: a Codex `token_count` line carries the usage and the
/// window but neither the model nor the working directory, which arrive earlier
/// on `session_meta` and `turn_context`. A fresh instance therefore has to see
/// a file from the top — `TranscriptFormat.codex.reingestsWholeFile` guarantees
/// that.
///
/// Token semantics differ from Claude. Codex's `input_tokens` is the whole
/// prompt, cached tokens included, where Claude's `input_tokens` is only the
/// uncached remainder. The prompt is split back into the four counters so they
/// keep their meaning and still sum to the prompt size (`context_tokens`). All
/// counts are real, so rows are `exact`; only tool-result sizes are estimates.
public final class CodexParser: TranscriptLineParser {
    public static let version = 1

    private var sourceFile = ""
    private var sessionId: String?
    private var cwd: String?
    private var model: String?
    private var lastWindow: Int?

    /// `function_call` / `*_output` buffered until the next usage line, then
    /// attached to that call: their tokens ride in the next request's prompt,
    /// the same place Claude Code counts a `tool_result`.
    private struct PendingTool {
        var id: String
        var name: String
        var ts: String
        var resultTokens: Int?
        var isError: Bool?
    }
    private var pendingTools: [PendingTool] = []

    public init() {}

    public func parse(line: Data, context: LineContext) -> ParsedLine? {
        sourceFile = context.sourceFile
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return nil
        }
        let ts = JSONAccess.string(root, "timestamp") ?? context.lastTimestamp ?? ""
        let payload = JSONAccess.dict(root, "payload")

        switch JSONAccess.string(root, "type") ?? "" {
        case "session_meta":
            sessionId = JSONAccess.string(payload, "session_id") ?? JSONAccess.string(payload, "id") ?? sessionId
            cwd = JSONAccess.string(payload, "cwd") ?? cwd
            return nil

        case "turn_context":
            model = JSONAccess.string(payload, "model") ?? model
            cwd = JSONAccess.string(payload, "cwd") ?? cwd
            return nil

        case "response_item":
            return parseResponseItem(payload: payload, ts: ts)

        case "event_msg":
            return parseEvent(payload: payload, ts: ts, root: root, fallbackSession: context.fallbackSessionId)

        case "compacted":
            // A top-level line, not an event_msg. Context falls off a cliff
            // here; the marker keeps the drop from reading as a bug.
            let session = sessionId ?? context.fallbackSessionId
            return .event(EventRow(
                id: "codex:compaction:\(session):\(JSONAccess.int(root, "ordinal") ?? 0)",
                sessionId: session,
                ts: ts,
                kind: EventKind.compaction.rawValue,
                detail: nil
            ))

        default:
            return nil
        }
    }

    // MARK: - Tools (buffered)

    private func parseResponseItem(payload: [String: Any]?, ts: String) -> ParsedLine? {
        switch JSONAccess.string(payload, "type") ?? "" {
        case "function_call", "custom_tool_call", "local_shell_call", "web_search_call":
            guard let id = JSONAccess.string(payload, "call_id") ?? JSONAccess.string(payload, "id") else { return nil }
            let name = JSONAccess.string(payload, "name")
                ?? JSONAccess.string(payload, "type")   // web_search_call has no name
                ?? "tool"
            pendingTools.append(PendingTool(id: id, name: name, ts: ts))
            return nil

        case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
            guard let id = JSONAccess.string(payload, "call_id") ?? JSONAccess.string(payload, "id") else { return nil }
            let output = payload?["output"]
            if let idx = pendingTools.lastIndex(where: { $0.id == id }) {
                pendingTools[idx].resultTokens = ClaudeCodeParser.estimateTokens(of: output)
                pendingTools[idx].isError = errorFlag(output)
            }
            return nil

        default:
            return nil
        }
    }

    private func errorFlag(_ output: Any?) -> Bool? {
        let dict = (output as? [String: Any]) ?? JSONAccess.dict(["o": output as Any], "o")
        guard let dict else { return nil }
        if let success = JSONAccess.bool(dict, "success") { return !success }
        if let exit = JSONAccess.int(dict, "exit_code") { return exit != 0 }
        return nil
    }

    // MARK: - Events and usage

    private func parseEvent(payload: [String: Any]?, ts: String, root: [String: Any], fallbackSession: String) -> ParsedLine? {
        let session = sessionId ?? fallbackSession
        let ordinal = JSONAccess.int(root, "ordinal") ?? 0
        switch JSONAccess.string(payload, "type") ?? "" {
        case "task_started":
            if let window = JSONAccess.int(payload, "model_context_window") { lastWindow = window }
            return nil

        case "token_count":
            return makeCall(info: JSONAccess.dict(payload, "info"), ts: ts, ordinal: ordinal, session: session)

        default:
            return nil
        }
    }

    private func makeCall(info: [String: Any]?, ts: String, ordinal: Int, session: String) -> ParsedLine? {
        guard let last = JSONAccess.dict(info, "last_token_usage") else { return nil }

        let totalInput = JSONAccess.intOrZero(last, "input_tokens")
        let cached = JSONAccess.intOrZero(last, "cached_input_tokens")
        let cacheWrite = JSONAccess.intOrZero(last, "cache_write_input_tokens")
        let output = JSONAccess.intOrZero(last, "output_tokens")
        // A usage line with no prompt and no output is Codex bookkeeping between
        // turns, not a model request.
        guard totalInput > 0 || output > 0 else { return nil }

        let uncached = max(0, totalInput - cached - cacheWrite)
        let contextTokens = uncached + cached + cacheWrite   // == totalInput
        let window = JSONAccess.int(info, "model_context_window") ?? lastWindow
        if let window { lastWindow = window }

        let dedupeKey = "codex:\(session):\(ordinal)"
        let toolCalls = pendingTools.map { tool in
            ToolCallRow(
                id: tool.id,
                callId: dedupeKey,
                sessionId: session,
                ts: tool.ts,
                name: tool.name,
                kind: kind(for: tool.name).rawValue,
                mcpServer: nil,
                target: nil,
                resultTokens: tool.resultTokens,
                isError: tool.isError,
                parserVersion: CodexParser.version
            )
        }
        pendingTools.removeAll(keepingCapacity: true)

        let call = CallRow(
            dedupeKey: dedupeKey,
            ts: ts,
            vendor: Vendor.codex,
            sessionId: session,
            project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            cwd: cwd,
            model: model,
            input: uncached,
            output: output,
            cacheRead: cached,
            cacheWrite: cacheWrite,
            reasoning: JSONAccess.int(last, "reasoning_output_tokens"),
            webSearch: nil,
            contextTokens: contextTokens,
            windowLimit: window,
            sourceFile: sourceFile,
            confidence: Confidence.exact.rawValue,
            parserVersion: CodexParser.version
        )
        return .call(ParsedCall(call: call, toolCalls: toolCalls, claudeVersion: nil))
    }

    private func kind(for name: String) -> ToolKind {
        name.contains("__") ? .mcp : .builtin
    }
}
