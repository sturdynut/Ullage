import Foundation

extension Vendor {
    public static let copilotCLI = "copilot-cli"
}

/// Where GitHub Copilot CLI keeps its sessions:
/// `$COPILOT_HOME/session-state/<sessionId>/events.jsonl`, `COPILOT_HOME`
/// defaulting to `~/.copilot` (the CLI's own variable; see
/// docs/harnesses/copilot-cli.md).
public enum CopilotCLIPaths {
    public static func homeDirectories(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        if let override = environment["COPILOT_HOME"], !override.isEmpty {
            return [URL(fileURLWithPath: ClaudePaths.expand(override), isDirectory: true)]
        }
        return [ClaudePaths.homeDirectory().appendingPathComponent(".copilot", isDirectory: true)]
    }

    public static func sessionStateDirectories(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        homeDirectories(environment: environment).map { $0.appendingPathComponent("session-state", isDirectory: true) }
    }

    /// `…/session-state/<id>/events.jsonl` and nothing else: the file name and
    /// its grandparent are both fixed by the CLI.
    public static func isEventLog(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count >= 3, parts[parts.count - 1] == "events.jsonl" else { return false }
        return parts[parts.count - 3] == "session-state"
    }

    /// The session directory's name, which is the session id.
    static func sessionId(fromPath path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return String(parts[parts.count - 2])
    }
}

/// Parses Copilot CLI's `events.jsonl`: one session event per line,
/// `{type, data, id, timestamp, parentId, agentId?, ephemeral?}`.
///
/// Per-call token usage (`assistant.usage`) is ephemeral — sent to clients,
/// never written — so the file holds no prompt size for any call. What it does
/// write is each model response (`assistant.message`) with its model, its
/// real `outputTokens`, and the tools it requested. Rows are therefore activity
/// with measured output: `unmeasured`, no prompt counters, no window, no
/// occupancy (rule 3). The session totals in `session.shutdown.modelMetrics`
/// are deliberately not read: a total across calls is not any call's context
/// (rule 2).
///
/// Stateful: model, cwd and effort arrive on earlier lines, so the file is
/// re-read whole on change (`tail: false`); dedupe keys keep that idempotent.
public final class CopilotCLIParser: TranscriptLineParser {
    public static let version = 1

    private var sessionId: String?
    private var cwd: String?
    private var model: String?
    private var effort: String?
    /// Turn model by `turnId` (`assistant.turn_start.model`), per agent.
    private var turnModels: [String: String] = [:]

    public init() {}

    public func parse(line: Data, context: LineContext) -> ParsedLine? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        // Ephemeral events are not supposed to be on disk; if one is, it is a
        // live-stream artefact and not part of the record.
        if JSONAccess.bool(root, "ephemeral") == true { return nil }
        let data = JSONAccess.dict(root, "data")
        let agentId = JSONAccess.string(root, "agentId")
        let ts = Timestamps.normalize(JSONAccess.string(root, "timestamp")) ?? context.lastTimestamp ?? context.fileModified ?? ""
        let session = sessionId
            ?? CopilotCLIPaths.sessionId(fromPath: context.sourceFile)
            ?? context.fallbackSessionId

