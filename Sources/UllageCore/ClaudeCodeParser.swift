import Foundation

/// Context a line needs that is not inside the line itself.
public struct LineContext {
    public var sourceFile: String
    /// Session id to use when the line omits one (`type: "summary"` lines do).
    /// The transcript filename stem is the session id.
    public var fallbackSessionId: String
    /// Timestamp of the last line that carried one, for lines that do not.
    public var lastTimestamp: String?

    public init(sourceFile: String, fallbackSessionId: String, lastTimestamp: String? = nil) {
        self.sourceFile = sourceFile
        self.fallbackSessionId = fallbackSessionId
        self.lastTimestamp = lastTimestamp
    }
}

public struct ParsedCall: Equatable {
    public var call: CallRow
    public var toolCalls: [ToolCallRow]
}

/// A `tool_result` block seen on a later `type: "user"` line, to be joined back
/// onto the `tool_call` row it answers.
public struct ToolResultObservation: Equatable {
    public var toolUseId: String
    public var resultTokens: Int
    public var isError: Bool
}

public enum ParsedLine: Equatable {
    case call(ParsedCall)
    case toolResults([ToolResultObservation])
    case event(EventRow)
}

/// Pure function from a transcript line to rows. No I/O, no database, no UI.
///
/// Nothing in here throws: a malformed line is logged by the caller and skipped.
/// One bad line must never stop ingestion (plan §8.2).
public enum ClaudeCodeParser {
    /// Bump on every parser change. Tells you which rows to distrust after an
    /// upstream format shift.
    public static let version = 1

