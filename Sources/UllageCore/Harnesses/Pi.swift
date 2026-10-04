import Foundation

extension Vendor {
    public static let pi = "pi"
}

/// Where Pi (badlogic/pi-mono `coding-agent`) keeps sessions:
/// `~/.pi/agent/sessions/--<cwd-slug>--/<timestamp>_<session-id>.jsonl`.
/// Pi's own overrides, in its precedence order: `PI_CODING_AGENT_SESSION_DIR`
/// (the sessions folder itself), then `PI_CODING_AGENT_DIR` (the agent folder,
/// `sessions/` under it). `--session-dir` and the `sessionDir` setting are
/// per-invocation and per-cwd, so they are not followed.
public enum PiPaths {
    public static func sessionsDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let override = environment["PI_CODING_AGENT_SESSION_DIR"], !override.isEmpty {
            return [URL(fileURLWithPath: ClaudePaths.expand(override), isDirectory: true)]
        }
        let agent: URL
        if let override = environment["PI_CODING_AGENT_DIR"], !override.isEmpty {
            agent = URL(fileURLWithPath: ClaudePaths.expand(override), isDirectory: true)
        } else {
            agent = ClaudePaths.homeDirectory().appendingPathComponent(".pi/agent", isDirectory: true)
        }
        return [agent.appendingPathComponent("sessions", isDirectory: true)]
    }

    public static func isPiTranscript(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl") else { return false }
        if path.contains("/.pi/agent/sessions/") { return true }
        return sessionsDirectories().contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }
}

/// Parses Pi session files.
///
/// Every assistant `message` entry is one model request and carries pi-ai's
/// `Usage`: `input` is the uncached remainder for every provider (pi-ai splits
/// cached tokens out of OpenAI/Google/Mistral prompts itself), so the four
/// counters map one to one and sum to the prompt. `reasoning` is a subset of
/// `output` and is stored beside it, as Codex's is.
///
/// Sessions are trees (`id`/`parentId`): a branch is more entries in the same
/// file, each a real request, so every assistant entry is a row keyed by its
/// own entry id. A `/fork` or branched session copies earlier entries into a
/// new file verbatim; those copies predate the new header and are skipped while
/// the parent file still exists, so a request is counted once, in the session
/// that made it.
///
/// Stateful: the header line holds the session id and cwd, so the file is
/// re-read from the top on change.
public final class PiParser: TranscriptLineParser {
    public static let version = 1

    private var sessionId: String?
    private var cwd: String?
    private var headerTime: String?
    private var isCopyOfExistingParent = false
    private var effort: String?
    private var ordinal = 0

    public init() {}

    public func parse(line: Data, context: LineContext) -> ParsedLine? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        let type = JSONAccess.string(root, "type") ?? ""
        let ts = Timestamps.normalize(JSONAccess.string(root, "timestamp")) ?? context.lastTimestamp ?? context.fileModified ?? ""

        if type == "session" {
            sessionId = JSONAccess.string(root, "id") ?? sessionId
            cwd = JSONAccess.string(root, "cwd") ?? cwd
            headerTime = Timestamps.normalize(JSONAccess.string(root, "timestamp"))
            if let parent = JSONAccess.string(root, "parentSession") {
                isCopyOfExistingParent = FileManager.default.fileExists(atPath: parent)
            }
            return nil
        }
        ordinal += 1

        // Copied from the parent session by /fork or a branched session.
        if isCopyOfExistingParent, let headerTime, !ts.isEmpty, ts < headerTime { return nil }