        switch JSONAccess.string(root, "type") ?? "" {
        case "session.start", "session.resume":
            if let id = JSONAccess.string(data, "sessionId") { sessionId = id }
            setContext(JSONAccess.dict(data, "context"))
            model = JSONAccess.string(data, "selectedModel") ?? model
            effort = JSONAccess.string(data, "reasoningEffort") ?? effort
            return nil

        case "session.context_changed":
            setContext(data)
            return nil

        case "session.model_change":
            model = JSONAccess.string(data, "newModel") ?? model
            if data?["reasoningEffort"] is NSNull { effort = nil }
            effort = JSONAccess.string(data, "reasoningEffort") ?? effort
            return nil

        case "assistant.turn_start":
            if let turn = JSONAccess.string(data, "turnId"), let m = JSONAccess.string(data, "model") {
                turnModels[(agentId ?? "") + "/" + turn] = m
            }
            return nil

        case "assistant.message":
            return message(data: data, root: root, agentId: agentId, session: session, ts: ts, context: context)

        case "session.compaction_complete":
            guard JSONAccess.bool(data, "success") != false else { return nil }
            // Figures from the CLI's own tokenizer, kept as the marker's
            // detail; the summary text is not stored.
            var detail: [String: Any] = [:]
            for key in ["preCompactionTokens", "postCompactionTokens", "tokenLimit", "trigger", "messagesRemoved"] {
                if let value = data?[key], !(value is NSNull) { detail[key] = value }
            }
            return .event(EventRow(
                id: "copilot-cli:compaction:\(session):\(JSONAccess.string(root, "id") ?? ts)",
                sessionId: session,
                agentId: agentId,
                ts: ts,
                kind: EventKind.compaction.rawValue,
                detail: JSONAccess.jsonString(detail)
            ))

        default:
            return nil
        }
    }

    private func setContext(_ context: [String: Any]?) {
        if let dir = JSONAccess.string(context, "cwd") { cwd = dir }
    }

    private func message(
        data: [String: Any]?, root: [String: Any], agentId: String?,
        session: String, ts: String, context: LineContext
    ) -> ParsedLine? {
        // One model call can be split into several messages (chunks) that
        // share `apiCallId`; they collapse onto one row.
        guard let callKey = JSONAccess.string(data, "apiCallId")
                ?? JSONAccess.string(data, "messageId")
                ?? JSONAccess.string(root, "id") else { return nil }
        let dedupeKey = "copilot-cli:\(session):\(callKey)"
        let turnModel = JSONAccess.string(data, "turnId").flatMap { turnModels[(agentId ?? "") + "/" + $0] }
        let callModel = JSONAccess.string(data, "model") ?? turnModel ?? model

        var tools: [ToolCallRow] = []
        for (index, item) in (JSONAccess.list(data, "toolRequests") ?? []).enumerated() {
            guard let request = item as? [String: Any], let name = JSONAccess.string(request, "name") else { continue }
            let server = JSONAccess.string(request, "mcpServerName")
            tools.append(ToolCallRow(
                id: JSONAccess.string(request, "toolCallId") ?? "\(dedupeKey):\(index)",
                callId: dedupeKey,
                sessionId: session,
                ts: ts,
                name: name,
                kind: (server != nil ? ToolKind.mcp : .builtin).rawValue,
                mcpServer: server,
                target: CopilotTools.target(arguments: request["arguments"]),
                parserVersion: CopilotCLIParser.version
            ))
        }

        let call = CallRow(
            dedupeKey: dedupeKey,
            ts: ts,
            vendor: Vendor.copilotCLI,
            agentId: agentId,
            sessionId: session,
            project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            cwd: cwd,
            model: callModel,
            input: 0, output: JSONAccess.intOrZero(data, "outputTokens"), cacheRead: 0, cacheWrite: 0,
            effort: effort,
            contextTokens: 0,      // no prompt size on disk; no occupancy
            windowLimit: nil,
            sourceFile: context.sourceFile,
            confidence: Confidence.unmeasured.rawValue,
            parserVersion: CopilotCLIParser.version
        )
        return .call(ParsedCall(call: call, toolCalls: tools, claudeVersion: nil))
    }
}

/// Helpers shared by both Copilot readers.
enum CopilotTools {
    /// The file or command a tool call acted on, when its arguments name one.
    /// Copilot's tools use camelCase (`filePath`) as well as snake_case.
    static func target(arguments: Any?) -> String? {
        var input = arguments as? [String: Any]
        if input == nil, let text = arguments as? String, let data = text.data(using: .utf8) {
            input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let input else { return nil }
        for key in ["filePath", "file_path", "path", "command", "query", "url", "pattern"] {
            if let value = JSONAccess.string(input, key) {
                return String(value.prefix(ClaudeCodeParser.targetLimit))
            }
        }
        return nil
    }

    static func isoTimestamp(epochMs: Double?) -> String? {
        guard let ms = epochMs, ms > 0 else { return nil }
        return Timestamps.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

extension Harness {
    public static let copilotCLI = Harness(
        id: Vendor.copilotCLI, name: "Copilot CLI",
        capabilities: .init(
            occupancy: .none, window: .none, cacheSplit: false, subagents: true, compaction: true, effort: true,
            notes: [
                "Copilot CLI keeps per-call token usage out of its session log, so its sessions show activity and output tokens but no context size.",
                "Its session-end totals are not shown: a total across calls is not the size of any one context.",
            ]),
        roots: { CopilotCLIPaths.sessionStateDirectories(environment: $0) },
        owns: CopilotCLIPaths.isEventLog,
        reading: .lines(tail: false, parser: { CopilotCLIParser() })
    )
}
