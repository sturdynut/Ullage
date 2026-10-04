import Foundation

extension Vendor {
    public static let droid = "droid"
}

/// Where Factory's Droid CLI keeps its sessions:
/// `~/.factory/sessions/<cwd-slug>/<uuid>.jsonl`, with a `<uuid>.settings.json`
/// beside each. Droid documents no override for `~/.factory`; `FACTORY_DIR`
/// is the convention CodeBurn uses, honoured here so a relocated tree can be
/// pointed at. See docs/harnesses/droid.md.
public enum DroidPaths {
    public static func homeDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let override = environment["FACTORY_DIR"], !override.isEmpty {
            return [URL(fileURLWithPath: ClaudePaths.expand(override), isDirectory: true)]
        }
        return [ClaudePaths.homeDirectory().appendingPathComponent(".factory", isDirectory: true)]
    }

    public static func sessionsDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        homeDirectories(environment: environment).map { $0.appendingPathComponent("sessions", isDirectory: true) }
    }

    public static func isDroidTranscript(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl") else { return false }
        if path.contains("/.factory/sessions/") { return true }
        return sessionsDirectories().contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }
}

/// Parses Droid's `<uuid>.jsonl` event log.
///
/// Droid writes no per-call token counts: the only usage on disk is the
/// session's running total in `<uuid>.settings.json` (`tokenUsage`), rewritten
/// in place. A total spread across turns would be a guess (rule 3), and a
/// cumulative figure stored as one call would read as a prompt millions of
/// tokens long. So Droid rows are **activity only**, like Cursor: one row per
/// assistant message, with its tools and its own timestamp,
/// `confidence = unmeasured`, zero counters and no window.
///
/// Stateful: `session_start` carries the session id and cwd that later
/// `message` lines do not, so the file is re-read from the top on change.
public final class DroidParser: TranscriptLineParser {
    public static let version = 1

    private var sessionId: String?
    private var cwd: String?
    private var ordinal = 0

    public init() {}

    public func parse(line: Data, context: LineContext) -> ParsedLine? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        let ts = Timestamps.normalize(JSONAccess.string(root, "timestamp")) ?? context.lastTimestamp ?? context.fileModified ?? ""

        switch JSONAccess.string(root, "type") ?? "" {
        case "session_start":
            sessionId = JSONAccess.string(root, "id") ?? sessionId
            cwd = JSONAccess.string(root, "cwd") ?? cwd
            return nil

        case "compaction_state":
            let session = sessionId ?? context.fallbackSessionId
            let id = JSONAccess.string(root, "id") ?? "\(ordinal)"
            return .event(EventRow(
                id: "droid:compaction:\(session):\(id)",
                sessionId: session,
                ts: ts,
                kind: EventKind.compaction.rawValue,
                detail: nil
            ))

        case "message":
            let message = JSONAccess.dict(root, "message")
            guard JSONAccess.string(message, "role") == "assistant" else { return nil }
            return assistant(root: root, message: message, ts: ts, context: context)

        default:
            return nil
        }
    }

    private func assistant(root: [String: Any], message: [String: Any]?, ts: String, context: LineContext) -> ParsedLine {
        let session = sessionId ?? context.fallbackSessionId
        let entryId = JSONAccess.string(root, "id") ?? "#\(ordinal)"
        ordinal += 1
        let dedupeKey = "droid:\(session):\(entryId)"

        var toolCalls: [ToolCallRow] = []
        for (index, item) in (JSONAccess.list(message, "content") ?? []).enumerated() {
            guard let block = item as? [String: Any], JSONAccess.string(block, "type") == "tool_use" else { continue }
            let name = JSONAccess.string(block, "name") ?? "tool"
            let classification = ClaudeCodeParser.classify(toolName: name)
            // Droid's shell tool is `Execute`; its input is `command`, as Bash's is.
            let targetName = name == "Execute" ? "Bash" : name
            toolCalls.append(ToolCallRow(
                id: JSONAccess.string(block, "id") ?? "\(dedupeKey):\(index)",
                callId: dedupeKey,
                sessionId: session,
                ts: ts,
                name: name,
                kind: classification.kind.rawValue,
                mcpServer: classification.server,
                target: ClaudeCodeParser.target(forTool: targetName, input: JSONAccess.dict(block, "input")),
                resultTokens: nil,
                isError: nil,
                parserVersion: DroidParser.version
            ))
        }

        let call = CallRow(
            dedupeKey: dedupeKey,
            ts: ts,
            vendor: Vendor.droid,
            sessionId: session,
            project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            cwd: cwd,
            model: nil,             // only the session's latest, in settings.json
            input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
            contextTokens: 0,
            windowLimit: nil,
            sourceFile: context.sourceFile,
            confidence: Confidence.unmeasured.rawValue,
            parserVersion: DroidParser.version
        )
        return .call(ParsedCall(call: call, toolCalls: toolCalls, claudeVersion: nil))
    }
}

extension Harness {
    public static let droid = Harness(
        id: Vendor.droid, name: "Droid",
        capabilities: .init(
            occupancy: .none, window: .none, cacheSplit: false, model: false, compaction: true,
            notes: [
                "Droid keeps only a running token total per session, not per turn, so its sessions show activity without a context gauge.",
                "Read from Droid's open-source parsers (tokscale, ccusage, CodeBurn); not yet checked against real files.",
            ]
        ),
        roots: { DroidPaths.sessionsDirectories(environment: $0) },
        owns: DroidPaths.isDroidTranscript,
        reading: .lines(tail: false, parser: { DroidParser() })
    )
}