        let session = sessionId ?? Self.sessionId(fromFile: context.fallbackSessionId)
        switch type {
        case "thinking_level_change":
            effort = JSONAccess.string(root, "thinkingLevel") ?? effort
            return nil

        case "compaction":
            let id = JSONAccess.string(root, "id") ?? "#\(ordinal)"
            let detail = JSONAccess.int(root, "tokensBefore").flatMap { JSONAccess.jsonString(["tokensBefore": $0]) }
            return .event(EventRow(
                id: "pi:compaction:\(session):\(id)", sessionId: session, ts: ts,
                kind: EventKind.compaction.rawValue, detail: detail
            ))

        case "message":
            let message = JSONAccess.dict(root, "message")
            switch JSONAccess.string(message, "role") ?? "" {
            case "assistant":
                return assistant(root: root, message: message, ts: ts, session: session, context: context)
            case "toolResult":
                guard let id = JSONAccess.string(message, "toolCallId") else { return nil }
                return .toolResults([ToolResultObservation(
                    toolUseId: id,
                    resultTokens: ClaudeCodeParser.estimateTokens(of: message?["content"]),
                    isError: JSONAccess.bool(message, "isError") ?? false
                )])
            default:
                return nil
            }

        default:
            // `usage` entries (cache warming) and summary generation are
            // requests outside the conversation's window; not rows here.
            return nil
        }
    }

    /// `<timestamp>_<session-id>` → `<session-id>`, for a file read without its header.
    static func sessionId(fromFile stem: String) -> String {
        guard let underscore = stem.firstIndex(of: "_") else { return stem }
        let rest = stem[stem.index(after: underscore)...]
        return rest.isEmpty ? stem : String(rest)
    }

    private func assistant(root: [String: Any], message: [String: Any]?, ts: String, session: String, context: LineContext) -> ParsedLine? {
        let usage = JSONAccess.dict(message, "usage")
        let input = max(0, JSONAccess.intOrZero(usage, "input"))
        let output = max(0, JSONAccess.intOrZero(usage, "output"))
        let cacheRead = max(0, JSONAccess.intOrZero(usage, "cacheRead"))
        let cacheWrite = max(0, JSONAccess.intOrZero(usage, "cacheWrite"))
        // An aborted or failed request with no usage measured nothing.
        guard input + output + cacheRead + cacheWrite > 0 else { return nil }

        let entryId = JSONAccess.string(root, "id")
            ?? JSONAccess.string(message, "timestamp").map { "t\($0)" }   // v1 entries had no id
            ?? "#\(ordinal)"
        let dedupeKey = "pi:\(session):\(entryId)"
        let model = JSONAccess.string(message, "model")

        var toolCalls: [ToolCallRow] = []
        for (index, item) in (JSONAccess.list(message, "content") ?? []).enumerated() {
            guard let block = item as? [String: Any], JSONAccess.string(block, "type") == "toolCall" else { continue }
            let name = JSONAccess.string(block, "name") ?? "tool"
            let classification = ClaudeCodeParser.classify(toolName: name)
            toolCalls.append(ToolCallRow(
                id: JSONAccess.string(block, "id") ?? "\(dedupeKey):\(index)",
                callId: dedupeKey,
                sessionId: session,
                ts: ts,
                name: name,
                kind: classification.kind.rawValue,
                mcpServer: classification.server,
                target: ClaudeCodeParser.target(forTool: name, input: JSONAccess.dict(block, "arguments")),
                parserVersion: PiParser.version
            ))
        }

        let call = CallRow(
            dedupeKey: dedupeKey,
            ts: ts,
            vendor: Vendor.pi,
            sessionId: session,
            project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            cwd: cwd,
            model: model,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            reasoning: JSONAccess.int(usage, "reasoning"),
            effort: JSONAccess.string(message, "thinkingLevel") ?? effort,
            contextTokens: input + cacheRead + cacheWrite,
            // Pi writes no window; only a model Ullage knows gets one.
            windowLimit: WindowLimits.knownLimit(for: model),
            stopReason: JSONAccess.string(message, "stopReason"),
            uuid: JSONAccess.string(root, "id"),
            parentUuid: JSONAccess.string(root, "parentId"),
            sourceFile: context.sourceFile,
            confidence: Confidence.exact.rawValue,
            parserVersion: PiParser.version
        )
        return .call(ParsedCall(call: call, toolCalls: toolCalls, claudeVersion: nil))
    }
}

extension Harness {
    public static let pi = Harness(
        id: Vendor.pi, name: "Pi",
        capabilities: .init(
            occupancy: .everyCall, window: .lookup, cacheSplit: true, toolResults: true, compaction: true, effort: true,
            notes: [
                "Pi runs many providers; a model Ullage has no window for is shown without a gauge.",
                "A branch of a Pi session continues from an earlier turn, so its context can drop without a compaction.",
            ]
        ),
        roots: { PiPaths.sessionsDirectories(environment: $0) },
        owns: PiPaths.isPiTranscript,
        reading: .lines(tail: false, parser: { PiParser() })
    )
}
