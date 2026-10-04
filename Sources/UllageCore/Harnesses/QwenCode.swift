import Foundation

extension Vendor {
    public static let qwenCode = "qwen-code"
}

/// Where Qwen Code keeps its session transcripts.
///
/// `<runtime>/projects/<sanitized-cwd>/chats/<sessionId>.jsonl` for a session
/// (qwen-code `services/chatRecordingService.ts:1309-1325`) and
/// `<runtime>/projects/<sanitized-cwd>/subagents/<sessionId>/agent-<agentId>.jsonl`
/// for a subagent, beside an `agent-<agentId>.meta.json` sidecar
/// (`agents/agent-transcript.ts:64-110`). The runtime directory is
/// `$QWEN_RUNTIME_DIR`, else `$QWEN_HOME`, else `~/.qwen`
/// (`config/storage.ts:172-203`).
public enum QwenPaths {
    public static func runtimeDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        for key in ["QWEN_RUNTIME_DIR", "QWEN_HOME"] {
            if let override = environment[key], !override.isEmpty {
                return [URL(fileURLWithPath: ClaudePaths.expand(override), isDirectory: true)]
            }
        }
        return [ClaudePaths.homeDirectory().appendingPathComponent(".qwen", isDirectory: true)]
    }

    public static func projectsDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        runtimeDirectories(environment: environment).map { $0.appendingPathComponent("projects", isDirectory: true) }
    }

    /// True only for `…/projects/<slug>/chats/<id>.jsonl` and
    /// `…/projects/<slug>/subagents/<session>/agent-<id>.jsonl` under `~/.qwen`
    /// or the runtime directory the environment names. Never claims
    /// `<id>.runtime.json`, Claude's `~/.claude/projects`, or anything else.
    public static func isQwenTranscript(_ path: String) -> Bool {
        isQwenTranscript(path, environment: ProcessInfo.processInfo.environment)
    }

    static func isQwenTranscript(_ path: String, environment: [String: String]) -> Bool {
        guard path.hasSuffix(".jsonl") else { return false }
        let bases = ["/.qwen/projects/"] + projectsDirectories(environment: environment).map {
            $0.standardizedFileURL.path.hasSuffix("/") ? $0.standardizedFileURL.path : $0.standardizedFileURL.path + "/"
        }
        guard let base = bases.first(where: { path.contains($0) }), let range = path.range(of: base) else { return false }
        let rest = path[range.upperBound...].split(separator: "/").map(String.init)
        if rest.count == 3 { return rest[1] == "chats" }
        if rest.count == 4 { return rest[1] == "subagents" && rest[3].hasPrefix("agent-") }
        return false
    }
}

/// Parses Qwen Code transcripts.
///
/// Qwen Code began as a Gemini CLI fork but no longer shares its recording
/// format: each line is a self-contained `ChatRecord` (`uuid`, `parentUuid`,
/// `sessionId`, `timestamp`, `cwd`, `type`; qwen-code
/// `services/chatRecordingService.ts:340-528`), so files are tailed. An
/// `assistant` record is one model response and carries `model`,
/// `usageMetadata` (Gemini's `GenerateContentResponseUsageMetadata`) and
/// `contextWindowSize` (`recordAssistantTurn`, :2580-2618).
///
/// `promptTokenCount` is the whole prompt for every provider Qwen Code
/// speaks: Gemini natively, OpenAI's `prompt_tokens` (cached included), and
/// Anthropic's three input counters summed (`anthropicContentGenerator/
/// usage.ts:30-75`). It is split back into an uncached remainder plus
/// `cachedContentTokenCount`. Anthropic cache writes are folded into the
/// prompt and not reported apart, so they land in `input`; `cacheWrite` is 0.
/// `thoughtsTokenCount` is not stored: for an OpenAI-compatible provider that
/// omits `reasoning_tokens`, Qwen Code fills it with a length estimate
/// (`openaiContentGenerator/converter.ts:1444-1455`) and the record does not
/// say which (rule 3).
public final class QwenCodeParser: TranscriptLineParser {
    public static let version = 1