    public static func parse(line: Data, context: LineContext) -> ParsedLine? {
        guard !line.isEmpty else { return nil }
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return nil
        }
        return parse(entry: root, rawLine: line, context: context)
    }

    static func parse(entry: [String: Any], rawLine: Data, context: LineContext) -> ParsedLine? {
        let type = JSONAccess.string(entry, "type") ?? ""

        // Compaction can be flagged on several shapes depending on the Claude
        // Code version, so check it before dispatching on `type`.
        if let event = compactionEvent(entry: entry, rawLine: rawLine, context: context) {
            return .event(event)
        }

        switch type {
        case "assistant":
            guard let parsed = parseAssistant(entry: entry, context: context) else { return nil }
            return .call(parsed)
        case "user":
            let results = parseToolResults(entry: entry)
            return results.isEmpty ? nil : .toolResults(results)
        case "summary":
            let event = EventRow(
                id: eventID(kind: .summary, entry: entry, rawLine: rawLine, context: context),
                sessionId: sessionId(entry: entry, context: context),
                ts: timestamp(entry: entry, context: context),
                kind: EventKind.summary.rawValue,
                detail: JSONAccess.jsonString(entry)
            )
            return .event(event)
        default:
            // Unknown line types get added upstream all the time. Skip silently.
            return nil
        }
    }

    // MARK: - Assistant entries

    static func parseAssistant(entry: [String: Any], context: LineContext) -> ParsedCall? {
        guard let message = JSONAccess.dict(entry, "message") else { return nil }
        // message.id is the dedupe key; without it we cannot insert safely, and
        // double-counting is worse than dropping (forked sessions replay parents).
        guard let dedupeKey = JSONAccess.string(message, "id") else { return nil }

        let usage = JSONAccess.dict(message, "usage")
        let input = JSONAccess.intOrZero(usage, "input_tokens")
        let cacheWrite = JSONAccess.intOrZero(usage, "cache_creation_input_tokens")
        let cacheRead = JSONAccess.intOrZero(usage, "cache_read_input_tokens")
        let output = JSONAccess.intOrZero(usage, "output_tokens")

        // Plan §6 — the one formula that matters. All three are prompt tokens;
        // input_tokens alone is only the uncached remainder and undercounts
        // occupancy by an order of magnitude on a cached session.
        let contextTokens = input + cacheWrite + cacheRead

        let model = JSONAccess.string(message, "model")
        let sessionId = sessionId(entry: entry, context: context)
        let ts = timestamp(entry: entry, context: context)
        let cwd = JSONAccess.string(entry, "cwd")

        let serverToolUse = JSONAccess.dict(usage, "server_tool_use")
        let webSearch = JSONAccess.int(serverToolUse, "web_search_requests")

        let call = CallRow(
            dedupeKey: dedupeKey,
            ts: ts,
            sessionId: sessionId,
            project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            cwd: cwd,
            model: model,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            // Anthropic usage does not break thinking out today; the column is
            // here for vendors that do. Never estimate into it.
            reasoning: JSONAccess.int(usage, "thinking_tokens")
                ?? JSONAccess.int(usage, "reasoning_output_tokens"),
            webSearch: webSearch,
            contextTokens: contextTokens,
            windowLimit: WindowLimits.limit(for: model),
            serviceTier: JSONAccess.string(usage, "service_tier"),
            stopReason: JSONAccess.string(message, "stop_reason"),
            durationMs: JSONAccess.int(entry, "durationMs"),
            isSidechain: JSONAccess.bool(entry, "isSidechain"),
            uuid: JSONAccess.string(entry, "uuid"),
            parentUuid: JSONAccess.string(entry, "parentUuid"),
            sourceFile: context.sourceFile,
            confidence: Confidence.exact.rawValue
        )

        let toolCalls = parseToolUses(
            message: message,
            callId: dedupeKey,
            sessionId: sessionId,
            ts: ts
        )
        return ParsedCall(call: call, toolCalls: toolCalls)
    }

    static func parseToolUses(
        message: [String: Any],
        callId: String,
        sessionId: String,
        ts: String
    ) -> [ToolCallRow] {
        guard let blocks = JSONAccess.list(message, "content") else { return [] }
        var rows: [ToolCallRow] = []
        for block in blocks {
            guard let block = JSONAccess.object(block),
                  JSONAccess.string(block, "type") == "tool_use",
                  let id = JSONAccess.string(block, "id"),
                  let name = JSONAccess.string(block, "name") else { continue }
            let classification = classify(toolName: name)
            rows.append(
                ToolCallRow(
                    id: id,
                    callId: callId,
                    sessionId: sessionId,
                    ts: ts,
                    name: name,
                    kind: classification.kind.rawValue,
                    mcpServer: classification.server,
                    target: target(forTool: name, input: JSONAccess.dict(block, "input"))
                )
            )
        }
        return rows
    }

    /// `mcp__<server>__<tool>` is MCP, `Skill` is a skill, `Task` spawns a
    /// subagent, everything else is builtin.
    public static func classify(toolName: String) -> (kind: ToolKind, server: String?) {
        if toolName.hasPrefix("mcp__") {
            let rest = toolName.dropFirst("mcp__".count)
            if let separator = rest.range(of: "__") {
                let server = String(rest[rest.startIndex..<separator.lowerBound])
                return (.mcp, server.isEmpty ? nil : server)
            }
            return (.mcp, rest.isEmpty ? nil : String(rest))
        }
        switch toolName {
        case "Skill": return (.skill, nil)
        case "Task": return (.agent, nil)
        default: return (.builtin, nil)
        }
    }

    /// Longest string a target is allowed to be. A Bash heredoc can be enormous
    /// and the target column is for identification, not archival.
    static let targetLimit = 1_000

    static func target(forTool name: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        let candidates: [String]
        switch name {
        case "Read", "Edit", "Write", "NotebookEdit":
            candidates = ["file_path", "notebook_path", "path"]
        case "Bash", "BashOutput":
            candidates = ["command", "description"]
        case "Task":
            candidates = ["subagent_type", "description"]
        case "Skill":
            candidates = ["skill", "command"]
        case "Glob", "Grep":
            candidates = ["pattern", "path"]
        case "WebFetch", "WebSearch":
            candidates = ["url", "query"]
        default:
            candidates = ["file_path", "path", "command", "query", "url", "pattern", "name"]
        }
        for key in candidates {
            if let value = JSONAccess.string(input, key) {
                return String(value.prefix(targetLimit))
            }
        }
        return nil
    }

    // MARK: - Tool results

    /// Results land on a *later* `type: "user"` entry, matched by tool_use id.
    /// That cross-line join is the awkward part of the parser, and it is why
    /// tool_call exists in M1 rather than being bolted on later.
    static func parseToolResults(entry: [String: Any]) -> [ToolResultObservation] {
        guard let message = JSONAccess.dict(entry, "message"),
              let blocks = JSONAccess.list(message, "content") else { return [] }
        var results: [ToolResultObservation] = []
        for block in blocks {
            guard let block = JSONAccess.object(block),
                  JSONAccess.string(block, "type") == "tool_result",
                  let id = JSONAccess.string(block, "tool_use_id") else { continue }
            results.append(
                ToolResultObservation(
                    toolUseId: id,
                    resultTokens: estimateTokens(of: block["content"]),
                    isError: JSONAccess.bool(block, "is_error") ?? false
                )
            )
        }
        return results
    }

    /// Length-based estimate, never a real count. A Read of a large file is
    /// where context actually goes and this is the only handle on it without
    /// shipping a tokenizer. Always estimated, hence no `confidence` column.
    public static func estimateTokens(of content: Any?) -> Int {
        let characters = payloadCharacters(content)
        guard characters > 0 else { return 0 }
        return (characters + 3) / 4
    }

    /// Keys that carry a tool result's payload. Counting every string in the
    /// block would also count structural labels (`"type": "text"`), which
    /// inflates small results.
    static let payloadKeys = ["text", "content", "data", "output", "stdout", "stderr", "url"]

    static func payloadCharacters(_ value: Any?, depth: Int = 0) -> Int {
        guard depth < 12 else { return 0 }
        switch value {
        case let s as String:
            return s.count
        case let array as [Any]:
            return array.reduce(0) { $0 + payloadCharacters($1, depth: depth + 1) }
        case let object as [String: Any]:
            return payloadKeys.reduce(0) { total, key in
                total + payloadCharacters(object[key], depth: depth + 1)
            }
        default:
            return 0
        }
    }

    // MARK: - Events

    static func compactionEvent(
        entry: [String: Any],
        rawLine: Data,
        context: LineContext
    ) -> EventRow? {
        let metadata = JSONAccess.dict(entry, "compactMetadata")
        let isCompactSummary = JSONAccess.bool(entry, "isCompactSummary") ?? false
        let subtype = JSONAccess.string(entry, "subtype")
        guard metadata != nil || isCompactSummary || subtype == "compact_boundary" else {
            return nil
        }
        return EventRow(
            id: eventID(kind: .compaction, entry: entry, rawLine: rawLine, context: context),
            sessionId: sessionId(entry: entry, context: context),
            ts: timestamp(entry: entry, context: context),
            kind: EventKind.compaction.rawValue,
            detail: JSONAccess.jsonString(metadata) ?? JSONAccess.jsonString(entry)
        )
    }

    /// Deterministic so re-ingesting a file cannot duplicate events.
    static func eventID(
        kind: EventKind,
        entry: [String: Any],
        rawLine: Data,
        context: LineContext
    ) -> String {
        if let uuid = JSONAccess.string(entry, "uuid") { return "\(kind.rawValue):\(uuid)" }
        if let leaf = JSONAccess.string(entry, "leafUuid") { return "\(kind.rawValue):\(leaf)" }
        return "\(kind.rawValue):\(sessionId(entry: entry, context: context)):\(Hashing.fnv1a(rawLine))"
    }

    static func sessionId(entry: [String: Any], context: LineContext) -> String {
        JSONAccess.string(entry, "sessionId") ?? context.fallbackSessionId
    }

    static func timestamp(entry: [String: Any], context: LineContext) -> String {
        Timestamps.normalize(JSONAccess.string(entry, "timestamp"))
            ?? context.lastTimestamp
            ?? ""
    }
}

enum Hashing {
    /// FNV-1a, for stable synthetic ids. Not security-relevant.
    static func fnv1a(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func fnv1a(_ string: String) -> String { fnv1a(Data(string.utf8)) }
}