    /// The last call of this file, so a subagent's tool-call record (written
    /// after the round's usage record, `agent-transcript.ts:778-830`) can be
    /// attached to it.
    private var lastCall: ParsedCall?
    /// Tool calls seen before any call of this read; they ride on the next.
    private var pendingTools: [ToolCallRow] = []
    private var sidecarModel: String??

    public init() {}

    public func parse(line: Data, context: LineContext) -> ParsedLine? {
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        // /branch copies every parent record verbatim under the new session
        // id; the original call is already counted in the parent.
        guard record["forkedFrom"] == nil else { return nil }
        let sessionId = JSONAccess.string(record, "sessionId") ?? context.fallbackSessionId
        let isSidechain = JSONAccess.bool(record, "isSidechain") ?? false
        let agentId = isSidechain ? (JSONAccess.string(record, "agentId") ?? Store.agentId(fromTranscriptPath: context.sourceFile)) : nil
        let ts = Timestamps.normalize(JSONAccess.string(record, "timestamp")) ?? context.lastTimestamp ?? context.fileModified ?? ""

        switch JSONAccess.string(record, "type") ?? "" {
        case "assistant":
            return assistant(record, sessionId: sessionId, agentId: agentId, ts: ts, context: context)

        case "tool_result":
            let result = JSONAccess.dict(record, "toolCallResult")
            guard let callId = JSONAccess.string(result, "callId") else { return nil }
            let status = JSONAccess.string(result, "status")
            let failed = status == "error" || (result?["error"].map { !($0 is NSNull) } ?? false)
            let parts = JSONAccess.list(JSONAccess.dict(record, "message"), "parts") ?? (result?["responseParts"] as? [Any])
            return .toolResults([ToolResultObservation(
                toolUseId: "\(Vendor.qwenCode):\(sessionId):\(callId)",
                resultTokens: GeminiContent.resultTokens(parts) ?? 0,
                isError: failed
            )])

        case "system":
            guard JSONAccess.string(record, "subtype") == "chat_compression" else { return nil }
            let uuid = JSONAccess.string(record, "uuid") ?? ts
            return .event(EventRow(
                id: "\(Vendor.qwenCode):compaction:\(sessionId):\(uuid)",
                sessionId: sessionId, agentId: agentId, ts: ts,
                kind: EventKind.compaction.rawValue,
                detail: JSONAccess.jsonString(JSONAccess.dict(JSONAccess.dict(record, "systemPayload"), "info"))
            ))

        default:
            return nil
        }
    }

    private func assistant(_ record: [String: Any], sessionId: String, agentId: String?, ts: String, context: LineContext) -> ParsedLine? {
        guard JSONAccess.string(record, "subtype") != "realtime_message" else { return nil }
        let parts = JSONAccess.list(JSONAccess.dict(record, "message"), "parts") ?? []
        let usage = JSONAccess.dict(record, "usageMetadata")

        guard let usage else {
            // No usage: a subagent's tool-call record, written after its
            // round's usage record, belongs to that call (re-emitting it is
            // idempotent). Otherwise the tools ride on the next call.
            let tools = toolRows(parts, callId: lastCall?.call.dedupeKey ?? "", sessionId: sessionId, ts: ts)
            guard !tools.isEmpty else { return nil }
            if agentId != nil, var last = lastCall, last.call.agentId == agentId {
                last.toolCalls += tools
                lastCall = last
                return .call(last)
            }
            pendingTools += tools
            return nil
        }

        let uuid = JSONAccess.string(record, "uuid") ?? ts
        let dedupeKey = "\(Vendor.qwenCode):\(sessionId):\(uuid)"
        let model = JSONAccess.string(record, "model") ?? (agentId != nil ? subagentModel(context.sourceFile) : nil)
        let output = JSONAccess.intOrZero(usage, "candidatesTokenCount")
        let measured = JSONAccess.int(usage, "promptTokenCount")
        let prompt = measured ?? 0
        let cached = min(JSONAccess.intOrZero(usage, "cachedContentTokenCount"), prompt)
        guard prompt > 0 || output > 0 else { return nil }

        let window: Int? = measured == nil ? nil
            : (JSONAccess.int(record, "contextWindowSize").flatMap { $0 > 0 ? $0 : nil } ?? WindowLimits.knownLimit(for: model))
        let cwd = JSONAccess.string(record, "cwd")
        var tools = pendingTools.map { row -> ToolCallRow in var row = row; row.callId = dedupeKey; return row }
        pendingTools.removeAll()
        tools += toolRows(parts, callId: dedupeKey, sessionId: sessionId, ts: ts)

        let call = CallRow(
            dedupeKey: dedupeKey,
            ts: ts,
            vendor: Vendor.qwenCode,
            agent: agentId != nil ? JSONAccess.string(record, "agentName") : nil,
            agentId: agentId,
            sessionId: sessionId,
            project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            cwd: cwd,
            model: model,
            input: prompt - cached,
            output: output,
            cacheRead: cached,
            cacheWrite: 0,
            reasoning: nil,
            contextTokens: prompt,
            windowLimit: window,
            isSidechain: agentId != nil ? true : nil,
            uuid: JSONAccess.string(record, "uuid"),
            parentUuid: JSONAccess.string(record, "parentUuid"),
            sourceFile: context.sourceFile,
            // A provider that sent only a total leaves the prompt unknown.
            confidence: (measured == nil ? Confidence.unmeasured : Confidence.exact).rawValue,
            parserVersion: QwenCodeParser.version
        )
        let parsed = ParsedCall(call: call, toolCalls: tools, claudeVersion: nil)
        lastCall = parsed
        return .call(parsed)
    }

    private func toolRows(_ parts: [Any], callId: String, sessionId: String, ts: String) -> [ToolCallRow] {
        parts.compactMap { part -> ToolCallRow? in
            guard let call = JSONAccess.dict(part as? [String: Any], "functionCall"),
                  let id = JSONAccess.string(call, "id") else { return nil }
            let name = JSONAccess.string(call, "name") ?? "tool"
            var (kind, server) = ClaudeCodeParser.classify(toolName: name)
            if name == "agent" { kind = .agent }
            if name == "skill" { kind = .skill }
            return ToolCallRow(
                id: "\(Vendor.qwenCode):\(sessionId):\(id)", callId: callId, sessionId: sessionId, ts: ts,
                name: name, kind: kind.rawValue, mcpServer: server,
                target: GeminiContent.target(args: JSONAccess.dict(call, "args")),
                parserVersion: QwenCodeParser.version
            )
        }
    }

    /// A subagent's lines carry no model; its sidecar does (`AgentMeta.model`,
    /// `agent-transcript.ts:175-178`). Read once per file.
    private func subagentModel(_ transcript: String) -> String? {
        if let cached = sidecarModel { return cached }
        let sidecar = URL(fileURLWithPath: transcript).deletingPathExtension().path + ".meta.json"
        let model = FileManager.default.contents(atPath: sidecar)
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            .flatMap { JSONAccess.string($0, "model") }
        sidecarModel = .some(model)
        return model
    }
}

extension Harness {
    public static let qwenCode = Harness(
        id: Vendor.qwenCode, name: "Qwen Code",
        capabilities: .init(
            occupancy: .everyCall, window: .reported, cacheSplit: true, subagents: true, toolResults: true,
            compaction: true,
            notes: [
                "Qwen Code reports cached input but not cache writes; an Anthropic model's cache writes count as input.",
                "The window is the one Qwen Code assumed for the model, which is 200k for a model it does not know.",
                "Reasoning tokens are not shown: Qwen Code estimates them for some providers and does not say which.",
            ]
        ),
        roots: { QwenPaths.projectsDirectories(environment: $0) },
        owns: QwenPaths.isQwenTranscript,
        reading: .lines(tail: true, parser: { QwenCodeParser() })
    )
}
